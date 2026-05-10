import Foundation
import CDeflate

/// Streaming block compression with bounded memory.
///
/// This is the engine that lets `knit pack` chew through inputs much
/// larger than physical RAM. The key contract: peak memory is
/// `O(batchSize × blockSize)` independent of the total input size, so a
/// 100 GB file compressed with 1 MiB blocks and a 16-block batch holds
/// at most ~16 MiB of compressed-frame `Data` in flight at once.
///
/// Each worker performs its block's full pipeline on cache-warm pages —
/// CPU byte-histogram → Shannon entropy → optional level downgrade →
/// CRC32 → zstd frame. That single in-cache pass replaces the previous
/// CRC-then-compress two-pass design (which forced ~2× the file size in
/// disk reads on memory-pressured systems with `MADV_SEQUENTIAL`).
///
/// Block CRCs are combined into the entry-level CRC32 via the GF(2)
/// matrix-power identity (`crc32Combine`), so we never need a separate
/// sequential walk over the uncompressed input.
///
/// `Sendable` is declared explicitly: every stored field is `let` and
/// of an already-`Sendable` type (`BlockBackend: Sendable`,
/// `EntropyProbing: Sendable`, `Int`), so the struct is safe to share
/// across `@Sendable` closure boundaries — which is what the
/// `KnitCompressor` cross-entry parallel batch path needs to capture
/// the streamer in `concurrentMap`. Swift 6 strict-concurrency does
/// *not* auto-infer `Sendable` for `public` structs, so without this
/// the captured-type diagnostic fires (`#SendableClosureCaptures`).
public struct StreamingBlockCompressor: Sendable {

    /// Result of one block's worth of work, returned from a worker to
    /// the driver.
    fileprivate struct ProcessedBlock: Sendable {
        let absoluteIdx: Int
        let originalSize: Int
        let frame: Data
        let blockCrc: UInt32
        let entropy: Float
        let levelUsed: Int32
        /// Per-block CPU-time spent in each sub-stage of the worker
        /// pipeline. Aggregated into `StageAnalytics` by the drain
        /// loop. Zero when the analytics accumulator is nil (the
        /// worker skips the per-stage `ContinuousClock.now` reads).
        let entropyCPU: TimeInterval
        let crcCPU: TimeInterval
        let compressCPU: TimeInterval
    }

    /// Aggregate output: per-block compressed sizes, total compressed
    /// bytes, and the combined entry CRC32.
    public struct Output: Sendable {
        public var blockSizes: [UInt32]
        public var totalIn: UInt64
        public var totalOut: UInt64
        public var crc32: UInt32
    }

    public let backend: BlockBackend
    public let blockSize: Int
    public let concurrency: Int
    /// Entropy probe used to decide per-block lvl=1 downgrade. Defaults
    /// to `MetalEntropyProbe` when constructible, with `CPUEntropyProbe`
    /// as fallback for hosts with no Metal device or for buffers below
    /// the GPU dispatch-amortisation threshold.
    ///
    /// **Why this is its own field, not inline in the worker**: pack
    /// analyse on a 80 GB Windows-VM `.pvm.knit` showed
    /// `compute.entropy` at 826 s (97.6 %) of cumulative worker CPU
    /// time — the per-block CPU histogram was almost the entire pack
    /// workload because the input was incompressible (ratio 99.7 %)
    /// and the workers' zstd phase was negligible. Batched GPU
    /// probing dispatches one Metal kernel per batch instead of N
    /// CPU histograms per worker, dropping 826 s of CPU work to
    /// ~few seconds of GPU work and unblocking the SSD-write path.
    public let entropyProbe: any EntropyProbing

    public init(backend: BlockBackend,
                blockSize: Int = 1 * 1024 * 1024,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                entropyProbe: (any EntropyProbing)? = nil) {
        self.backend = backend
        self.blockSize = blockSize
        self.concurrency = max(1, concurrency)
        // Resolve the probe: explicit override wins, otherwise pick
        // GPU-when-available via AutoEntropyProbe (which falls back to
        // CPU internally on hosts with no Metal device).
        self.entropyProbe = entropyProbe ?? AutoEntropyProbe()
    }

