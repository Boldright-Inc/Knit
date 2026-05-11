import Foundation

/// Inline zstd-frame decoder for the all-`Raw_Block`/`RLE_Block` fast
/// path. PR #74.
///
/// Motivation. Sample-trace of an 80 GB `.pvm.knit` unpack on M5 Max
/// showed the main thread blocked **87 %** of the time on
/// `_dispatch_semaphore_wait_slow` and `_dispatch_group_wait_slow` —
/// waiting for `HybridZstdBatchDecoder`'s workers to come back from a
/// libzstd `ZSTD_decompressDCtx` call. For incompressible source data
/// (VM disk images, encrypted blobs, already-compressed media) libzstd
/// emits frames where ~99.7 % of inner blocks are `Raw_Block` — the
/// decoder's "work" is essentially `memcpy`. The worker round-trip
/// (semaphore acquire, thread context switch, libzstd context init,
/// semaphore release) dominates the per-block wall.
///
/// This module short-circuits the worker dispatch for frames that
/// consist entirely of `Raw_Block` and `RLE_Block` inner blocks:
/// instead of dispatching to a worker, the main thread does the parse
/// + `memcpy` / `memset` inline. The CRC fold + writer sink stay
/// unchanged, so the rest of the pipeline is undisturbed.
///
/// Format reference: RFC 8478 §3 (Zstandard Frame Format).
///
/// Out of scope:
/// - `Compressed_Block`s. These need libzstd's full FSE / Huffman
///   pipeline. Returning `.needsFullDecoder` routes the caller back to
///   the worker path; mixed frames go through the worker for *all*
///   blocks to keep the implementation simple (partial-batch inlining
///   would need block-level dispatch, which adds plumbing without much
///   payoff for the canonical VM-image case).
/// - Frames using a Dictionary. We don't write those (KnitWriter never
///   emits with `ZSTD_c_compressionLevel < 0` or dict-trained streams),
///   so the frame-header DictID field should always be zero. We accept
///   them in the parser just to keep the walker correct on synthetic
///   inputs.
/// - Content checksum verification. The frame's trailing 4-byte CRC32
///   (if `Content_Checksum_flag == 1`) is skipped rather than
///   re-verified — the outer `HybridZstdBatchDecoder` already folds a
///   per-entry CRC32 over the decoded bytes, so checking it twice would
///   be wasted work.
internal enum RawFrameDecoder {

    /// Outcome of `decode(frame:destination:)`.
    enum Result {
        /// Frame consisted entirely of `Raw_Block`/`RLE_Block` inner
        /// blocks and was decoded inline. `count` is the number of
        /// bytes written to `destination`. May be less than
        /// `destination.count` if the caller over-allocated; the caller
        /// should compare against the declared `uncompressed_size`.
        case decoded(count: Int)

        /// Frame contains at least one `Compressed_Block` — caller
        /// must fall back to the full libzstd decoder via the worker
        /// path. `destination` may have been partially written; the
        /// caller is expected to overwrite it via the fallback.
        case needsFullDecoder

        /// Frame header / block header malformed, or output overflowed
        /// `destination.count`. Caller should treat this as a fatal
        /// error for the batch and either bail out or fall back to the
        /// full decoder (which may also fail, in which case the user
        /// gets a real error).
        case parseError
    }

