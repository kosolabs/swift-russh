import Foundation
import RusshFFI

public struct SSHChannelData: Sendable, AsyncSequence {
  private let channel: SSHSessionChannel
  private let stream: StreamType
  private let length: Int

  init(channel: SSHSessionChannel, stream: StreamType, length: Int) {
    self.channel = channel
    self.stream = stream
    self.length = length
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(channel: channel, stream: stream, length: length)
  }

  public class Iterator: AsyncIteratorProtocol {
    private let channel: SSHSessionChannel
    private let stream: StreamType
    private let length: Int

    init(channel: SSHSessionChannel, stream: StreamType, length: Int) {
      self.channel = channel
      self.stream = stream
      self.length = length
    }

    public func next() async throws -> Data? {
      try Task.checkCancellation()
      return try await channel.read(length: length, stream: stream)
    }
  }
}

public struct SSHSessionChannel: Sendable {
  private let channel: ExecChannel

  init(_ channel: ExecChannel) {
    self.channel = channel
  }

  public func close() async {
    await channel.close()
  }

  public func execute(command: String) async throws(SSHError) {
    try await bridge { try await channel.exec(command: command) }
  }

  public func exitStatus() async throws(SSHError) -> SSHExitStatus {
    SSHExitStatus(try await bridge { try await channel.exitStatus() })
  }

  func read(length: Int, stream: StreamType) async throws(SSHError) -> Data? {
    let data = try await bridge {
      try await channel.read(stream: stream.kind, maxLength: UInt32(length))
    }
    return data.isEmpty ? nil : data
  }

  public func read(from: StreamType) async throws -> Data {
    var output = Data()
    for try await data in stream(from: from) {
      output.append(data)
    }
    return output
  }

  public func stream(from: StreamType, length: Int = 1248) -> SSHChannelData {
    return SSHChannelData(channel: self, stream: from, length: length)
  }
}
