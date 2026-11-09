import Foundation
import RusshFFI

public struct SFTPDirectory: Sendable, AsyncSequence {
  private let cursor: Cursor

  init(_ directory: Directory) {
    cursor = Cursor(directory)
  }

  func read() async throws(SSHError) -> SFTPAttributes? {
    while true {
      guard let attrs = try await cursor.next() else {
        return nil
      }

      if attrs.name == "" || attrs.name == "." || attrs.name == ".." {
        continue
      }
      return attrs
    }
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(directory: self)
  }

  public struct Iterator: AsyncIteratorProtocol {
    private let directory: SFTPDirectory

    init(directory: SFTPDirectory) {
      self.directory = directory
    }

    public func next() async throws -> SFTPAttributes? {
      try Task.checkCancellation()
      return try await directory.read()
    }
  }

  private actor Cursor {
    private let directory: Directory
    private var pending: [SFTPAttributes] = []

    init(_ directory: Directory) {
      self.directory = directory
    }

    func next() async throws(SSHError) -> SFTPAttributes? {
      try bridge { try directory.checkOpen() }
      if pending.isEmpty {
        let batch = try await bridge { try await directory.read() }
        pending = batch.reversed().map(SFTPAttributes.init)
      }
      return pending.popLast()
    }
  }
}
