import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import SwiftRussh

private var host: String {
  let env = ProcessInfo.processInfo.environment
  return env["SWIFT_LIBSSH_TEST_HOST"] ?? "localhost"
}

private var port: UInt16 {
  let env = ProcessInfo.processInfo.environment
  if let portString = env["SWIFT_LIBSSH_TEST_PORT"], let port = UInt16(portString) {
    return port
  }
  return 2248
}

private var user: String {
  let env = ProcessInfo.processInfo.environment
  return env["SWIFT_LIBSSH_TEST_USER"] ?? NSUserName()
}

private var password: String? {
  let env = ProcessInfo.processInfo.environment
  return env["SWIFT_LIBSSH_TEST_PASSWORD"]
}

private let passwordComment: Comment =
  "Set SWIFT_LIBSSH_TEST_PASSWORD to the login password of the account running the test server."

private var privateKey: URL {
  let env = ProcessInfo.processInfo.environment
  return URL(fileURLWithPath: env["SWIFT_LIBSSH_TEST_PRIVATE_KEY_PATH"] ?? "Tests/Data/id_ed25519")
}

private var publicKey: URL {
  let env = ProcessInfo.processInfo.environment
  return URL(
    fileURLWithPath: env["SWIFT_LIBSSH_TEST_PUBLIC_KEY_PATH"] ?? "Tests/Data/id_ed25519.pub"
  )
}

private var encryptedPrivateKey: URL {
  let env = ProcessInfo.processInfo.environment
  return URL(
    fileURLWithPath: env["SWIFT_LIBSSH_TEST_ENCRYPTED_PRIVATE_KEY_PATH"]
      ?? "Tests/Data/id_ed25519_encrypted"
  )
}

private let encryptedPassphrase = "hunter2"

private var serverHostKey: SSHHostKey {
  get throws {
    let env = ProcessInfo.processInfo.environment
    let path =
      env["SWIFT_LIBSSH_TEST_HOST_KEY_PATH"]
      ?? "/tmp/ssh-test-server-\(user)/host_key_ed25519.pub"
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    return try #require(SSHHostKey(contents.trimmingCharacters(in: .whitespacesAndNewlines)))
  }
}

func client() async throws -> SSHClient {
  return try await SSHClient.connect(
    host: host, port: port, user: user, auth: .privateKey(contentsOf: privateKey),
    hostKey: .expecting(serverHostKey))
}

@discardableResult
func withAuthenticatedClient<T: Sendable>(
  perform body: @Sendable (SSHClient) async throws -> T
) async throws -> T {
  let client = try await client()
  do {
    let result = try await body(client)
    await client.close()
    return result
  } catch {
    await client.close()
    throw error
  }
}

