import Foundation
import Metal

/// CRC32 (IEEE / zlib) computed on the GPU. Useful for hiding CRC latency
/// behind block compression for very large entries; the small-buffer cost
/// is higher than libdeflate's CPU CRC32 due to dispatch overhead.
public final class MetalCRC32: @unchecked Sendable {

    private let context: MetalContext
    private let pipeline: MTLComputePipelineState
    private let sliceSize: Int

    public init?(sliceSize: Int = 1 * 1024 * 1024) {
        guard let ctx = MetalContext() else { return nil }
        self.context = ctx
        self.sliceSize = sliceSize
        do {
            self.pipeline = try ctx.makePipeline("crc32_per_slice")
        } catch {
            return nil
        }
    }

    /// Computes CRC-32 of an arbitrary buffer using GPU per-slice + CPU combine.
    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>) throws -> UInt32 {
        let total = buffer.count
        if total == 0 { return 0 }

        let numSlices = (total + sliceSize - 1) / sliceSize

        // Input: zero-copy buffer if length and alignment are friendly.
        guard let inBuf = context.device.makeBuffer(
            bytes: buffer.baseAddress!,
            length: total,
            options: .storageModeShared
        ) else {
            throw KnitError.allocationFailure("Metal input buffer")
        }
        guard let outBuf = context.device.makeBuffer(
            length: numSlices * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw KnitError.allocationFailure("Metal output buffer")
        }

        var params = CRCParams(
            totalBytes: UInt32(total),
            sliceSize: UInt32(sliceSize),
            numSlices: UInt32(numSlices)
        )

        guard let commandBuffer = context.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw KnitError.codecFailure("Metal command encoder")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inBuf, offset: 0, index: 0)
        encoder.setBuffer(outBuf, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<CRCParams>.stride, index: 2)

        let tgWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let threadsPerGroup = MTLSize(width: tgWidth, height: 1, depth: 1)
        let groupCount = MTLSize(
            width: (numSlices + tgWidth - 1) / tgWidth,
            height: 1, depth: 1
        )
        encoder.dispatchThreadgroups(groupCount, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Combine slice CRCs on CPU using zlib's crc32_combine64 math.
        let slicePtr = outBuf.contents().bindMemory(to: UInt32.self, capacity: numSlices)
        var combined: UInt32 = slicePtr[0]
        var combinedLen = min(sliceSize, total)
        for i in 1..<numSlices {
            let sliceLen = min(sliceSize, total - i * sliceSize)
            combined = crc32Combine(crc1: combined, crc2: slicePtr[i], len2: UInt(sliceLen))
            combinedLen += sliceLen
        }
        return combined
    }
}

private struct CRCParams {
    var totalBytes: UInt32
    var sliceSize: UInt32
    var numSlices: UInt32
}

// zlib-compatible CRC32 combine implementation. Public-domain port from zlib's
// crc32.c (gf2_matrix_times / gf2_matrix_square approach).
private func crc32Combine(crc1: UInt32, crc2: UInt32, len2: UInt) -> UInt32 {
    if len2 == 0 { return crc1 }

    var even = [UInt32](repeating: 0, count: 32)
    var odd = [UInt32](repeating: 0, count: 32)

    // odd[0] = polynomial in reflected form
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

private func gf2MatrixSquare(_ square: inout [UInt32], mat: [UInt32]) {
    for n in 0..<32 {
        square[n] = gf2MatrixTimes(mat: mat, vec: mat[n])
    }
}
