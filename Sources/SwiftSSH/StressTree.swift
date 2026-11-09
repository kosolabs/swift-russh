import ArgumentParser
import Foundation
import SwiftRussh
import Synchronization

struct TreeStats: Sendable {
  var directories = 0
  var files = 0
  var bytes: UInt64 = 0
  var listings = 0
  var entries = 0
  var renames = 0
  var reads = 0
  var trees = 0
  var mismatches = 0
  var errors = 0

  /// Everything that costs a request round trip, which is what this test is
  /// really measuring.
  var operations: Int {
    directories + files + listings + renames + reads
  }
}

/// Shareable wrapper around the counters. `Mutex` is noncopyable, so it cannot be
/// passed between tasks on its own.
final class TreeCounters: Sendable {
  private let state = Mutex(TreeStats())

  var snapshot: TreeStats {
    state.withLock { $0 }
  }

  func update(_ body: (inout TreeStats) -> Void) {
    state.withLock { stats in body(&stats) }
  }
}

struct StressTree: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stress-tree",
    abstract: "Hammer the library with directory trees full of small files"
  )

  @OptionGroup var sshConfig: SSHConfig

  @Option(help: "How much state concurrent workers share")
  var topology: StressTopology = .sharedSftp

  @Option(help: "Number of concurrent workers")
  var workers: Int = 8

  @Option(help: "Build/verify/tear-down cycles per worker")
  var rounds: Int = 3

  @Option(help: "Levels of directories below each round's root")
  var depth: Int = 3

  @Option(help: "Subdirectories per level")
  var fanout: Int = 3

  @Option(help: "Files created in every directory")
  var filesPerDir: Int = 8

  @Option(help: "Concurrent file creations within one directory")
  var dirConcurrency: Int = 4

  @Option(help: "Smallest file to create")
  var sizeMin: ByteSize = ByteSize(bytes: 0)

  @Option(help: "Largest file to create")
  var sizeMax: ByteSize = ByteSize(bytes: 4 << 10)

  @Option(help: "Remote scratch directory")
  var remoteDir: String = "/tmp/swift-russh-stress-tree"

  @Option(help: "Fraction of files read back and compared against their digest")
  var readFraction: Double = 0.25

  @Option(
    help: """
      Fraction of files renamed after creation, checking that the listing and \
      both paths agree afterwards
      """
  )
  var renameFraction: Double = 0.1

  @Option(help: "Seed for file sizes and contents; omit for a random run")
  var seed: UInt64?

  @Option(help: "Seconds between progress reports")
  var reportInterval: Double = 1.0

  @Flag(help: "Stop the whole run on the first failure")
  var stopOnError: Bool = false

  @Flag(help: "Leave the remote tree in place when the run ends")
  var keepFiles: Bool = false

  /// Directories in one round's tree, root included.
  private var directoriesPerTree: Int {
    var total = 1
    var level = 1
    for _ in 0..<depth {
      level *= fanout
      total += level
    }
    return total
  }

  func run() async throws {
    let runSeed = seed ?? UInt64.random(in: 0...UInt64.max)
    guard sizeMin.bytes <= sizeMax.bytes else {
      throw StressError(message: "--size-min must not exceed --size-max")
    }
    guard workers > 0, rounds > 0, dirConcurrency > 0 else {
      throw StressError(message: "--workers, --rounds and --dir-concurrency must be positive")
    }
    guard depth >= 0, fanout > 0, filesPerDir >= 0 else {
      throw StressError(message: "--depth, --fanout and --files-per-dir must not be negative")
    }

    let trees = workers * rounds
    let totalDirs = trees * directoriesPerTree
    print("Stress run seed \(runSeed) (replay with --seed \(runSeed))")
    print(
      """
      Topology \(topology.rawValue), \(workers) workers x \(rounds) rounds, \
      depth \(depth) fanout \(fanout), \(filesPerDir) files per directory, \
      sizes \(sizeMin)-\(sizeMax)
      """
    )
    print(
      """
      \(trees) trees, \(totalDirs) directories, \(totalDirs * filesPerDir) files, \
      remote scratch \(remoteDir)
      """
    )

    let stats = TreeCounters()
    let baselineRss = ResourceProbe.residentBytes()
    let baselineFds = ResourceProbe.openDescriptors()
    let start = Date()

    // A control connection owned by nobody in particular: it creates the remote
    // scratch directory and cleans up at the end.
    let (control, controlSftp) = try await sshConfig.connectWithSftp()
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
                  worker: worker, runSeed: runSeed, shared: shared, stats: stats)
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
      await cleanup(control: control, sftp: controlSftp)
      throw error
    }

    let elapsed = Date().timeIntervalSince(start)
    await cleanup(control: control, sftp: controlSftp)
    summarize(stats: stats, elapsed: elapsed, baselineRss: baselineRss, baselineFds: baselineFds)

    let final = stats.snapshot
    if final.mismatches > 0 || final.errors > 0 {
      throw ExitCode.failure
    }
  }

  // MARK: - Worker

  private func runWorker(
    worker: Int, runSeed: UInt64, shared: StressShared, stats: TreeCounters
  ) async throws {
    try await shared.withWorkerContext { _, sftp in
      let workerRoot = "\(remoteDir)/w\(worker)"
      try await sftp.createDirectoryRecursively(at: workerRoot, permissions: 0o755)

      for round in 0..<rounds {
        try Task.checkCancellation()
        let root = "\(workerRoot)/r\(round)"
        do {
          var generator = SplitMix64(
            seed: derivedSeed(run: runSeed, worker: worker, iteration: round))
          try await buildTree(
            at: root, depth: depth, label: "worker \(worker) round \(round)",
            sftp: sftp, generator: &generator, stats: stats
          )
          try await tearDown(
            root: root, label: "worker \(worker) round \(round)", sftp: sftp, stats: stats)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          stats.update { $0.errors += 1 }
          print("[worker \(worker) round \(round)] error: \(error)")
          if stopOnError { throw error }
          // A half-built tree would poison the next round's listings.
          try? await sftp.removeDirectoryRecursively(at: root)
        }
      }

      if !keepFiles {
        try? await sftp.removeDirectoryRecursively(at: workerRoot)
      }
    }
  }

  /// What one file in a directory should end up being. Planned up front so the
  /// seeded generator stays out of the concurrent creation below.
  private struct FilePlan: Sendable {
    let name: String
    let size: Int
    let seed: UInt64
    let rename: Bool
    let read: Bool

    var finalName: String { rename ? "\(name).moved" : name }
  }

  /// Creates `path`, fills it with small files, recurses into its subdirectories,
  /// and then reads the whole directory back to confirm what landed.
  private func buildTree(
    at path: String, depth: Int, label: String,
    sftp: SFTPClient, generator: inout SplitMix64, stats: TreeCounters
  ) async throws {
    try Task.checkCancellation()
    try await sftp.createDirectory(at: path, permissions: 0o755)
    stats.update { $0.directories += 1 }

    var plans: [FilePlan] = []
    for index in 0..<filesPerDir {
      plans.append(
        FilePlan(
          name: "f\(index).dat",
          size: Int.random(in: Int(sizeMin.bytes)...Int(sizeMax.bytes), using: &generator),
          seed: generator.next(),
          rename: Double.random(in: 0..<1, using: &generator) < renameFraction,
          read: Double.random(in: 0..<1, using: &generator) < readFraction
        )
      )
    }

    // Small writes fanned out over one SFTP client: several requests are in
    // flight against the same session while the responses come back interleaved.
    var digests: [String: String] = [:]
    try await withThrowingTaskGroup(of: (String, String).self) { group in
      var pending = 0
      for plan in plans {
        if pending == dirConcurrency, let (name, digest) = try await group.next() {
          digests[name] = digest
          pending -= 1
        }
        group.addTask {
          try await create(plan: plan, in: path, sftp: sftp, stats: stats)
        }
        pending += 1
      }
      for try await (name, digest) in group {
        digests[name] = digest
      }
    }

    var subdirectories: [String] = []
    if depth > 0 {
      for index in 0..<fanout {
        let name = "d\(index)"
        subdirectories.append(name)
        try await buildTree(
          at: "\(path)/\(name)", depth: depth - 1, label: label,
          sftp: sftp, generator: &generator, stats: stats
        )
      }
    }

    let sizes = Dictionary(uniqueKeysWithValues: plans.map { ($0.finalName, UInt64($0.size)) })
    try await verifyListing(
      at: path, files: sizes, subdirectories: Set(subdirectories), label: label,
      sftp: sftp, stats: stats
    )

    for plan in plans where plan.read {
      let filePath = "\(path)/\(plan.finalName)"
      let contents: Data
      do {
        contents = try await sftp.withFile(at: filePath, access: .readOnly) { file in
          try await file.read()
        }
      } catch {
        // One unreadable file should not hide what the rest of the directory says.
        stats.update { $0.errors += 1 }
        print("[\(label)] READ FAILED \(filePath): \(error)")
        continue
      }
      stats.update { $0.reads += 1 }

      if contents.md5Hex != digests[plan.finalName] {
        stats.update { $0.mismatches += 1 }
        print(
          """
          [\(label)] CONTENT MISMATCH \(filePath) (\(ByteSize.format(UInt64(plan.size)))): \
          expected \(digests[plan.finalName] ?? "?"), got \(contents.md5Hex)
          """
        )
      }
    }
  }

  /// Writes one small file straight from memory, renaming it afterwards if the
  /// plan calls for it. Returns its final name and digest.
  private func create(
    plan: FilePlan, in directory: String, sftp: SFTPClient, stats: TreeCounters
  ) async throws -> (String, String) {
    let payload = payloadData(size: plan.size, seed: plan.seed)
    let path = "\(directory)/\(plan.name)"

    try await sftp.withFile(
      at: path, access: .writeOnly, options: [.create, .truncate], permissions: 0o644
    ) { file in
      try await file.write(contentsOf: payload, at: 0)
    }
    stats.update {
      $0.files += 1
      $0.bytes += UInt64(plan.size)
    }

    if plan.rename {
      try await sftp.move(from: path, to: "\(directory)/\(plan.finalName)")
      stats.update { $0.renames += 1 }
    }

    return (plan.finalName, payload.md5Hex)
  }

  /// Reads the directory back and holds it against what we just created: every
  /// name present exactly once, of the right type, at the right size.
  private func verifyListing(
    at path: String, files: [String: UInt64], subdirectories: Set<String>, label: String,
    sftp: SFTPClient, stats: TreeCounters
  ) async throws {
    // The directory closure is @Sendable, so drain it first and judge after.
    let listed = try await sftp.withDirectory(at: path) { directory in
      var entries: [SFTPAttributes] = []
      for try await entry in directory {
        entries.append(entry)
      }
      return entries
    }
    stats.update {
      $0.listings += 1
      $0.entries += listed.count
    }

    var seenFiles: [String: UInt64] = [:]
    var seenDirectories: Set<String> = []
    var unexpected: [String] = []
    var duplicates: [String] = []

    for entry in listed {
      guard let name = entry.name else {
        unexpected.append("<unnamed>")
        continue
      }

      switch entry.type {
      case .directory:
        guard subdirectories.contains(name) else {
          unexpected.append(name)
          continue
        }
        if !seenDirectories.insert(name).inserted {
          duplicates.append(name)
        }
      default:
        guard files[name] != nil else {
          unexpected.append(name)
          continue
        }
        if seenFiles.updateValue(entry.size ?? 0, forKey: name) != nil {
          duplicates.append(name)
        }
      }
    }

    var problems: [String] = []
    let missingFiles = Set(files.keys).subtracting(seenFiles.keys).sorted()
    let missingDirectories = subdirectories.subtracting(seenDirectories).sorted()
    if !missingFiles.isEmpty {
      problems.append("missing files \(missingFiles)")
    }
    if !missingDirectories.isEmpty {
      problems.append("missing directories \(missingDirectories)")
    }
    if !unexpected.isEmpty {
      problems.append("unexpected entries \(unexpected.sorted())")
    }
    if !duplicates.isEmpty {
      problems.append("duplicate entries \(duplicates.sorted())")
    }
    for (name, expected) in files.sorted(by: { $0.key < $1.key }) {
      guard let actual = seenFiles[name], actual != expected else { continue }
      problems.append("\(name) is \(actual) bytes, expected \(expected)")
    }

    guard problems.isEmpty else {
      stats.update { $0.mismatches += 1 }
      print("[\(label)] LISTING MISMATCH \(path): \(problems.joined(separator: "; "))")
      return
    }
  }

  /// Removes the tree recursively -- itself a listing-driven walk -- and confirms
  /// the server agrees it is gone.
  private func tearDown(
    root: String, label: String, sftp: SFTPClient, stats: TreeCounters
  ) async throws {
    guard !keepFiles else {
      stats.update { $0.trees += 1 }
      return
    }

    try await sftp.removeDirectoryRecursively(at: root)
    stats.update { $0.trees += 1 }

    do {
      _ = try await sftp.attributes(at: root)
      stats.update { $0.mismatches += 1 }
      print("[\(label)] STALE TREE \(root) still exists after recursive removal")
    } catch SSHError.sftp(.noSuchFile, _) {
    }
  }

  // MARK: - Reporting

  private func report(
    stats: TreeCounters, start: Date, baselineRss: UInt64?, baselineFds: Int?
  ) async {
    var previous = TreeStats()
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(reportInterval))
      if Task.isCancelled { return }

      let current = stats.snapshot
      let deltaOps = current.operations - previous.operations
      previous = current

      // ops/s counts requests this process issued; the recursive teardown walks
      // inside the library, so it shows up as trees rather than as ops.
      var line = """
        \(String(format: "%6.1fs", Date().timeIntervalSince(start)))  \
        dirs \(current.directories)  files \(current.files) (\(ByteSize.format(current.bytes)))  \
        listings \(current.listings)  trees \(current.trees)  \
        \(String(format: "%.0f", Double(deltaOps) / reportInterval)) ops/s
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
      if current.mismatches > 0 || current.errors > 0 {
        line += "  mismatches \(current.mismatches)  errors \(current.errors)"
      }
      print(line)
    }
  }

  private func summarize(
    stats: TreeCounters, elapsed: TimeInterval, baselineRss: UInt64?, baselineFds: Int?
  ) {
    let final = stats.snapshot

    print("")
    print("Finished in \(String(format: "%.1fs", elapsed))")
    print("  trees        \(final.trees)")
    print("  directories  \(final.directories)")
    print("  files        \(final.files) (\(ByteSize.format(final.bytes)))")
    print("  renames      \(final.renames)")
    print("  listings     \(final.listings) (\(final.entries) entries)")
    print("  reads        \(final.reads)")
    print(
      """
        throughput   \
      \(String(format: "%.0f", Double(final.operations) / max(elapsed, 0.001))) ops/s aggregate
      """
    )
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

  private func cleanup(control: SSHClient, sftp: SFTPClient) async {
    if !keepFiles {
      try? await sftp.removeDirectoryRecursively(at: remoteDir)
    }
    await sftp.close()
    await control.close()
  }
}