struct SSHConnectTests {
  @Test(.enabled(if: password != nil, passwordComment))
  func passwordAuthenticationSucceeds() async throws {
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .password(#require(password)),
      hostKey: .expecting(serverHostKey)
    ) { ssh in
      let proc = try await ssh.execute("whoami")
      let actual = try proc.stdout
        .decoded(as: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let expected = user
      #expect(actual == expected)
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func privateKeyFileAuthenticationSucceeds() async throws {
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(contentsOf: privateKey),
      hostKey: .expecting(serverHostKey)
    ) { ssh in

      let proc = try await ssh.execute("whoami")
      let actual = try proc.stdout
        .decoded(as: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let expected = user
      #expect(actual == expected)
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func base64PrivateKeyAuthenticationSucceeds() async throws {
    let privateKey = try String(contentsOf: privateKey, encoding: .utf8)
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(contents: privateKey),
      hostKey: .expecting(serverHostKey)
    ) { ssh in

      let proc = try await ssh.execute("whoami")
      let actual = try proc.stdout
        .decoded(as: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let expected = user
      #expect(actual == expected)
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func importedPrivateKeyAuthenticationSucceeds() async throws {
    let key = try SSHPrivateKey(contentsOf: privateKey)
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(key),
      hostKey: .expecting(serverHostKey)
    ) { ssh in
      let proc = try await ssh.execute("whoami")
      let actual = try proc.stdout
        .decoded(as: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let expected = user
      #expect(actual == expected)
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func importedPrivateKeyIsReusableAcrossConnections() async throws {
    let key = try SSHPrivateKey(contentsOf: privateKey)
    for _ in 0..<3 {
      try await SSHClient.withConnection(
        host: host, port: port, user: user, auth: .privateKey(key),
        hostKey: .expecting(serverHostKey)
      ) { ssh in
        let proc = try await ssh.execute("true")
        #expect(proc.status == .exited(code: 0))
      }
    }
  }

  @Test func encryptedPrivateKeyAuthenticationSucceeds() async throws {
    try await SSHClient.withConnection(
      host: host, port: port, user: user,
      auth: .privateKey(contentsOf: encryptedPrivateKey, passphrase: encryptedPassphrase),
      hostKey: .expecting(serverHostKey)
    ) { ssh in
      let proc = try await ssh.execute("whoami")
      let actual = try proc.stdout
        .decoded(as: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

      let expected = user
      #expect(actual == expected)
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func noPasswordThrowsAuthenticationFailed() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user, hostKey: .expecting(serverHostKey))
    } throws: { error in
      if case .authenticationFailed? = error as? SSHError { true } else { false }
    }
  }

  @Test func badPasswordThrowsAuthenticationFailed() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user, auth: .password("bad"),
        hostKey: .expecting(serverHostKey))
    } throws: { error in
      if case .authenticationFailed? = error as? SSHError { true } else { false }
    }
  }

  @Test func missingPrivateKeyThrowsUnreadable() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user,
        auth: .privateKey(contentsOf: URL(filePath: "/tmp/missing_pk")),
        hostKey: .expecting(serverHostKey))
    } throws: { error in
      (error as? SSHError)?.privateKeyFailure == .unreadable
    }
  }

  @Test func invalidPrivateKeyThrowsInvalid() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user, auth: .privateKey(contentsOf: publicKey),
        hostKey: .expecting(serverHostKey))
    } throws: { error in
      (error as? SSHError)?.privateKeyFailure == .invalid
    }
  }

