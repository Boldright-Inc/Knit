import Foundation

/// Orchestrator for the `.knit` path.
///
/// Unlike `ZipCompressor`, the entry-level loop here is **serial** because
/// `KnitWriter` is append-only and we want deterministic on-disk layout.
/// The parallelism instead happens *inside* each entry: a single large
/// file is split into many independent zstd-frame blocks, all of which
/// compress in parallel via `StreamingBlockCompressor`.
///
/// **Memory contract**: peak RSS during compression is bounded by
/// `concurrency × blockSize`, independent of input file size. This is
/// what lets the tool handle 100 GB+ single files without OOM.
///
/// This shape suits the `.knit` use-case (often "one or a handful of very
/// large files") better than the ZIP shape (often "many small files").
public final class KnitCompressor: Sendable {

    public struct Options: Sendable {
        public var level: CompressionLevel
        public var concurrency: Int
        public var blockSize: Int
        /// Optional sink for per-block compressibility samples driving the
        /// heatmap visualization.
        public var heatmapRecorder: HeatmapRecorder?
        /// When true, blocks above the entropy threshold are compressed at
        /// lvl=1 even if the user requested higher — match search is pure
        /// overhead on incompressible data.
        public var entropyProbeEnabled: Bool
        /// Optional progress sink. The compressor calls `advance(by:)`
        /// once per block written, in input-byte units.
        public var progressReporter: ProgressReporter?

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    blockSize: Int = Int(KnitFormat.defaultBlockSize),
                    heatmapRecorder: HeatmapRecorder? = nil,
                    entropyProbeEnabled: Bool = true,
                    progressReporter: ProgressReporter? = nil) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.blockSize = blockSize
            self.heatmapRecorder = heatmapRecorder
            self.entropyProbeEnabled = entropyProbeEnabled
            self.progressReporter = progressReporter
        }
    }

    private let backend: BlockBackend
    private let options: Options

    public init(backend: BlockBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.options = options
    }

    /// Walk the input tree and stream each entry into a `.knit` archive
    /// without ever buffering an entry's full compressed payload in
    /// memory. Peak memory is `O(concurrency × blockSize)` regardless of
    /// total file size, so 100 GB+ inputs no longer trigger the OOM
    /// killer that the old buffer-then-write design hit on every
    /// memory-constrained Mac.
    ///
    /// Per-block CRC32 and entropy classification happen inside each
    /// worker on cache-warm pages, then the driver folds CRCs in input
    /// order via `crc32Combine`. This collapses what used to be three
    /// passes over the input (CRC → entropy probe → compression) into
    /// a single cache-warm pass per block.
    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(input)
        let writer = try KnitWriter(url: output)
        let start = ContinuousClock.now

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        let streamer = StreamingBlockCompressor(
            backend: backend,
            blockSize: options.blockSize,
            concurrency: options.concurrency
        )
        let baseLevel = options.level.clampedForZstd()

        for entry in entries {
            let header = KnitWriter.EntryHeader(
                name: entry.relativePath,
                modificationDate: entry.modificationDate,
                unixMode: entry.unixMode,
                isDirectory: entry.isDirectory
            )

            if entry.isDirectory {
                // Directory entries carry no data; write an empty
                // streaming entry to keep the on-disk layout uniform.
                let streamEntry = try writer.beginStreamingEntry(
                    header: header,
                    uncompressedSize: 0,
                    blockSize: 0,
                    numBlocks: 0
                )
                try streamEntry.finish(crc32: 0)
                continue
            }

            let mapped = try MappedFile(url: entry.absoluteURL)
            let buf = mapped.buffer

            let numBlocks = (buf.count + options.blockSize - 1) / options.blockSize
            let streamEntry = try writer.beginStreamingEntry(
                header: header,
                uncompressedSize: UInt64(buf.count),
                blockSize: UInt32(options.blockSize),
                numBlocks: UInt32(numBlocks)
            )

            let result = try streamer.compress(
                buf,
                level: baseLevel,
                entropyDowngradeEnabled: options.entropyProbeEnabled,
                heatmapRecorder: options.heatmapRecorder,
                progressReporter: options.progressReporter
            ) { _, frame in
                try streamEntry.writeBlock(frame)
            }

            try streamEntry.finish(crc32: result.crc32)

            bytesIn += result.totalIn
            bytesOut += result.totalOut
        }

        try writer.close()
        let elapsed = ContinuousClock.now - start
        return CompressionStats(
            entriesWritten: entries.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }
}
