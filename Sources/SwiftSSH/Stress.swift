import ArgumentParser
import Foundation
import SwiftRussh
import Synchronization

struct StressStats: Sendable {
  var uploads = 0
  var downloads = 0
  var bytesUp: UInt64 = 0
  var bytesDown: UInt64 = 0
  var mismatches = 0
  var errors = 0
  var cancellations = 0
}

/// Shareable wrapper around the counters. `Mutex` is noncopyable, so it cannot be
/// passed between tasks on its own.
final class StressCounters: Sendable {
  private let state = Mutex(StressStats())

  var snapshot: StressStats {
    state.withLock { $0 }
  }

  func update(_ body: (inout StressStats) -> Void) {
    state.withLock { stats in body(&stats) }
  }
}

struct Stress: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Hammer the library with concurrent uploads and downloads"
  )

  @OptionGroup var sshConfig: SSHConfig

  @Option(help: "How much state concurrent workers share")
  var topology: StressTopology = .sharedSftp

  @Option(help: "Number of concurrent workers")
  var workers: Int = 8

  @Option(help: "Upload/download round trips per worker")
  var iterations: Int = 25

  @Option(help: "Smallest payload to transfer")
  var sizeMin: ByteSize = ByteSize(bytes: 1 << 10)

  @Option(help: "Largest payload to transfer")
  var sizeMax: ByteSize = ByteSize(bytes: 8 << 20)

  @Option(help: "Remote scratch directory")
  var remoteDir: String = "/tmp/swift-russh-stress"

  @Option(help: "Transfer buffer size")
  var bufferSize: Int = SFTPLimits.defaultBufferSize

  @Option(
    help: """
      Fraction of downloads that stream into retained Data slices instead of \
      writing straight to disk, exercising the reader's shared buffer
      """
  )
  var streamFraction: Double = 0.25

  @Option(
    help: """
      Fraction of iterations that abort a transfer mid-flight before redoing it \
      verified, checking that a cancelled transfer leaves the session usable
      """
  )
  var cancelFraction: Double = 0.0

  @Option(help: "Seed for payload sizes and contents; omit for a random run")
  var seed: UInt64?

  @Option(help: "Concurrent server-side checksum commands; sshd MaxSessions caps this")
  var verifyConcurrency: Int = 6

  @Option(help: "Seconds between progress reports")
  var reportInterval: Double = 1.0

  @Flag(help: "Stop the whole run on the first failure")
  var stopOnError: Bool = false

  @Flag(help: "Leave remote and local scratch files in place when the run ends")
  var keepFiles: Bool = false

  func run() async throws {
    let runSeed = seed ?? UInt64.random(in: 0...UInt64.max)
    guard sizeMin.bytes <= sizeMax.bytes else {
      throw StressError(message: "--size-min must not exceed --size-max")
    }
    guard workers > 0, iterations > 0 else {
      throw StressError(message: "--workers and --iterations must be positive")
    }

    let localDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("swift-russh-stress-\(runSeed)")
    try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

    print("Stress run seed \(runSeed) (replay with --seed \(runSeed))")
    print(
      """
      Topology \(topology.rawValue), \(workers) workers x \(iterations) iterations, \
      payloads \(sizeMin)-\(sizeMax), buffer \(ByteSize.format(UInt64(bufferSize)))
      """
    )
    print("Local scratch \(localDir.path), remote scratch \(remoteDir)")

    let stats = StressCounters()
    let baselineRss = ResourceProbe.residentBytes()
    let baselineFds = ResourceProbe.openDescriptors()
    let start = Date()

    // A control connection owned by nobody in particular: it creates the remote
    // scratch directory, verifies checksums server-side, and cleans up at the end.
    let (control, controlSftp) = try await sshConfig.connectWithSftp()
    let limiter = ChannelLimiter(limit: verifyConcurrency)
    try await controlSftp.createDirectoryRecursively(at: remoteDir, permissions: 0o755)

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          await report(
            stats: stats, start: start, baselineRss: baselineRss, baselineFds: baselineFds)
        }

        try await topology.withShared(config: sshConfig) { shared in
          try await withThrowingTaskGroup(of: Void.self) { workerGroup in
            for worker in 0..<workers {
              workerGroup.addTask {
                try await runWorker(
                  worker: worker, runSeed: runSeed, shared: shared,
                  control: control, limiter: limiter, localDir: localDir, stats: stats
                )
              }
            }
            // `waitForAll` collects errors and only rethrows once every worker
            // has finished, which lets a run limp on for minutes after a setup
            // failure. Iterating rethrows the first one and cancels the rest.
            for try await _ in workerGroup {}
          }
        }

        group.cancelAll()
      }
    } catch {
      await cleanup(control: control, sftp: controlSftp, localDir: localDir)
      throw error
    }

    let elapsed = Date().timeIntervalSince(start)
    await cleanup(control: control, sftp: controlSftp, localDir: localDir)
    summarize(stats: stats, elapsed: elapsed, baselineRss: baselineRss, baselineFds: baselineFds)

    let final = stats.snapshot
    if final.mismatches > 0 || final.errors > 0 {
      throw ExitCode.failure
    }
  }

  // MARK: - Worker

  private func runWorker(
    worker: Int, runSeed: UInt64, shared: StressShared,
    control: SSHClient, limiter: ChannelLimiter, localDir: URL, stats: StressCounters
  ) async throws {
    try await shared.withWorkerContext { ssh, sftp in
      for iteration in 0..<iterations {
        try Task.checkCancellation()
        do {
          try await roundTrip(
            worker: worker, iteration: iteration, runSeed: runSeed,
            ssh: ssh, sftp: sftp, control: control, limiter: limiter,
            localDir: localDir, stats: stats
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          stats.update { $0.errors += 1 }
          print("[worker \(worker) iteration \(iteration)] error: \(error)")
          if stopOnError { throw error }
        }
      }
    }
  }

  /// Generate, upload, verify server-side, download, verify locally, clean up.
  private func roundTrip(
    worker: Int, iteration: Int, runSeed: UInt64,
    ssh: SSHClient, sftp: SFTPClient, control: SSHClient, limiter: ChannelLimiter,
    localDir: URL, stats: StressCounters
  ) async throws {
    let payloadSeed = derivedSeed(run: runSeed, worker: worker, iteration: iteration)
    var generator = SplitMix64(seed: payloadSeed)
    let size = logUniformSize(using: &generator)

    let name = "w\(worker)-i\(iteration)"
    let source = localDir.appendingPathComponent("\(name).src")
    let sink = localDir.appendingPathComponent("\(name).dst")
    let remotePath = "\(remoteDir)/\(name).bin"

    let expected = try writePayload(to: source, size: size, seed: payloadSeed)
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: sink)
    }

    // Abandon a transfer partway through, then redo it verified on the same
    // session. Freeing in-flight AIO handles leaves responses on the wire that a
    // later request must not pick up, so the digests below are the real check.
    let cancelUpload = Double.random(in: 0..<1, using: &generator) < cancelFraction
    let cancelDownload = Double.random(in: 0..<1, using: &generator) < cancelFraction

    if cancelUpload {
      await abort(after: &generator) {
        try await sftp.upload(
          from: source, to: remotePath, permissions: 0o644, bufferSize: bufferSize)
      }
      stats.update { $0.cancellations += 1 }
    }

    // Upload, then confirm the bytes that landed are the bytes we sent.
    try await sftp.upload(from: source, to: remotePath, permissions: 0o644, bufferSize: bufferSize)
    stats.update {
      $0.uploads += 1
      $0.bytesUp += size
    }

    let remoteDigest = try await remoteMD5(ssh: control, limiter: limiter, path: remotePath)
    if remoteDigest != expected {
      stats.update { $0.mismatches += 1 }
      print(
        """
        [worker \(worker) iteration \(iteration)] UPLOAD MISMATCH \(remotePath) \
        (\(ByteSize.format(size))): expected \(expected), remote \(remoteDigest)
        """
      )
    }

    if cancelDownload {
      await abort(after: &generator) {
        try await sftp.download(from: remotePath, to: sink, bufferSize: bufferSize)
      }
      stats.update { $0.cancellations += 1 }
    }

    // Download it back, alternating between the buffered-to-disk path and the
    // streaming path that retains the reader's slices past the next read.
    let useStream = Double.random(in: 0..<1, using: &generator) < streamFraction
    let downloaded: String
    if useStream {
      downloaded = try await streamedDigest(sftp: sftp, path: remotePath)
    } else {
      try await sftp.download(from: remotePath, to: sink, bufferSize: bufferSize)
      downloaded = try md5(ofFile: sink)
    }
    stats.update {
      $0.downloads += 1
      $0.bytesDown += size
    }

    if downloaded != expected {
      stats.update { $0.mismatches += 1 }
      print(
        """
        [worker \(worker) iteration \(iteration)] DOWNLOAD MISMATCH \(remotePath) \
        (\(ByteSize.format(size)), \(useStream ? "streamed" : "buffered")): \
        expected \(expected), got \(downloaded)
        """
      )
    }

    if !keepFiles {
      try await sftp.removeFile(at: remotePath)
    }
  }

  /// Starts `body` in its own task, cancels it a few milliseconds in, and waits
  /// for it to unwind. Errors are swallowed: an aborted transfer may fail any way
  /// it likes, so long as the session survives it.
  private func abort(
    after generator: inout SplitMix64, _ body: @escaping @Sendable () async throws -> Void
  ) async {
    let delay = Int.random(in: 1...25, using: &generator)
    let task = Task { try await body() }
    try? await Task.sleep(for: .milliseconds(delay))
    task.cancel()
    _ = try? await task.value
  }

  /// Reads the whole file through `stream`, holding every yielded slice until the
  /// stream ends. The reader hands out prefixes of one reused buffer, so anything
  /// short of a real copy-on-write shows up here as a corrupted digest.
  private func streamedDigest(sftp: SFTPClient, path: String) async throws -> String {
    try await sftp.withFile(at: path, access: .readOnly) { file in
      var chunks: [Data] = []
      for try await chunk in file.stream(bufferSize: bufferSize) {
        chunks.append(chunk)
      }
      var combined = Data()
      for chunk in chunks {
        combined.append(chunk)
      }
      return combined.md5Hex
    }
  }

  private func remoteMD5(
    ssh: SSHClient, limiter: ChannelLimiter, path: String
  ) async throws -> String {
    await limiter.acquire()
    defer { Task { await limiter.release() } }

    let result = try await ssh.execute("md5sum '\(path)'")
    guard let text = String(data: result.stdout, encoding: .utf8),
      let digest = text.split(separator: " ").first
    else {
      let error = String(data: result.stderr, encoding: .utf8) ?? ""
      throw StressError(message: "md5sum failed for \(path): \(error)")
    }
    return String(digest).lowercased()
  }

  /// Log-uniform so small files -- the ones that exercise short reads and
  /// single-chunk paths -- stay well represented against a large maximum.
  private func logUniformSize(using generator: inout SplitMix64) -> UInt64 {
    let low = Double(max(sizeMin.bytes, 1))
    let high = Double(max(sizeMax.bytes, 1))
    guard high > low else { return sizeMin.bytes }
    let exponent = Double.random(in: log(low)...log(high), using: &generator)
    return UInt64(exp(exponent)).clamped(to: sizeMin.bytes...sizeMax.bytes)
  }

  // MARK: - Reporting

  private func report(
    stats: StressCounters, start: Date, baselineRss: UInt64?, baselineFds: Int?
  ) async {
    var previous = StressStats()
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(reportInterval))
      if Task.isCancelled { return }

      let current = stats.snapshot
      let deltaBytes =
        (current.bytesUp + current.bytesDown)
        - (previous.bytesUp + previous.bytesDown)
      previous = current

      var line = """
        \(String(format: "%6.1fs", Date().timeIntervalSince(start)))  \
        up \(current.uploads) (\(ByteSize.format(current.bytesUp)))  \
        down \(current.downloads) (\(ByteSize.format(current.bytesDown)))  \
        \(ByteSize.format(UInt64(Double(deltaBytes) / reportInterval)))/s
        """
      if let rss = ResourceProbe.residentBytes() {
        line += "  rss \(ByteSize.format(rss))"
        if let baselineRss {
          line += " (+\(ByteSize.format(rss > baselineRss ? rss - baselineRss : 0)))"
        }
      }
      if let fds = ResourceProbe.openDescriptors() {
        line += "  fds \(fds)"
        if let baselineFds {
          line += " (\(fds >= baselineFds ? "+" : "")\(fds - baselineFds))"
        }
      }
      if current.cancellations > 0 {
        line += "  cancelled \(current.cancellations)"
      }
      if current.mismatches > 0 || current.errors > 0 {
        line += "  mismatches \(current.mismatches)  errors \(current.errors)"
      }
      print(line)
    }
  }

  private func summarize(
    stats: StressCounters, elapsed: TimeInterval, baselineRss: UInt64?, baselineFds: Int?
  ) {
    let final = stats.snapshot
    let total = final.bytesUp + final.bytesDown

    print("")
    print("Finished in \(String(format: "%.1fs", elapsed))")
    print("  uploads      \(final.uploads) (\(ByteSize.format(final.bytesUp)))")
    print("  downloads    \(final.downloads) (\(ByteSize.format(final.bytesDown)))")
    print(
      "  throughput   \(ByteSize.format(UInt64(Double(total) / max(elapsed, 0.001))))/s aggregate")
    print("  cancelled    \(final.cancellations)")
    print("  mismatches   \(final.mismatches)")
    print("  errors       \(final.errors)")

    if let baselineRss, let rss = ResourceProbe.residentBytes() {
      let delta = rss > baselineRss ? rss - baselineRss : 0
      print("  rss          \(ByteSize.format(rss)) (+\(ByteSize.format(delta)) since start)")
    }
    if let baselineFds, let fds = ResourceProbe.openDescriptors() {
      print("  descriptors  \(fds) (\(fds - baselineFds) since start)")
    }
  }

  private func cleanup(control: SSHClient, sftp: SFTPClient, localDir: URL) async {
    if !keepFiles {
      try? await sftp.removeDirectoryRecursively(at: remoteDir)
      try? FileManager.default.removeItem(at: localDir)
    }
    await sftp.close()
    await control.close()
  }
}

extension UInt64 {
  fileprivate func clamped(to range: ClosedRange<UInt64>) -> UInt64 {
    Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
  }
}
