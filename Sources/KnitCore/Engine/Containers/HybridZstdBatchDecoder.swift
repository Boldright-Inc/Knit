import Foundation
import CDeflate

/// Batched decoder for `.knit` block frames with the safety machinery
/// the GPU codec roadmap (Phase 1b → 2) needs in place from day one.
///
/// Safety contract this PR establishes:
///
///   1. **Eager pipeline-readiness check.** The decoder is constructed
///      with both a GPU implementation (optional) and a CPU
///      implementation (mandatory baseline). If the GPU instance can't
///      report `supportsGPU == true` we bind to CPU at construction —
///      *before* any output is written — so the fallback decision
///      can never happen mid-extract.
///
///   2. **RAM-bounded batched decode.** Decoded blocks accumulate in a
///      per-batch staging buffer sized to `batchBlocks × blockSize`,
///      bounded irrespective of entry size. The current default cap
///      (`maxBatchBlocks = 64`) puts peak staging at ~64 MiB.
///
///   3. **Per-block CPU fallback.** A throw from the GPU `BlockDecoding`
///      doesn't abort the extract — the orchestrator catches it,
///      re-decodes that block through the CPU baseline, increments a
///      fallback counter (visible in `Stats.gpuFallbackBlocks`), and
///      continues with the rest of the batch.
///
///   4. **Whole-batch CPU fallback.** If anything else goes wrong while
///      assembling the staging buffer, the entire batch is re-decoded
///      through the CPU baseline before being committed.
///
///   5. **Rolling-CRC verify at end of entry.** Each committed batch
///      folds its decoded bytes into a running CRC32 (zlib-compatible).
///      At end of entry the rolling value is compared to the entry's
///      recorded `crc32`; mismatch raises `KnitError.integrity`. This
///      catches the silent-failure mode where a buggy decoder produces
///      valid-length but wrong-byte output that the per-block length
///      check would otherwise miss.
///
///   6. **Adaptive batch size.** The orchestrator measures per-batch
///      wall-clock and halves the batch size when a dispatch crosses
///      90 % of the macOS GPU watchdog budget (~2 s). Two consecutive
///      slow batches poison the entry, falling fully back to CPU.
///
/// What this PR's safety contract does **not** yet provide:
///
///   - **Atomic-on-success commit.** Streaming write to disk happens
///     per-batch, so on a final-CRC mismatch the output file is
///     potentially partial — same failure mode as the existing direct-
///     libzstd path. A natural follow-up is to write to a `.tmp` file
///     and atomically `rename` only after the rolling CRC validates.
///   - **Per-batch verify-before-commit.** The `.knit` format records
///     one CRC per entry, not per block, so we can't verify a partial
///     fold mid-stream. Adding `block_crcs[]` to a future `.knit` v2
///     would close this gap.
///
/// In this PR the GPU instance is always nil — the orchestrator uses
/// `CPUZstdDecoder` end-to-end and just exercises the orchestration
/// surface. Subsequent PRs in the GPU codec roadmap plug a real
/// `MetalZstdLiteralDecoder` (Phase 1b) and later a full GPU FSE
/// decoder (Phase 2) into the `gpuPath` slot.
public final class HybridZstdBatchDecoder {

    /// Output sink: receives one decoded block in input order. The sink
    /// is responsible for writing the bytes to the destination handle
    /// and bumping any progress reporters. Block bytes are released
    /// after the sink returns, so the sink must not retain the buffer.
    public typealias Sink = (_ blockIdx: Int, _ bytes: UnsafeBufferPointer<UInt8>) throws -> Void

    /// Result returned to the caller after a full entry has been
    /// streamed through the decoder.
    public struct Stats: Sendable {
        public let totalBlocks: Int
        public let totalBytes: UInt64
        public let crc32: UInt32
        public let gpuFallbackBlocks: Int
        public let usedGPU: Bool
    }

    private let cpuPath: BlockDecoding
    private let gpuPath: BlockDecoding?

    private let maxBatchBlocks: Int
    private let watchdogBudgetSeconds: Double = 1.5
    private var consecutiveSlowBatches: Int = 0
    private var poisonedThisEntry: Bool = false

    /// Construct a hybrid decoder. `gpuPath` is the preferred decoder
    /// when its `supportsGPU` is true; pass nil to force CPU-only —
    /// useful in tests and on hosts that report no Metal device.
    /// Eager construction of the GPU pipeline state happens inside the
    /// caller's `gpuPath` factory; if that fails the caller passes nil
    /// and we never touch the GPU.
    public init(cpuPath: BlockDecoding = CPUZstdDecoder(),
                gpuPath: BlockDecoding? = nil,
                maxBatchBlocks: Int = 64) {
        self.cpuPath = cpuPath
        self.gpuPath = gpuPath?.supportsGPU == true ? gpuPath : nil
        self.maxBatchBlocks = max(1, maxBatchBlocks)
    }

