import Foundation
import RusshFFI

public struct SFTPClient: Sendable {
  private let sftp: Sftp
  public let limits: SFTPLimits

  init(_ sftp: Sftp) {
    self.sftp = sftp
    self.limits = SFTPLimits(sftp.limits())
  }

  public func close() async {
    await sftp.close()
  }

  public func createDirectory(at path: String, permissions: mode_t = 0o777) async throws {
    try await bridge { try await sftp.mkdir(path: path, mode: UInt32(permissions)) }
  }

  public func createDirectoryRecursively(
    at path: String, permissions: mode_t = 0o777
  ) async throws {
    let isAbsolute = path.hasPrefix("/")
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    for i in components.indices {
      let partial = (isAbsolute ? "/" : "") + components[0...i].joined(separator: "/")
      do {
        try await createDirectory(at: partial, permissions: permissions)
      } catch SSHError.sftp(.fileAlreadyExists, _) {
        continue
      }
    }
  }

  public func removeDirectory(at path: String) async throws {
    try await bridge { try await sftp.rmdir(path: path) }
  }

  public func removeDirectoryRecursively(at path: String) async throws {
    try await withDirectory(at: path) { directory in
      for try await entry in directory {
        let entryPath = path + "/" + entry.name
        if entry.attributes.type == .directory {
          try await removeDirectoryRecursively(at: entryPath)
        } else {
          try await removeFile(at: entryPath)
        }
      }
    }
    try await removeDirectory(at: path)
  }

  public nonisolated(nonsending) func withDirectory<T>(
    at path: String, perform: (SFTPDirectory) async throws -> T
  ) async throws -> T {
    let directory = try await bridge { try await sftp.openDir(path: path) }
    do {
      let result = try await perform(SFTPDirectory(directory))
      await directory.close()
      return result
    } catch {
      await directory.close()
      throw error
    }
  }

  public func attributes(
    at path: String, followSymlinks: Bool = true
  ) async throws -> SFTPAttributes {
    SFTPAttributes(
      try await bridge { try await sftp.stat(path: path, followSymlinks: followSymlinks) })
  }

  public func setAttributes(
    at path: String,
    followSymlinks: Bool = true,
    size: UInt64? = nil,
    uid: UInt32? = nil,
    gid: UInt32? = nil,
    permissions: mode_t? = nil,
    accessTime: Date? = nil,
    modifyTime: Date? = nil
  ) async throws {
    let changes = AttributeChanges(
      size: size,
      uid: uid,
      gid: gid,
      permissions: permissions.map(UInt32.init),
      accessTime: accessTime?.sftpTimestamp,
      modifyTime: modifyTime?.sftpTimestamp
    )
    try await bridge {
      try await sftp.setAttributes(path: path, followSymlinks: followSymlinks, changes: changes)
    }
  }

  public func move(from oldPath: String, to newPath: String) async throws {
    try await bridge { try await sftp.rename(from: oldPath, to: newPath) }
  }

  public func removeFile(at path: String) async throws {
    try await bridge { try await sftp.remove(path: path) }
  }

  public func symlinkTarget(at path: String) async throws -> String {
    try await bridge { try await sftp.readlink(path: path) }
  }

  public func createSymlink(to target: String, at dest: String) async throws {
    try await bridge { try await sftp.symlink(target: target, dest: dest) }
  }

  public nonisolated(nonsending) func withFile<T>(
    at path: String, access: SFTPFile.AccessMode, options: SFTPFile.OpenOptions = [],
    permissions: mode_t = 0o666,
    perform: (SFTPFile) async throws -> T
  ) async throws -> T {
    let file = try await bridge {
      try await sftp.open(
        path: path, mode: access.openMode(options), permissions: UInt32(permissions))
    }
    do {
      let result = try await perform(SFTPFile(file, limits: limits))
      await file.close()
      return result
    } catch {
      await file.close()
      throw error
    }
  }

  public nonisolated(nonsending) func download(
    from remotePath: String, to localURL: URL,
    bufferSize: Int = SFTPLimits.defaultBufferSize,
    progress: ((UInt64) -> Void)? = nil
  ) async throws {
    try await withFile(at: remotePath, access: .readOnly) { file in
      try await file.download(to: localURL, bufferSize: bufferSize, progress: progress)
    }
  }

  public nonisolated(nonsending) func upload(
    from localURL: URL, to remotePath: String, permissions: mode_t = 0o666,
    bufferSize: Int = SFTPLimits.defaultBufferSize,
    progress: ((UInt64) -> Void)? = nil
  ) async throws {
    try await withFile(
      at: remotePath, access: .writeOnly, options: [.create, .truncate], permissions: permissions
    ) { file in
      try await file.upload(from: localURL, bufferSize: bufferSize, progress: progress)
    }
  }
}

extension Date {
  fileprivate var sftpTimestamp: UInt32 {
    let seconds = timeIntervalSince1970.rounded(.down)
    guard seconds > 0 else { return 0 }
    guard seconds < Double(UInt32.max) else { return .max }
    return UInt32(seconds)
  }
}
