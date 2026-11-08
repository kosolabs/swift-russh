import ArgumentParser
import CryptoKit
import Foundation
import SwiftRussh

// MARK: - Topology

extension ByteSize: ExpressibleByArgument {}

/// How much state the concurrent workers share. Each tier exercises a different
/// layer: reentrancy on one SFTP client, channel multiplexing on one session,
/// and genuinely parallel sessions across executor threads.
enum StressTopology: String, ExpressibleByArgument, CaseIterable {
  /// One SSHClient, one SFTPClient, all workers interleaved through it.
  case sharedSftp = "shared-sftp"
  /// One SSHClient, one SFTPClient per worker.
  case perWorkerSftp = "per-worker-sftp"
  /// One SSHClient per worker.
  case perWorkerSession = "per-worker-session"

  /// Sets up whatever the topology shares between workers and tears it down
  /// again once `body` returns.
  func withShared<T>(
    config: SSHConfig, perform body: (StressShared) async throws -> T
  ) async throws -> T {
    switch self {
    case .sharedSftp:
      return try await config.withConnection { ssh, sftp in
        try await body(StressShared(ssh: ssh, sftp: sftp, topology: self, config: config))
      }

    case .perWorkerSftp:
      return try await config.withSSHConnection { ssh in
        try await body(StressShared(ssh: ssh, sftp: nil, topology: self, config: config))
      }

    case .perWorkerSession:
      return try await body(StressShared(ssh: nil, sftp: nil, topology: self, config: config))
    }
  }
}

/// Resources shared by every worker. What is shared depends on the topology;
/// a nil member means each worker makes its own.
struct StressShared: Sendable {
  let ssh: SSHClient?
  let sftp: SFTPClient?
  let topology: StressTopology
  let config: SSHConfig

  /// Per-worker resources plus the teardown for whatever this worker owns.
  func withWorkerContext<T>(
    perform body: (SSHClient, SFTPClient) async throws -> T
  ) async throws -> T {
    switch topology {
    case .sharedSftp:
      return try await body(ssh!, sftp!)

    case .perWorkerSftp:
      let ssh = ssh!
      let sftp: SFTPClient
      do {
        sftp = try await ssh.sftp()
      } catch {
        // `sftp()` has typed throws, so `error` is already an SSHError here.
        guard error.isChannelOpenFailed else { throw error }
        throw StressError(
          message: """
            The server refused another SFTP channel on this connection. sshd caps \
            sessions per connection (MaxSessions, 10 by default), which caps \
            --workers for this topology: \(error)
            """
        )
      }
      do {
        let result = try await body(ssh, sftp)
        await sftp.close()
        return result
      } catch {
        await sftp.close()
        throw error
      }

    case .perWorkerSession:
      return try await config.withConnection(body)
    }
  }
}

// MARK: - Deterministic Payloads

/// SplitMix64: a small, fast, seedable generator. Every payload in a stress run
/// is derived from the run seed, so a failing iteration can be replayed exactly.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Mixes the run seed with the worker and iteration so each transfer gets an
/// independent but reproducible stream.
func derivedSeed(run: UInt64, worker: Int, iteration: Int) -> UInt64 {
  var mixer = SplitMix64(seed: run &+ UInt64(worker) &* 0x9E37_79B9 &+ UInt64(iteration))
  return mixer.next()
}

/// Writes `size` pseudo-random bytes to `url` and returns their MD5.
@discardableResult
func writePayload(to url: URL, size: UInt64, seed: UInt64) throws -> String {
  guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
    throw StressError(message: "Failed to create payload at \(url.path)")
  }
  let fp = try FileHandle(forWritingTo: url)
  defer { try? fp.close() }

  var generator = SplitMix64(seed: seed)
  var digest = Insecure.MD5()
  var remaining = size

  while remaining > 0 {
    let chunkSize = Int(min(remaining, 1 << 20))
    var chunk = Data(count: chunkSize)
    chunk.withUnsafeMutableBytes { raw in
      var offset = 0
      while offset < chunkSize {
        var word = generator.next()
        let count = min(8, chunkSize - offset)
        withUnsafeBytes(of: &word) { bytes in
          raw.baseAddress!.advanced(by: offset).copyMemory(
            from: bytes.baseAddress!, byteCount: count)
        }
        offset += count
      }
    }
    digest.update(data: chunk)
    try fp.write(contentsOf: chunk)
    remaining -= UInt64(chunkSize)
  }

  return digest.finalize().map { String(format: "%02hhx", $0) }.joined()
}

