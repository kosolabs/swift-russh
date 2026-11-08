import Foundation
import RusshFFI

struct SFTPAioReadContext: Sendable {
  private let pending: PendingRead

  init(_ pending: PendingRead) {
    self.pending = pending
  }

  func read() async throws(SSHError) -> Data {
    try await bridge { try await pending.wait() }
  }
}

struct SFTPAioWriteContext: Sendable {
  private let pending: PendingWrite
  let length: Int

  init(_ pending: PendingWrite) {
    self.pending = pending
    self.length = Int(pending.length())
  }

  func flush() async throws(SSHError) {
    try await bridge { try await pending.wait() }
  }
}
