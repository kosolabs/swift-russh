import Foundation
import Testing

@testable import SwiftRussh

private func cancelCurrentTask() {
  withUnsafeCurrentTask { $0?.cancel() }
}

struct CancellationTests {
  @Test func cancellingChannelStreamThrowsCancellationError() async throws {
    try await withAuthenticatedClient { ssh in
      let task = Task {
        try await ssh.execute("dd if=/dev/urandom bs=1000000 count=1 of=/dev/stdout") { channel in
          for try await _ in channel.stream(from: .stdout) {
            cancelCurrentTask()
          }
        }
      }

      await #expect(throws: CancellationError.self) { try await task.value }
    }
  }

  @Test func cancellingFileStreamThrowsCancellationError() async throws {
    try await withAuthenticatedClient { ssh in
      let path = "/tmp/cancel-stream.dat"
      try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1M count=1")

      try await ssh.withSftp { sftp in
        let task = Task {
          try await sftp.withFile(at: path, access: .readOnly) { file in
            for try await _ in file.stream(bufferSize: 1024) {
              cancelCurrentTask()
            }
          }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
      }
    }
  }

  @Test func cancellingDirectoryIterationThrowsCancellationError() async throws {
    try await withAuthenticatedClient { ssh in
      let path = "/tmp/cancel-directory"
      try await ssh.execute(
        "rm -rf \(path) && mkdir \(path) && touch \(path)/a \(path)/b \(path)/c")

      try await ssh.withSftp { sftp in
        let task = Task {
          try await sftp.withDirectory(at: path) { directory in
            for try await _ in directory {
              cancelCurrentTask()
            }
          }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
      }
    }
  }

  @Test func cancellingDownloadThrowsCancellationError() async throws {
    try await withAuthenticatedClient { ssh in
      let path = "/tmp/cancel-download.dat"
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancel-download.dat")
      defer { try? FileManager.default.removeItem(at: destination) }
      try await ssh.execute("dd if=/dev/urandom of=\(path) bs=1M count=1")

      try await ssh.withSftp { sftp in
        let task = Task {
          try await sftp.download(from: path, to: destination, bufferSize: 1024) { _ in
            cancelCurrentTask()
          }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
      }
    }
  }

  @Test func cancellingUploadThrowsCancellationError() async throws {
    try await withAuthenticatedClient { ssh in
      let source = FileManager.default.temporaryDirectory
        .appendingPathComponent("cancel-upload.dat")
      defer { try? FileManager.default.removeItem(at: source) }
      try Data(count: 1_048_576).write(to: source)

      try await ssh.withSftp { sftp in
        let task = Task {
          try await sftp.upload(from: source, to: "/tmp/cancel-upload.dat", bufferSize: 1024) {
            _ in
            cancelCurrentTask()
          }
        }

        await #expect(throws: CancellationError.self) { try await task.value }
      }
    }
  }
}
