import Foundation
import Testing

@testable import SwiftRussh

struct SFTPFileTests {
  struct Attributes {
    @Test func attributesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/stat-file-test.dat"
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1024 count=1")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: path, accessType: .readOnly) { file in
            try await file.attributes()
          }
        }

        #expect(attrs.name == nil)
        #expect(attrs.type == .regular)
        #expect(attrs.size == 1024)
      }
    }
  }

  struct Read {
    @Test func readRangeSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/read-range-small-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1024 count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            try await file.read(range: 0..<1024).md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readRangeSomeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/read-range-some-test.dat"
        let range = UInt64(153600)..<UInt64(307200)

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(
          ofFile: srcPath, offset: range.lowerBound,
          length: range.upperBound - range.lowerBound)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            try await file.read(range: range).md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/read-small-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1024 count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            try await file.read().md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readSomeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/read-some-test.dat"
        let offset = 153600 as UInt64
        let length = 153600 as UInt64

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath, offset: offset, length: length)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            try await file.read(offset: offset, length: length).md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readBigSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/read-big-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            try await file.read().md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.withSftpFile(at: "/tmp/nonexistent.dat", accessType: .readOnly) {
              file in
              try await file.read()
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpError == .noSuchFile
      }
    }

    @Test func readRestrictedThrowsPermissionDenied() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let srcPath = "/tmp/restricted.dat"
          try await ssh.execute("touch \(srcPath)")
          try await ssh.execute("chmod 000 \(srcPath)")

          try await ssh.withSftp { sftp in
            try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
              for try await _ in file.stream(length: 1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpError == .permissionDenied
      }
    }

    @Test func readDirectoryThrowsFailed() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.withSftpFile(at: "/tmp", accessType: .readOnly) { file in
              for try await _ in file.stream(length: 1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpError == .failure
      }
    }
  }

  struct Stream {
    @Test func streamRangeSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-range-small-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1024 count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(range: 0..<1024) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamRangeSomeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-range-some-test.dat"
        let range = UInt64(153600)..<UInt64(307200)

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(
          ofFile: srcPath, offset: range.lowerBound,
          length: range.upperBound - range.lowerBound)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(range: range) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-small-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1024 count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(length: 1024) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamSomeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-some-test.dat"
        let offset = 153600 as UInt64
        let length = 153600 as UInt64

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath, offset: offset, length: length)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(offset: offset, length: length) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamBigSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-big-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: srcPath, accessType: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(length: 1_048_576) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSftp { sftp in
            try await sftp.withSftpFile(at: "/tmp/nonexistent.dat", accessType: .readOnly) {
              file in
              for try await _ in file.stream(length: 1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpError == .noSuchFile
      }
    }
  }

  struct Write {
    @Test func createdFileDefaultModeDelegatesToServerUmask() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-default-mode.dat"
        try await ssh.execute("rm -f \(destPath)")

        let attrs = try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: destPath, accessType: .writeOnly) { file in
            try await file.write(data: Data("hello".utf8))
          }
          return try await sftp.attributes(at: destPath)
        }

        // 0o666 requested, reduced by the server's 022 umask.
        #expect((attrs.permissions! & 0o777) == 0o644)
      }
    }

    @Test func writeSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-small-test.dat"

        let data =
          Data((0..<1024).map { _ in UInt8.random(in: .min ... .max) })
        let expected = data.md5()

        try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: destPath, accessType: .writeOnly) {
            file in
            try await file.write(data: data)
          }
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }

    @Test func writeBigSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-big-test.dat"

        let data =
          Data((0..<1_048_576).map { _ in UInt8.random(in: .min ... .max) })
        let expected = data.md5()

        try await ssh.withSftp { sftp in
          try await sftp.withSftpFile(at: destPath, accessType: .writeOnly) {
            file in
            try await file.write(data: data)
          }
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }

    @Test func asyncWriterBufferLargerThanMaxWriteLengthSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-oversized-test.dat"

        let expected = try await ssh.withSftp { sftp -> String in
          let size = Int(sftp.limits.maxWriteLength) * 4
          let data = Data((0..<size).map { _ in UInt8.random(in: .min ... .max) })

          try await sftp.withSftpFile(at: destPath, accessType: .writeOnly) {
            file in
            try await file.withAsyncWriter { writer in
              try await writer.write(data: data)
            }
          }

          return data.md5()
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }

    @Test func asyncWriterDataSliceSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-slice-test.dat"

        let expected = try await ssh.withSftp { sftp -> String in
          let size = Int(sftp.limits.maxWriteLength) * 4
          let padding = 1024

          // Padding in front so the slice starts well clear of zero.
          let backing = Data(
            (0..<(size + padding)).map { _ in UInt8.random(in: .min ... .max) }
          )
          let slice = backing[(backing.startIndex + padding)...]

          try await sftp.withSftpFile(at: destPath, accessType: .writeOnly) {
            file in
            try await file.withAsyncWriter { writer in
              try await writer.write(data: slice)
            }
          }

          return Data(slice).md5()
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }
  }

  @Test func simultaneousDownloadsSucceed() async throws {
    try await withAuthenticatedClient { ssh in
      let path1 = "/tmp/simultaneous-1-test.dat"
      let path2 = "/tmp/simultaneous-2-test.dat"

      // Create two large files
      try await ssh.execute("dd if=/dev/urandom of=\(path1) bs=1M count=5")
      try await ssh.execute("dd if=/dev/urandom of=\(path2) bs=1M count=5")

      let expected1 = try await ssh.md5(ofFile: path1)
      let expected2 = try await ssh.md5(ofFile: path2)

      try await ssh.withSftp { sftp in
        async let md5_1 = sftp.withSftpFile(at: path1, accessType: .readOnly) { file in
          try await file.read().md5()
        }
        async let md5_2 = sftp.withSftpFile(at: path2, accessType: .readOnly) { file in
          try await file.read().md5()
        }

        let (actual1, actual2) = try await (md5_1, md5_2)

        #expect(actual1 == expected1)
        #expect(actual2 == expected2)
      }
    }
  }

  struct Lifecycle {
    @Test func sftpFileOperationAfterCloseThrowsClosed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()
      let path = "/tmp/swift-libssh-lifecycle-\(UUID().uuidString)"

      try await sftp.withSftpFile(at: path, accessType: .writeOnly) { file in
        try await file.write(data: Data("hello".utf8))

        await ssh.close()

        await #expect {
          _ = try await file.attributes()
        } throws: { error in
          (error as? SSHError)?.isClosed == true
        }
      }

      try? FileManager.default.removeItem(atPath: path)
    }

    @Test func sftpFileOperationAfterConnectionDropThrowsConnectionFailed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()
      let path = "/tmp/swift-libssh-lifecycle-\(UUID().uuidString)"

      try await sftp.withSftpFile(at: path, accessType: .readWrite) { file in
        try await file.write(data: Data("hello".utf8))

        await ssh.dropConnection()

        await #expect {
          _ = try await file.read()
        } throws: { error in
          (error as? SSHError)?.connectionFailure == .lost
        }
      }

      await sftp.close()
      await ssh.close()
      try? FileManager.default.removeItem(atPath: path)
    }

    @Test func sftpFileOperationAfterSftpCloseThrowsClosed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()
      let path = "/tmp/swift-libssh-lifecycle-\(UUID().uuidString)"

      try await sftp.withSftpFile(at: path, accessType: .writeOnly) { file in
        try await file.write(data: Data("hello".utf8))

        await sftp.close()

        await #expect {
          _ = try await file.attributes()
        } throws: { error in
          (error as? SSHError)?.isClosed == true
        }
      }

      await ssh.close()
      try? FileManager.default.removeItem(atPath: path)
    }
  }
}
