import Foundation

/// Lock-protected accumulator for per-stage timings during a `.knit`
/// pack or unpack. Wired through optionally — when nil, callers skip
/// instrumentation entirely so the hot path pays nothing in
/// production. When supplied (driven by the CLI's hidden `--analyze`
/// flag), the orchestrators record per-stage seconds into a single
/// snapshot the renderer can dump to stderr.
///
/// The accumulator itself is direction-agnostic: `record(stage:seconds:)`
/// just maps a string key to a running TimeInterval total. The stage
/// label set is decided by the caller. Conventional labels:
///
///   **Decode (HybridZstdBatchDecoder)**
///   * `staging.alloc`        — `[UInt8](repeating: 0, count: …)` per
///                              batch (zero-fill cost, lazy mmap
///                              page faults, allocator pressure).
///   * `parallel.decode`      — `concurrentMap` over per-block libzstd
///                              (wall, not CPU-time).
///   * `crc.fold`             — serial libdeflate `crc32` over the
///                              assembled batch.
///   * `sink`                 — caller-supplied write callback.
///
///   **Encode (StreamingBlockCompressor)**
///   * `parallel.compress`    — wall time of `concurrentMap` over
///                              per-block workers (combined entropy +
///                              CRC + zstd).
///   * `archive.write`        — wall time of the in-order sink-drain
///                              loop (write to the archive).
///   * `compute.entropy`      — cumulative *CPU-time* across all
///                              workers in the histogram phase.
///   * `compute.crc`          — cumulative CPU-time across workers
///                              for libdeflate per-block CRC.
///   * `compute.compress`     — cumulative CPU-time across workers
///                              inside libzstd.
///
/// Note the wall-vs-CPU-time distinction. Wall-time stages (the
/// `parallel.*` and `archive.*` ones) sum toward the orchestrator's
/// total wall. CPU-time stages (the `compute.*` ones) sum across
/// workers and can therefore exceed total wall — that's intentional,
/// because what we want to know is *how much CPU work* the GPU could
/// potentially absorb if it took over that stage.
///
/// Without measured numbers from this accumulator, every speed-up
/// plan is speculation. With them, we know exactly which stage to
/// hand the spare GPU next.
public final class StageAnalytics: @unchecked Sendable {

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
