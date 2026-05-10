import Foundation

/// Orchestrator for the `.knit` path.
///
/// Mixed-granularity parallelism (since v3):
///
///   * **Large entries** (≥ `concurrency × 2 × blockSize` bytes — i.e.
///     enough blocks to saturate the worker pool on their own) take a
///     **serial streaming path**: one entry at a time, with
///     intra-entry block parallelism via
///     `StreamingBlockCompressor`. Memory stays `O(concurrency × blockSize)`,
///     so 100 GB+ single files never OOM.
///   * **Small entries** (the typical "git tree with 100 k tiny files"
///     workload) are gathered into batches and compressed **across
///     workers in parallel** via `concurrentMap`. Each worker runs its
///     own `streamer.compress` end-to-end on a single small entry.
///     The collected results are then drained into the archive in
///     entry order so on-disk layout is deterministic.
///
/// This split solves the bottleneck the analyse output flagged on
/// the github corpus: 76k single-block entries processed serially
/// left 15 of 16 cores idle, capping pack throughput at ~460 MB/s.
/// With cross-entry batching we get the same N-way parallelism the
/// `pack` path already had on big files, just lifted up to entry
/// granularity.
///
/// Memory contract:
///   * Large-entry path: `O(concurrency × blockSize)` (unchanged).
///   * Small-entry batch: `O(batchSize × largeEntryThreshold)` —
///     bounded by `concurrency × 4 entries × concurrency × 2 ×
///     blockSize / entry` = `concurrency² × 8 × blockSize`. For the
///     defaults (16, 1 MiB) that's ~2 GiB worst case, but only when
///     every entry is exactly at the threshold; in practice small
///     entries are tiny and the batch sits well under 1 GiB.
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
        /// Optional per-stage timing accumulator (driven by the CLI's
        /// hidden `--analyze` flag on `pack`). When non-nil the
        /// streamer records per-batch wall times and per-block CPU
        /// times — the data needed to decide which encode stage to
        /// hand off to the GPU. Nil in production: zero overhead.
        public var stageAnalytics: StageAnalytics?
        /// When true, the file walker excludes hidden items
        /// (POSIX dotfiles + items with `kCFURLIsHiddenKey` set).
        /// Defaults to **false** — the tar/zip-compatible policy of
        /// "archive what's there". Pass `true` for distribution-style
        /// archives where things like `.git/`, `.DS_Store`, `.vscode/`
        /// shouldn't leak.
        public var excludeHidden: Bool
        /// Optional collector populated by `FileWalker.enumerate` with
        /// every item it chose to skip (hidden, when excluded; always
        /// symlinks). Pair with `--analyze` to emit a "what was
        /// skipped" section to stderr after pack finishes.
        public var walkSkipCollector: WalkSkipCollector?

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    blockSize: Int = Int(KnitFormat.defaultBlockSize),
                    heatmapRecorder: HeatmapRecorder? = nil,
                    entropyProbeEnabled: Bool = true,
                    progressReporter: ProgressReporter? = nil,
                    stageAnalytics: StageAnalytics? = nil,
                    excludeHidden: Bool = false,
                    walkSkipCollector: WalkSkipCollector? = nil) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.blockSize = blockSize
            self.heatmapRecorder = heatmapRecorder
            self.entropyProbeEnabled = entropyProbeEnabled
            self.progressReporter = progressReporter
            self.stageAnalytics = stageAnalytics
            self.excludeHidden = excludeHidden
            self.walkSkipCollector = walkSkipCollector
        }
    }

    private let backend: BlockBackend
    private let options: Options

    public init(backend: BlockBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.options = options
    }

    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(
            input,
            excludeHidden: options.excludeHidden,
            skipCollector: options.walkSkipCollector
        )
        let writer = try KnitWriter(url: output)
        let start = ContinuousClock.now

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        let streamer = StreamingBlockCompressor(
            backend: backend,
            blockSize: options.blockSize,
            concurrency: options.concurrency
        )
        options.stageAnalytics?.startWallClock()
        let baseLevel = options.level.clampedForZstd()

        // Threshold: an entry that already has enough blocks to
        // saturate `concurrency` workers via intra-entry block
        // parallelism gains nothing from cross-entry batching. Below
        // this size, the entry is effectively serial in the old
        // streamer path (1 block ≈ 1 worker active) and benefits from
        // running alongside its siblings.
        let largeEntryThreshold = UInt64(options.concurrency) * 2 * UInt64(options.blockSize)

        var i = 0
        while i < entries.count {
            let entry = entries[i]

            // Directories: emit empty streaming entry; no data work.
            if entry.isDirectory {
                let header = KnitWriter.EntryHeader(
                    name: entry.relativePath,
                    modificationDate: entry.modificationDate,
                    unixMode: entry.unixMode,
                    isDirectory: true
                )
                let se = try writer.beginStreamingEntry(
                    header: header,
                    uncompressedSize: 0,
                    blockSize: 0,
                    numBlocks: 0
                )
                try se.finish(crc32: 0)
                i += 1
                continue
            }

            // Large entry: serial streaming path. Compresses block-
            // by-block and writes frames straight to the archive as
            // they're produced — keeps memory bounded for
            // multi-GiB single files.
            if entry.size >= largeEntryThreshold {
                let r = try compressLargeEntryStreaming(
                    entry: entry,
                    writer: writer,
                    streamer: streamer,
                    level: baseLevel
                )
                bytesIn += r.totalIn
                bytesOut += r.totalOut
                i += 1
                continue
            }

            // Small entry: gather a run of consecutive small entries
            // and compress them in parallel. The walker emits entries
            // in deterministic order, so consecutive small runs map
            // cleanly to a contiguous batch slice — and writing
            // results in `processed` order preserves the on-disk
            // entry order.
            var j = i
            let maxBatch = max(options.concurrency * 4, 8)
            while j < entries.count
                && (j - i) < maxBatch
                && !entries[j].isDirectory
                && entries[j].size < largeEntryThreshold {
                j += 1
            }
            let batch = Array(entries[i..<j])

            // Capture the values the parallel closure needs as
            // immutable lets so the @Sendable check passes without
            // pulling `self` in.
            let levelLocal = baseLevel
            let entropyEnabled = options.entropyProbeEnabled
            let heatmap = options.heatmapRecorder
            let reporter = options.progressReporter
            let analytics = options.stageAnalytics
            let blockSizeLocal = options.blockSize
            let streamerLocal = streamer

            let processed: [SmallEntryResult] = try concurrentMap(
                batch,
                concurrency: options.concurrency
            ) { entry in
                let mapped = try MappedFile(url: entry.absoluteURL)
                let buf = mapped.buffer
                var frames: [Data] = []
                let result = try streamerLocal.compress(
                    buf,
                    level: levelLocal,
                    entropyDowngradeEnabled: entropyEnabled,
                    heatmapRecorder: heatmap,
                    progressReporter: reporter,
                    analytics: analytics
                ) { _, frame in
                    frames.append(frame)
                }
                return SmallEntryResult(
                    entry: entry,
                    frames: frames,
                    crc32: result.crc32,
                    totalIn: result.totalIn,
                    totalOut: result.totalOut,
                    uncompressedSize: UInt64(buf.count),
                    blockSize: blockSizeLocal
                )
            }

            // Drain in input order — preserves the on-disk entry
            // sequence and lets `KnitWriter`'s append-only API stay
            // exactly as-is.
            for pe in processed {
                let header = KnitWriter.EntryHeader(
                    name: pe.entry.relativePath,
                    modificationDate: pe.entry.modificationDate,
                    unixMode: pe.entry.unixMode,
                    isDirectory: false
                )
                let se = try writer.beginStreamingEntry(
                    header: header,
                    uncompressedSize: pe.uncompressedSize,
                    blockSize: UInt32(pe.blockSize),
                    numBlocks: UInt32(pe.frames.count)
                )
                for frame in pe.frames {
                    try se.writeBlock(frame)
                }
                try se.finish(crc32: pe.crc32)
                bytesIn += pe.totalIn
                bytesOut += pe.totalOut
            }

            i = j
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

    /// Serial streaming path used for entries large enough to keep
    /// the worker pool saturated on their own. Identical to the v2
    /// (pre-entry-parallelism) flow: open the streaming entry, run
    /// `streamer.compress` with a sink that writes each frame
    /// straight to the archive as it's produced, then finish with
    /// the entry CRC.
    private func compressLargeEntryStreaming(
        entry: FileEntry,
        writer: KnitWriter,
        streamer: StreamingBlockCompressor,
        level: Int32
    ) throws -> StreamingBlockCompressor.Output {
        let header = KnitWriter.EntryHeader(
            name: entry.relativePath,
            modificationDate: entry.modificationDate,
            unixMode: entry.unixMode,
            isDirectory: false
        )
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
            level: level,
            entropyDowngradeEnabled: options.entropyProbeEnabled,
            heatmapRecorder: options.heatmapRecorder,
            progressReporter: options.progressReporter,
            analytics: options.stageAnalytics
        ) { _, frame in
            try streamEntry.writeBlock(frame)
        }
        try streamEntry.finish(crc32: result.crc32)
        return result
    }
}

/// Buffered result of compressing one small entry under the parallel
/// batch path. `Sendable` because it crosses the `concurrentMap`
/// boundary; all fields are value types or already-Sendable
/// references (`FileEntry` is a Sendable struct, `Data` is a value
/// type, `[Data]` is Sendable for Sendable Element).
private struct SmallEntryResult: Sendable {
    let entry: FileEntry
    let frames: [Data]
    let crc32: UInt32
    let totalIn: UInt64
    let totalOut: UInt64
    let uncompressedSize: UInt64
    let blockSize: Int
}
