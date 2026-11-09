import Foundation
import Synchronization
import Testing

@testable import SwiftRussh

func metrics(size: UInt64, duration: Duration) -> String {
  let megabytes = Double(size) / 1_048_576
  let speed = megabytes / (duration / .seconds(1))
  return "\(megabytes)MB in \(duration): \(String(format: "%.2f", speed))MB/s"
}

struct SFTPClientTests {
  struct Attributes {
    @Test func attributesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/stat-test.dat"
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1024 count=1")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(attrs.name == nil)
        #expect(attrs.type == .regular)
        #expect(attrs.size == 1024)
      }
    }

    @Test func attributesOfMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.attributes(at: "/tmp/missing.dat")
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }

    @Test func attributesOfSymlinkFollowsSymlink() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/stat-follow-target.dat"
        let link = "/tmp/stat-follow-link.dat"
        try await ssh.execute(
          "dd if=/dev/urandom of=\(target) bs=1024 count=1 && ln -sf \(target) \(link)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link)
        }

        #expect(attrs.type == .regular)
        #expect(attrs.size == 1024)
      }
    }

    @Test func attributesOfSymlinkSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/lstat-target.txt"
        let link = "/tmp/lstat-link.txt"
        try await ssh.execute("touch \(target) && ln -sf \(target) \(link)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link, followSymlinks: false)
        }

        #expect(attrs.type == .symlink)
      }
    }
  }

  struct SetAttributes {
    @Test func setPermissionsSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-perm.txt"
        try await ssh.execute("touch \(path) && chmod 0777 \(path)")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, permissions: 0o600)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect((after.permissions! & 0o777) == 0o600)
        // Unchanged
        #expect(after.size == before.size)
        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        #expect(after.accessTime == before.accessTime)
        #expect(after.modifyTime == before.modifyTime)
      }
    }

    @Test func setModifyTimeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-mtime.txt"
        try await ssh.execute("touch \(path)")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        let targetDate = Date(timeIntervalSince1970: 1_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, modifyTime: targetDate)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.modifyTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        // Unchanged
        #expect(after.size == before.size)
        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        #expect((after.permissions! & 0o777) == (before.permissions! & 0o777))
        #expect(after.accessTime == before.accessTime)
      }
    }

    @Test func setAccessTimeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-atime.txt"
        try await ssh.execute("touch \(path)")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        let targetDate = Date(timeIntervalSince1970: 1_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, accessTime: targetDate)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.accessTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        // Unchanged
        #expect(after.size == before.size)
        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        #expect((after.permissions! & 0o777) == (before.permissions! & 0o777))
        #expect(after.modifyTime == before.modifyTime)
      }
    }

    @Test(
      arguments: zip(
        [Date(timeIntervalSince1970: -86_400), Date.distantFuture],
        [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: TimeInterval(UInt32.max))]
      ))
    func setTimesOutsideProtocolRangeClamps(target: Date, expected: Date) async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-clamp-\(Int64(target.timeIntervalSince1970)).txt"
        try await ssh.execute("touch \(path)")

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, accessTime: target, modifyTime: target)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.accessTime == expected)
        #expect(after.modifyTime == expected)
      }
    }

    @Test func setSizeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-size.dat"
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1024 count=4")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, size: 1024)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.size == 1024)
        // Unchanged
        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        #expect((after.permissions! & 0o777) == (before.permissions! & 0o777))
        #expect(after.accessTime == before.accessTime)
        // Truncating to a new size updates the modification time.
        #expect(try #require(after.modifyTime) >= #require(before.modifyTime))
      }
    }

    @Test func setUidGidSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-uidgid.txt"
        try await ssh.execute("touch \(path)")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        // Setting uid/gid to their current values is always permitted
        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: path, uid: before.uid, gid: before.gid)
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        // Unchanged
        #expect(after.size == before.size)
        #expect((after.permissions! & 0o777) == (before.permissions! & 0o777))
        #expect(after.accessTime == before.accessTime)
        #expect(after.modifyTime == before.modifyTime)
      }
    }

    @Test func setMultipleAttributesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/sftp-setattr-multi.dat"
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1024 count=4 && chmod 0777 \(path)")

        let before = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        let targetDate = Date(timeIntervalSince1970: 2_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(
            at: path,
            size: 512,
            permissions: 0o644,
            modifyTime: targetDate
          )
        }

        let after = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }

        #expect(after.size == 512)
        #expect((after.permissions! & 0o777) == 0o644)
        #expect(after.modifyTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        // Unchanged
        #expect(after.uid == before.uid)
        #expect(after.gid == before.gid)
        #expect(after.accessTime == before.accessTime)
      }
    }

    @Test func setModifyTimeOnSymlinkFollowsSymlinkByDefault() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/sftp-setattr-follow-target.txt"
        let link = "/tmp/sftp-setattr-follow-link.txt"
        try await ssh.execute("touch \(target) && rm -f \(link) && ln -s \(target) \(link)")

        let linkBefore = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link, followSymlinks: false)
        }

        let targetDate = Date(timeIntervalSince1970: 1_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: link, modifyTime: targetDate)
        }

        let (targetAfter, linkAfter) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        #expect(targetAfter.modifyTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        #expect(linkAfter.modifyTime == linkBefore.modifyTime)
      }
    }

    @Test func setModifyTimeOnSymlinkSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/sftp-setattr-lmtime-target.txt"
        let link = "/tmp/sftp-setattr-lmtime-link.txt"
        try await ssh.execute("touch \(target) && rm -f \(link) && ln -s \(target) \(link)")

        let (targetBefore, linkBefore) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        let targetDate = Date(timeIntervalSince1970: 1_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: link, followSymlinks: false, modifyTime: targetDate)
        }

        let (targetAfter, linkAfter) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        #expect(linkAfter.type == .symlink)
        #expect(linkAfter.modifyTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        // The link's other attributes are unchanged, including atime: the
        // baseline must come from lstat, not from the target.
        #expect(linkAfter.accessTime == linkBefore.accessTime)
        #expect(linkAfter.uid == linkBefore.uid)
        #expect(linkAfter.gid == linkBefore.gid)
        #expect((linkAfter.permissions! & 0o777) == (linkBefore.permissions! & 0o777))
        // Target untouched
        #expect(targetAfter.modifyTime == targetBefore.modifyTime)
        #expect(targetAfter.accessTime == targetBefore.accessTime)
      }
    }

    @Test func setAccessTimeOnSymlinkSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/sftp-setattr-latime-target.txt"
        let link = "/tmp/sftp-setattr-latime-link.txt"
        try await ssh.execute("touch \(target) && rm -f \(link) && ln -s \(target) \(link)")

        let (targetBefore, linkBefore) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        let targetDate = Date(timeIntervalSince1970: 1_000_000)

        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: link, followSymlinks: false, accessTime: targetDate)
        }

        let (targetAfter, linkAfter) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        #expect(linkAfter.type == .symlink)
        #expect(linkAfter.accessTime?.timeIntervalSince1970 == targetDate.timeIntervalSince1970)
        #expect(linkAfter.modifyTime == linkBefore.modifyTime)
        // Target untouched
        #expect(targetAfter.modifyTime == targetBefore.modifyTime)
        #expect(targetAfter.accessTime == targetBefore.accessTime)
      }
    }

    @Test func setPermissionsOnSymlinkSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/sftp-setattr-lperm-target.txt"
        let link = "/tmp/sftp-setattr-lperm-link.txt"
        try await ssh.execute(
          "touch \(target) && chmod 0644 \(target) && rm -f \(link) && ln -s \(target) \(link)")

        let linkBefore = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link, followSymlinks: false)
        }
        #expect((linkBefore.permissions! & 0o777) != 0o600)

        // OpenSSH implements this with fchmodat(AT_SYMLINK_NOFOLLOW), which
        // macOS/BSD honor. Linux servers reject it with .opUnsupported.
        try await ssh.withSftp { sftp in
          try await sftp.setAttributes(at: link, followSymlinks: false, permissions: 0o600)
        }

        let (targetAfter, linkAfter) = try await ssh.withSftp { sftp in
          (
            try await sftp.attributes(at: target),
            try await sftp.attributes(at: link, followSymlinks: false)
          )
        }

        #expect(linkAfter.type == .symlink)
        #expect((linkAfter.permissions! & 0o777) == 0o600)
        #expect(linkAfter.modifyTime == linkBefore.modifyTime)
        #expect(linkAfter.accessTime == linkBefore.accessTime)
        // Target untouched
        #expect((targetAfter.permissions! & 0o777) == 0o644)
      }
    }

    @Test func setSizeOnSymlinkThrowsBadMessage() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let target = "/tmp/sftp-setattr-lsize-target.txt"
          let link = "/tmp/sftp-setattr-lsize-link.txt"
          try await ssh.execute("touch \(target) && rm -f \(link) && ln -s \(target) \(link)")
          try await ssh.withSftp { sftp in
            try await sftp.setAttributes(at: link, followSymlinks: false, size: 0)
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .badMessage
      }
    }
  }

  struct CreateDirectory {
    @Test func createDirectorySucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-directory"
        try await ssh.execute("rmdir \(path)")

        try await ssh.withSftp(perform: { sftp in
          try await sftp.createDirectory(at: path)
        })

        let attrs = try await ssh.withSftp(perform: { sftp in
          try await sftp.attributes(at: path)
        })

        #expect(attrs.type == .directory)
      }
    }

    @Test func createDirectoryDefaultModeDelegatesToServerUmask() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-directory-default-mode"
        try await ssh.execute("rm -rf \(path)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.createDirectory(at: path)
          return try await sftp.attributes(at: path)
        }

        // 0o777 requested, reduced by the server's 022 umask.
        #expect((attrs.permissions! & 0o777) == 0o755)
      }
    }

    @Test func createDirectoryHonorsExplicitMode() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-directory-explicit-mode"
        try await ssh.execute("rm -rf \(path)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.createDirectory(at: path, mode: 0o700)
          return try await sftp.attributes(at: path)
        }

        #expect((attrs.permissions! & 0o777) == 0o700)
      }
    }

    @Test func createExistingDirectoryThrowsFileAlreadyExists() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let path = "/tmp/test-create-existing-directory"
          try await ssh.execute("rm -rf \(path) && mkdir \(path)")

          try await ssh.withSftp(perform: { sftp in
            try await sftp.createDirectory(at: path)
          })
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .fileAlreadyExists
      }
    }
  }

  struct CreateDirectoryRecursively {
    @Test func createSingleDirectorySucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-recursive-single"
        try await ssh.execute("rm -rf \(path)")

        try await ssh.withSftp { sftp in
          try await sftp.createDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }
        #expect(attrs.type == .directory)
      }
    }

    @Test func createDirectoryRecursivelyAppliesModeToEveryLevel() async throws {
      try await withAuthenticatedClient { ssh in
        let base = "/tmp/test-create-recursive-mode"
        try await ssh.execute("rm -rf \(base)")

        let permissions = try await ssh.withSftp { sftp -> [UInt32] in
          try await sftp.createDirectoryRecursively(at: "\(base)/a/b")
          var result: [UInt32] = []
          for path in [base, "\(base)/a", "\(base)/a/b"] {
            result.append(try await sftp.attributes(at: path).permissions! & 0o777)
          }
          return result
        }

        #expect(permissions == [0o755, 0o755, 0o755])
      }
    }

    @Test func createNestedDirectoriesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-recursive-nested/a/b/c"
        try await ssh.execute("rm -rf /tmp/test-create-recursive-nested")

        try await ssh.withSftp { sftp in
          try await sftp.createDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }
        #expect(attrs.type == .directory)
      }
    }

    @Test func createDirectoryWhenAlreadyExistsSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-create-recursive-existing"
        try await ssh.execute("rm -rf \(path) && mkdir \(path)")

        try await ssh.withSftp { sftp in
          try await sftp.createDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }
        #expect(attrs.type == .directory)
      }
    }

    @Test func createNestedDirectoriesWhenIntermediateExistsSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let base = "/tmp/test-create-recursive-partial"
        let path = "\(base)/a/b"
        try await ssh.execute("rm -rf \(base) && mkdir -p \(base)/a")

        try await ssh.withSftp { sftp in
          try await sftp.createDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: path)
        }
        #expect(attrs.type == .directory)
      }
    }
  }

  struct RemoveDirectory {
    @Test func removeDirectorySucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-remove-directory"
        try await ssh.execute("mkdir \(path)")

        try await ssh.withSftp(perform: { sftp in
          try await sftp.removeDirectory(at: path)
        })

        let attrs = try await ssh.withSftp(perform: { sftp in
          try? await sftp.attributes(at: path)
        })

        #expect(attrs == nil)
      }
    }

    @Test func removeMissingDirectoryThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp(perform: { sftp in
            try await sftp.removeDirectory(at: "/tmp/missing")
          })
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct RemoveDirectoryRecursively {
    @Test func removeEmptyDirectorySucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-remove-recursive-empty"
        try await ssh.execute("rm -rf \(path) && mkdir \(path)")

        try await ssh.withSftp { sftp in
          try await sftp.removeDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try? await sftp.attributes(at: path)
        }
        #expect(attrs == nil)
      }
    }

    @Test func removeDirectoryWithFilesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-remove-recursive-files"
        try await ssh.execute(
          "rm -rf \(path) && mkdir \(path) && touch \(path)/a.txt \(path)/b.txt")

        try await ssh.withSftp { sftp in
          try await sftp.removeDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try? await sftp.attributes(at: path)
        }
        #expect(attrs == nil)
      }
    }

    @Test func removeNestedDirectorySucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-remove-recursive-nested"
        try await ssh.execute(
          "rm -rf \(path) && mkdir -p \(path)/sub1/sub2 && touch \(path)/sub1/sub2/file.txt \(path)/sub1/other.txt \(path)/root.txt"
        )

        try await ssh.withSftp { sftp in
          try await sftp.removeDirectoryRecursively(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try? await sftp.attributes(at: path)
        }
        #expect(attrs == nil)
      }
    }

    @Test func removeMissingDirectoryThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.removeDirectoryRecursively(at: "/tmp/missing-recursive")
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct SymlinkTarget {
    @Test func symlinkTargetSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/readlink-target.txt"
        let link = "/tmp/readlink-link.txt"
        try await ssh.execute("touch \(target) && ln -sf \(target) \(link)")

        let resolved = try await ssh.withSftp { sftp in
          try await sftp.symlinkTarget(at: link)
        }

        #expect(resolved == target)
      }
    }

    @Test func symlinkTargetOnNonSymlinkThrows() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let path = "/tmp/readlink-regular.txt"
          try await ssh.execute("touch \(path)")
          try await ssh.withSftp { sftp in
            try await sftp.symlinkTarget(at: path)
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .badMessage
      }
    }

    @Test func symlinkTargetOnMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.symlinkTarget(at: "/tmp/readlink-missing.txt")
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct CreateSymlink {
    @Test func createSymlinkSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let target = "/tmp/symlink-target.txt"
        let link = "/tmp/symlink-link.txt"
        try await ssh.execute("touch \(target) && rm -f \(link)")

        try await ssh.withSftp { sftp in
          try await sftp.createSymlink(to: target, at: link)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link, followSymlinks: false)
        }
        #expect(attrs.type == .symlink)

        let resolved = try await ssh.withSftp { sftp in
          try await sftp.symlinkTarget(at: link)
        }
        #expect(resolved == target)
      }
    }

    @Test func createSymlinkToDanglingTargetSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let link = "/tmp/symlink-dangling.txt"
        try await ssh.execute("rm -f \(link)")

        try await ssh.withSftp { sftp in
          try await sftp.createSymlink(to: "/tmp/does-not-exist.txt", at: link)
        }

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.attributes(at: link, followSymlinks: false)
        }
        #expect(attrs.type == .symlink)
      }
    }

    @Test func createSymlinkAtExistingFileThrowsFileAlreadyExists() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let link = "/tmp/symlink-existing.txt"
          try await ssh.execute("touch \(link)")
          try await ssh.withSftp { sftp in
            try await sftp.createSymlink(to: "/tmp/anything.txt", at: link)
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .fileAlreadyExists
      }
    }

    @Test func createSymlinkAtExistingSymlinkThrowsFileAlreadyExists() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let link = "/tmp/symlink-existing-link.txt"
          try await ssh.execute("rm -f \(link) && ln -s /tmp/anything.txt \(link)")
          try await ssh.withSftp { sftp in
            try await sftp.createSymlink(to: "/tmp/anything.txt", at: link)
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .fileAlreadyExists
      }
    }

    @Test func createSymlinkInMissingDirectoryThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.createSymlink(
              to: "/tmp/anything.txt", at: "/tmp/no-such-dir-\(UUID().uuidString)/link")
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct IterateDirectory {
    @Test func iterateDirectoryReturnsNames() async throws {
      try await withAuthenticatedClient { ssh in
        let dirPath = "/tmp/test-iterate-names"
        try await ssh.execute("rm -rf \(dirPath) && mkdir \(dirPath)")

        try await ssh.execute("touch \(dirPath)/file{1..3}.txt")

        try await ssh.withSftp(perform: { sftp in
          let names = try await sftp.withDirectory(at: dirPath) { directory in
            var names = Set<String>()
            for try await attrs in directory {
              if let name = attrs.name {
                names.insert(name)
              }
            }
            return names
          }

          #expect(names == Set(["file1.txt", "file2.txt", "file3.txt"]))
        })
      }
    }

    @Test func iterateDirectoryReturnsCorrectTypes() async throws {
      try await withAuthenticatedClient { ssh in
        let dirPath = "/tmp/test-iterate-types"

        try await ssh.execute(
          """
          rm -rf \(dirPath) && \
          mkdir \(dirPath) && \
          touch \(dirPath)/file.txt && \
          mkdir \(dirPath)/subdir && \
          ln -s \(dirPath)/file.txt \(dirPath)/linked-file.txt && \
          ln -s \(dirPath)/subdir \(dirPath)/linked-dir
          """)

        try await ssh.withSftp { sftp in
          let types = try await sftp.withDirectory(at: dirPath) { directory in
            var types: [String: SFTPAttributes.FileType] = [:]
            for try await attrs in directory {
              if let name = attrs.name {
                types[name] = attrs.type
              }
            }
            return types
          }

          #expect(types["file.txt"] == .regular)
          #expect(types["subdir"] == .directory)
          #expect(types["linked-file.txt"] == .symlink)
          #expect(types["linked-dir"] == .symlink)
        }
      }
    }

    @Test func iterateMissingDirectoryThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp(perform: { sftp in
            try await sftp.withDirectory(at: "/tmp/missing") { directory in
              for try await _ in directory {}
            }
          })
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct Limits {
    @Test func limitsSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        try await ssh.withSftp(perform: { sftp in
          #expect(sftp.limits.maxOpenHandles > 0)
          #expect(sftp.limits.maxPacketLength > 0)
          #expect(sftp.limits.maxReadLength > 0)
          #expect(sftp.limits.maxWriteLength > 0)
        })
      }
    }
  }

  struct Download {
    @Test func downloadSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/dl-test.dat"

        let destURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("dl-test.dat")

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=50")
        let expected = try await ssh.md5(ofFile: srcPath)

        try await ssh.withSftp { sftp in
          let attrs = try await sftp.attributes(at: srcPath)
          let transferred = Atomic<UInt64>(0)

          let elapsed = try await ContinuousClock().measure {
            try await sftp.download(from: srcPath, to: destURL) { progress in
              transferred.store(progress, ordering: .relaxed)
            }
          }
          print("Download: \(metrics(size: attrs.size!, duration: elapsed))")

          #expect(transferred.load(ordering: .relaxed) == attrs.size!)
        }

        let actual = try md5(ofFile: destURL.path)
        #expect(actual == expected)
      }
    }

    @Test func downloadWith1MBBufferSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/dl-1mb-buf-test.dat"

        let destURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("dl-1mb-buf-test.dat")

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        try await ssh.withSftp { sftp in
          let attrs = try await sftp.attributes(at: srcPath)
          let transferred = Atomic<UInt64>(0)

          try await sftp.download(from: srcPath, to: destURL, bufferSize: 1_048_576) { progress in
            transferred.store(progress, ordering: .relaxed)
          }

          #expect(transferred.load(ordering: .relaxed) == attrs.size!)
        }

        let actual = try md5(ofFile: destURL.path)
        #expect(actual == expected)
      }
    }
  }

  struct Upload {
    @Test func uploadDefaultModeDelegatesToServerUmask() async throws {
      try await withAuthenticatedClient { ssh in
        let srcURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("ul-default-mode.dat")

        let destPath = "/tmp/ul-default-mode.dat"

        try shell("dd if=/dev/urandom of=\(srcURL.path) bs=1024 count=1")
        try await ssh.execute("rm -f \(destPath)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.upload(from: srcURL, to: destPath)
          return try await sftp.attributes(at: destPath)
        }

        // 0o666 requested, reduced by the server's 022 umask.
        #expect((attrs.permissions! & 0o777) == 0o644)
      }
    }

    @Test func uploadSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("ul-test.dat")

        let destPath = "/tmp/ul-test.dat"

        try shell("dd if=/dev/urandom of=\(srcURL.path) bs=1M count=50")
        let expected = try md5(ofFile: srcURL.path)

        try await ssh.withSftp { sftp in
          let size = try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as! UInt64
          let transferred = Atomic<UInt64>(0)

          let elapsed = try await ContinuousClock().measure {
            try await sftp.upload(from: srcURL, to: destPath, mode: 0o644) { progress in
              transferred.store(progress, ordering: .relaxed)
            }
          }
          print("Upload: \(metrics(size: size, duration: elapsed))")

          #expect(transferred.load(ordering: .relaxed) == size)
        }

        try await Task.sleep(for: .seconds(1))
        let actual = try await ssh.md5(ofFile: destPath)
        #expect(actual == expected)
      }
    }

    @Test func uploadWith1MBBufferSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("ul-1mb-buf-test.dat")

        let destPath = "/tmp/ul-1mb-buf-test.dat"

        try shell("dd if=/dev/urandom of=\(srcURL.path) bs=1M count=1")
        let expected = try md5(ofFile: srcURL.path)

        try await ssh.withSftp { sftp in
          let size = try FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as! UInt64
          let transferred = Atomic<UInt64>(0)

          try await sftp.upload(from: srcURL, to: destPath, mode: 0o644, bufferSize: 1_048_576) {
            progress in
            transferred.store(progress, ordering: .relaxed)
          }

          #expect(transferred.load(ordering: .relaxed) == size)
        }

        try await Task.sleep(for: .seconds(1))
        let actual = try await ssh.md5(ofFile: destPath)
        #expect(actual == expected)
      }
    }
  }

  @Test func testRenameFileSucceeds() async throws {
    try await withAuthenticatedClient { ssh in
      let oldPath = "/tmp/test-rename-old.txt"
      let newPath = "/tmp/test-rename-new.txt"

      try await ssh.execute("touch \(oldPath) && rm -f \(newPath)")

      try await ssh.withSftp { sftp in
        try await sftp.move(from: oldPath, to: newPath)
      }

      let oldAttrs = try await ssh.withSftp { sftp in
        try? await sftp.attributes(at: oldPath)
      }
      #expect(oldAttrs == nil)

      let newAttrs = try await ssh.withSftp { sftp in
        try await sftp.attributes(at: newPath)
      }
      #expect(newAttrs.type == .regular)
    }
  }

  @Test func testRenameOverExistingFileReplacesIt() async throws {
    try await withAuthenticatedClient { ssh in
      let oldPath = "/tmp/test-rename-over-old.txt"
      let newPath = "/tmp/test-rename-over-new.txt"

      try await ssh.execute("printf new > \(oldPath) && printf old > \(newPath)")

      try await ssh.withSftp { sftp in
        try await sftp.move(from: oldPath, to: newPath)
      }

      let oldAttrs = try await ssh.withSftp { sftp in
        try? await sftp.attributes(at: oldPath)
      }
      #expect(oldAttrs == nil)
      #expect(try await ssh.execute("cat \(newPath)").stdout.decoded(as: .utf8) == "new")
    }
  }

  @Test func testRenameDirectoryOverEmptyDirectoryReplacesIt() async throws {
    try await withAuthenticatedClient { ssh in
      let oldPath = "/tmp/test-rename-dir-old"
      let newPath = "/tmp/test-rename-dir-new"

      try await ssh.execute(
        "rm -rf \(oldPath) \(newPath) && mkdir \(oldPath) \(newPath) && touch \(oldPath)/file"
      )

      try await ssh.withSftp { sftp in
        try await sftp.move(from: oldPath, to: newPath)
      }

      #expect(try await ssh.execute("ls \(newPath)").stdout.decoded(as: .utf8) == "file\n")
    }
  }

  @Test func testRenameDirectoryOverNonEmptyDirectoryThrows() async throws {
    try await withAuthenticatedClient { ssh in
      let oldPath = "/tmp/test-rename-full-old"
      let newPath = "/tmp/test-rename-full-new"

      try await ssh.execute(
        "rm -rf \(oldPath) \(newPath) && mkdir \(oldPath) \(newPath) && touch \(newPath)/file"
      )

      await #expect(throws: SSHError.self) {
        try await ssh.withSftp { sftp in
          try await sftp.move(from: oldPath, to: newPath)
        }
      }
    }
  }

  @Test func testRenameMissingFileThrowsNoSuchFile() async throws {
    await #expect {
      try await withAuthenticatedClient { ssh in
        try await ssh.withSftp { sftp in
          try await sftp.move(from: "/tmp/missing.dat", to: "/tmp/new.dat")
        }
      }
    } throws: { error in
      (error as? SSHError)?.sftpStatus == .noSuchFile
    }
  }

  @Test func testMoveFileSucceeds() async throws {
    try await withAuthenticatedClient { ssh in
      let oldFolder = "/tmp/test-move-old"
      let newFolder = "/tmp/test-move-new"
      let oldPath = "\(oldFolder)/file.txt"
      let newPath = "\(newFolder)/file.txt"

      try await ssh.execute("rm -rf \(oldFolder) \(newFolder)")
      try await ssh.execute("mkdir \(oldFolder) && mkdir \(newFolder) && touch \(oldPath)")

      try await ssh.withSftp { sftp in
        try await sftp.move(from: oldPath, to: newPath)
      }

      let oldAttrs = try await ssh.withSftp { sftp in
        try? await sftp.attributes(at: oldPath)
      }
      #expect(oldAttrs == nil)

      let newAttrs = try await ssh.withSftp { sftp in
        try await sftp.attributes(at: newPath)
      }
      #expect(newAttrs.type == .regular)
    }
  }

  struct RemoveFile {
    @Test func removeFileSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/test-remove-file.txt"
        try await ssh.execute("touch \(path)")

        try await ssh.withSftp { sftp in
          try await sftp.removeFile(at: path)
        }

        let attrs = try await ssh.withSftp { sftp in
          try? await sftp.attributes(at: path)
        }

        #expect(attrs == nil)
      }
    }

    @Test func removeMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.removeFile(at: "/tmp/missing.dat")
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct LocalFile {
    @Test func uploadFromMissingLocalFileThrowsFileNoSuchFile() async throws {
      try await withAuthenticatedClient { ssh in
        let srcURL = FileManager
          .default
          .temporaryDirectory
          .appendingPathComponent("missing-\(UUID().uuidString).dat")
        let destPath = "/tmp/missing-upload-\(UUID().uuidString).dat"

        try await ssh.withSftp { sftp in
          await #expect {
            try await sftp.upload(from: srcURL, to: destPath)
          } throws: { error in
            (error as? CocoaError)?.code == .fileNoSuchFile
          }
        }

        try await ssh.execute("rm -f \(destPath)")
      }
    }

    @Test func downloadToMissingLocalDirectoryThrowsFileNoSuchFile() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/download-source-\(UUID().uuidString).dat"
        let destURL = URL(fileURLWithPath: "/tmp/no-such-directory-\(UUID().uuidString)/out.dat")

        try await ssh.execute("echo hello > \(srcPath)")

        try await ssh.withSftp { sftp in
          await #expect {
            try await sftp.download(from: srcPath, to: destURL)
          } throws: { error in
            (error as? CocoaError)?.code == .fileNoSuchFile
          }
        }

        try await ssh.execute("rm -f \(srcPath)")
      }
    }
  }

  struct Lifecycle {

    @Test func sftpCloseAfterSessionCloseSucceeds() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()

      await ssh.close()
      await sftp.close()
    }

    @Test func sftpOperationAfterConnectionDropThrowsConnectionFailed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()

      await ssh.dropConnection()

      await #expect {
        _ = try await sftp.attributes(at: "/tmp")
      } throws: { error in
        (error as? SSHError)?.connectionFailure == .lost
      }

      await sftp.close()
      await ssh.close()
    }

    @Test func iterateDirectoryAfterConnectionDropThrowsConnectionFailed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()
      let path = "/tmp/swift-libssh-lifecycle-\(UUID().uuidString)"

      try await ssh.execute("mkdir -p \(path) && touch \(path)/{1..500}")

      try await sftp.withDirectory(at: path) { directory in
        let iterator = directory.makeAsyncIterator()
        _ = try await iterator.next()

        await ssh.dropConnection()

        await #expect {
          while try await iterator.next() != nil {}
        } throws: { error in
          (error as? SSHError)?.connectionFailure == .lost
        }
      }

      await sftp.close()
      await ssh.close()
      try? FileManager.default.removeItem(atPath: path)
    }

    @Test func closeAfterConnectionDropSucceeds() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()

      await ssh.dropConnection()

      await sftp.close()
      await ssh.close()

      #expect(!(await ssh.isConnected))
    }

    @Test func sftpOperationAfterCloseThrowsClosed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()

      await ssh.close()

      await #expect {
        _ = try await sftp.attributes(at: "/tmp")
      } throws: { error in
        if case .closed? = error as? SSHError { true } else { false }
      }
    }

    @Test func openingSftpAfterCloseThrowsClosed() async throws {
      let ssh = try await client()
      await ssh.close()

      await #expect {
        _ = try await ssh.sftp()
      } throws: { error in
        if case .closed? = error as? SSHError { true } else { false }
      }
    }

    @Test func sftpOperationAfterSftpCloseThrowsClosed() async throws {
      try await withAuthenticatedClient { ssh in
        let sftp = try await ssh.sftp()
        await sftp.close()

        await #expect {
          _ = try await sftp.attributes(at: "/tmp")
        } throws: { error in
          if case .closed? = error as? SSHError { true } else { false }
        }
      }
    }

    @Test func openDirectoryAfterSftpCloseThrowsClosed() async throws {
      try await withAuthenticatedClient { ssh in
        let sftp = try await ssh.sftp()

        try await sftp.withDirectory(at: "/tmp") { directory in
          let iterator = directory.makeAsyncIterator()
          _ = try await iterator.next()

          await sftp.close()

          await #expect {
            _ = try await iterator.next()
          } throws: { error in
            if case .closed? = error as? SSHError { true } else { false }
          }
        }
      }
    }
  }
}
