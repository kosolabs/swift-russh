import Foundation
import RusshFFI

public enum SSHKeyType: Sendable, Equatable {
  case dss
  case rsa
  case ecdsaP256
  case ecdsaP384
  case ecdsaP521
  case ed25519
  case securityKeyEcdsa
  case securityKeyEd25519
  case other(name: String)

  init(_ keyType: KeyType) {
    switch keyType {
    case .dss: self = .dss
    case .rsa: self = .rsa
    case .ecdsaP256: self = .ecdsaP256
    case .ecdsaP384: self = .ecdsaP384
    case .ecdsaP521: self = .ecdsaP521
    case .ed25519: self = .ed25519
    case .securityKeyEcdsa: self = .securityKeyEcdsa
    case .securityKeyEd25519: self = .securityKeyEd25519
    case .other(let name): self = .other(name: name)
    }
  }
}

public final class SSHPrivateKey: Sendable {
  let key: PrivateKey

  public convenience init(contentsOf file: URL, passphrase: String? = nil) throws {
    let source = "file \(file.path)"
    guard let data = FileManager.default.contents(atPath: file.path) else {
      let reason = SSHError.PrivateKeyFailure.unreadable
      throw SSHError.privateKey(reason, message: reason.message(source: source))
    }
    try self.init(contents: String(decoding: data, as: UTF8.self), passphrase: passphrase, source: source)
  }

  public convenience init(contents: String, passphrase: String? = nil) throws {
    try self.init(contents: contents, passphrase: passphrase, source: "data")
  }

  private init(contents: String, passphrase: String?, source: String) throws(SSHError) {
    do {
      key = try PrivateKey.decode(contents: contents, passphrase: passphrase)
    } catch {
      let reason: SSHError.PrivateKeyFailure =
        if case RusshError.Key(.passphraseRequired, _) = error { .passphraseRequired } else { .invalid }
      throw SSHError.privateKey(reason, message: reason.message(source: source))
    }
  }

  public var keyType: SSHKeyType {
    SSHKeyType(key.keyType())
  }
}

extension SSHError.PrivateKeyFailure {
  fileprivate func message(source: String) -> String {
    switch self {
    case .unreadable:
      "Failed to read private key from \(source)"
    case .passphraseRequired:
      "Private key from \(source) is encrypted and requires a passphrase"
    case .invalid:
      "Failed to import private key from \(source)"
    }
  }
}