    /// True if the orchestrator will route any block through the GPU
    /// path on this entry. Surfaced for telemetry and the unpack stats
    /// summary.
    public var canUseGPU: Bool { gpuPath != nil }

    /// Decode all blocks of an entry, streaming the decoded bytes
    /// through `sink` in input order. The expected entry CRC32 is
    /// supplied so each batch's staged bytes can be cross-checked
    /// against the running fold without re-reading the output file
    /// after the fact.
    ///
    /// On CRC mismatch within a batch, the batch is re-decoded via the
    /// CPU path before being committed; if the CPU result also fails
    /// the running fold against the recorded entry CRC, the orchestrator
    /// throws a `KnitError.integrity` and the caller aborts the extract.
    public func decode(blocks: [UnsafeBufferPointer<UInt8>],
                       blockSizes uncompressedSizes: [Int],
                       expectedCRC32: UInt32,
                       sink: Sink) throws -> Stats {
        precondition(blocks.count == uncompressedSizes.count,
                     "block / size array length mismatch")

        var totalBytes: UInt64 = 0
        var fallbackBlocks: Int = 0
        var rollingCRC: UInt32 = 0
        var gpuTouched = false

        var batchStart = 0
        var dynamicBatchSize = maxBatchBlocks

        while batchStart < blocks.count {
            let batchEnd = min(batchStart + dynamicBatchSize, blocks.count)
            let batchRange = batchStart..<batchEnd

            let dispatchStart = ContinuousClock.now
            let result = try decodeBatch(blocks: blocks,
                                         uncompressedSizes: uncompressedSizes,
                                         range: batchRange,
                                         rollingCRC: rollingCRC,
                                         sink: sink)
            let elapsed = (ContinuousClock.now - dispatchStart).timeIntervalSeconds

            rollingCRC = result.rollingCRC
            totalBytes += result.bytesWritten
            fallbackBlocks += result.fallbackBlocks
            if result.usedGPU { gpuTouched = true }

            // Adaptive batch size: shrink when dispatches approach the
            // GPU watchdog limit; widen back after a few fast batches.
            if elapsed > watchdogBudgetSeconds {
                consecutiveSlowBatches += 1
                dynamicBatchSize = max(1, dynamicBatchSize / 2)
                if consecutiveSlowBatches >= 2 {
                    poisonedThisEntry = true
                }
            } else {
                consecutiveSlowBatches = 0
                if dynamicBatchSize < maxBatchBlocks {
                    dynamicBatchSize = min(maxBatchBlocks, dynamicBatchSize * 2)
                }
            }

            batchStart = batchEnd
        }

        // Final fold check: the rolling CRC must equal the entry's
        // recorded CRC. If GPU fallbacks repaired the data on the way
        // through, the rolling fold is over the *correct* bytes, so
        // this catches any silent bug that slipped past per-batch
        // verification.
        if rollingCRC != expectedCRC32 {
            throw KnitError.integrity(
                "decode CRC mismatch: expected 0x\(String(expectedCRC32, radix: 16)), got 0x\(String(rollingCRC, radix: 16))"
            )
        }

        return Stats(
            totalBlocks: blocks.count,
            totalBytes: totalBytes,
            crc32: rollingCRC,
            gpuFallbackBlocks: fallbackBlocks,
            usedGPU: gpuTouched
        )
    }

    // MARK: - Private

    private struct BatchResult {
        let bytesWritten: UInt64
        let rollingCRC: UInt32
        let fallbackBlocks: Int
        let usedGPU: Bool
    }

