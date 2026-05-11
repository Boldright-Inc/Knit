import Foundation

/// Aggregate result of one compression run. Surfaces both the raw counts
/// and a derived MB/s figure for the CLI's status print and the bench
/// harness.
public struct CompressionStats: Sendable {
    public let entriesWritten: Int
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let elapsed: TimeInterval

    /// Throughput measured against *uncompressed* input bytes — the
    /// number users care about, since it tracks "how fast did the tool
    /// chew through my data".
    public var inputThroughputMBPerSec: Double {
        guard elapsed > 0 else { return 0 }
        return Double(bytesIn) / 1_000_000.0 / elapsed
    }

    /// Compressed/uncompressed ratio in [0, 1]. Lower is better.
    public var ratio: Double {
        guard bytesIn > 0 else { return 0 }
        return Double(bytesOut) / Double(bytesIn)
    }
}

/// High-level orchestrator for the ZIP path. Operates as a two-stage
/// pipeline:
///
///   1. **Concurrent prepare** (fan-out): each entry is mmap'd, optionally
///      entropy-screened, compressed via the supplied backend, and turned
///      into a `PreparedEntry` — all in parallel via `concurrentMap`.
///   2. **Serial write**: the prepared entries are streamed into
///      `ZipWriter` in walk order so local-header offsets stay
///      monotonically increasing (a ZIP requirement that simplifies
///      central-directory construction).
///
/// Splitting the pipeline this way means the codec runs N-way parallel
/// while the I/O writer remains single-threaded, which keeps both the
/// archive layout deterministic and the file handle's mutation
/// well-defined.
public final class ZipCompressor: Sendable {

