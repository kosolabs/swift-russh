import ArgumentParser
import Foundation
import SwiftRussh

struct SSHConfig: ParsableArguments {
  @Option(name: .shortAndLong, help: "The user to log in as on the remote machine")
  var loginName: String = ProcessInfo.processInfo.userName

  @Option(name: .shortAndLong, help: "Identity file to use as the private key")
  var identityFile: String

  @Option(name: .shortAndLong, help: "The port to connect to on the remote host")
  var port: UInt16 = 22

  @Option(name: .shortAndLong, help: "Session timeout in seconds")
  var timeout: UInt = 60

  @Argument(help: "The remote host to connect to")
  var host: String

  func connect() async throws -> SSHClient {
    try await SSHClient.connect(
      host: host, port: port, user: loginName,
      auth: .privateKey(contentsOf: URL(fileURLWithPath: identityFile)),
      hostKey: .acceptingAny, timeout: .seconds(timeout)
    )
  }

  func connectWithSftp() async throws -> (ssh: SSHClient, sftp: SFTPClient) {
    let ssh = try await connect()
    do {
      return (ssh, try await ssh.sftp())
    } catch {
      await ssh.close()
      throw error
    }
  }

  /// A connection with no SFTP client of its own. Each SFTP client costs one of
  /// the server's per-connection sessions (sshd `MaxSessions`, 10 by default), so
  /// topologies that open their own must not be charged for one they never use.
  func withSSHConnection<T>(_ body: (SSHClient) async throws -> T) async throws -> T {
    let ssh = try await connect()
    do {
      let result = try await body(ssh)
      await ssh.close()
      return result
    } catch {
      await ssh.close()
      throw error
    }
  }

  func withConnection<T>(_ body: (SSHClient, SFTPClient) async throws -> T) async throws -> T {
    let (ssh, sftp) = try await connectWithSftp()
    do {
      let result = try await body(ssh, sftp)
      await sftp.close()
      await ssh.close()
      return result
    } catch {
      await sftp.close()
      await ssh.close()
      throw error
    }
  }
}

@main
struct SwiftSSH: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "SwiftRussh CLI test tool",
    subcommands: [Upload.self, Download.self, Stress.self, StressTree.self]
  )
}
