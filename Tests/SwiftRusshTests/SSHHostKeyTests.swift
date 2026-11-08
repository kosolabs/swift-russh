import Foundation
import Testing

@testable import SwiftRussh

private let ed25519 =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIALP5YSWXJpkjStnmSGSkkeXGkyryGvYLszMja86gYhe"

struct SSHHostKeyTests {
  @Test func parsesKnownHostsKeyFields() throws {
    let key = try #require(SSHHostKey(ed25519))
    #expect(key.type == "ssh-ed25519")
    #expect(key.description == ed25519)
  }

  @Test func ignoresTrailingComment() throws {
    let key = try #require(SSHHostKey("\(ed25519) test@local"))
    #expect(key.description == ed25519)
  }

  @Test func fingerprintMatchesSSHKeygen() throws {
    let key = try #require(SSHHostKey(ed25519))
    #expect(key.fingerprint == "SHA256:AhIePRuUQiaORQD/iDaYVCB5n30ba1L2+S9RyUqfe0Y")
  }

  @Test(arguments: ["", "ssh-ed25519", "ssh-ed25519 not*base64"])
  func rejectsMalformedKeys(_ description: String) {
    #expect(SSHHostKey(description) == nil)
  }

  @Test func keysWithDifferentTypesAreNotEqual() throws {
    let key = try #require(SSHHostKey(ed25519))
    #expect(key != SSHHostKey(type: "ssh-rsa", blob: key.blob))
  }
}