    public struct Options: Sendable {
        public var level: CompressionLevel
        /// Maximum concurrent compression jobs. Defaults to physical core count.
        public var concurrency: Int
        /// Files smaller than this are compressed inline; larger files are
        /// memory-mapped before compression.
        public var mmapThreshold: Int
        /// Optional sink for per-block compressibility samples. When set,
        /// the compressor pushes one `HeatmapSample` per processed entry.
        public var heatmapRecorder: HeatmapRecorder?
        /// When true, run the entropy probe before invoking the codec and
        /// store the raw bytes when the entry's overall entropy exceeds the
        /// incompressibility threshold.
        public var entropyProbeEnabled: Bool
        /// Optional progress sink. The compressor calls `advance(by:)`
        /// once per finished entry, in input-byte units.
        public var progressReporter: ProgressReporter?
        /// When true, the file walker excludes hidden items. Defaults
        /// to **false** — see the matching field in
        /// `KnitCompressor.Options` for the rationale.
        public var excludeHidden: Bool
        /// Optional collector populated by `FileWalker.enumerate`.
        public var walkSkipCollector: WalkSkipCollector?

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    mmapThreshold: Int = 4 * 1024 * 1024,
                    heatmapRecorder: HeatmapRecorder? = nil,
                    entropyProbeEnabled: Bool = true,
                    progressReporter: ProgressReporter? = nil,
                    excludeHidden: Bool = false,
                    walkSkipCollector: WalkSkipCollector? = nil) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.mmapThreshold = mmapThreshold
            self.heatmapRecorder = heatmapRecorder
            self.entropyProbeEnabled = entropyProbeEnabled
            self.progressReporter = progressReporter
            self.excludeHidden = excludeHidden
            self.walkSkipCollector = walkSkipCollector
        }
    }

    private let backend: DeflateBackend
    private let crc: CRC32Computing
    private let options: Options
    private let probe: any EntropyProbing

    public init(backend: DeflateBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.crc = backend
        self.options = options
        self.probe = AutoEntropyProbe()
    }

    /// Compress every entry under `input` (file or directory) into a ZIP at `output`.
    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(
            input,
            excludeHidden: options.excludeHidden,
            skipCollector: options.walkSkipCollector
        )
        let writer = try ZipWriter(url: output)

        let start = ContinuousClock.now
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        // Stage 1: concurrently produce per-entry compressed payloads.
        // Stage 2: write to ZIP serially in walk order.
        //
        // Progress reporting (PR #71): each entry contributes
        // `uncompressedSize` to the reporter's total budget. The
        // budget is distributed across three phases (probe, codec,
        // write) so the bar visibly moves regardless of which phase
        // dominates wall-clock for the workload:
        //
        //   entropy probe — half rate, fires per Metal dispatch
        //                   (≤4 GiB/dispatch on M3 Max / M5 Max, so a
        //                   long incompressible-file probe ticks ~20
        //                   times instead of sitting silent for
        //                   seconds)
        //   codec compress — half rate, fires per chunk via
        //                   ParallelDeflate's onProgress (PR #54)
        //   payload write — variable rate per entry, controlled by
        //                   PreparedEntry.writeAdvanceRate; see the
        //                   enum's doc-block for the four cases.
        //
        // Net effect on a typical entry: the bar ticks throughout
        // the entry's lifetime instead of all-or-nothing during one
        // phase. Sums per entry to exactly `uncompressedSize`.
        let reporter = options.progressReporter
        // Half-rate closures for the prepare phases.  Explicit `if
        // let` (instead of `Optional.map`) because Swift 6's
        // inferencer fails on closure-returning-closure with
        // @Sendable.
        let probeOnProgress: (@Sendable (UInt64) -> Void)?
        let codecOnProgress: (@Sendable (UInt64) -> Void)?
        if let r = reporter {
            probeOnProgress = { bytes in r.advance(by: bytes / 2) }
            codecOnProgress = { bytes in r.advance(by: bytes / 2) }
        } else {
            probeOnProgress = nil
            codecOnProgress = nil
        }
        let prepared: [PreparedEntry] = try concurrentMap(
            entries,
            concurrency: options.concurrency
        ) { entry in
            return try self.prepare(entry: entry,
                                     probeOnProgress: probeOnProgress,
                                     codecOnProgress: codecOnProgress)
        }

        for p in prepared {
            // PR #71: writer rate per entry. See `WriteAdvanceRate`
            // for what each case represents.
            let writeProgress: (@Sendable (UInt64) -> Void)?
            switch p.writeAdvanceRate {
            case .none:
                writeProgress = nil
            case .full:
                if let r = reporter {
                    writeProgress = { written in r.advance(by: written) }
                } else {
                    writeProgress = nil
                }
            case .half:
                if let r = reporter {
                    writeProgress = { written in r.advance(by: written / 2) }
                } else {
                    writeProgress = nil
                }
            }
            try writer.writeEntry(
                descriptor: p.descriptor,
                method: p.method,
                crc32: p.crc,
                uncompressedSize: p.uncompressedSize,
                payload: p.payload,
                onProgress: writeProgress
            )
            bytesIn  += p.uncompressedSize
            bytesOut += p.payloadByteCount
        }

        try writer.close()
        let elapsed = ContinuousClock.now - start

        return CompressionStats(
            entriesWritten: prepared.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }

    // MARK: - Per-entry preparation

    /// PR #71. Per-entry "how much of the entry's byte budget should
    /// the writer advance during the payload drain" indicator,
    /// replacing the prior `needsWriteAdvance: Bool`. Three states
    /// cover every prepare path:
    ///
    /// - `.none`  — every byte has already been credited during
    ///              prepare (the probe + codec phases together
    ///              covered the entry's `uncompressedSize`). Writer
    ///              does not advance the reporter.
    /// - `.full`  — nothing has been credited yet; the probe didn't
    ///              run (level=0 short-circuit, or empty file) and
    ///              the codec didn't run either. Writer advances by
    ///              the full payload byte count.
    /// - `.half`  — the probe ran (and contributed half the entry's
    ///              budget) but the codec was short-circuited
    ///              (entropy-too-high → `.stored`). Writer advances
    ///              by the OTHER half: each chunk-byte advances the
    ///              reporter by 0.5 byte.
    fileprivate enum WriteAdvanceRate: Sendable {
        case none
        case full
        case half
    }

    fileprivate struct PreparedEntry: @unchecked Sendable {
        let descriptor: ZipWriter.EntryDescriptor
        let method: CompressionMethod
        let crc: UInt32
        let uncompressedSize: UInt64
        /// PR #70. Was `Data`; widened to `ZipWriter.Payload` so a
        /// `.stored` entry pointing at a huge incompressible file (e.g.
        /// an 80 GB Parallels VM image) can stream straight from the
        /// mmap during the writer's drain instead of `Data(bytes:count:)`-
        /// copying the entire buffer into a fresh allocation during
        /// `prepare()`. `@unchecked Sendable` because the new
        /// `.mapped(MappedFile)` case carries a class — by the time the
        /// PreparedEntry reaches the serial write loop, the MappedFile
        /// has been fully constructed and is only read from, so the
        /// closed-over reference is effectively immutable.
        let payload: ZipWriter.Payload
        /// Convenience: payload byte count captured at construction
        /// so the write loop doesn't re-walk the enum every iteration.
        let payloadByteCount: UInt64
        /// PR #71. How much of this entry's `uncompressedSize`
        /// budget the writer should advance during its payload drain.
        /// See `WriteAdvanceRate` for the three cases.
        let writeAdvanceRate: WriteAdvanceRate
    }

    private static func dataFromBuffer(_ buf: UnsafeBufferPointer<UInt8>) -> Data {
        guard let base = buf.baseAddress, buf.count > 0 else { return Data() }
        return Data(bytes: base, count: buf.count)
    }

    private func prepare(entry: FileEntry,
                         probeOnProgress: (@Sendable (UInt64) -> Void)?,
                         codecOnProgress: (@Sendable (UInt64) -> Void)?) throws -> PreparedEntry {
        let descriptor = ZipWriter.EntryDescriptor(
            name: entry.relativePath,
            modificationDate: entry.modificationDate,
            unixMode: entry.unixMode,
            isDirectory: entry.isDirectory
        )

        if entry.isDirectory {
            // Directory entries don't contribute payload bytes — nothing
            // to advance for.
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: 0,
                uncompressedSize: 0,
                payload: .data(Data()),
                payloadByteCount: 0,
                writeAdvanceRate: .none
            )
        }

        let mapped = try MappedFile(url: entry.absoluteURL)
        let buf = mapped.buffer

        // Decide method: store if data is small, incompressible (heuristic on
        // try-then-fallback) or level == 0.
        if options.level.raw == 0 || buf.count == 0 {
            let crcVal = buf.count == 0 ? 0 : crc.crc32(buf, seed: 0)
            // .stored short-circuit: backend.compress(onProgress:) is
            // skipped AND the probe doesn't run for this branch. PR
            // #71: the writer is the only phase that contributes to
            // this entry's progress budget, so `.full` advance rate.
            // PR #70 streams from mmap (no Data copy).
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: .mapped(mapped),
                payloadByteCount: UInt64(buf.count),
                writeAdvanceRate: .full
            )
        }

        // Pre-screen via the entropy probe. Above the incompressibility
        // threshold there's no productive work for the codec to do — we'd
        // attempt a full compress() and then fall back to .stored anyway.
        // Skip straight to .stored, saving the wasted CPU pass.
        //
        // PR #71: pass `probeOnProgress` so a multi-GB probe (~ 5 s on
        // M5 Max for an 80 GB buffer) ticks the bar at half-rate as
        // each Metal dispatch completes.
        let probeBlockSize = 1 * 1024 * 1024
        var probeResults: [EntropyResult] = []
        var probeRan = false
        if options.entropyProbeEnabled {
            probeResults = (try? probe.probe(buf,
                                              blockSize: probeBlockSize,
                                              onProgress: probeOnProgress)) ?? []
            probeRan = !probeResults.isEmpty
        }
        let overall = byteWeightedEntropy(probeResults)

        if options.entropyProbeEnabled,
           !probeResults.isEmpty,
           overall >= EntropyResult.incompressibleThreshold {
            let crcVal = crc.crc32(buf, seed: 0)
            recordEntryHeatmap(probe: probeResults,
                               originalBytes: buf.count,
                               storedBytes: buf.count,
                               disposition: .stored)
            // Entropy-driven .stored: backend skipped. Probe advanced
            // half the budget (PR #71); writer advances the other half.
            // PR #70 streams from mmap, so no 80 GB Data copy.
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: .mapped(mapped),
                payloadByteCount: UInt64(buf.count),
                writeAdvanceRate: .half
            )
        }

        // The codec path: backend.compress(onProgress:) fires the
        // callback itself as it makes progress. ParallelDeflate fires
        // per chunk; CPUDeflate fires once at the end via the protocol
        // extension default. PR #71: half-rate when probe also ran
        // (typical), full-rate when probe was skipped (entropy probe
        // disabled by caller) — the codec then carries the whole
        // budget itself.
        let codecCallback = probeRan ? codecOnProgress : Self.reporterFullRateClosure(reporter: options.progressReporter)
        let compressed = try backend.compress(
            buf,
            level: options.level.clampedForDeflate(),
            onProgress: codecCallback
        )
        let crcVal = crc.crc32(buf, seed: 0)

        // If compression made it larger, store uncompressed instead
        // (ZIP spec encourages this). Probe + codec together have
        // already accounted for `buf.count`, so write must NOT advance.
        // PR #70 streams from mmap.
        if compressed.count >= buf.count {
            recordEntryHeatmap(probe: probeResults,
                               originalBytes: buf.count,
                               storedBytes: buf.count,
                               disposition: .stored)
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: .mapped(mapped),
                payloadByteCount: UInt64(buf.count),
                writeAdvanceRate: .none
            )
        }

        recordEntryHeatmap(probe: probeResults,
                           originalBytes: buf.count,
                           storedBytes: compressed.count,
                           disposition: .compressed)
        return PreparedEntry(
            descriptor: descriptor,
            method: .deflate,
            crc: crcVal,
            uncompressedSize: UInt64(buf.count),
            payload: .data(compressed),
            payloadByteCount: UInt64(compressed.count),
            writeAdvanceRate: .none
        )
    }

    /// PR #71 helper. When `entropyProbeEnabled == false` and the
    /// codec is the only phase that touches the bytes, it carries
    /// the entire entry budget at full rate. Built once per `prepare`
    /// call to keep the @Sendable closure construction off the hot
    /// path of the normal probe-ran case.
    private static func reporterFullRateClosure(
        reporter: ProgressReporter?
    ) -> (@Sendable (UInt64) -> Void)? {
        guard let r = reporter else { return nil }
        return { bytes in r.advance(by: bytes) }
    }

    /// Push one `HeatmapSample` per probed block into the recorder. When the
    /// probe wasn't run we synthesize a single coarse sample so the heatmap
    /// still reflects the entry's contribution to the archive.
    private func recordEntryHeatmap(probe: [EntropyResult],
                                    originalBytes: Int,
                                    storedBytes: Int,
                                    disposition: HeatmapSample.Disposition) {
        guard let recorder = options.heatmapRecorder, originalBytes > 0 else { return }
        if probe.isEmpty {
            recorder.record(HeatmapSample(
                entropy: 0,
                originalBytes: originalBytes,
                storedBytes: storedBytes,
                disposition: disposition
            ))
            return
        }
        // Distribute the entry's stored byte budget across blocks proportionally
        // to their original sizes. This isn't exact (blocks compress at
        // different individual ratios) but it's the right aggregate signal
        // for the visualization.
        let scale = Double(storedBytes) / Double(originalBytes)
        var batch: [HeatmapSample] = []
        batch.reserveCapacity(probe.count)
        for r in probe {
            let approxStored = Int((Double(r.byteCount) * scale).rounded())
            let perBlockDisposition: HeatmapSample.Disposition =
                (disposition == .stored || r.isLikelyIncompressible) ? .stored : .compressed
            batch.append(HeatmapSample(
                entropy: r.entropy,
                originalBytes: r.byteCount,
                storedBytes: approxStored,
                disposition: perBlockDisposition
            ))
        }
        recorder.recordBatch(batch)
    }

    private func byteWeightedEntropy(_ results: [EntropyResult]) -> Float {
        guard !results.isEmpty else { return 0 }
        var num: Double = 0
        var den: Double = 0
        for r in results {
            num += Double(r.entropy) * Double(r.byteCount)
            den += Double(r.byteCount)
        }
        return den > 0 ? Float(num / den) : 0
    }
}

