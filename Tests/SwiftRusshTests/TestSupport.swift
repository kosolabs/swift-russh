import CryptoKit
import Foundation

@testable import SwiftRussh

@discardableResult
func shell(_ command: String) throws -> (status: Int32, stdout: Data, stderr: Data) {
  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()

  process.standardOutput = stdout
  process.standardError = stderr
  process.executableURL = URL(fileURLWithPath: "/bin/bash")
  process.arguments = ["-c", command]

  try process.run()
  process.waitUntilExit()

  return (
    process.terminationStatus,
    stdout.fileHandleForReading.readDataToEndOfFile(),
    stderr.fileHandleForReading.readDataToEndOfFile()
  )
}

func md5(
  ofFile path: String, offset: UInt64 = 0, length: UInt64 = UInt64(UInt32.max)
) throws -> String {
  let command = "tail -c +\(offset + 1) \(path) | head -c \(length) | md5sum"
  return try shell(command)
    .stdout
    .decoded(as: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .split(separator: " ")[0]
    .lowercased()
}

struct TestError: Error {
  let message: String
}

extension Data {
  func md5() -> String {
    let digest = Insecure.MD5.hash(data: self)
    return digest.map { String(format: "%02hhx", $0) }.joined()
  }

  func decoded(as encoding: String.Encoding) throws -> String {
    guard let str = String(data: self, encoding: encoding) else {
      throw TestError(message: "Failed to decode data as \(encoding)")
    }
    return str
  }
}

extension SSHClient {
  func dropConnection() async {
    _ = try? await execute("kill -9 $PPID")
  }

  func md5(
    ofFile path: String, offset: UInt64 = 0, length: UInt64 = UInt64(UInt32.max)
  ) async throws -> String {
    let command = "tail -c +\(offset + 1) \(path) | head -c \(length) | md5sum"
    return try await self.execute(command)
      .stdout
      .decoded(as: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ")[0]
      .lowercased()
  }
}