    /// Compress `input` block-by-block, calling `sink` with each
    /// compressed frame in input order. The sink is the streaming write
    /// boundary: typically a `KnitWriter.StreamingEntry.writeBlock(_:)`.
    /// Optionally records `HeatmapSample` per block for the visualization.
    ///
    /// - Parameters:
    ///   - input: full mmap'd or in-memory uncompressed buffer.
    ///   - level: base zstd compression level. Per-block downgrade to 1
    ///     is applied internally for blocks above the entropy threshold
    ///     when `entropyDowngradeEnabled` is true.
    ///   - entropyDowngradeEnabled: opt-out for the inline entropy probe.
    ///   - heatmapRecorder: optional collector for the heatmap UI.
    ///   - sink: called once per block in input order. Block bytes are
    ///     released as soon as it returns.
    public func compress(
        _ input: UnsafeBufferPointer<UInt8>,
        level: Int32,
        entropyDowngradeEnabled: Bool = true,
        heatmapRecorder: HeatmapRecorder? = nil,
        progressReporter: ProgressReporter? = nil,
        analytics: StageAnalytics? = nil,
        sink: (_ blockIdx: Int, _ frame: Data) throws -> Void
    ) throws -> Output {
        if input.count == 0 {
            return Output(blockSizes: [], totalIn: 0, totalOut: 0, crc32: 0)
        }

        // Slice plan up front: deterministic and trivial to chunk.
        // Built into a `let` rather than a `var` so the @Sendable
        // worker closures below can capture it without tripping Swift 6
        // strict-concurrency's "captured mutable variable" diagnostic.
        let slices: [(offset: Int, length: Int)] = stride(
            from: 0, to: input.count, by: blockSize
        ).map { off in
            (offset: off, length: min(blockSize, input.count - off))
        }

        let basePtr = SendableRawPointer(input.baseAddress!)
        let backend = self.backend
        let baseLevel = level

        // Batches keep memory bounded. A batch is `concurrency × 2` so
        // workers stay saturated while the driver drains the previous
        // batch's results in order.
        let batchSize = max(8, concurrency * 2)

        var blockSizes: [UInt32] = Array(repeating: 0, count: slices.count)
        var totalOut: UInt64 = 0
        var combinedCRC: UInt32 = 0
        var firstBlock = true
        var batchStart = 0

        let entropyProbe = self.entropyProbe
        let blockSizeLocal = self.blockSize
        let entropyDowngradeEnabledLocal = entropyDowngradeEnabled

        // Pipelined probe (Phase 2): instead of running the per-batch
        // entropy probe synchronously between worker batches, we launch
        // each probe on `DispatchQueue.global` BEFORE workers start on
        // the current batch — so the probe for batch N+1 overlaps with
        // worker compress on batch N. The 18 ms GPU dispatch + wait
        // that dominated VM pack wall (PR #36's revert root cause) is
        // now hidden behind worker work that runs at the same
        // ~17 ms-idle / 1 ms-busy cadence as pre-#36, avoiding the
        // sustained-load thermal/scheduler regression PR #36's
        // probe-elimination triggered.
        //
        // `currentProbe` is the entropies for the batch we're about
        // to compress; resolved synchronously below. `prepareProbe`
        // either synthesises immediately (entropy disabled, or batch
        // below `MetalEntropyProbe.minBufferForGPU`) or dispatches
        // the GPU work async and returns a `ProbeFuture` we `wait()`
        // on later.
        let probeContext = ProbeContext(
            entropyProbe: entropyProbe,
            entropyDowngradeEnabled: entropyDowngradeEnabledLocal,
            slices: slices,
            basePtr: basePtr,
            blockSize: blockSizeLocal
        )
        var currentProbe = probeContext.prepare(
            batchStart: 0,
            batchEnd: min(batchSize, slices.count)
        )

        while batchStart < slices.count {
            let batchEnd = min(batchStart + batchSize, slices.count)
            let batchIndices = Array(batchStart..<batchEnd)

            // Launch probe for the NEXT batch *before* resolving the
            // current one. The GPU dispatch + wait happens on a
            // background queue; the orchestrator returns immediately
            // and proceeds to workers.
            var nextProbe: PreparedProbe? = nil
            if batchEnd < slices.count {
                let nextEnd = min(batchEnd + batchSize, slices.count)
                nextProbe = probeContext.prepare(
                    batchStart: batchEnd,
                    batchEnd: nextEnd
                )
            }

            // Step 0: resolve current entropies. For batches whose
            // probe was synthesised (sync case) this is free; for
            // async-dispatched probes this blocks only if the probe
            // hasn't finished yet — which is the rare case where the
            // previous batch's worker work was faster than its
            // overlapping probe.
            let entropyWallStart = ContinuousClock.now
            let entropies: [EntropyResult] = currentProbe.resolve(
                batchStart: batchStart,
                batchEnd: batchEnd,
                slices: slices
            )
            let entropyWallSeconds = (ContinuousClock.now - entropyWallStart).timeIntervalSeconds
            analytics?.record(stage: "entropy.probe", seconds: entropyWallSeconds)

            // Pre-compute decisions on the orchestrator thread so the
            // worker closure stays minimal. `EntropyResult.entropy` is
            // a `Float`, so the array is trivially Sendable for the
            // concurrentMap closure.
            let perBlockEntropy: [Float] = (0..<batchIndices.count).map { i in
                i < entropies.count ? entropies[i].entropy : 0
            }

            // Process this batch in parallel. Each worker does the
            // remaining per-block pipeline (level decision, CRC, zstd)
            // on cache-warm pages.
            let measureCPU = analytics != nil
            // Snapshot the outer-loop var into an immutable `let` for
            // the concurrentMap closure. Capturing the `var batchStart`
            // directly trips Swift 6 strict-concurrency
            // (`#SendableClosureCaptures` — captured mutable variable
            // in concurrently-executing code).
            let batchBase = batchStart
            let parallelStart = ContinuousClock.now
            let processed: [ProcessedBlock] = try concurrentMap(
                batchIndices,
                concurrency: concurrency
            ) { absoluteIdx in
                let slice = slices[absoluteIdx]
                let p = basePtr.value.advanced(by: slice.offset)
                let bv = UnsafeBufferPointer(start: p, count: slice.length)

                // Step 1: pre-computed entropy from the batch probe.
                // Per-worker `entropyCPU` is now zero — that line is
                // batch-level wall, recorded once below as
                // `entropy.probe`. We keep the field on
                // `ProcessedBlock` for compatibility with the analyse
                // aggregation but it stays 0.
                let entropy: Float = perBlockEntropy[absoluteIdx - batchBase]
                let entropyCPU: TimeInterval = 0

                // Step 2: per-block level decision. lvl≥3 match search
                // is overhead on incompressible blocks; downgrade to
                // lvl=1 (`fast` strategy) for those.
                let useFast = entropyDowngradeEnabled
                    && entropy >= EntropyResult.incompressibleThreshold
                    && baseLevel > 1
                let lvl: Int32 = useFast ? 1 : baseLevel

                // Step 3: CRC32. libdeflate's hardware-accelerated path
                // hits the dedicated arm64 CRC32 instruction, ~5–8 GB/s
                // per P-core. Same in-cache pages as the histogram and
                // codec walks, so disk-read amplification is gone.
                let crcStart = measureCPU ? ContinuousClock.now : nil
                let blockCrc = UInt32(libdeflate_crc32(0, bv.baseAddress, bv.count))
                let crcCPU = crcStart.map { (ContinuousClock.now - $0).timeIntervalSeconds } ?? 0

                // Step 4: zstd frame.
                let compressStart = measureCPU ? ContinuousClock.now : nil
                let frame = try backend.compressBlock(bv, level: lvl)
                let compressCPU = compressStart.map { (ContinuousClock.now - $0).timeIntervalSeconds } ?? 0

                return ProcessedBlock(
                    absoluteIdx: absoluteIdx,
                    originalSize: bv.count,
                    frame: frame,
                    blockCrc: blockCrc,
                    entropy: entropy,
                    levelUsed: lvl,
                    entropyCPU: entropyCPU,
                    crcCPU: crcCPU,
                    compressCPU: compressCPU
                )
            }
            analytics?.record(stage: "parallel.compress",
                              seconds: (ContinuousClock.now - parallelStart).timeIntervalSeconds)

            // Aggregate the batch's per-block CPU times into the
            // analytics. These sums are *cumulative across workers*,
            // not wall, so they can exceed `parallel.compress` —
            // that's the point: they tell us how much CPU work each
            // sub-stage costs, which is what decides whether GPU
            // offload of that stage is worth building.
            if let analytics = analytics {
                var totalEntropyCPU: TimeInterval = 0
                var totalCRCCPU: TimeInterval = 0
                var totalCompressCPU: TimeInterval = 0
                for pb in processed {
                    totalEntropyCPU += pb.entropyCPU
                    totalCRCCPU += pb.crcCPU
                    totalCompressCPU += pb.compressCPU
                }
                analytics.record(stage: "compute.entropy", seconds: totalEntropyCPU)
                analytics.record(stage: "compute.crc",     seconds: totalCRCCPU)
                analytics.record(stage: "compute.compress", seconds: totalCompressCPU)
            }

            // Drain the batch in order: write to disk, fold CRC, record
            // heatmap. After this loop the batch's `Data` references are
            // released and the worker pool can repopulate.
            let drainStart = ContinuousClock.now
            var heatmapBatch: [HeatmapSample] = []
            if heatmapRecorder != nil {
                heatmapBatch.reserveCapacity(processed.count)
            }
            for pb in processed {
                try sink(pb.absoluteIdx, pb.frame)
                blockSizes[pb.absoluteIdx] = UInt32(pb.frame.count)
                totalOut += UInt64(pb.frame.count)
                // Record uncompressed bytes processed — this matches what
                // the user's mental model of "how much of my file is
                // done" expects (the input side, not the encoder output).
                progressReporter?.advance(by: UInt64(pb.originalSize))
                if firstBlock {
                    combinedCRC = pb.blockCrc
                    firstBlock = false
                } else {
                    combinedCRC = crc32Combine(crc1: combinedCRC,
                                               crc2: pb.blockCrc,
                                               len2: UInt(pb.originalSize))
                }
                if heatmapRecorder != nil {
                    let disposition: HeatmapSample.Disposition =
                        (pb.levelUsed == 1 && baseLevel > 1) ? .stored : .compressed
                    heatmapBatch.append(HeatmapSample(
                        entropy: pb.entropy,
                        originalBytes: pb.originalSize,
                        storedBytes: pb.frame.count,
                        disposition: disposition
                    ))
                }
            }
            heatmapRecorder?.recordBatch(heatmapBatch)
            analytics?.record(stage: "archive.write",
                              seconds: (ContinuousClock.now - drainStart).timeIntervalSeconds)
            // Per-batch tick: aggregate input bytes for the average-batch-size
            // line. Fallback count is unused on the encode path (no GPU
            // fallback yet), passed as 0.
            let batchInputBytes = processed.reduce(0) { $0 + UInt64($1.originalSize) }
            analytics?.recordBatch(bytes: batchInputBytes, fallback: 0)

            // Advance to the next batch's probe (already launched
            // above and likely already complete by this point —
            // workers + drain are typically faster than the 18 ms
            // probe dispatch on big-file batches).
            if let nextProbe = nextProbe {
                currentProbe = nextProbe
            }
            batchStart = batchEnd
        }

        return Output(
            blockSizes: blockSizes,
            totalIn: UInt64(input.count),
            totalOut: totalOut,
            crc32: combinedCRC
        )
    }
}

