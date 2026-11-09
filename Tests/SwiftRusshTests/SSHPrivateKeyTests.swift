import Foundation
import Testing

@testable import SwiftRussh

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

private func privateKeyError(
  _ failure: SSHError.PrivateKeyFailure, message: String
) -> (any Error) -> Bool {
  { error in
    guard case .privateKey(failure, let actual)? = error as? SSHError else { return false }
    return actual == message
  }
}

private func unreadable(file: URL) -> (any Error) -> Bool {
  privateKeyError(.unreadable, message: "Failed to read private key from file \(file.path)")
}

private func passphraseRequired(file: URL) -> (any Error) -> Bool {
  privateKeyError(
    .passphraseRequired,
    message: "Private key from file \(file.path) is encrypted and requires a passphrase")
}

private func invalid(source: String) -> (any Error) -> Bool {
  privateKeyError(.invalid, message: "Failed to import private key from \(source)")
}

private func invalid(file: URL) -> (any Error) -> Bool {
  invalid(source: "file \(file.path)")
}

struct SSHPrivateKeyTests {
  @Test func importsKeyFromFile() throws {
    let key = try SSHPrivateKey(contentsOf: privateKey)
    #expect(key.keyType == .ed25519)
  }

  @Test func importsKeyFromContents() throws {
    let contents = try String(contentsOf: privateKey, encoding: .utf8)
    let key = try SSHPrivateKey(contents: contents)
    #expect(key.keyType == .ed25519)
  }

  @Test func importsEncryptedKeyWithPassphrase() throws {
    let key = try SSHPrivateKey(contentsOf: encryptedPrivateKey, passphrase: encryptedPassphrase)
    #expect(key.keyType == .ed25519)
  }

  @Test func encryptedKeyWithoutPassphraseThrowsPassphraseRequired() throws {
    #expect(performing: {
      try SSHPrivateKey(contentsOf: encryptedPrivateKey)
    }, throws: passphraseRequired(file: encryptedPrivateKey))
  }

  @Test func encryptedKeyWithWrongPassphraseThrowsInvalid() throws {
    #expect(performing: {
      try SSHPrivateKey(contentsOf: encryptedPrivateKey, passphrase: "wrong")
    }, throws: invalid(file: encryptedPrivateKey))
  }

  @Test func encryptedKeyWithEmptyPassphraseThrowsInvalid() throws {
    #expect(performing: {
      try SSHPrivateKey(contentsOf: encryptedPrivateKey, passphrase: "")
    }, throws: invalid(file: encryptedPrivateKey))
  }

  @Test func missingFileThrowsUnreadable() throws {
    let missing = URL(filePath: "/tmp/definitely_missing_pk")
    #expect(performing: {
      try SSHPrivateKey(contentsOf: missing)
    }, throws: unreadable(file: missing))
  }

  @Test func malformedKeyThrowsInvalid() throws {
    #expect(performing: {
      try SSHPrivateKey(contentsOf: publicKey)
    }, throws: invalid(file: publicKey))
  }

  @Test func emptyContentsThrowsInvalid() throws {
    #expect(performing: {
      try SSHPrivateKey(contents: "")
    }, throws: invalid(source: "data"))
  }

  @Test func strippedArmorThrowsInvalid() throws {
    let pem = try String(contentsOf: privateKey, encoding: .utf8)
    let stripped = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    #expect(performing: {
      try SSHPrivateKey(contents: stripped)
    }, throws: invalid(source: "data"))
  }

  /// Guards the deinit-based free: anything that retains the key past its
  /// scope (a session reference, a cache) would leak the underlying `ssh_key`.
  @Test func keyIsReleasedWhenLastReferenceDrops() throws {
    weak var weakKey: SSHPrivateKey?
    do {
      let key = try SSHPrivateKey(contentsOf: privateKey)
      weakKey = key
      #expect(weakKey != nil)
    }
    #expect(weakKey == nil)
  }
}
