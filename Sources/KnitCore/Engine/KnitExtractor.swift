import Foundation

/// Top-level extractor for `.knit` archives.
///
/// Sits between the CLI and `KnitReader`: opens the archive, validates
/// each entry name with `SafePath` (zip-slip defence), and routes large
/// entries through the optional GPU CRC32 verifier. Decompression itself
/// happens inside `KnitReader.extract`.
///
/// The extractor is intentionally synchronous and serial — extract speed
/// is dominated by SSD write bandwidth on every Apple Silicon
/// configuration we measure, so per-entry parallelism wouldn't help.
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

    public init(useGPUVerify: Bool = true,
                progressReporter: ProgressReporter? = nil) {
        self.useGPUVerify = useGPUVerify
        self.progressReporter = progressReporter
    }

    public func extract(archive: URL, to destDir: URL) throws -> Stats {
        let reader = try KnitReader(url: archive)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Lazily instantiate the GPU CRC pipeline. Failing to construct one
        // (no Metal device, kernel compile failure, etc.) silently falls
        // back to libdeflate's CPU CRC32 — verification still happens.
        let gpuCRC: MetalCRC32? = useGPUVerify ? MetalCRC32() : nil
        var gpuUsed = false

        let start = ContinuousClock.now
        var bytesOut: UInt64 = 0
        for entry in reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: destDir)
            try reader.extract(entry,
                               to: outURL,
                               gpuCRC: gpuCRC,
                               progressReporter: progressReporter)
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
