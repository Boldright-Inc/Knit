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
        let reporter = options.progressReporter
        let prepared: [PreparedEntry] = try concurrentMap(
            entries,
            concurrency: options.concurrency
        ) { entry in
            let p = try self.prepare(entry: entry)
            // ZIP path is per-entry; advance by uncompressed size as
            // each entry finishes its codec pass. The reporter sees
            // bumps roughly in walk order modulo concurrency.
            reporter?.advance(by: p.uncompressedSize)
            return p
        }

        for p in prepared {
            try writer.writeEntry(
                descriptor: p.descriptor,
                method: p.method,
                crc32: p.crc,
                uncompressedSize: p.uncompressedSize,
                payload: p.payload
            )
            bytesIn  += p.uncompressedSize
            bytesOut += UInt64(p.payload.count)
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

    fileprivate struct PreparedEntry: Sendable {
        let descriptor: ZipWriter.EntryDescriptor
        let method: CompressionMethod
        let crc: UInt32
        let uncompressedSize: UInt64
        let payload: Data
    }

    private static func dataFromBuffer(_ buf: UnsafeBufferPointer<UInt8>) -> Data {
        guard let base = buf.baseAddress, buf.count > 0 else { return Data() }
        return Data(bytes: base, count: buf.count)
    }

    private func prepare(entry: FileEntry) throws -> PreparedEntry {
        let descriptor = ZipWriter.EntryDescriptor(
            name: entry.relativePath,
            modificationDate: entry.modificationDate,
            unixMode: entry.unixMode,
            isDirectory: entry.isDirectory
        )

        if entry.isDirectory {
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: 0,
                uncompressedSize: 0,
                payload: Data()
            )
        }

        let mapped = try MappedFile(url: entry.absoluteURL)
        let buf = mapped.buffer

        // Decide method: store if data is small, incompressible (heuristic on
        // try-then-fallback) or level == 0.
        if options.level.raw == 0 || buf.count == 0 {
            let crcVal = buf.count == 0 ? 0 : crc.crc32(buf, seed: 0)
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: Self.dataFromBuffer(buf)
            )
        }

        // Pre-screen via the entropy probe. Above the incompressibility
        // threshold there's no productive work for the codec to do — we'd
        // attempt a full compress() and then fall back to .stored anyway.
        // Skip straight to .stored, saving the wasted CPU pass.
        let probeBlockSize = 1 * 1024 * 1024
        var probeResults: [EntropyResult] = []
        if options.entropyProbeEnabled {
            probeResults = (try? probe.probe(buf, blockSize: probeBlockSize)) ?? []
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
            return PreparedEntry(
                descriptor: descriptor,
                method: .stored,
                crc: crcVal,
                uncompressedSize: UInt64(buf.count),
                payload: Self.dataFromBuffer(buf)
            )
        }

        let compressed = try backend.compress(buf, level: options.level.clampedForDeflate())
        let crcVal = crc.crc32(buf, seed: 0)

        // If compression made it larger, store uncompressed instead (ZIP spec encourages this).
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
                payload: Self.dataFromBuffer(buf)
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
            payload: compressed
        )
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
