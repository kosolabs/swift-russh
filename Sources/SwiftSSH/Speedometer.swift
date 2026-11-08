import Foundation
import Synchronization

struct Speedometer: Sendable, ~Copyable {
  private let start: UInt64
  private let progress: Progress
  private let frequency: UInt64
  private let lastUpdate: Atomic<UInt64>
  private let pending: Atomic<Int>

  init(total: UInt64, frequency: TimeInterval = 1.0) {
    self.progress = Progress(totalUnitCount: Int64(total))
    self.frequency = UInt64(frequency * 1_000_000_000)

    self.start = DispatchTime.now().uptimeNanoseconds
    self.lastUpdate = Atomic(start)
    self.pending = Atomic(0)

    self.progress.kind = .file
    self.progress.fileOperationKind = .downloading
    self.progress.fileTotalCount = 1
    self.progress.fileCompletedCount = 0
  }

  func update(completed: Int) -> String? {
    let delta = completed - Int(self.progress.completedUnitCount)
    return update(delta: delta)
  }

  func update(delta: Int) -> String? {
    self.pending.add(delta, ordering: .relaxed)
    self.progress.completedUnitCount += Int64(delta)
    let now = DispatchTime.now().uptimeNanoseconds
    let interval = now - lastUpdate.load(ordering: .relaxed)
    guard interval >= frequency else { return nil }
    let pending = self.pending.exchange(0, ordering: .relaxed)
    self.lastUpdate.store(now, ordering: .relaxed)
    return update(bytes: pending, interval: interval)
  }

  func finalize() -> String {
    let interval = DispatchTime.now().uptimeNanoseconds - start
    return update(interval: interval)
  }

  private func update(bytes: Int? = nil, interval: UInt64) -> String {
    let bytes = bytes ?? Int(self.progress.totalUnitCount)

    if interval > 0 {
      let total = Double(progress.totalUnitCount)
      let completed = Double(progress.completedUnitCount)
      let throughput = Double(bytes) / Double(interval) * 1_000_000_000
      progress.throughput = Int(throughput)
      progress.estimatedTimeRemaining = (total - completed) / throughput
    } else {
      progress.throughput = 0
      progress.estimatedTimeRemaining = nil
    }

    if progress.isFinished {
      self.progress.fileCompletedCount = 1
      self.progress.estimatedTimeRemaining = nil
    }

    return progress.localizedAdditionalDescription
  }
}
