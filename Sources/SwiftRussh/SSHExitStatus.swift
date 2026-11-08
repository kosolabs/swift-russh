import RusshFFI

public struct SSHExitStatus: Codable, Sendable {
  public let code: UInt8?
  public let signal: String?
  public let coreDumped: Bool

  init(_ status: ExitStatus) {
    code = status.code.map { UInt8(truncatingIfNeeded: $0) }
    signal = status.signal
    coreDumped = status.coreDumped
  }
}
