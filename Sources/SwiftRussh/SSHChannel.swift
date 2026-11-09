import Foundation
import RusshFFI

public struct SSHChannel: Sendable {
  public struct Output: AsyncSequence, Sendable {
    fileprivate let channel: ExecChannel
    fileprivate let kind: StreamKind

    public func makeAsyncIterator() -> Iterator {
      Iterator(channel: channel, kind: kind)
    }

    public struct Iterator: AsyncIteratorProtocol {
      fileprivate let channel: ExecChannel
      fileprivate let kind: StreamKind

      public func next() async throws -> Data? {
        try Task.checkCancellation()
        let data = try await bridge {
          try await channel.read(stream: kind, maxLength: SSHChannel.chunkSize)
        }
        return data.isEmpty ? nil : data
      }
    }
  }

  private static let chunkSize: UInt32 = 32_768

  private let channel: ExecChannel

  init(_ channel: ExecChannel) {
    self.channel = channel
  }

  public var stdout: Output {
    Output(channel: channel, kind: .stdout)
  }

  public var stderr: Output {
    Output(channel: channel, kind: .stderr)
  }

  public func exitStatus() async throws -> SSHExitStatus {
    SSHExitStatus(try await bridge { try await channel.exitStatus() })
  }

  public func close() async {
    await channel.close()
  }

  func execute(command: String) async throws(SSHError) {
    try await bridge { try await channel.exec(command: command) }
  }
}

extension SSHChannel.Output {
  func collect() async throws -> Data {
    var output = Data()
    for try await chunk in self {
      output.append(chunk)
    }
    return output
  }
}
