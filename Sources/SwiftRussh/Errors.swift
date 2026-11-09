import Foundation
import RusshFFI

public enum StreamType: Int32, Sendable {
  case stdout = 0
  case stderr = 1

  var kind: StreamKind {
    switch self {
    case .stdout: .stdout
    case .stderr: .stderr
    }
  }
}

public enum SSHError: Error, Sendable {
  case connectionFailed(ConnectionFailure, message: String)
  case closed(message: String)
  case authenticationFailed(message: String)
  case hostKeyMismatch(expected: SSHHostKey, actual: SSHHostKey, message: String)
  case privateKey(PrivateKeyFailure, message: String)
  case sftp(SFTPStatus, message: String)
  case channelOpenFailed(message: String)
  case invalidState(message: String)

  public enum ConnectionFailure: Hashable, Sendable {
    case unknownHost
    case refused
    case timedOut
    case lost
    case other
  }

  public enum PrivateKeyFailure: Hashable, Sendable {
    case unreadable
    case passphraseRequired
    case invalid
  }

  public enum SFTPStatus: Hashable, Sendable {
    case endOfFile
    case noSuchFile
    case permissionDenied
    case failure
    case badMessage
    case noConnection
    case connectionLost
    case operationUnsupported
    case fileAlreadyExists
  }

  public var message: String {
    switch self {
    case .connectionFailed(_, let message),
      .closed(let message),
      .authenticationFailed(let message),
      .hostKeyMismatch(_, _, let message),
      .privateKey(_, let message),
      .sftp(_, let message),
      .channelOpenFailed(let message),
      .invalidState(let message):
      message
    }
  }

  public var connectionFailure: ConnectionFailure? {
    guard case .connectionFailed(let failure, _) = self else { return nil }
    return failure
  }

  public var privateKeyFailure: PrivateKeyFailure? {
    guard case .privateKey(let failure, _) = self else { return nil }
    return failure
  }

  public var sftpStatus: SFTPStatus? {
    guard case .sftp(let status, _) = self else { return nil }
    return status
  }
}

extension SSHError: LocalizedError {
  public var errorDescription: String? { message }
}

extension SSHError {
  init(_ error: RusshError) {
    switch error {
    case .ConnectionFailed(let kind, let message):
      self = .connectionFailed(ConnectionFailure(kind), message: message)
    case .Closed(let message):
      self = .closed(message: message)
    case .AuthenticationFailed(let message):
      self = .authenticationFailed(message: message)
    case .Key(let kind, let message):
      self = .privateKey(
        kind == .passphraseRequired ? .passphraseRequired : .invalid, message: message)
    case .Sftp(let code, let message):
      self = .sftp(SFTPStatus(code: code), message: message)
    case .ChannelOpenFailed(let message):
      self = .channelOpenFailed(message: message)
    case .InvalidState(let message):
      self = .invalidState(message: message)
    }
  }
}

extension SSHError.ConnectionFailure {
  init(_ kind: ConnectionFailureKind) {
    switch kind {
    case .unknownHost: self = .unknownHost
    case .refused: self = .refused
    case .timedOut: self = .timedOut
    case .lost: self = .lost
    case .other: self = .other
    }
  }
}

extension SSHError.SFTPStatus {
  init(code: UInt32) {
    switch code {
    case 1: self = .endOfFile
    case 2: self = .noSuchFile
    case 3: self = .permissionDenied
    case 5: self = .badMessage
    case 6: self = .noConnection
    case 7: self = .connectionLost
    case 8: self = .operationUnsupported
    case 11: self = .fileAlreadyExists
    default: self = .failure
    }
  }
}

nonisolated(nonsending) func bridge<T>(
  _ body: nonisolated(nonsending) () async throws -> T
) async throws(SSHError) -> T {
  do {
    return try await body()
  } catch let error as RusshError {
    throw SSHError(error)
  } catch {
    throw .invalidState(message: "\(error)")
  }
}

func bridge<T>(_ body: () throws -> T) throws(SSHError) -> T {
  do {
    return try body()
  } catch let error as RusshError {
    throw SSHError(error)
  } catch {
    throw .invalidState(message: "\(error)")
  }
}
