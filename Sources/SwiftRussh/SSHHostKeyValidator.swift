public struct SSHHostKeyValidator: Sendable {
  private let validate: @Sendable (SSHHostKey) async throws -> Void

  /// Creates a validator that rejects a host key by throwing.
  public init(_ validate: @escaping @Sendable (SSHHostKey) async throws -> Void) {
    self.validate = validate
  }

  /// Accepts only `expected`, and otherwise throws ``SSHError/hostKeyMismatch(expected:actual:message:)``.
  public static func expecting(_ expected: SSHHostKey) -> Self {
    Self { actual in
      guard actual == expected else {
        throw SSHError.hostKeyMismatch(
          expected: expected, actual: actual,
          message: "Server host key \(actual.fingerprint) does not match \(expected.fingerprint)"
        )
      }
    }
  }

  /// Accepts any host key, which leaves the connection open to an attacker
  /// impersonating the server.
  public static let acceptingAny = Self { _ in }

  func callAsFunction(_ hostKey: SSHHostKey) async throws {
    try await validate(hostKey)
  }
}
