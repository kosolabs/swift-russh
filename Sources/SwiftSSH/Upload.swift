import ArgumentParser
import Foundation
import SwiftRussh

struct Upload: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Upload a file"
  )

  @OptionGroup var sshConfig: SSHConfig

  @Argument(help: "Local source file path")
  var src: String

  @Argument(help: "Remote destination file path")
  var dst: String

  @Option(help: "Permissions")
  var mode: mode_t = 0o644

  @Option(help: "Buffer size")
  var bufferSize: Int = SFTPLimits.defaultBufferSize

  func run() async throws {
    try await sshConfig.withConnection { ssh, sftp in
      let fp = try FileHandle(forReadingFrom: URL(filePath: src))
      let speedometer = Speedometer(total: try fp.seekToEnd())
      try fp.seek(toOffset: 0)

      try await sftp.withFile(
        at: dst, access: .writeOnly, options: [.create, .truncate], permissions: mode
      ) { file in
        try await file.upload(from: URL(filePath: src), bufferSize: bufferSize) { completed in
          if let progress = speedometer.update(completed: Int(completed)) {
            print("Uploading from \(src) to \(dst): \(progress)")
          }
        }
      }
      print("Uploaded \(src) to \(dst): \(speedometer.finalize())")
    }
  }
}