/// Builds `size` deterministic bytes in memory. Small-file runs keep their
/// payloads here rather than on disk: at thousands of files the local writes
/// would dominate what we are trying to measure.
func payloadData(size: Int, seed: UInt64) -> Data {
  var generator = SplitMix64(seed: seed)
  var data = Data(count: size)
  data.withUnsafeMutableBytes { raw in
    var offset = 0
    while offset < size {
      var word = generator.next()
      let count = min(8, size - offset)
      withUnsafeBytes(of: &word) { bytes in
        raw.baseAddress!.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: count)
      }
      offset += count
    }
  }
  return data
}

/// Streams a local file through MD5 without holding it in memory.
func md5(ofFile url: URL, bufferSize: Int = 1 << 20) throws -> String {
  guard let fp = try? FileHandle(forReadingFrom: url) else {
    throw StressError(message: "Failed to open \(url.path) for reading")
  }
  defer { try? fp.close() }

  var digest = Insecure.MD5()
  while let chunk = try fp.read(upToCount: bufferSize), !chunk.isEmpty {
    digest.update(data: chunk)
  }
  return digest.finalize().map { String(format: "%02hhx", $0) }.joined()
}

extension Data {
  var md5Hex: String {
    Insecure.MD5.hash(data: self).map { String(format: "%02hhx", $0) }.joined()
  }
}

struct StressError: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}

// MARK: - Byte Sizes

/// Accepts plain byte counts as well as `4KiB`, `64MiB`, `1GB` style suffixes.
struct ByteSize: Sendable, CustomStringConvertible {
  let bytes: UInt64

  private static let units: [(suffix: String, multiplier: UInt64)] = [
    ("kib", 1 << 10), ("mib", 1 << 20), ("gib", 1 << 30),
    ("kb", 1_000), ("mb", 1_000_000), ("gb", 1_000_000_000),
    ("k", 1 << 10), ("m", 1 << 20), ("g", 1 << 30),
    ("b", 1),
  ]

  init(bytes: UInt64) {
    self.bytes = bytes
  }

  init?(argument: String) {
    let text = argument.trimmingCharacters(in: .whitespaces).lowercased()
    guard !text.isEmpty else { return nil }

    for (suffix, multiplier) in ByteSize.units where text.hasSuffix(suffix) {
      let number = text.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
      guard let value = Double(number), value >= 0 else { return nil }
      self.init(bytes: UInt64(value * Double(multiplier)))
      return
    }

    guard let value = UInt64(text) else { return nil }
    self.init(bytes: value)
  }

  var description: String {
    ByteSize.format(bytes)
  }

  static func format(_ bytes: UInt64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024 && index < units.count - 1 {
      value /= 1024
      index += 1
    }
    return index == 0
      ? "\(bytes) B"
      : String(format: "%.1f %@", value, units[index])
  }
}

// MARK: - Resource Probes

/// Resident memory and open descriptor count, sampled to spot leaks across a
/// long run. AIO contexts are hand-allocated, so a leak there is otherwise silent.
enum ResourceProbe {
  static func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : nil
  }

  /// Counts entries in /dev/fd. The listing itself holds one descriptor open, so
  /// this is a constant overcount by one -- fine for watching the trend.
  static func openDescriptors() -> Int? {
    try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
  }
}

// MARK: - Channel Limiting

/// Counting semaphore over SSH channels.
///
/// Every `execute` opens its own channel, and sshd caps concurrent sessions per
/// connection (`MaxSessions`, 10 by default). Without a bound, verification
/// commands fan out past that limit and fail the channel open rather than
/// telling us anything about the transfer under test.
actor ChannelLimiter {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.available = limit
  }

  func acquire() async {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      available += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}