// MARK: - Concurrent map helper

/// Shared mutable result + error state for `concurrentMap`. `@unchecked
/// Sendable` is correct because every access goes through `lock`.
private final class ConcurrentMapState<V: Sendable>: @unchecked Sendable {
    var results: [V?]
    var firstError: Error?
    let lock = NSLock()
    init(count: Int) { self.results = Array(repeating: nil, count: count) }
}

/// Apply `transform` to each element of `items` concurrently, preserving
/// input order in the result. Order preservation matters: the ZIP layout
/// relies on monotonically increasing local-header offsets, so we can't
/// just append results as workers finish.
///
/// On the first thrown error, in-flight tasks complete normally but no
/// new ones start. The first observed error is rethrown to the caller.
/// We chose this over a fully cancelling design because the codec calls
/// are short-lived (1 MiB blocks) and a few extra completions cost less
/// than wiring cancellation through libdeflate / libzstd.
func concurrentMap<T: Sendable, U: Sendable>(
    _ items: [T],
    concurrency: Int,
    _ transform: @escaping @Sendable (T) throws -> U
) throws -> [U] {
    if items.isEmpty { return [] }

    // Serial fast path. With `concurrency <= 1` (or a single item)
    // the parallel machinery — `DispatchQueue` creation,
    // `DispatchSemaphore`, `DispatchGroup`, async dispatch — is pure
    // overhead. The fast path matters in nested-parallel scenarios:
    // `KnitExtractor`'s parallel-batch unpack constructs per-worker
    // `HybridZstdBatchDecoder`s with `concurrency: 1` (the outer
    // entry-level `concurrentMap` is the source of parallelism), so
    // each of 100 k decode calls would otherwise allocate a brand
    // new `DispatchQueue` for one task.
    if concurrency <= 1 || items.count == 1 {
        return try items.map(transform)
    }

    let state = ConcurrentMapState<U>(count: items.count)
    let queue = DispatchQueue(label: "co.boldright.knit.concurrent",
                              attributes: .concurrent)
    // Semaphore caps simultaneous executions to `concurrency` regardless
    // of how many GCD threads the queue happens to spin up.
    let semaphore = DispatchSemaphore(value: concurrency)
    let group = DispatchGroup()

    for (idx, item) in items.enumerated() {
        semaphore.wait()
        state.lock.lock()
        let stop = state.firstError != nil
        state.lock.unlock()
        if stop {
            semaphore.signal()
            break
        }
        group.enter()
        queue.async {
            defer {
                semaphore.signal()
                group.leave()
            }
            do {
                let value = try transform(item)
                state.lock.lock(); state.results[idx] = value; state.lock.unlock()
            } catch {
                state.lock.lock()
                if state.firstError == nil { state.firstError = error }
                state.lock.unlock()
            }
        }
    }
    group.wait()
    if let e = state.firstError { throw e }
    return state.results.compactMap { $0 }
}

// MARK: - Helpers

extension Duration {
    public var timeIntervalSeconds: TimeInterval {
        let (sec, atto) = self.components
        return Double(sec) + Double(atto) / 1.0e18
    }
}
