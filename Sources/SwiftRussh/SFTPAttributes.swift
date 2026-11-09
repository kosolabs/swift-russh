import Foundation
import RusshFFI

public struct SFTPAttributes: Hashable, Sendable {
  public enum FileType: Hashable, Sendable {
    case regular
    case directory
    case symlink
    case special
    case unknown

    init(mode: UInt32?) {
      guard let mode else {
        self = .unknown
        return
      }
      switch mode & UInt32(S_IFMT) {
      case UInt32(S_IFREG): self = .regular
      case UInt32(S_IFDIR): self = .directory
      case UInt32(S_IFLNK): self = .symlink
      case UInt32(S_IFSOCK), UInt32(S_IFBLK), UInt32(S_IFCHR), UInt32(S_IFIFO): self = .special
      default: self = .unknown
      }
    }
  }

  public let type: FileType
  public let size: UInt64?
  public let uid: UInt32?
  public let gid: UInt32?
  public let permissions: mode_t?
  public let accessTime: Date?
  public let modifyTime: Date?

  public init(
    type: FileType = .unknown,
    size: UInt64? = nil,
    uid: UInt32? = nil,
    gid: UInt32? = nil,
    permissions: mode_t? = nil,
    accessTime: Date? = nil,
    modifyTime: Date? = nil
  ) {
    self.type = type
    self.size = size
    self.uid = uid
    self.gid = gid
    self.permissions = permissions
    self.accessTime = accessTime
    self.modifyTime = modifyTime
  }

  init(_ attributes: Attributes) {
    self.init(
      type: FileType(mode: attributes.permissions),
      size: attributes.size,
      uid: attributes.uid,
      gid: attributes.gid,
      permissions: attributes.permissions.map { mode_t($0 & 0o7777) },
      accessTime: attributes.accessTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      modifyTime: attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    )
  }
}
