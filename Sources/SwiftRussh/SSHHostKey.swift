import CryptoKit
import Foundation
import RusshFFI

public struct SSHHostKey: Codable, Sendable, Hashable, LosslessStringConvertible {
  public let type: String
  public let blob: Data

  public init(type: String, blob: Data) {
    self.type = type
    self.blob = blob
  }

  public init?(_ description: String) {
    let fields = description.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
      return nil
    }
    self.init(type: String(fields[0]), blob: blob)
  }

  init(_ hostKey: HostKey) {
    self.init(type: hostKey.keyType, blob: hostKey.blob)
  }

  public var description: String {
    "\(type) \(blob.base64EncodedString())"
  }

  public var fingerprint: String {
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:\(digest.trimmingCharacters(in: ["="]))"
  }
}
