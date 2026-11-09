import Foundation
import Synchronization
import Testing

@testable import SwiftRussh

private final class Latch: Sendable {
  private let state = Mutex(false)

  var isSet: Bool {
    state.withLock { $0 }
  }

  func signal() {
    state.withLock { $0 = true }
  }
}

private struct WedgedError: Error, CustomStringConvertible {
  let seconds: Double
  var description: String {
    "SFTP session made no progress for \(seconds)s"
  }
}

private func withWatchdog(
  seconds: Double = 30, _ body: @escaping @Sendable () async throws -> Void
) async throws {
  let latch = Latch()
  let task = Task {
    defer { latch.signal() }
    try await body()
  }

  let deadline = Date().addingTimeInterval(seconds)
  while !latch.isSet && Date() < deadline {
    try? await Task.sleep(for: .milliseconds(50))
  }

  guard latch.isSet else {
    throw WedgedError(seconds: seconds)
  }
  try await task.value
}

struct SFTPConcurrencyTests {
  @Test func cancellationOfForAwaitLoopOverSftpStreamSucceeds() async throws {
    try await withAuthenticatedClient { ssh in
      try await ssh.execute("dd if=/dev/urandom of=/tmp/drain.dat bs=1M count=1")

      let expected = try await ssh.withSFTP { sftp in
        try await sftp.attributes(at: "/tmp/drain.dat").size!
      }

      let actual = try await ssh.withSFTP { sftp in
        try await sftp.withFile(at: "/tmp/drain.dat", access: .readOnly) { file in
          for try await chunk in file.stream() {
            // Returning here causes stream to cancel
            return chunk
          }
          fatalError("Stream should not complete")
        }
      }

      #expect(actual.count > 0)
      #expect(actual.count < expected)
    }
  }

  @Test func singleRequestStreamDuringConcurrentUploadSucceeds() async throws {
    let remoteSource = "/tmp/single-request-source.dat"
    let remoteUpload = "/tmp/single-request-upload.dat"
    let localUpload = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("single-request-upload.dat")
    defer { try? FileManager.default.removeItem(at: localUpload) }

    try await withWatchdog {
      try await withAuthenticatedClient { ssh in
        try await ssh.execute("dd if=/dev/urandom of=\(remoteSource) bs=1M count=8")
        try shell("dd if=/dev/urandom of=\(localUpload.path) bs=1m count=4")

        let sftp = try await ssh.sftp()
        let window = sftp.limits.maxReadLength

        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            try? await sftp.upload(
              from: localUpload, to: remoteUpload, bufferSize: sftp.limits.maxWriteLength
            )
          }

          group.addTask {
            try? await sftp.withFile(at: remoteSource, access: .readOnly) { file in
              for try await _ in file.stream(..<UInt64(window), bufferSize: window) {}
            }
          }
        }

        // The session has to still be good for something afterwards.
        let attributes = try await sftp.attributes(at: remoteSource)
        #expect(attributes.size == 8 * 1024 * 1024)

        try await ssh.execute("rm -f /tmp/single-request-*.dat")
        await sftp.close()
      }
    }
  }

  @Test func pipelinedStreamDuringConcurrentUploadSucceeds() async throws {
    let remoteSource = "/tmp/pipelined-source.dat"
    let remoteUpload = "/tmp/pipelined-upload.dat"
    let localUpload = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pipelined-upload.dat")
    defer { try? FileManager.default.removeItem(at: localUpload) }

    try await withWatchdog {
      try await withAuthenticatedClient { ssh in
        try await ssh.execute("dd if=/dev/urandom of=\(remoteSource) bs=1M count=8")
        try shell("dd if=/dev/urandom of=\(localUpload.path) bs=1m count=4")

        let sftp = try await ssh.sftp()
        let window = sftp.limits.maxReadLength

        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            try? await sftp.upload(
              from: localUpload, to: remoteUpload, bufferSize: sftp.limits.maxWriteLength
            )
          }

          group.addTask {
            try? await sftp.withFile(at: remoteSource, access: .readOnly) { file in
              for try await _ in file.stream(bufferSize: window) {}
            }
          }
        }

        // The session has to still be good for something afterwards.
        let attributes = try await sftp.attributes(at: remoteSource)
        #expect(attributes.size == 8 * 1024 * 1024)

        try await ssh.execute("rm -f /tmp/pipelined-*.dat")
        await sftp.close()
      }
    }
  }

  @Test func closingSftpClientDuringDownloadSucceeds() async throws {
    let remoteSource = "/tmp/close-during-download.dat"
    let localDownload = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("close-during-download.dat")
    defer { try? FileManager.default.removeItem(at: localDownload) }

    try await withWatchdog {
      try await withAuthenticatedClient { ssh in
        try await ssh.execute("dd if=/dev/urandom of=\(remoteSource) bs=1M count=64")

        for _ in 0..<5 {
          let sftp = try await ssh.sftp()
          let started = Latch()

          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              try? await sftp.download(from: remoteSource, to: localDownload) { count in
                if count > 0 { started.signal() }
              }
            }

            group.addTask {
              while !started.isSet {
                await Task.yield()
              }
              await sftp.close()
            }
          }
        }

        let result = try await ssh.execute("echo alive")
        #expect(try result.stdout.decoded(as: .utf8) == "alive\n")

        try await ssh.execute("rm -f \(remoteSource)")
      }
    }
  }
}