// MARK: - Pipelined entropy-probe machinery

/// Thread-safe holder for an async entropy-probe result.
///
/// `@unchecked Sendable` because the safety property (single
/// producer signals the semaphore at most once; consumers `wait()`
/// before reading) is enforced by `DispatchSemaphore` rather than
/// the type system.
fileprivate final class ProbeFuture: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var entropies: [EntropyResult] = []
    private var error: Error?

    func succeed(_ e: [EntropyResult]) {
        lock.lock(); entropies = e; lock.unlock()
        done.signal()
    }

    func fail(_ err: Error) {
        lock.lock(); error = err; lock.unlock()
        done.signal()
    }

    /// Block until the async probe completes, then return its
    /// result. Errors are propagated to the caller, which falls
    /// back to synthesised zero-entropy results.
    func wait() throws -> [EntropyResult] {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        if let err = error { throw err }
        return entropies
    }
}

/// One batch's probe — either synthesised on the spot (when the
/// batch is below the GPU dispatch threshold or entropy downgrade
/// is disabled), or an in-flight async future. Resolution is
/// uniform: `resolve(...)` returns `[EntropyResult]` either way.
fileprivate enum PreparedProbe {
    case sync([EntropyResult])
    case async(ProbeFuture)

    func resolve(batchStart: Int,
                 batchEnd: Int,
                 slices: [(offset: Int, length: Int)]) -> [EntropyResult] {
        switch self {
        case .sync(let e):
            return e
        case .async(let f):
            do { return try f.wait() }
            catch {
                // Fail-soft: synthesise zero entropy on probe error
                // so the user-requested level is honoured for the
                // batch. Same semantics as the existing inline-
                // catch path that this pipeline replaces.
                return (batchStart..<batchEnd).map { i in
                    EntropyResult(entropy: 0, byteCount: slices[i].length)
                }
            }
        }
    }
}

