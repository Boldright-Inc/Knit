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
public struct StreamingBlockCompressor {

    /// Result of one block's worth of work, returned from a worker to
    /// the driver.
    fileprivate struct ProcessedBlock: Sendable {
        let absoluteIdx: Int
        let originalSize: Int
        let frame: Data
        let blockCrc: UInt32
        let entropy: Float
        let levelUsed: Int32
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

    public init(backend: BlockBackend,
                blockSize: Int = 1 * 1024 * 1024,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.backend = backend
        self.blockSize = blockSize
        self.concurrency = max(1, concurrency)
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

        while batchStart < slices.count {
            let batchEnd = min(batchStart + batchSize, slices.count)
            let batchIndices = Array(batchStart..<batchEnd)

            // Process this batch in parallel. Each worker does the
            // entire per-block pipeline on cache-warm pages.
            let processed: [ProcessedBlock] = try concurrentMap(
                batchIndices,
                concurrency: concurrency
            ) { absoluteIdx in
                let slice = slices[absoluteIdx]
                let p = basePtr.value.advanced(by: slice.offset)
                let bv = UnsafeBufferPointer(start: p, count: slice.length)

                // Step 1: byte histogram on CPU. ~0.5 ms for a 1 MiB
                // block on a P-core; the bytes are then resident in L1
                // cache for the CRC and codec walks that follow.
                let entropy: Float
                if entropyDowngradeEnabled {
                    let hist = EntropyMath.histogram(of: bv.baseAddress!, count: bv.count)
                    entropy = EntropyMath.shannonEntropy(histogram: hist, total: bv.count)
                } else {
                    entropy = 0
                }

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
                let blockCrc = UInt32(libdeflate_crc32(0, bv.baseAddress, bv.count))

                // Step 4: zstd frame.
                let frame = try backend.compressBlock(bv, level: lvl)

                return ProcessedBlock(
                    absoluteIdx: absoluteIdx,
                    originalSize: bv.count,
                    frame: frame,
                    blockCrc: blockCrc,
                    entropy: entropy,
                    levelUsed: lvl
                )
            }

            // Drain the batch in order: write to disk, fold CRC, record
            // heatmap. After this loop the batch's `Data` references are
            // released and the worker pool can repopulate.
            var heatmapBatch: [HeatmapSample] = []
            if heatmapRecorder != nil {
                heatmapBatch.reserveCapacity(processed.count)
            }
            for pb in processed {
                try sink(pb.absoluteIdx, pb.frame)
                blockSizes[pb.absoluteIdx] = UInt32(pb.frame.count)
                totalOut += UInt64(pb.frame.count)
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
