import ArgumentParser
import Foundation
import SwiftRussh

struct Download: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Download a file"
  )

  @OptionGroup var sshConfig: SSHConfig

  @Argument(help: "Remote source file path")
  var src: String

  @Argument(help: "Local destination file path")
  var dst: String

  @Option(help: "Buffer size")
  var bufferSize: UInt64 = SFTPLimits.defaultBufferSize

  func run() async throws {
    try await sshConfig.withConnection { ssh, sftp in
      let attrs = try await sftp.attributes(at: src)
      let speedometer = Speedometer(total: attrs.size ?? 0)

      try await sftp.withSftpFile(at: src, accessType: .readOnly) { file in
        try await file.download(to: URL(filePath: dst), bufferSize: bufferSize) { completed in
          if let progress = speedometer.update(completed: Int(completed)) {
            print("Downloading from \(src) to \(dst): \(progress)")
          }
        }
      }
      print("Downloaded from \(src) to \(dst): \(speedometer.finalize())")
    }
  }
}