  @Test func invalidKeyContentsThrowsInvalid() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user, auth: .privateKey(contents: ""),
        hostKey: .expecting(serverHostKey))
    } throws: { error in
      (error as? SSHError)?.privateKeyFailure == .invalid
    }
  }

  @Test func encryptedPrivateKeyWithoutPassphraseThrowsPassphraseRequired() async throws {
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user,
        auth: .privateKey(contentsOf: encryptedPrivateKey),
        hostKey: .expecting(serverHostKey))
    } throws: { error in
      (error as? SSHError)?.privateKeyFailure == .passphraseRequired
    }
  }

  @Test func hostKeyIsServerHostKey() async throws {
    let expected = try serverHostKey
    try await withAuthenticatedClient { ssh in
      #expect(ssh.hostKey == expected)
    }
  }

  @Test func hostKeyFetchesServerHostKeyWithoutAuthenticating() async throws {
    let hostKey = try await SSHClient.hostKey(host: host, port: port)
    #expect(hostKey == (try serverHostKey))
  }

  @Test func closingReleasesTheSocket() async throws {
    let before = try openDescriptorCount()
    for _ in 0..<25 {
      _ = try await SSHClient.hostKey(host: host, port: port)
      let ssh = try await client()
      await ssh.close()
    }

    #expect(try openDescriptorCount() - before < 25)
  }

  @Test func hostKeyForInvalidHostThrowsConnectionFailed() async throws {
    await #expect {
      try await SSHClient.hostKey(host: "invalid")
    } throws: { error in
      (error as? SSHError)?.connectionFailure == .unknownHost
    }
  }

  @Test func connectTriesTheNextAddressWhenOneRefuses() async throws {
    // localhost resolves to ::1 before 127.0.0.1, and only 127.0.0.1 listens.
    let listener = try IPv4LoopbackListener()
    let port = listener.port
    let connecting = Task {
      try await SSHClient.hostKey(host: "localhost", port: port, timeout: .seconds(10))
    }
    let connected = await listener.receivesConnection(within: .seconds(10))
    _ = await connecting.result

    #expect(connected)
  }

  @Test func matchingExpectedHostKeySucceeds() async throws {
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(contentsOf: privateKey),
      hostKey: .expecting(serverHostKey)
    ) { ssh in
      let proc = try await ssh.execute("true")
      #expect(proc.status == .exited(code: 0))
    }
  }

  @Test func mismatchedExpectedHostKeyThrowsBeforeAuthenticating() async throws {
    let actual = try serverHostKey
    let expected = try #require(
      SSHHostKey(String(contentsOf: publicKey, encoding: .utf8))
    )
    await #expect {
      try await SSHClient.connect(
        host: host, port: port, user: user, auth: .password("wrong"),
        hostKey: .expecting(expected)
      )
    } throws: { error in
      guard case .hostKeyMismatch(expected, actual, let message)? = error as? SSHError else {
        return false
      }
      return message
        == "Server host key \(actual.fingerprint) does not match \(expected.fingerprint)"
    }
  }

  @Test func hostKeyValidatorReceivesServerHostKey() async throws {
    let received = Mutex<SSHHostKey?>(nil)
    try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(contentsOf: privateKey),
      hostKey: SSHHostKeyValidator { key in received.withLock { $0 = key } }
    ) { _ in }
    let expected = try serverHostKey
    #expect(received.withLock { $0 } == expected)
  }

  @Test func hostKeyValidatorErrorIsThrownBeforeAuthenticating() async throws {
    struct Untrusted: Error {}
    await #expect(throws: Untrusted.self) {
      try await SSHClient.connect(
        host: host, port: port, user: user, auth: .password("wrong"),
        hostKey: SSHHostKeyValidator { _ in throw Untrusted() })
    }
  }

  @Test func acceptingAnyHostKeyConnects() async throws {
    let hostKey = try await SSHClient.withConnection(
      host: host, port: port, user: user, auth: .privateKey(contentsOf: privateKey),
      hostKey: .acceptingAny
    ) { ssh in ssh.hostKey }
    #expect(hostKey == (try serverHostKey))
  }

  @Test(arguments: [
    (Duration.seconds(5), UInt64(5)),
    (.milliseconds(1500), 2),
    (.nanoseconds(1), 1),
    (.zero, 0),
    (.seconds(-3), 0),
  ])
  func timeoutRoundsUpToWholeSeconds(_ timeout: Duration, _ seconds: UInt64) {
    #expect(timeout.secondsRoundedUp == seconds)
  }

  @Test func invalidHostThrowsConnectionFailed() async throws {
    await #expect {
      try await SSHClient.connect(host: "invalid", user: user, hostKey: .acceptingAny)
    } throws: { error in
      (error as? SSHError)?.connectionFailure == .unknownHost
    }
  }

  @Test func invalidPortThrowsConnectionFailed() async throws {
    await #expect {
      try await SSHClient.connect(host: host, port: 2200, user: user, hostKey: .acceptingAny)
    } throws: { error in
      (error as? SSHError)?.connectionFailure == .refused
    }
  }

  @Test func timeoutThrowsConnectionFailed() async throws {
    await #expect {
      try await SSHClient.connect(
        host: "192.0.2.1", user: user, hostKey: .acceptingAny, timeout: .seconds(1))
    } throws: { error in
      (error as? SSHError)?.connectionFailure == .timedOut
    }
  }
}

private func openDescriptorCount() throws -> Int {
  try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private final class IPv4LoopbackListener: Sendable {
  let fd: Int32
  let port: UInt16

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard rc else {
      Darwin.close(fd)
      throw POSIXError(.init(rawValue: errno)!)
    }
    self.fd = fd
    port = UInt16(bigEndian: addr.sin_port)
  }

  deinit {
    Darwin.close(fd)
  }

  /// Accepts and closes one connection. Waits on a Dispatch thread, so the
  /// blocking poll can't starve the cooperative thread pool that the
  /// connecting client needs.
  func receivesConnection(within timeout: Duration) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: self.acceptAndClose(timeout: timeout))
      }
    }
  }

  private func acceptAndClose(timeout: Duration) -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let milliseconds = Int32(timeout.components.seconds * 1000)
    guard poll(&pfd, 1, milliseconds) == 1 else { return false }
    let connection = Darwin.accept(fd, nil, nil)
    guard connection >= 0 else { return false }
    Darwin.close(connection)
    return true
  }
}