    /// Attempt to decode `frame` (a complete zstd frame, including
    /// 4-byte magic + frame header + blocks + optional trailing
    /// checksum) into `destination`. See `Result` for the return-value
    /// semantics.
    ///
    /// Performance contract: the all-Raw-block path is purely
    /// `memcpy` + 3-byte block-header parse per inner block. On M5 Max
    /// this hits memory bandwidth (~200 GB/s for cache-resident
    /// pages); on base M2 / M3 it hits the cache subsystem bandwidth
    /// (~50-100 GB/s). Either way, far above NVMe write speed, so the
    /// inline decode never becomes the new bottleneck.
    @inline(__always)
    static func decode(frame: UnsafeBufferPointer<UInt8>,
                       destination: UnsafeMutableBufferPointer<UInt8>) -> Result {
        guard let src = frame.baseAddress,
              let dst = destination.baseAddress,
              frame.count >= 6 else {
            return .parseError
        }
        let end = src.advanced(by: frame.count)
        var p = src

        // 4-byte magic — 0xFD2FB528 little-endian.
        let magic = readU32LE(p)
        guard magic == 0xFD2F_B528 else { return .parseError }
        p = p.advanced(by: 4)

        // Frame_Header_Descriptor (1 byte).
        guard p < end else { return .parseError }
        let fhd = p.pointee
        p = p.advanced(by: 1)
        let singleSegment = (fhd & 0x20) != 0
        let contentChecksum = (fhd & 0x04) != 0
        let dictIDFlag = Int(fhd & 0x03)
        let fcsFlag = Int((fhd >> 6) & 0x03)

        // Window_Descriptor (1 byte iff !singleSegment).
        if !singleSegment {
            guard p < end else { return .parseError }
            p = p.advanced(by: 1)
        }

        // Dictionary_ID (0/1/2/4 bytes).
        let didSize: Int
        switch dictIDFlag {
        case 0: didSize = 0
        case 1: didSize = 1
        case 2: didSize = 2
        case 3: didSize = 4
        default: return .parseError
        }
        if didSize > 0 {
            guard end - p >= didSize else { return .parseError }
            p = p.advanced(by: didSize)
        }

        // Frame_Content_Size (0/1/2/4/8 bytes).
        let fcsSize: Int
        switch fcsFlag {
        case 0: fcsSize = singleSegment ? 1 : 0
        case 1: fcsSize = 2
        case 2: fcsSize = 4
        case 3: fcsSize = 8
        default: return .parseError
        }
        if fcsSize > 0 {
            guard end - p >= fcsSize else { return .parseError }
            p = p.advanced(by: fcsSize)
        }

        // Walk inner blocks. Each block has a 3-byte header:
        //   bit 0     : Last_Block flag
        //   bit 1-2   : Block_Type  (0=Raw, 1=RLE, 2=Compressed, 3=Reserved)
        //   bit 3-23  : Block_Size  (21 bits)
        let outCap = destination.count
        var outOffset = 0
        while true {
            guard end - p >= 3 else { return .parseError }
            let b0 = UInt32(p.pointee)
            let b1 = UInt32(p.advanced(by: 1).pointee)
            let b2 = UInt32(p.advanced(by: 2).pointee)
            let bh = b0 | (b1 << 8) | (b2 << 16)
            p = p.advanced(by: 3)

            let isLast = (bh & 0x01) != 0
            let blockType = (bh >> 1) & 0x03
            let blockSize = Int(bh >> 3)

            switch blockType {
            case 0:  // Raw_Block — `blockSize` literal bytes follow.
                guard end - p >= blockSize,
                      outOffset + blockSize <= outCap else {
                    return .parseError
                }
                if blockSize > 0 {
                    memcpy(dst.advanced(by: outOffset), p, blockSize)
                }
                outOffset += blockSize
                p = p.advanced(by: blockSize)
            case 1:  // RLE_Block — 1-byte symbol, repeat `blockSize` times.
                guard end - p >= 1,
                      outOffset + blockSize <= outCap else {
                    return .parseError
                }
                if blockSize > 0 {
                    memset(dst.advanced(by: outOffset),
                           Int32(p.pointee),
                           blockSize)
                }
                outOffset += blockSize
                p = p.advanced(by: 1)
            case 2:  // Compressed_Block — needs libzstd.
                return .needsFullDecoder
            default:
                // Reserved (3) → spec says decoders must fail.
                return .parseError
            }

            if isLast { break }
        }

        // Skip the trailing content checksum if present. We don't
        // verify it here — the outer HybridZstdBatchDecoder already
        // folds an entry-wide CRC32 over the decoded bytes, so a
        // double-check would be wasted work.
        if contentChecksum {
            guard end - p >= 4 else { return .parseError }
            // p = p.advanced(by: 4)   // not needed — we return now
        }

        return .decoded(count: outOffset)
    }

    @inline(__always)
    private static func readU32LE(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p.pointee)
            | (UInt32(p.advanced(by: 1).pointee) << 8)
            | (UInt32(p.advanced(by: 2).pointee) << 16)
            | (UInt32(p.advanced(by: 3).pointee) << 24)
    }
}
