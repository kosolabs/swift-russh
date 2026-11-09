import Foundation
import RusshFFI

public enum SSHAuthMethod: Sendable {
  case none
  case password(String)
  case privateKey(SSHPrivateKey)

  public static func privateKey(
    contentsOf file: URL, passphrase: String? = nil
  ) throws -> Self {
    .privateKey(try SSHPrivateKey(contentsOf: file, passphrase: passphrase))
  }

  public static func privateKey(
    contents: String, passphrase: String? = nil
  ) throws -> Self {
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
  public let hostKey: SSHHostKey

  private init(host: String, port: UInt16, timeout: Duration) async throws(SSHError) {
    let session = try await bridge {
      try await RusshFFI.connect(host: host, port: port, timeoutSecs: timeout.secondsRoundedUp)
    }
    do {
      hostKey = SSHHostKey(try bridge { try session.hostKey() })
    } catch {
      await session.close()
      throw error
    }
    self.session = session
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
    host: String, port: UInt16 = 22, user: String, auth: SSHAuthMethod = .none,
    hostKey validateHostKey: SSHHostKeyValidator, timeout: Duration = .seconds(60)
  ) async throws -> SSHClient {
    let client = try await SSHClient(host: host, port: port, timeout: timeout)
    do {
      try await validateHostKey(client.hostKey)
      try await client.authenticate(user: user, auth: auth)
      return client
    } catch {
      await client.close()
      throw error
    }
  }

  public static func hostKey(
    host: String, port: UInt16 = 22, timeout: Duration = .seconds(60)
  ) async throws -> SSHHostKey {
    let client = try await SSHClient(host: host, port: port, timeout: timeout)
    await client.close()
    return client.hostKey
  }

  @discardableResult
  public static func withAuthenticatedClient<T: Sendable>(
    host: String, port: UInt16 = 22, user: String, auth: SSHAuthMethod = .none,
    hostKey validateHostKey: SSHHostKeyValidator, timeout: Duration = .seconds(60),
    perform body: @Sendable (SSHClient) async throws -> T
  ) async throws -> T {
    let client = try await connect(
      host: host, port: port, user: user, auth: auth, hostKey: validateHostKey,
      timeout: timeout
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

  public var isConnected: Bool {
    get async {
      await session.isConnected()
    }
  }

  public func sftp() async throws -> SFTPClient {
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
        stdout: channel.stdout.collect(),
        stderr: channel.stderr.collect()
      )
    }
  }

  public func execute<T: Sendable>(
    _ command: String,
    perform body: @Sendable (SSHChannel) async throws -> T
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

  private func openChannel() async throws(SSHError) -> SSHChannel {
    SSHChannel(try await bridge { try await session.openChannel() })
  }
}

extension Duration {
  var secondsRoundedUp: UInt64 {
    let (seconds, attoseconds) = components
    guard seconds >= 0 else { return 0 }
    return UInt64(seconds) + (attoseconds > 0 ? 1 : 0)
  }
}
