import Foundation
import RusshFFI

public struct SFTPAttributes: Codable, Sendable {
  public struct Flags: OptionSet, Codable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let size = Flags(rawValue: 0x0000_0001)
    public static let uidGid = Flags(rawValue: 0x0000_0002)
    public static let permissions = Flags(rawValue: 0x0000_0004)
    public static let accessTime = Flags(rawValue: 0x0000_0008)
    public static let createTime = Flags(rawValue: 0x0000_0010)
    public static let modifyTime = Flags(rawValue: 0x0000_0020)
    public static let ownerGroup = Flags(rawValue: 0x0000_0080)
    public static let subsecondTimes = Flags(rawValue: 0x0000_0100)
  }

  public enum FileType: Codable, Sendable {
    case regular
    case directory
    case symlink
    case special
    case unknown

    init(permissions: UInt32?) {
      guard let permissions else {
        self = .unknown
        return
      }
      switch permissions & UInt32(S_IFMT) {
      case UInt32(S_IFREG): self = .regular
      case UInt32(S_IFDIR): self = .directory
      case UInt32(S_IFLNK): self = .symlink
      case UInt32(S_IFSOCK), UInt32(S_IFBLK), UInt32(S_IFCHR), UInt32(S_IFIFO): self = .special
      default: self = .unknown
      }
    }
  }

  public let name: String?
  public let type: FileType
  public let size: UInt64?
  public let uid: UInt32?
  public let gid: UInt32?
  public let owner: String?
  public let group: String?
  public let permissions: UInt32?
  public let accessTime: Date?
  public let accessTimeNanos: UInt32?
  public let createTime: Date?
  public let createTimeNanos: UInt32?
  public let modifyTime: Date?
  public let modifyTimeNanos: UInt32?
  public let extendedCount: UInt32

  public init(
    name: String? = nil,
    type: FileType = .unknown,
    size: UInt64? = nil,
    uid: UInt32? = nil,
    gid: UInt32? = nil,
    owner: String? = nil,
    group: String? = nil,
    permissions: UInt32? = nil,
    accessTime: Date? = nil,
    accessTimeNanos: UInt32? = nil,
    createTime: Date? = nil,
    createTimeNanos: UInt32? = nil,
    modifyTime: Date? = nil,
    modifyTimeNanos: UInt32? = nil,
    extendedCount: UInt32 = 0
  ) {
    self.name = name
    self.type = type
    self.size = size
    self.uid = uid
    self.gid = gid
    self.owner = owner
    self.group = group
    self.permissions = permissions
    self.accessTime = accessTime
    self.accessTimeNanos = accessTimeNanos
    self.createTime = createTime
    self.createTimeNanos = createTimeNanos
    self.modifyTime = modifyTime
    self.modifyTimeNanos = modifyTimeNanos
    self.extendedCount = extendedCount
  }

  init(_ attributes: Attributes) {
    let longname = attributes.longname?.split(separator: " ", omittingEmptySubsequences: true)
    let ownerGroup = longname.flatMap { $0.count >= 4 ? (String($0[2]), String($0[3])) : nil }
    self.init(
      name: attributes.name,
      type: FileType(permissions: attributes.permissions),
      size: attributes.size,
      uid: attributes.uid,
      gid: attributes.gid,
      owner: ownerGroup?.0,
      group: ownerGroup?.1,
      permissions: attributes.permissions,
      accessTime: attributes.accessTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
      modifyTime: attributes.modifyTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    )
  }
}