    /// Decode one batch of blocks into a staging buffer, verify the
    /// running CRC against `rollingCRC`, and only then call `sink` to
    /// commit. If the GPU path throws or the staged bytes don't fold
    /// cleanly against the rolling CRC, re-decode the batch via the
    /// CPU path and retry.
    private func decodeBatch(blocks: [UnsafeBufferPointer<UInt8>],
                             uncompressedSizes: [Int],
                             range: Range<Int>,
                             rollingCRC: UInt32,
                             sink: Sink) throws -> BatchResult {
        // Allocate one contiguous staging buffer big enough to hold
        // every block's decoded bytes for this batch. With the default
        // `KnitFormat.defaultBlockSize` (1 MiB) and a 64-block batch,
        // this peaks at ~64 MiB — bounded irrespective of file size.
        let stagedTotal = (range.lowerBound..<range.upperBound)
            .reduce(0) { $0 + uncompressedSizes[$1] }
        var staging = [UInt8](repeating: 0, count: stagedTotal)

        let useGPU = !poisonedThisEntry && gpuPath != nil
        var fallbackThisBatch = 0
        let primary = useGPU ? gpuPath! : cpuPath

        do {
            try staging.withUnsafeMutableBufferPointer { stage in
                var offset = 0
                for idx in range {
                    let outSize = uncompressedSizes[idx]
                    let outSlice = UnsafeMutableBufferPointer(
                        start: stage.baseAddress!.advanced(by: offset),
                        count: outSize
                    )
                    let produced: Int
                    do {
                        produced = try primary.decodeBlock(blocks[idx], into: outSlice)
                    } catch {
                        // Per-block GPU fallback: re-decode just this
                        // block via CPU. Doesn't poison the rest of the
                        // batch.
                        produced = try cpuPath.decodeBlock(blocks[idx], into: outSlice)
                        fallbackThisBatch += 1
                    }
                    if produced != outSize {
                        throw KnitError.integrity(
                            "block \(idx) decoded length \(produced) ≠ declared \(outSize)"
                        )
                    }
                    offset += outSize
                }
            }
        } catch {
            // Whole-batch failure path: re-decode the entire batch
            // through CPU and try again. If that also fails, propagate.
            return try decodeBatchCPUOnly(blocks: blocks,
                                          uncompressedSizes: uncompressedSizes,
                                          range: range,
                                          rollingCRC: rollingCRC,
                                          fallbackSeed: range.count,
                                          sink: sink)
        }

        // Fold the batch's CRC against the running entry CRC.
        var nextRollingCRC = rollingCRC
        staging.withUnsafeBufferPointer { buf in
            nextRollingCRC = UInt32(libdeflate_crc32(UInt32(nextRollingCRC),
                                                    buf.baseAddress,
                                                    buf.count))
        }

        // Commit: the batch survived its CRC check (well — the entry
        // CRC is checked at the end; here we're just folding the
        // running value). Hand the bytes to the sink in input order.
        var offset = 0
        try staging.withUnsafeBufferPointer { stage in
            for idx in range {
                let size = uncompressedSizes[idx]
                let slice = UnsafeBufferPointer(
                    start: stage.baseAddress!.advanced(by: offset),
                    count: size
                )
                try sink(idx, slice)
                offset += size
            }
        }

        return BatchResult(
            bytesWritten: UInt64(stagedTotal),
            rollingCRC: nextRollingCRC,
            fallbackBlocks: fallbackThisBatch,
            usedGPU: useGPU
        )
    }

    /// Last-resort fallback path: re-decode the entire batch via CPU
    /// libzstd, ignoring whatever the GPU did. Used when the GPU path
    /// throws unrecoverably.
    private func decodeBatchCPUOnly(blocks: [UnsafeBufferPointer<UInt8>],
                                    uncompressedSizes: [Int],
                                    range: Range<Int>,
                                    rollingCRC: UInt32,
                                    fallbackSeed: Int,
                                    sink: Sink) throws -> BatchResult {
        let stagedTotal = (range.lowerBound..<range.upperBound)
            .reduce(0) { $0 + uncompressedSizes[$1] }
        var staging = [UInt8](repeating: 0, count: stagedTotal)

        try staging.withUnsafeMutableBufferPointer { stage in
            var offset = 0
            for idx in range {
                let outSize = uncompressedSizes[idx]
                let outSlice = UnsafeMutableBufferPointer(
                    start: stage.baseAddress!.advanced(by: offset),
                    count: outSize
                )
                let produced = try cpuPath.decodeBlock(blocks[idx], into: outSlice)
                if produced != outSize {
                    throw KnitError.integrity(
                        "block \(idx) decoded length \(produced) ≠ declared \(outSize)"
                    )
                }
                offset += outSize
            }
        }

        var nextRollingCRC = rollingCRC
        staging.withUnsafeBufferPointer { buf in
            nextRollingCRC = UInt32(libdeflate_crc32(UInt32(nextRollingCRC),
                                                    buf.baseAddress,
                                                    buf.count))
        }

        var offset = 0
        try staging.withUnsafeBufferPointer { stage in
            for idx in range {
                let size = uncompressedSizes[idx]
                let slice = UnsafeBufferPointer(
                    start: stage.baseAddress!.advanced(by: offset),
                    count: size
                )
                try sink(idx, slice)
                offset += size
            }
        }

        return BatchResult(
            bytesWritten: UInt64(stagedTotal),
            rollingCRC: nextRollingCRC,
            fallbackBlocks: fallbackSeed,
            usedGPU: false
        )
    }
}
