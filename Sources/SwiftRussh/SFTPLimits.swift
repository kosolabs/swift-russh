import Foundation
import RusshFFI

public struct SFTPLimits: Hashable, Sendable {
  public static let defaultBufferSize = 102_400

  public let maxOpenHandles: Int
  public let maxPacketLength: Int
  public let maxReadLength: Int
  public let maxWriteLength: Int

  public func writeLength(for bufferSize: Int = defaultBufferSize) -> Int {
    precondition(bufferSize > 0, "bufferSize must be positive")
    return min(bufferSize, maxWriteLength)
  }

  public func readLength(for bufferSize: Int = defaultBufferSize) -> Int {
    precondition(bufferSize > 0, "bufferSize must be positive")
    return min(bufferSize, maxReadLength)
  }

  init(_ limits: SftpLimits) {
    maxOpenHandles = Int(clamping: limits.maxOpenHandles)
    maxPacketLength = Int(clamping: limits.maxPacketLength)
    maxReadLength = Int(clamping: limits.maxReadLength)
    maxWriteLength = Int(clamping: limits.maxWriteLength)
  }
}
