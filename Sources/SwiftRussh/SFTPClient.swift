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

  public func createDirectory(at path: String, mode: mode_t = 0o777) async throws(SSHError) {
    try await bridge { try await sftp.mkdir(path: path, mode: UInt32(mode)) }
  }

  public func createDirectoryRecursively(
    at path: String, mode: mode_t = 0o777
  ) async throws(SSHError) {
    let isAbsolute = path.hasPrefix("/")
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    for i in components.indices {
      let partial = (isAbsolute ? "/" : "") + components[0...i].joined(separator: "/")
      do {
        try await createDirectory(at: partial, mode: mode)
      } catch {
        guard error.sftpError == .fileAlreadyExists else { throw error }
      }
    }
  }

  public func removeDirectory(at path: String) async throws(SSHError) {
    try await bridge { try await sftp.rmdir(path: path) }
  }

  public func removeDirectoryRecursively(at path: String) async throws {
    try await withDirectory(at: path) { directory in
      for try await entry in directory {
        guard let name = entry.name else { continue }
        let entryPath = path + "/" + name
        if entry.type == .directory {
          try await removeDirectoryRecursively(at: entryPath)
        } else {
          try await removeFile(at: entryPath)
        }
      }
    }
    try await removeDirectory(at: path)
  }

  public func withDirectory<T: Sendable>(
    at path: String, perform: @Sendable (SFTPDirectory) async throws -> T
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
  ) async throws(SSHError) -> SFTPAttributes {
    SFTPAttributes(try await bridge { try await sftp.stat(path: path, followSymlinks: followSymlinks) })
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
  ) async throws(SSHError) {
    let changes = AttributeChanges(
      size: size,
      uid: uid,
      gid: gid,
      permissions: permissions.map(UInt32.init),
      accessTime: accessTime.map { UInt32($0.timeIntervalSince1970) },
      modifyTime: modifyTime.map { UInt32($0.timeIntervalSince1970) }
    )
    try await bridge {
      try await sftp.setAttributes(path: path, followSymlinks: followSymlinks, changes: changes)
    }
  }

  public func move(from oldPath: String, to newPath: String) async throws(SSHError) {
    try await bridge { try await sftp.rename(from: oldPath, to: newPath) }
  }

  public func removeFile(at path: String) async throws(SSHError) {
    try await bridge { try await sftp.remove(path: path) }
  }

  public func symlinkTarget(at path: String) async throws(SSHError) -> String {
    try await bridge { try await sftp.readlink(path: path) }
  }

  public func createSymlink(to target: String, at dest: String) async throws(SSHError) {
    try await bridge { try await sftp.symlink(target: target, dest: dest) }
  }

  public func withSftpFile<T: Sendable>(
    at path: String, accessType: AccessType, mode: mode_t = 0o666,
    perform: @Sendable (SFTPFile) async throws -> T
  ) async throws -> T {
    let file = try await bridge {
      try await sftp.open(path: path, access: accessType.mode, mode: UInt32(mode))
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

  public func download(
    from remotePath: String, to localURL: URL,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws {
    try await withSftpFile(at: remotePath, accessType: .readOnly) { file in
      try await file.download(to: localURL, bufferSize: bufferSize, progress: progress)
    }
  }

  public func upload(
    from localURL: URL, to remotePath: String, mode: mode_t = 0o666,
    bufferSize: UInt64 = SFTPLimits.defaultBufferSize,
    progress: (@Sendable (UInt64) -> Void)? = nil
  ) async throws {
    try await withSftpFile(at: remotePath, accessType: .writeOnly, mode: mode) { file in
      try await file.upload(from: localURL, bufferSize: bufferSize, progress: progress)
    }
  }
}
