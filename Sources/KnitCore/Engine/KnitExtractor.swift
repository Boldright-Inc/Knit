import Foundation

/// Top-level extractor for `.knit` archives.
///
/// Sits between the CLI and `KnitReader`: opens the archive, validates
/// each entry name with `SafePath` (zip-slip defence), and routes large
/// entries through the optional GPU CRC32 verifier. Decompression itself
/// happens inside `KnitReader.extract`, driven by a shared
/// `HybridZstdBatchDecoder` that parallelises per-block libzstd calls
/// across `concurrency` worker threads — the same pattern that gives
/// `pack` its 8 GB/s ceiling. Without this, decode is a single-threaded
/// `ZSTD_decompress` loop and tops out at ~750 MB/s on M5 Max even
/// though SSD write bandwidth is ten times higher.
///
/// Cross-entry parallelism isn't done here because real archives often
/// have one giant entry that dominates total decode time (e.g. a single
/// VM disk image inside a `.pvm.knit`); intra-entry block parallelism
/// is what closes the gap to the SSD ceiling on those workloads.
public final class KnitExtractor {

    /// Aggregate result returned to the CLI / callers. `gpuVerifyUsed`
    /// lets the CLI report which verification path actually ran for the
    /// archive (the GPU path is conditional on entry size and Metal
    /// availability).
    public struct Stats: Sendable {
        public let entries: Int
        public let bytesOut: UInt64
        public let elapsed: TimeInterval
        /// True iff at least one entry was verified on the GPU.
        public let gpuVerifyUsed: Bool
    }

    /// When true, large entries are CRC-verified on the GPU after extraction.
    /// On unified-memory Apple Silicon the verification mmap is page-cache
    /// hot so the cost is dominated by the GPU dispatch + compute, not I/O.
    public var useGPUVerify: Bool

    /// Optional progress sink. Receives one `advance(by:)` call per
    /// decompressed block, plus a final per-entry catch-up so the line
    /// reaches 100% even when the verify path runs.
    public var progressReporter: ProgressReporter?

    /// Number of worker threads the `HybridZstdBatchDecoder` runs per
    /// batch. Defaults to `activeProcessorCount`; pass 1 to force
    /// serial decode (mostly useful in tests).
    public var concurrency: Int

    /// Optional per-stage timing accumulator. Wired through to the
    /// staged decoder; nil = no instrumentation overhead. Driven by
    /// the CLI's hidden `--analyze` flag, which renders the snapshot
    /// after extract finishes.
    public var analytics: DecodeAnalytics?

    public init(useGPUVerify: Bool = true,
                progressReporter: ProgressReporter? = nil,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                analytics: DecodeAnalytics? = nil) {
        self.useGPUVerify = useGPUVerify
        self.progressReporter = progressReporter
        self.concurrency = max(1, concurrency)
        self.analytics = analytics
    }

    public func extract(archive: URL, to destDir: URL) throws -> Stats {
        let reader = try KnitReader(url: archive)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Lazily instantiate the GPU CRC pipeline. Failing to construct one
        // (no Metal device, kernel compile failure, etc.) silently falls
        // back to libdeflate's CPU CRC32 — verification still happens.
        let gpuCRC: MetalCRC32? = useGPUVerify ? MetalCRC32() : nil
        var gpuUsed = false

        // One staged decoder shared across all entries: its only mutable
        // state is per-entry watchdog tracking, which the call-site loop
        // resets implicitly between entries. CPU-only at the moment;
        // future GPU `BlockDecoding` implementations slot into the
        // `gpuPath:` parameter.
        let stagedDecoder = HybridZstdBatchDecoder(concurrency: concurrency,
                                                   analytics: analytics)

        let start = ContinuousClock.now
        var bytesOut: UInt64 = 0
        for entry in reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: destDir)
            try reader.extract(entry,
                               to: outURL,
                               gpuCRC: gpuCRC,
                               progressReporter: progressReporter,
                               stagedDecoder: stagedDecoder)
            bytesOut += entry.uncompressedSize
            if gpuCRC != nil, entry.uncompressedSize >= 4 * 1024 * 1024 {
                gpuUsed = true
            }
        }
        let elapsed = ContinuousClock.now - start
        return Stats(
            entries: reader.archive.entries.count,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds,
            gpuVerifyUsed: gpuUsed
        )
    }
}
