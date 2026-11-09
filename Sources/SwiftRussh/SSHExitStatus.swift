import RusshFFI

public enum SSHExitStatus: Hashable, Sendable {
  case exited(code: Int32)
  case signaled(signal: String, coreDumped: Bool)
  case unknown

  init(_ status: ExitStatus) {
    if let code = status.code {
      self = .exited(code: Int32(bitPattern: code))
    } else if let signal = status.signal {
      self = .signaled(signal: signal, coreDumped: status.coreDumped)
    } else {
      self = .unknown
    }
  }
}
