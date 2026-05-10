import Foundation

/// Lock-protected accumulator for per-stage timings during a `.knit`
/// extract. Wired through optionally — when nil, callers skip
/// instrumentation entirely so the hot path pays nothing in
/// production. When supplied (driven by the CLI's hidden `--analyze`
/// flag), `HybridZstdBatchDecoder` records the wall time it spends in
/// each stage of every batch:
///
///   * `staging.alloc`        — `[UInt8](repeating: 0, count: …)` per
///                               batch (zero-fill cost, lazy mmap
///                               page faults, allocator pressure).
///   * `parallel.decode`      — `concurrentMap` over per-block libzstd
///                               (wall, not CPU-time — see commentary
///                               in `decode()`).
///   * `crc.fold`             — serial libdeflate `crc32` over the
///                               assembled batch.
///   * `sink`                 — caller-supplied write callback (the
///                               `outHandle.write` path under most
///                               configs).
///
/// The output of a knit unpack run with `--analyze` is what tells us
/// where the wall-clock time is actually going on the user's host —
/// the data needed to decide *which* stage the spare GPU should
/// accelerate next (CRC fold? Huffman literal decode? double-buffered
/// write overlap?). Without measured numbers, every speed-up plan is
/// speculation.
public final class DecodeAnalytics: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public struct StageEntry: Sendable {
            public let name: String
            public let seconds: TimeInterval
        }
        /// Insertion-ordered for stable rendering.
        public let stages: [StageEntry]
        public let batchCount: Int
        public let totalBatchBytes: UInt64
        public let fallbackBlocks: Int
        public let totalWall: TimeInterval
    }

    private let lock = NSLock()
    private var stagesDict: [String: TimeInterval] = [:]
    private var orderedKeys: [String] = []
    private var batches: Int = 0
    private var totalBytes: UInt64 = 0
    private var fallbackCount: Int = 0
    private var startInstant: ContinuousClock.Instant?

    public init() {}

    /// Mark the start of the timed window. Called once at the top of
    /// `decode()`; the snapshot's `totalWall` is computed from this.
    public func startWallClock() {
        lock.lock()
        startInstant = .now
        lock.unlock()
    }

    /// Add `seconds` to a stage's running total. Lock-guarded so it's
    /// safe to call from `concurrentMap` workers, although in practice
    /// the orchestrator only records from its own thread (workers do
    /// the work; orchestrator times the whole call).
    public func record(stage: String, seconds: TimeInterval) {
        lock.lock()
        if stagesDict[stage] == nil { orderedKeys.append(stage) }
        stagesDict[stage, default: 0] += seconds
        lock.unlock()
    }

    public func recordBatch(bytes: UInt64, fallback: Int) {
        lock.lock()
        batches += 1
        totalBytes += bytes
        fallbackCount += fallback
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        let totalWall: TimeInterval = startInstant.map {
            (ContinuousClock.now - $0).timeIntervalSeconds
        } ?? 0
        let stages = orderedKeys.map {
            Snapshot.StageEntry(name: $0, seconds: stagesDict[$0] ?? 0)
        }
        let snap = Snapshot(stages: stages,
                            batchCount: batches,
                            totalBatchBytes: totalBytes,
                            fallbackBlocks: fallbackCount,
                            totalWall: totalWall)
        lock.unlock()
        return snap
    }
}
