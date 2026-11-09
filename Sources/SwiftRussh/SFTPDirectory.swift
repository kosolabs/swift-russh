import Foundation
import RusshFFI

public struct SFTPDirectory: Sendable, AsyncSequence {
  public struct Entry: Hashable, Sendable {
    public let name: String
    public let attributes: SFTPAttributes

    public init(name: String, attributes: SFTPAttributes) {
      self.name = name
      self.attributes = attributes
    }
  }

  private let cursor: Cursor

  init(_ directory: Directory) {
    cursor = Cursor(directory)
  }

  func read() async throws(SSHError) -> Entry? {
    while let entry = try await cursor.next() {
      if !["", ".", ".."].contains(entry.name) {
        return entry
      }
    }
    return nil
  }

  public func makeAsyncIterator() -> Iterator {
    Iterator(directory: self)
  }

  public struct Iterator: AsyncIteratorProtocol {
    private let directory: SFTPDirectory

    init(directory: SFTPDirectory) {
      self.directory = directory
    }

    public func next() async throws -> Entry? {
      try Task.checkCancellation()
      return try await directory.read()
    }
  }

  private actor Cursor {
    private let directory: Directory
    private var pending: [Entry] = []

    init(_ directory: Directory) {
      self.directory = directory
    }

    func next() async throws(SSHError) -> Entry? {
      try bridge { try directory.checkOpen() }
      if pending.isEmpty {
        let batch = try await bridge { try await directory.read() }
        pending = batch.reversed().map { attributes in
          Entry(name: attributes.name ?? "", attributes: SFTPAttributes(attributes))
        }
      }
      return pending.popLast()
    }
  }
}
