import Foundation
import Testing

@testable import SwiftRussh

private final class Tally {
  var count = 0
}

private actor Recorder {
  var names: [String] = []
  var progress: [UInt64] = []

  func list(_ path: String, with sftp: SFTPClient) async throws -> Int {
    let tally = try await sftp.withDirectory(at: path) { directory in
      let tally = Tally()
      for try await entry in directory {
        names.append(entry.name)
        tally.count += 1
      }
      return tally
    }
    return tally.count
  }

  func download(_ path: String, to url: URL, with sftp: SFTPClient) async throws {
    try await sftp.download(from: path, to: url, bufferSize: 1024) { bytes in
      self.progress.append(bytes)
    }
  }
}

struct CallerIsolationTests {
  @Test func closuresRunOnTheCallersActor() async throws {
    try await withAuthenticatedClient { ssh in
      let dirPath = "/tmp/test-caller-isolation"
      try await ssh.execute(
        "rm -rf \(dirPath) && mkdir \(dirPath) && head -c 3072 /dev/zero > \(dirPath)/a && touch \(dirPath)/b"
      )
      let local = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: local) }

      let recorder = Recorder()
      let count = try await ssh.withSFTP { sftp in
        try await recorder.download("\(dirPath)/a", to: local, with: sftp)
        return try await recorder.list(dirPath, with: sftp)
      }

      #expect(count == 2)
      #expect(await recorder.names.sorted() == ["a", "b"])
      #expect(await recorder.progress == [1024, 2048, 3072])
    }
  }
}
