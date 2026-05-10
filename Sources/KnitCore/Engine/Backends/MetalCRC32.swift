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
        guard let basePtr = buffer.baseAddress else { return 0 }

        let numSlices = (total + sliceSize - 1) / sliceSize

        // On Apple Silicon (unified memory), alias the caller's buffer directly
        // into a Metal buffer to skip a host->device memcpy. Metal's
        // `bytesNoCopy:` form requires a page-aligned address and length;
        // otherwise we fall back to the copying `bytes:` path.
        let pageSize = UInt(getpagesize())
        let pageMask = pageSize &- 1
        let rawBase = UnsafeRawPointer(basePtr)
        let addrAligned = (UInt(bitPattern: rawBase) & pageMask) == 0
        let lengthAligned = (UInt(total) & pageMask) == 0

        let inBuf: MTLBuffer
        if addrAligned && lengthAligned {
            let mutablePtr = UnsafeMutableRawPointer(mutating: rawBase)
            guard let b = context.device.makeBuffer(
                bytesNoCopy: mutablePtr,
                length: total,
                options: .storageModeShared,
                deallocator: nil  // caller owns the underlying memory
            ) else {
                throw KnitError.allocationFailure("Metal input buffer (bytesNoCopy)")
            }
            inBuf = b
        } else {
            guard let b = context.device.makeBuffer(
                bytes: basePtr,
                length: total,
                options: .storageModeShared
            ) else {
                throw KnitError.allocationFailure("Metal input buffer")
            }
            inBuf = b
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

// CRC combine math now lives in CRC32Combine.swift so the streaming
// `.knit` writer can call it for in-order block CRC accumulation.
