import Foundation
import Testing

@testable import SwiftRussh

struct SSHErrorTests {
  @Test func localizedDescriptionIsTheMessage() {
    let error: any Error = SSHError.sftp(.noSuchFile, message: "No such file: /tmp/missing")
    #expect(error.localizedDescription == "No such file: /tmp/missing")
  }

  @Test(
    arguments: [
      (1, SSHError.SFTPStatus.endOfFile),
      (2, .noSuchFile),
      (3, .permissionDenied),
      (4, .failure),
      (5, .badMessage),
      (6, .noConnection),
      (7, .connectionLost),
      (8, .operationUnsupported),
      (11, .fileAlreadyExists),
      (9, .failure),
    ] as [(UInt32, SSHError.SFTPStatus)])
  func sftpStatusFromCode(code: UInt32, expected: SSHError.SFTPStatus) {
    #expect(SSHError.SFTPStatus(code: code) == expected)
  }
}
