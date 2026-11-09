import Foundation
import RusshFFI

public enum AccessType: Sendable {
  case readOnly
  case writeOnly
  case readWrite

  var mode: AccessMode {
    switch self {
    case .readOnly: .readOnly
    case .writeOnly: .writeOnly
    case .readWrite: .readWrite
    }
  }
}

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

public enum SFTPError: Codable, Error, Sendable, Equatable {
  case eof
  case noSuchFile
  case permissionDenied
  case failure
  case badMessage
  case noConnection
  case connectionLost
  case opUnsupported
  case invalidHandle
  case noSuchPath
  case fileAlreadyExists
  case writeProtect
  case noMedia

  static func from(code: UInt32) -> SFTPError? {
    switch code {
    case 1: .eof
    case 2: .noSuchFile
    case 3: .permissionDenied
    case 4: .failure
    case 5: .badMessage
    case 6: .noConnection
    case 7: .connectionLost
    case 8: .opUnsupported
    case 9: .invalidHandle
    case 10: .noSuchPath
    case 11: .fileAlreadyExists
    case 12: .writeProtect
    case 13: .noMedia
    default: nil
    }
  }
}

public enum ConnectionFailure: Codable, Sendable, Equatable {
  case unknownHost
  case refused
  case timedOut
  case lost
  case other

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

public enum SSHKeyError: Codable, Error, Sendable, Equatable {
  case unreadable
  case passphraseRequired
  case invalid
}

public enum SSHError: Codable, Error, Sendable, Equatable {
  case connectionFailed(ConnectionFailure, message: String)
  case closed(message: String)
  case authenticationFailed(message: String)
  case hostKeyMismatch(expected: SSHHostKey, actual: SSHHostKey, message: String)
  case keyError(SSHKeyError, message: String)
  case sftpError(SFTPError, message: String)
  case channelOpenFailed(message: String)
  case localFileError(message: String)
  case libraryError(code: Int32, message: String)
  case invalidState(message: String)

  init(_ error: RusshError) {
    switch error {
    case .ConnectionFailed(let kind, let message):
      self = .connectionFailed(ConnectionFailure(kind), message: message)
    case .Closed(let message):
      self = .closed(message: message)
    case .AuthenticationFailed(let message):
      self = .authenticationFailed(message: message)
    case .Key(let kind, let message):
      self = .keyError(kind == .passphraseRequired ? .passphraseRequired : .invalid, message: message)
    case .Sftp(let code, let message):
      if let sftpError = SFTPError.from(code: code) {
        self = .sftpError(sftpError, message: message)
      } else {
        self = .libraryError(code: Int32(bitPattern: code), message: message)
      }
    case .ChannelOpenFailed(let message):
      self = .channelOpenFailed(message: message)
    case .InvalidState(let message):
      self = .invalidState(message: message)
    }
  }

  public var isConnectionFailed: Bool {
    if case .connectionFailed = self { return true }
    return false
  }

  public var connectionFailure: ConnectionFailure? {
    guard case .connectionFailed(let failure, _) = self else { return nil }
    return failure
  }

  public var isClosed: Bool {
    if case .closed = self { return true }
    return false
  }

  public var isAuthenticationFailed: Bool {
    if case .authenticationFailed = self { return true }
    return false
  }

  public var isHostKeyMismatch: Bool {
    if case .hostKeyMismatch = self { return true }
    return false
  }

  public var keyError: SSHKeyError? {
    guard case .keyError(let error, _) = self else { return nil }
    return error
  }

  public var sftpError: SFTPError? {
    guard case .sftpError(let error, _) = self else { return nil }
    return error
  }

  public var isChannelOpenFailed: Bool {
    if case .channelOpenFailed = self { return true }
    return false
  }

  public var isLocalFileError: Bool {
    if case .localFileError = self { return true }
    return false
  }

  public var isLibraryError: Bool {
    if case .libraryError = self { return true }
    return false
  }

  public var isInvalidState: Bool {
    if case .invalidState = self { return true }
    return false
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
