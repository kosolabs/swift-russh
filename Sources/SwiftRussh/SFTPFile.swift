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

    private var count: UInt64 = 0
    private var queue: [SFTPAioReadContext] = []

    init(file: SFTPFile, offset: UInt64, length: UInt64, bufferSize: UInt64) {
      self.file = file
      self.offset = offset
      self.length = length
      self.bufferSize = bufferSize
    }

    public func next() async throws(SSHError) -> Data? {
      if Task.isCancelled {
        return nil
      }

      if count == 0 {
        try await file.seek(offset: offset)
      }

      while queue.count < Iterator.QueueSize && count < length {
        let size = Swift.min(bufferSize, length - count)
        guard let aio = try await file.beginRead(length: Int(size)) else {
          if !queue.isEmpty { break }
          await Task.yield()
          continue
        }
        count += size
        queue.append(aio)
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
  private var queue: [SFTPAioWriteContext] = []

  init(file: SFTPFile) {
    self.file = file
  }

  public func write(data: Data) async throws(SSHError) {
    var remaining = data[...]
    while !remaining.isEmpty {
      guard queue.count < Self.QueueSize,
        let aio = try await file.beginWrite(data: remaining)
      else {
        if queue.isEmpty {
          await Task.yield()
        } else {
          try await queue.removeFirst().flush()
        }
        continue
      }
      remaining = remaining.dropFirst(aio.length)
      queue.append(aio)
    }
  }

  public func flush() async throws(SSHError) {
    while !queue.isEmpty {
      try await queue.removeFirst().flush()
    }
  }
}

public struct SFTPFile: Sendable {
  private let file: File
  private let limits: SFTPLimits

  init(_ file: File, limits: SFTPLimits) {
    self.file = file
    self.limits = limits
  }

  public func close() async {
    await file.close()
  }

  public func attributes() async throws(SSHError) -> SFTPAttributes {
    SFTPAttributes(try await bridge { try await file.stat() })
  }

  func seek(offset: UInt64) async throws(SSHError) {
    try bridge { try file.seek(offset: offset) }
  }

  public func read(
    range: Range<UInt64>,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) async throws(SSHError) -> Data {
    try await read(
      offset: range.lowerBound, length: range.upperBound - range.lowerBound,
      bufferSize: bufferSize
    )
  }

  public func read(
    offset: UInt64 = 0, length: UInt64 = UInt64.max,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) async throws(SSHError) -> Data {
    let bufferSize = limits.readLength(for: bufferSize)
    try await seek(offset: offset)
    var result = Data()
    while result.count < length {
      let bytesToRead = UInt32(min(bufferSize, length - UInt64(result.count)))
      let data = try await bridge { try await file.read(length: bytesToRead) }
      guard !data.isEmpty else { break }
      result.append(data)
    }
    return result
  }

  public func write(
    data: Data, bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) async throws(SSHError) {
    let bufferSize = Int(limits.writeLength(for: bufferSize))
    for curr in stride(from: 0, to: data.count, by: bufferSize) {
      let next = min(data.count, curr + bufferSize)
      let buffer = data.subdata(in: curr..<next)
      let bytesWritten = try await bridge { try await file.write(data: buffer) }
      if Int(bytesWritten) != buffer.count {
        throw SSHError.invalidState(
          message:
            "Failed to write all data to file: \(bytesWritten) of \(buffer.count) bytes written")
      }
    }
  }

  func beginRead(length: Int) async throws(SSHError) -> SFTPAioReadContext? {
    SFTPAioReadContext(try bridge { try file.beginRead(length: UInt32(length)) })
  }

  public func stream(
    range: Range<UInt64>,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) -> SFTPReader {
    let bufferSize = limits.readLength(for: bufferSize)
    return SFTPReader(
      file: self,
      offset: range.lowerBound, length: range.upperBound - range.lowerBound,
      bufferSize: bufferSize
    )
  }

  public func stream(
    offset: UInt64 = 0, length: UInt64 = UInt64.max,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize
  ) -> SFTPReader {
    let bufferSize = limits.readLength(for: bufferSize)
    return SFTPReader(file: self, offset: offset, length: length, bufferSize: bufferSize)
  }

  func beginWrite(data: Data) async throws(SSHError) -> SFTPAioWriteContext? {
    let chunk = data.prefix(Int(limits.writeLength(for: UInt64(data.count))))
    return SFTPAioWriteContext(try bridge { try file.beginWrite(data: Data(chunk)) })
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
    if !FileManager.default.createFile(atPath: localURL.path, contents: nil) {
      throw SSHError.localFileError(message: "Failed to create local file at \(localURL)")
    }

    guard let fp = try? FileHandle(forWritingTo: localURL) else {
      throw SSHError.localFileError(message: "Failed to open local file for writing at \(localURL)")
    }
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
    guard let fp = try? FileHandle(forReadingFrom: localURL) else {
      throw SSHError.localFileError(message: "Failed to open local file for reading at \(localURL)")
    }
    defer { try? fp.close() }

    var count: UInt64 = 0
    try await withAsyncWriter { writer in
      while let data = try fp.read(upToCount: bufferSize) {
        try await writer.write(data: data)
        count += UInt64(data.count)
        progress?(count)
      }
    }
  }
}
