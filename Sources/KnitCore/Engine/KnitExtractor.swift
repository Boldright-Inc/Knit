import Foundation

public final class KnitExtractor {

    public struct Stats: Sendable {
        public let entries: Int
        public let bytesOut: UInt64
        public let elapsed: TimeInterval
        /// Whether GPU CRC32 verification was used for at least one entry.
        public let gpuVerifyUsed: Bool
    }

    /// When true, large entries are CRC-verified on the GPU after extraction.
    /// On unified-memory Apple Silicon the verification mmap is page-cache
    /// hot so the cost is dominated by the GPU dispatch + compute, not I/O.
    public var useGPUVerify: Bool

    public init(useGPUVerify: Bool = true) {
        self.useGPUVerify = useGPUVerify
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
            try reader.extract(entry, to: outURL, gpuCRC: gpuCRC)
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
