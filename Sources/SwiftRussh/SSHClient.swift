import Foundation
import RusshFFI

public enum SSHAuthMethod: Sendable {
  case none
  case password(String)
  case privateKey(SSHPrivateKey)

  public static func privateKey(
    contentsOf file: URL, passphrase: String? = nil
  ) throws(SSHError) -> Self {
    .privateKey(try SSHPrivateKey(contentsOf: file, passphrase: passphrase))
  }

  public static func privateKey(
    contents: String, passphrase: String? = nil
  ) throws(SSHError) -> Self {
    .privateKey(try SSHPrivateKey(contents: contents, passphrase: passphrase))
  }
}

public struct SSHClient: Sendable {
  public struct CommandResult: Sendable {
    public let status: SSHExitStatus
    public let stdout: Data
    public let stderr: Data
  }

  private let session: Session

  private init(host: String, port: UInt16, timeout: UInt) async throws(SSHError) {
    session = try await bridge {
      try await RusshFFI.connect(host: host, port: port, timeoutSecs: UInt64(timeout))
    }
  }

  private func verifyHostKey(_ expected: SSHHostKey) async throws(SSHError) {
    let actual = try await hostKey
    guard actual == expected else {
      throw .hostKeyMismatch(
        expected: expected, actual: actual,
        message: "Server host key \(actual.fingerprint) does not match \(expected.fingerprint)"
      )
    }
  }

  private func authenticate(user: String, auth: SSHAuthMethod) async throws(SSHError) {
    switch auth {
    case .none:
      try await bridge { try await session.authenticateNone(user: user) }

    case .password(let password):
      try await bridge { try await session.authenticatePassword(user: user, password: password) }

    case .privateKey(let key):
      try await bridge { try await session.authenticateKey(user: user, key: key.key) }
    }
  }

  public static func connect(
    host: String, port: UInt16 = 22, timeout: UInt = 60,
    user: String, auth: SSHAuthMethod = .none, expectedHostKey: SSHHostKey? = nil
  ) async throws(SSHError) -> SSHClient {
    let client = try await SSHClient(host: host, port: port, timeout: timeout)
    do {
      if let expectedHostKey {
        try await client.verifyHostKey(expectedHostKey)
      }
      try await client.authenticate(user: user, auth: auth)
      return client
    } catch {
      await client.close()
      throw error
    }
  }

  public static func hostKey(
    host: String, port: UInt16 = 22, timeout: UInt = 60
  ) async throws(SSHError) -> SSHHostKey {
    let client = try await SSHClient(host: host, port: port, timeout: timeout)
    do {
      let hostKey = try await client.hostKey
      await client.close()
      return hostKey
    } catch {
      await client.close()
      throw error
    }
  }

  @discardableResult
  public static func withAuthenticatedClient<T: Sendable>(
    host: String, port: UInt16 = 22, timeout: UInt = 60,
    user: String, auth: SSHAuthMethod = .none, expectedHostKey: SSHHostKey? = nil,
    perform body: @Sendable (SSHClient) async throws -> T
  ) async throws -> T {
    let client = try await connect(
      host: host, port: port, timeout: timeout, user: user, auth: auth,
      expectedHostKey: expectedHostKey
    )
    do {
      let result = try await body(client)
      await client.close()
      return result
    } catch {
      await client.close()
      throw error
    }
  }

  public var hostKey: SSHHostKey {
    get async throws(SSHError) {
      SSHHostKey(try bridge { try session.hostKey() })
    }
  }

  public var isConnected: Bool {
    get async {
      await session.isConnected()
    }
  }

  public func sftp() async throws(SSHError) -> SFTPClient {
    SFTPClient(try await bridge { try await session.sftp() })
  }

  @discardableResult
  public func withSftp<T: Sendable>(
    perform body: @Sendable (SFTPClient) async throws -> T
  ) async throws -> T {
    let sftp = try await sftp()
    do {
      let result = try await body(sftp)
      await sftp.close()
      return result
    } catch {
      await sftp.close()
      throw error
    }
  }

  public func close() async {
    await session.close()
  }

  @discardableResult
  public func execute(_ command: String) async throws -> CommandResult {
    try await execute(command) { channel in
      try await CommandResult(
        status: channel.exitStatus(),
        stdout: channel.read(from: .stdout),
        stderr: channel.read(from: .stderr)
      )
    }
  }

  public func execute<T: Sendable>(
    _ command: String,
    perform body: @Sendable (SSHSessionChannel) async throws -> T
  ) async throws -> T {
    let channel = try await openChannel()
    do {
      try await channel.execute(command: command)
      let result = try await body(channel)
      await channel.close()
      return result
    } catch {
      await channel.close()
      throw error
    }
  }

  private func openChannel() async throws(SSHError) -> SSHSessionChannel {
    SSHSessionChannel(try await bridge { try await session.openChannel() })
  }
}
