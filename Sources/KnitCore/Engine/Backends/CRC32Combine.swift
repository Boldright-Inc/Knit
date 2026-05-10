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
