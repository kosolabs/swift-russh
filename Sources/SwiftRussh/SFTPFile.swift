import Foundation
import RusshFFI

public class SFTPReader: AsyncSequence {
  private let file: SFTPFile
  private let offset: UInt64
  private let length: UInt64
  private let bufferSize: UInt64

  init(file: SFTPFile, offset: UInt64, length: UInt64, bufferSize: UInt64) {
    self.file = file
    self.offset = offset
    self.length = length
    self.bufferSize = bufferSize
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(file: file, offset: offset, length: length, bufferSize: bufferSize)
  }

  public class Iterator: AsyncIteratorProtocol {
    static let QueueSize: Int = 16

    private let file: SFTPFile
    private let offset: UInt64
    private let length: UInt64
    private let bufferSize: UInt64

    private var requested: UInt64 = 0
    private var queue: [SFTPAioReadContext] = []

    init(file: SFTPFile, offset: UInt64, length: UInt64, bufferSize: UInt64) {
      self.file = file
      self.offset = offset
      self.length = length
      self.bufferSize = bufferSize
    }

    public func next() async throws -> Data? {
      try Task.checkCancellation()

      while queue.count < Iterator.QueueSize && requested < length {
        let size = Swift.min(bufferSize, length - requested)
        queue.append(try file.beginRead(at: offset + requested, length: Int(size)))
        requested += size
      }

      if queue.isEmpty {
        return nil
      }

      let data = try await queue.removeFirst().read()
      return data.isEmpty ? nil : data
    }
  }
}

public class SFTPWriter {
  static let QueueSize: Int = 16

  private let file: SFTPFile
  private var offset: UInt64 = 0
  private var queue: [SFTPAioWriteContext] = []

  init(file: SFTPFile) {
    self.file = file
  }

  public func write(contentsOf data: Data) async throws {
    var remaining = data[...]
    while !remaining.isEmpty {
      if queue.count == Self.QueueSize {
        try await queue.removeFirst().flush()
      }
      let aio = try file.beginWrite(at: offset, data: remaining)
      offset += UInt64(aio.length)
      remaining = remaining.dropFirst(aio.length)
      queue.append(aio)
    }
  }

  public func flush() async throws {
    while !queue.isEmpty {
      try await queue.removeFirst().flush()
    }
  }
}

public struct SFTPFile: Sendable {
  public enum AccessMode: Sendable {
    case readOnly
    case writeOnly
    case readWrite
  }

  public struct OpenOptions: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let create = OpenOptions(rawValue: 1 << 0)
    public static let truncate = OpenOptions(rawValue: 1 << 1)
    public static let append = OpenOptions(rawValue: 1 << 2)
    public static let exclusiveCreate = OpenOptions(rawValue: 1 << 3)
  }

  private let file: File
  private let limits: SFTPLimits

  init(_ file: File, limits: SFTPLimits) {
    self.file = file
    self.limits = limits
  }

  public func close() async {
    await file.close()
  }

  public func attributes() async throws -> SFTPAttributes {
    SFTPAttributes(try await bridge { try await file.stat() })
  }

  public func read(
    _ range: some RangeExpression<UInt64> = 0...,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) async throws -> Data {
    let range = range.relative(to: 0..<UInt64.max)
    let length = range.upperBound - range.lowerBound
    let bufferSize = limits.readLength(for: bufferSize)
    var result = Data()
    while UInt64(result.count) < length {
      let bytesToRead = UInt32(min(bufferSize, length - UInt64(result.count)))
      let position = range.lowerBound + UInt64(result.count)
      let data = try await bridge { try await file.read(offset: position, length: bytesToRead) }
      guard !data.isEmpty else { break }
      result.append(data)
    }
    return result
  }

  public func write(
    contentsOf data: Data, at offset: UInt64,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) async throws {
    let bufferSize = Int(limits.writeLength(for: bufferSize))
    var written = 0
    while written < data.count {
      let chunk = Data(data.dropFirst(written).prefix(bufferSize))
      let position = offset + UInt64(written)
      try await bridge { try await file.write(offset: position, data: chunk) }
      written += chunk.count
    }
  }

  public func stream(
    _ range: some RangeExpression<UInt64> = 0...,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) -> SFTPReader {
    let range = range.relative(to: 0..<UInt64.max)
    let bufferSize = limits.readLength(for: bufferSize)
    return SFTPReader(
      file: self, offset: range.lowerBound, length: range.upperBound - range.lowerBound,
      bufferSize: bufferSize)
  }

  public func withAsyncWriter(
    perform body: (SFTPWriter) async throws -> Void
  ) async throws {
    let writer = SFTPWriter(file: self)
    try await body(writer)
    try await writer.flush()
  }

  public func download(
    to localURL: URL, bufferSize: UInt64 = SFTPLimits.defaultBufferSize,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws {
    let bufferSize = limits.readLength(for: bufferSize)
    try Data().write(to: localURL)
    let fp = try FileHandle(forWritingTo: localURL)
    defer { try? fp.close() }

    var count: UInt64 = 0
    for try await data in stream(bufferSize: bufferSize) {
      try fp.write(contentsOf: data)
      count += UInt64(data.count)
      progress?(count)
    }
  }

  public func upload(
    from localURL: URL, bufferSize: UInt64 = SFTPLimits.defaultBufferSize,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws {
    let bufferSize = Int(limits.writeLength(for: bufferSize))
    let fp = try FileHandle(forReadingFrom: localURL)
    defer { try? fp.close() }

    var count: UInt64 = 0
    try await withAsyncWriter { writer in
      while let data = try fp.read(upToCount: bufferSize) {
        try Task.checkCancellation()
        try await writer.write(contentsOf: data)
        count += UInt64(data.count)
        progress?(count)
      }
    }
  }

  func beginRead(at offset: UInt64, length: Int) throws(SSHError) -> SFTPAioReadContext {
    SFTPAioReadContext(try bridge { try file.beginRead(offset: offset, length: UInt32(length)) })
  }

  func beginWrite(at offset: UInt64, data: Data) throws(SSHError) -> SFTPAioWriteContext {
    let chunk = data.prefix(Int(limits.writeLength(for: UInt64(data.count))))
    return SFTPAioWriteContext(
      try bridge { try file.beginWrite(offset: offset, data: Data(chunk)) })
  }
}

extension SFTPFile.AccessMode {
  func openMode(_ options: SFTPFile.OpenOptions) -> OpenMode {
    OpenMode(
      read: self != .writeOnly,
      write: self != .readOnly,
      append: options.contains(.append),
      create: options.contains(.create),
      truncate: options.contains(.truncate),
      exclusive: options.contains(.exclusiveCreate)
    )
  }
}
