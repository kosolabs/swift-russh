import Foundation
import Testing

@testable import SwiftRussh

struct SFTPFileTests {
  struct Attributes {
    @Test func attributesSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/stat-file-test.dat"
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1024 count=1")

        let attrs = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: path, access: .readOnly) { file in
            try await file.attributes()
          }
        }

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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            try await file.read(0..<1024).md5()
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            try await file.read(range).md5()
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            try await file.read(offset..<offset + length).md5()
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            try await file.read().md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func readMissingFileThrowsNoSuchFile() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSFTP { sftp in
            try await sftp.withFile(at: "/tmp/nonexistent.dat", access: .readOnly) {
              file in
              try await file.read()
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }

    @Test func readRestrictedThrowsPermissionDenied() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          let srcPath = "/tmp/restricted.dat"
          try await ssh.execute("touch \(srcPath)")
          try await ssh.execute("chmod 000 \(srcPath)")

          try await ssh.withSFTP { sftp in
            try await sftp.withFile(at: srcPath, access: .readOnly) { file in
              for try await _ in file.stream(..<1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .permissionDenied
      }
    }

    @Test func readDirectoryThrowsFailed() async throws {
      await #expect {
        try await withAuthenticatedClient { ssh in
          try await ssh.withSFTP { sftp in
            try await sftp.withFile(at: "/tmp", access: .readOnly) { file in
              for try await _ in file.stream(..<1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .failure
      }
    }
  }

  struct Stream {
    @Test func streamRangeSmallSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-range-small-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1024 count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(0..<1024) {
              result.append(data)
            }
            return result.md5()
          }
        }

        #expect(actual == expected)
      }
    }

    @Test func streamIsConsumableFromConcurrentTasks() async throws {
      try await withAuthenticatedClient { ssh in
        let srcPath = "/tmp/stream-concurrent-tasks-test.dat"

        try await ssh.execute("dd if=/dev/urandom of=\(srcPath) bs=1M count=1")
        let expected = try await ssh.md5(ofFile: srcPath)

        let digests = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            let stream = file.stream()
            return try await withThrowingTaskGroup(of: String.self) { group in
              for _ in 0..<2 {
                group.addTask {
                  var result = Data()
                  for try await data in stream { result.append(data) }
                  return result.md5()
                }
              }
              return try await group.reduce(into: []) { $0.append($1) }
            }
          }
        }

        #expect(digests == [expected, expected])
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(range) {
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(..<1024) {
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(offset..<offset + length) {
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

        let actual = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: srcPath, access: .readOnly) { file in
            var result = Data()
            for try await data in file.stream(..<1_048_576) {
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
          try await ssh.withSFTP { sftp in
            try await sftp.withFile(at: "/tmp/nonexistent.dat", access: .readOnly) {
              file in
              for try await _ in file.stream(..<1024) {}
            }
          }
        }
      } throws: { error in
        (error as? SSHError)?.sftpStatus == .noSuchFile
      }
    }
  }

  struct Write {
    @Test func createdFileDefaultModeDelegatesToServerUmask() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-default-mode.dat"
        try await ssh.execute("rm -f \(destPath)")

        let attrs = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: destPath, access: .writeOnly, options: [.create, .truncate]) {
            file in
            try await file.write(contentsOf: Data("hello".utf8), at: 0)
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

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: destPath, access: .writeOnly, options: [.create, .truncate]) {
            file in
            try await file.write(contentsOf: data, at: 0)
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

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: destPath, access: .writeOnly, options: [.create, .truncate]) {
            file in
            try await file.write(contentsOf: data, at: 0)
          }
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }

    @Test func asyncWriterBufferLargerThanMaxWriteLengthSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let destPath = "/tmp/write-oversized-test.dat"

        let expected = try await ssh.withSFTP { sftp -> String in
          let size = Int(sftp.limits.maxWriteLength) * 4
          let data = Data((0..<size).map { _ in UInt8.random(in: .min ... .max) })

          try await sftp.withFile(at: destPath, access: .writeOnly, options: [.create, .truncate]) {
            file in
            try await file.withWriter { writer in
              try await writer.write(contentsOf: data)
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

        let expected = try await ssh.withSFTP { sftp -> String in
          let size = Int(sftp.limits.maxWriteLength) * 4
          let padding = 1024

          // Padding in front so the slice starts well clear of zero.
          let backing = Data(
            (0..<(size + padding)).map { _ in UInt8.random(in: .min ... .max) }
          )
          let slice = backing[(backing.startIndex + padding)...]

          try await sftp.withFile(at: destPath, access: .writeOnly, options: [.create, .truncate]) {
            file in
            try await file.withWriter { writer in
              try await writer.write(contentsOf: slice)
            }
          }

          return Data(slice).md5()
        }

        let actual = try await ssh.md5(ofFile: destPath)

        #expect(actual == expected)
      }
    }
  }

  struct Open {
    @Test func writeOnlyWithoutCreateOnMissingFileThrowsNoSuchFile() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/open-no-create-\(UUID().uuidString).dat"

        try await ssh.withSFTP { sftp in
          await #expect {
            try await sftp.withFile(at: path, access: .writeOnly) { _ in }
          } throws: { error in
            (error as? SSHError)?.sftpStatus == .noSuchFile
          }
        }
      }
    }

    @Test func writeWithoutTruncatePreservesTheRestOfTheFile() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/open-no-truncate.txt"
        try await ssh.execute("printf 0123456789 > \(path)")

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: path, access: .writeOnly) { file in
            try await file.write(contentsOf: Data("ab".utf8), at: 0)
          }
        }

        #expect(try await ssh.execute("cat \(path)").stdout == Data("ab23456789".utf8))
      }
    }

    @Test func appendWritesAtTheEndOfTheFile() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/open-append.txt"
        try await ssh.execute("printf abc > \(path)")

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: path, access: .writeOnly, options: .append) { file in
            try await file.write(contentsOf: Data("def".utf8), at: 0)
          }
        }

        #expect(try await ssh.execute("cat \(path)").stdout == Data("abcdef".utf8))
      }
    }

    @Test func exclusiveCreateOfExistingFileThrowsFileAlreadyExists() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/open-exclusive.txt"
        try await ssh.execute("touch \(path)")

        try await ssh.withSFTP { sftp in
          await #expect {
            try await sftp.withFile(
              at: path, access: .writeOnly, options: [.create, .exclusiveCreate]
            ) { _ in }
          } throws: { error in
            (error as? SSHError)?.sftpStatus == .fileAlreadyExists
          }
        }
      }
    }

    @Test func exclusiveCreateOfMissingFileCreatesIt() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/open-exclusive-\(UUID().uuidString).txt"

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(
            at: path, access: .writeOnly, options: [.create, .exclusiveCreate]
          ) { file in
            try await file.write(contentsOf: Data("new".utf8), at: 0)
          }
        }

        #expect(try await ssh.execute("cat \(path)").stdout == Data("new".utf8))
        try await ssh.execute("rm -f \(path)")
      }
    }
  }

  struct Positional {
    @Test func writesLandAtTheirOffsetsInAnyOrder() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/positional-write.txt"

        try await ssh.withSFTP { sftp in
          try await sftp.withFile(
            at: path, access: .writeOnly, options: [.create, .truncate]
          ) { file in
            try await file.write(contentsOf: Data("world".utf8), at: 5)
            try await file.write(contentsOf: Data("hello".utf8), at: 0)
          }
        }

        #expect(try await ssh.execute("cat \(path)").stdout == Data("helloworld".utf8))
      }
    }

    @Test func readAcceptsAnyRangeExpression() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/positional-ranges.txt"
        try await ssh.execute("printf 0123456789 > \(path)")

        let reads = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: path, access: .readOnly) { file in
            try await [file.read(), file.read(4...), file.read(..<3), file.read(2...4)]
          }
        }

        #expect(
          reads.map { String(decoding: $0, as: UTF8.self) } == [
            "0123456789", "456789", "012", "234",
          ])
      }
    }

    @Test func concurrentReadsOfOneFileDoNotInterfere() async throws {
      try await withAuthenticatedClient { ssh in
        let path = "/tmp/positional-concurrent-read.dat"
        let half: UInt64 = 1_048_576
        try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1M count=2")
        let expectedFirst = try await ssh.md5(ofFile: path, offset: 0, length: half)
        let expectedSecond = try await ssh.md5(ofFile: path, offset: half, length: half)

        let (first, second) = try await ssh.withSFTP { sftp in
          try await sftp.withFile(at: path, access: .readOnly) { file in
            async let first = file.read(..<half, bufferSize: 4096)
            async let second = file.read(half..<2 * half, bufferSize: 4096)
            return try await (first.md5(), second.md5())
          }
        }

        #expect(first == expectedFirst)
        #expect(second == expectedSecond)
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

      try await ssh.withSFTP { sftp in
        async let md5_1 = sftp.withFile(at: path1, access: .readOnly) { file in
          try await file.read().md5()
        }
        async let md5_2 = sftp.withFile(at: path2, access: .readOnly) { file in
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

      try await sftp.withFile(at: path, access: .writeOnly, options: [.create, .truncate]) { file in
        try await file.write(contentsOf: Data("hello".utf8), at: 0)

        await ssh.close()

        await #expect {
          _ = try await file.attributes()
        } throws: { error in
          if case .closed? = error as? SSHError { true } else { false }
        }
      }

      try? FileManager.default.removeItem(atPath: path)
    }

    @Test func sftpFileOperationAfterConnectionDropThrowsConnectionFailed() async throws {
      let ssh = try await client()
      let sftp = try await ssh.sftp()
      let path = "/tmp/swift-libssh-lifecycle-\(UUID().uuidString)"

      try await sftp.withFile(at: path, access: .readWrite, options: [.create, .truncate]) { file in
        try await file.write(contentsOf: Data("hello".utf8), at: 0)

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

      try await sftp.withFile(at: path, access: .writeOnly, options: [.create, .truncate]) { file in
        try await file.write(contentsOf: Data("hello".utf8), at: 0)

        await sftp.close()

        await #expect {
          _ = try await file.attributes()
        } throws: { error in
          if case .closed? = error as? SSHError { true } else { false }
        }
      }

      await ssh.close()
      try? FileManager.default.removeItem(atPath: path)
    }
  }
}
