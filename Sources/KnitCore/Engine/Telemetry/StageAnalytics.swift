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
///   * `entropy.probe`        — orchestrator-thread wall of the
///                              per-batch entropy probe (or its skip).
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
/// **Sharding (since the post-#33 measurement-quality work):**
/// `record(stage:seconds:)` is in the inner-most hot path of any
/// parallel-batch pack or unpack run. With a single shared `NSLock`
/// and 16 worker threads each calling `record` 5+ times per batch
/// (~89 k batches on the github corpus), the lock became the
/// dominant wall cost on `--analyze` runs — short tasks → frequent
/// lock acquisitions → contention storm → `ContinuousClock.now`
/// readings inside other stages got *inflated* by waiting for the
/// analytics lock. The per-block `compute.crc` measurement jumped
/// 12× post-#33 even though the CRC code was unchanged, because
/// the time interval it was measuring now contained more lock-wait
/// time at its end.
///
/// Fix: stripe the accumulator across N shards (currently 32). A
/// caller's `pthread_self()` mod N picks one shard, and only that
/// shard's lock is touched on `record`. With 16 workers and 32
/// shards the steady-state collision probability is small, so the
/// hot path approaches lock-free. `snapshot()` locks every shard,
/// merges them into a single result, then unlocks — done once at
/// extract end so the contention there is irrelevant.
///
/// Without measured numbers from this accumulator, every speed-up
/// plan is speculation. With them — and with the measurement
/// itself not artificially inflating other stages — we know
/// exactly which stage to hand the spare GPU next.
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

    /// One shard's mutable state. Each shard has its own NSLock so
    /// the typical case (one worker, one shard) is uncontested.
    private final class Shard {
        let lock = NSLock()
        var stagesDict: [String: TimeInterval] = [:]
        var orderedKeys: [String] = []
        var batches: Int = 0
        var totalBytes: UInt64 = 0
        var fallbackCount: Int = 0
    }

    /// Number of shards. 32 is large enough that 16 worker threads
    /// distribute over them with low collision probability, but
    /// small enough that `snapshot()`'s merge stays cheap. Must be a
    /// power of two so the shard-index reduction can use the high
    /// bits of a multiplicative hash via `>>`.
    private static let shardBits = 5
    private static let shardCount = 1 << shardBits   // 32

    private let shards: [Shard]

    /// Wall-window start. Single value protected by its own lock —
    /// it's only touched once per entry on the orchestrator thread,
    /// so contention here is negligible. Kept separate from the
    /// shards so `snapshot()` can read it without unlocking the
    /// shard locks first.
    private let wallLock = NSLock()
    private var startInstant: ContinuousClock.Instant?

    public init() {
        self.shards = (0..<Self.shardCount).map { _ in Shard() }
    }

    public func startWallClock() {
        wallLock.lock()
        startInstant = .now
        wallLock.unlock()
    }

    public func record(stage: String, seconds: TimeInterval) {
        let shard = currentShard()
        shard.lock.lock()
        if shard.stagesDict[stage] == nil { shard.orderedKeys.append(stage) }
        shard.stagesDict[stage, default: 0] += seconds
        shard.lock.unlock()
    }

    public func recordBatch(bytes: UInt64, fallback: Int) {
        let shard = currentShard()
        shard.lock.lock()
        shard.batches += 1
        shard.totalBytes += bytes
        shard.fallbackCount += fallback
        shard.lock.unlock()
    }

    public func snapshot() -> Snapshot {
        // Lock every shard in index order to merge a consistent view.
        // Snapshot is called once per extract from the orchestrator
        // thread, so this serial fan-in cost is negligible.
        for shard in shards { shard.lock.lock() }
        defer {
            for shard in shards { shard.lock.unlock() }
        }
        wallLock.lock()
        let totalWall: TimeInterval = startInstant.map {
            (ContinuousClock.now - $0).timeIntervalSeconds
        } ?? 0
        wallLock.unlock()

        // Merge: preserve first-insertion order across shards. We
        // walk shards in index order and append new stage names as
        // we encounter them, accumulating their seconds.
        var mergedDict: [String: TimeInterval] = [:]
        var mergedOrder: [String] = []
        var totalBatches = 0
        var totalBytes: UInt64 = 0
        var totalFallback = 0
        for shard in shards {
            for key in shard.orderedKeys {
                if mergedDict[key] == nil {
                    mergedOrder.append(key)
                }
                mergedDict[key, default: 0] += shard.stagesDict[key] ?? 0
            }
            totalBatches += shard.batches
            totalBytes &+= shard.totalBytes
            totalFallback += shard.fallbackCount
        }
        let stages = mergedOrder.map {
            Snapshot.StageEntry(name: $0, seconds: mergedDict[$0] ?? 0)
        }
        return Snapshot(
            stages: stages,
            batchCount: totalBatches,
            totalBatchBytes: totalBytes,
            fallbackBlocks: totalFallback,
            totalWall: totalWall
        )
    }

    /// Pick the shard for the calling thread. `Thread.current` is
    /// thread-local-storage backed on Apple platforms (effectively a
    /// register read), and its `ObjectIdentifier` is stable for the
    /// lifetime of the thread — so this is effectively thread-
    /// affinity routing without us managing TLS by hand.
    private func currentShard() -> Shard {
        // Knuth multiplicative hash. The conventional form takes
        // the *high* bits of the product, not the low bits, because
        // the high bits of `key * golden_ratio` are well-mixed
        // (they depend on every bit of `key`) while the low bits
        // depend mostly on the low bits of `key`. The first version
        // of this code used `& shardMask` (low bits) which was
        // measurably broken: `ObjectIdentifier(Thread.current).hashValue`
        // for a class instance is the object pointer, and pointers
        // are 8-byte aligned (low 3 bits zero) and clustered (low
        // 5 bits often shared between sibling thread allocations).
        // Most workers hashed to the same one or two shards, so the
        // sharding cut contention by ~50 % instead of the ~95 % we'd
        // expect from 16 workers across 32 shards.
        //
        // Switching to the high-bit form (right-shift by `64 - 5`)
        // restores the textbook distribution.
        let raw = UInt(bitPattern: ObjectIdentifier(Thread.current).hashValue)
        let idx = Int((raw &* 11400714819323198485) >> (UInt.bitWidth - Self.shardBits))
        return shards[idx]
    }
}
