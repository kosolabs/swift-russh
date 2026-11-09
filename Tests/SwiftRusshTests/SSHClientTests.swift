import Foundation
import Testing

@testable import SwiftRussh

struct SSHClientTests {
  struct Execute {
    @Test func executeSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let expected = "hello"

        let proc = try await ssh.execute("echo '\(expected)'")

        let actual = try proc.stdout
          .decoded(as: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(actual == expected)
      }
    }

    @Test func executeMoreThanOnceSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let actual1 = try await ssh.execute("whoami")
          .stdout
          .decoded(as: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)

        let actual2 = try await ssh.execute("whoami")
          .stdout
          .decoded(as: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(actual1 == actual2)
      }
    }

    @Test func executeInvalidCommandReturnsErrorStatusCode() async throws {
      try await withAuthenticatedClient { ssh in
        let proc = try await ssh.execute("blah")

        #expect(proc.status == .exited(code: 127))
      }
    }

    @Test func executeWithStderrSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let proc = try await ssh.execute("echo 'custom error' >&2")

        let stderr = try proc.stderr
          .decoded(as: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(stderr == "custom error")
        #expect(proc.status == .exited(code: 0))
      }
    }

    @Test func channelStreamsStdoutAndStderrSeparately() async throws {
      try await withAuthenticatedClient { ssh in
        let (stdout, stderr, status) = try await ssh.execute("echo out; echo err >&2") { channel in
          var stdout = Data()
          for try await chunk in channel.stdout { stdout.append(chunk) }
          var stderr = Data()
          for try await chunk in channel.stderr { stderr.append(chunk) }
          return (stdout, stderr, try await channel.exitStatus())
        }

        #expect(stdout == Data("out\n".utf8))
        #expect(stderr == Data("err\n".utf8))
        #expect(status == .exited(code: 0))
      }
    }

    @Test func executeWithSignalSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let proc = try await ssh.execute("kill -9 $$")

        #expect(proc.status == .signaled(signal: "KILL", coreDumped: false))
      }
    }

    @Test func executeWithLargerOutputSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let proc = try await ssh.execute(
          "for i in {1..500}; do echo 'Hello world'; done"
        )
        let actual = try proc.stdout.decoded(as: .utf8)

        let expected = Array(repeating: "Hello world\n", count: 500).joined()
        #expect(actual == expected)
        #expect(proc.status == .exited(code: 0))
      }
    }

    @Test func cancellationOfForAwaitLoopOverChannelStreamSucceeds() async throws {
      try await withAuthenticatedClient { ssh in
        let expected = 1_000_000
        let actual = try await ssh.execute(
          "dd if=/dev/urandom bs=\(expected) count=1 of=/dev/stdout"
        ) { channel in
          for try await data in channel.stdout {
            // Returning here causes stream to cancel
            return data
          }
          fatalError("Stream should not complete")
        }

        #expect(actual.count > 0)
        #expect(actual.count < expected)
      }
    }

    @Test func executeAfterCloseThrowsClosed() async throws {
      let ssh = try await client()

      await ssh.close()

      await #expect {
        try await ssh.execute("whoami")
      } throws: { error in
        if case .closed? = error as? SSHError { true } else { false }
      }
    }
  }

  struct ChannelLimits {
    @Test func exhaustingSftpChannelsThrowsChannelOpenFailed() async throws {
      try await withAuthenticatedClient { ssh in
        var clients: [SFTPClient] = []
        var caught: SSHError?

        for _ in 0..<64 {
          do {
            clients.append(try await ssh.sftp())
          } catch let error as SSHError {
            caught = error
            break
          }
        }

        for client in clients { await client.close() }

        guard case .channelOpenFailed? = caught else {
          Issue.record("Expected channelOpenFailed, got \(String(describing: caught))")
          return
        }
      }
    }

    @Test func exhaustingExecuteChannelsThrowsChannelOpenFailed() async throws {
      try await withAuthenticatedClient { ssh in
        let failures = await withTaskGroup(of: SSHError?.self) { group in
          for _ in 0..<64 {
            group.addTask {
              do {
                _ = try await ssh.execute("sleep 2")
                return nil
              } catch let error as SSHError {
                return error
              } catch {
                return nil
              }
            }
          }

          var seen: [SSHError] = []
          for await result in group {
            if let result { seen.append(result) }
          }
          return seen
        }

        #expect(!failures.isEmpty)
        #expect(failures.allSatisfy { if case .channelOpenFailed = $0 { true } else { false } })
      }
    }
  }

  struct Lifecycle {
    @Test func connectedStatusIsConsistent() async throws {
      let ssh = try await client()

      #expect(await ssh.isConnected)

      await ssh.close()

      #expect(!(await ssh.isConnected))
    }

    @Test func executeAfterConnectionDropThrowsConnectionFailed() async throws {
      let ssh = try await client()

      await ssh.dropConnection()

      await #expect {
        try await ssh.execute("whoami")
      } throws: { error in
        (error as? SSHError)?.connectionFailure == .lost
      }

      #expect(!(await ssh.isConnected))

      await ssh.close()
    }

    @Test func testMultipleCallsToClose() async throws {
      let ssh = try await client()

      #expect(await ssh.isConnected)

      await ssh.close()
      await ssh.close()

      #expect(!(await ssh.isConnected))
    }
  }

  @Test func executeAfterCloseThrowsClosed() async throws {
    let ssh = try await client()
    await ssh.close()

    await #expect {
      _ = try await ssh.execute("whoami")
    } throws: { error in
      if case .closed? = error as? SSHError { true } else { false }
    }
  }
}
