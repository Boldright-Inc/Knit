import Foundation

/// zlib-compatible CRC32 combine: given `CRC(A)` and `CRC(B)` plus `|B|`,
/// return `CRC(A ‖ B)` without re-walking the bytes.
///
/// This is the same trick `crc32_combine64` from zlib uses (public-domain
/// port via the GF(2) matrix-power approach). It's the linchpin of the
/// streaming `.knit` writer: each compression worker computes its block's
/// CRC32 with seed=0 alongside the codec on cache-warm pages, and the
/// driver combines them in input order without any extra walk over the
/// uncompressed input.
///
/// Complexity is O(log |B|) GF(2) matrix multiplications per call, which
/// is ~negligible compared to the per-block compression cost.
@inline(__always)
internal func crc32Combine(crc1: UInt32, crc2: UInt32, len2: UInt) -> UInt32 {
    if len2 == 0 { return crc1 }

    var even = [UInt32](repeating: 0, count: 32)
    var odd = [UInt32](repeating: 0, count: 32)

    // odd[0] = the polynomial in reflected form (IEEE 802.3 / zlib).
    odd[0] = 0xEDB88320
    var row: UInt32 = 1
    for i in 1..<32 {
        odd[i] = row
        row <<= 1
    }

    gf2MatrixSquare(&even, mat: odd)
    gf2MatrixSquare(&odd, mat: even)

    var crc = crc1
    var len = len2
    while true {
        gf2MatrixSquare(&even, mat: odd)
        if (len & 1) != 0 {
            crc = gf2MatrixTimes(mat: even, vec: crc)
        }
        len >>= 1
        if len == 0 { break }
        gf2MatrixSquare(&odd, mat: even)
        if (len & 1) != 0 {
            crc = gf2MatrixTimes(mat: odd, vec: crc)
        }
        len >>= 1
        if len == 0 { break }
    }

    return crc ^ crc2
}

@inline(__always)
private func gf2MatrixTimes(mat: [UInt32], vec: UInt32) -> UInt32 {
    var sum: UInt32 = 0
    var v = vec
    var i = 0
    while v != 0 {
        if (v & 1) != 0 { sum ^= mat[i] }
        v >>= 1
        i += 1
    }
    return sum
}

@inline(__always)
private func gf2MatrixSquare(_ square: inout [UInt32], mat: [UInt32]) {
    for n in 0..<32 {
        square[n] = gf2MatrixTimes(mat: mat, vec: mat[n])
    }
}

// MARK: - Parallel CRC32 over a large buffer

/// PR #72. Compute CRC32 over a (potentially multi-GB) buffer by
/// splitting it into chunks, computing each chunk's CRC concurrently,
/// then combining the chunk CRCs in input order via `crc32Combine`.
///
/// Motivated by ZIP-side `.stored` entries on huge incompressible
/// inputs (the 80 GB Parallels VM image case): the previous single-
/// threaded `crc.crc32(buf, seed: 0)` took ~8 s on M5 Max (libdeflate's
/// hardware-CRC peaks around 10 GB/s per core). Parallelising across
/// the host's worker pool drops that to ~0.5 s on a 16-P-core machine
/// — the prepare-phase silence reported by the user shrinks from
/// "~13 s (probe + CRC)" to "~5 s (probe only)".
///
/// Below `minBufferForParallel` the dispatch overhead outweighs the
/// per-core wins; we fall through to the serial backend call.
internal func parallelCRC32(_ buffer: UnsafeBufferPointer<UInt8>,
                            using crc: any CRC32Computing,
                            concurrency: Int) -> UInt32 {
    let total = buffer.count
    // 64 MiB threshold matches MetalCRC32's "amortisation point"
    // analysis in CLAUDE.md. Below this, libdeflate's hardware-CRC
    // walks the whole buffer faster than the dispatch loop's
    // setup-and-teardown overhead.
    let minBufferForParallel = 64 * 1024 * 1024
    if total < minBufferForParallel || concurrency <= 1 {
        return crc.crc32(buffer, seed: 0)
    }
    guard let base = buffer.baseAddress else { return 0 }

    // One chunk per worker; cap at 64 to keep `crc32Combine`'s O(N)
    // sequential reduction cheap (~log(chunkLen) GF(2) matmuls per
    // combine, ~negligible for any sane N but bounded by sanity).
    let chunkCount = max(2, min(concurrency, 64))
    let chunkSize = (total + chunkCount - 1) / chunkCount
    let basePtrSendable = SendableRawPointer(base)

    struct ChunkResult: Sendable {
        let crc: UInt32
        let length: Int
    }

    // concurrentMap preserves input order, so the index in the
    // returned array equals the chunk index — exactly what
    // `crc32Combine`'s left-to-right fold needs.
    let chunks: [ChunkResult]
    do {
        chunks = try concurrentMap(Array(0..<chunkCount),
                                   concurrency: chunkCount) { i in
            let off = i * chunkSize
            if off >= total {
                return ChunkResult(crc: 0, length: 0)
            }
            let len = min(chunkSize, total - off)
            let chunkBuf = UnsafeBufferPointer<UInt8>(
                start: basePtrSendable.value.advanced(by: off),
                count: len
            )
            return ChunkResult(crc: crc.crc32(chunkBuf, seed: 0),
                               length: len)
        }
    } catch {
        // concurrentMap's transform doesn't throw in our usage (the
        // closure body is non-throwing) but the API still needs the
        // catch. Fall back to serial on any error.
        return crc.crc32(buffer, seed: 0)
    }

    // Combine in order. Skip empty trailing chunks (can happen when
    // chunkCount doesn't evenly divide total).
    var combined: UInt32 = 0
    var firstSeen = false
    for c in chunks where c.length > 0 {
        if !firstSeen {
            combined = c.crc
            firstSeen = true
        } else {
            combined = crc32Combine(crc1: combined,
                                    crc2: c.crc,
                                    len2: UInt(c.length))
        }
    }
    return combined
}