/// Captures the immutable inputs `prepare(...)` needs from the
/// surrounding `compress(...)` scope so the async closure that
/// runs the probe doesn't have to capture `self` or the per-batch
/// `var`s. Built once at the top of `compress(...)`.
fileprivate struct ProbeContext: @unchecked Sendable {
    let entropyProbe: any EntropyProbing
    let entropyDowngradeEnabled: Bool
    let slices: [(offset: Int, length: Int)]
    let basePtr: SendableRawPointer
    let blockSize: Int

    /// Prepare the entropy result for the batch range
    /// `[batchStart, batchEnd)`. Either returns a synced
    /// `PreparedProbe.sync(...)` immediately (cheap synthesis
    /// paths) or dispatches the GPU work async and returns
    /// `PreparedProbe.async(future)`. Callers `resolve(...)` the
    /// future when they actually need the entropies.
    func prepare(batchStart: Int, batchEnd: Int) -> PreparedProbe {
        // Probe disabled: synthesise zero entropy so the worker's
        // downgrade test stays simple.
        if !entropyDowngradeEnabled {
            return .sync((batchStart..<batchEnd).map { i in
                EntropyResult(entropy: 0, byteCount: slices[i].length)
            })
        }
        let firstSlice = slices[batchStart]
        let lastSlice = slices[batchEnd - 1]
        let batchByteStart = firstSlice.offset
        let batchByteEnd = lastSlice.offset + lastSlice.length
        let batchBufferLen = batchByteEnd - batchByteStart
        // Below GPU dispatch threshold: skip the probe and
        // synthesise zero entropy (PR #33 semantics). Workers
        // honour the user-requested level on the tiny batch.
        // Sync-resolved so no `DispatchQueue.global` round-trip
        // is incurred on small-file workloads.
        if batchBufferLen < MetalEntropyProbe.minBufferForGPU {
            return .sync((batchStart..<batchEnd).map { i in
                EntropyResult(entropy: 0, byteCount: slices[i].length)
            })
        }
        // Big-batch path: dispatch the probe to a background
        // queue so the orchestrator can immediately move on to
        // running workers on the *previous* batch's entropies.
        // The 18 ms GPU dispatch + wait that dominated VM pack
        // wall now overlaps with worker compress instead of
        // serially preceding it.
        let basePtrLocal = basePtr
        let blockSizeLocal = blockSize
        let probeLocal = entropyProbe
        let future = ProbeFuture()
        DispatchQueue.global(qos: .userInitiated).async {
            let buf = UnsafeBufferPointer(
                start: basePtrLocal.value.advanced(by: batchByteStart),
                count: batchBufferLen
            )
            do {
                let r = try probeLocal.probe(buf, blockSize: blockSizeLocal)
                future.succeed(r)
            } catch {
                future.fail(error)
            }
        }
        return .async(future)
    }
}
