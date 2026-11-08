import Foundation
import RusshFFI

public struct SFTPLimits: Codable, Sendable {
  public static let defaultBufferSize: UInt64 = 102400

  public let maxOpenHandles: UInt64
  public let maxPacketLength: UInt64
  public let maxReadLength: UInt64
  public let maxWriteLength: UInt64

  public func writeLength(for bufferSize: UInt64 = defaultBufferSize) -> UInt64 {
    min(bufferSize, maxWriteLength)
  }

  public func readLength(for bufferSize: UInt64 = defaultBufferSize) -> UInt64 {
    min(bufferSize, maxReadLength)
  }

  init(_ limits: SftpLimits) {
    maxOpenHandles = limits.maxOpenHandles
    maxPacketLength = limits.maxPacketLength
    maxReadLength = limits.maxReadLength
    maxWriteLength = limits.maxWriteLength
  }
}
