import Foundation

public struct CompressionStats: Sendable {
    public let entriesWritten: Int
    public let bytesIn: UInt64
    public let bytesOut: UInt64
    public let elapsed: TimeInterval

    public var inputThroughputMBPerSec: Double {
        guard elapsed > 0 else { return 0 }
        return Double(bytesIn) / 1_000_000.0 / elapsed
    }

    public var ratio: Double {
        guard bytesIn > 0 else { return 0 }
        return Double(bytesOut) / Double(bytesIn)
    }
}

/// High-level compression orchestrator. Reads files, fans out to a backend,
/// writes results into a streaming `ZipWriter`.
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

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    mmapThreshold: Int = 4 * 1024 * 1024,
                    heatmapRecorder: HeatmapRecorder? = nil,
                    entropyProbeEnabled: Bool = true) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.mmapThreshold = mmapThreshold
            self.heatmapRecorder = heatmapRecorder
            self.entropyProbeEnabled = entropyProbeEnabled
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
        let entries = try FileWalker.enumerate(input)
        let writer = try ZipWriter(url: output)

        let start = ContinuousClock.now
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        // Stage 1: concurrently produce per-entry compressed payloads.
        // Stage 2: write to ZIP serially in walk order.
        let prepared: [PreparedEntry] = try concurrentMap(
            entries,
            concurrency: options.concurrency
        ) { entry in
            try self.prepare(entry: entry)
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

private final class ConcurrentMapState<V: Sendable>: @unchecked Sendable {
    var results: [V?]
    var firstError: Error?
    let lock = NSLock()
    init(count: Int) { self.results = Array(repeating: nil, count: count) }
}

/// Apply `transform` to each element of `items` using a concurrent dispatch
/// queue, preserving input order in the result. Throws the first error seen.
func concurrentMap<T: Sendable, U: Sendable>(
    _ items: [T],
    concurrency: Int,
    _ transform: @escaping @Sendable (T) throws -> U
) throws -> [U] {
    if items.isEmpty { return [] }
    let state = ConcurrentMapState<U>(count: items.count)
    let queue = DispatchQueue(label: "co.boldright.knit.concurrent",
                              attributes: .concurrent)
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
