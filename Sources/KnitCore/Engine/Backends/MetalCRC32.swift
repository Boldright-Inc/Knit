import Foundation
import Metal

/// CRC32 (IEEE / zlib) computed on the GPU. Useful for hiding CRC latency
/// behind block compression for very large entries; the small-buffer cost
/// is higher than libdeflate's CPU CRC32 due to dispatch overhead.
///
/// **Per-dispatch size limit**: each Metal dispatch is capped at 1 GiB
/// for two independent reasons. (1) The kernel's slice indexing
/// (`uint start = gid * slice_size`) overflows the 32-bit `uint` once
/// the buffer crosses 4 GiB. (2) `MTLDevice.maxBufferLength` on Apple
/// Silicon is roughly the recommended working-set size (≈ 70-75% of
/// physical UMA), so a single 100 GiB MTLBuffer cannot be created on
/// any consumer Mac. Inputs above the limit are sliced into 1-GiB
/// chunks; per-chunk CRCs are combined via `crc32Combine`.
public final class MetalCRC32: @unchecked Sendable {

    /// Maximum bytes per single Metal dispatch. Keeps both the kernel's
    /// `uint` indexing and `MTLDevice.maxBufferLength` happy.
    public static let perDispatchByteLimit: Int = 1 * 1024 * 1024 * 1024

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

    /// Computes CRC-32 of an arbitrary buffer using GPU per-slice + CPU
    /// combine. Buffers above `perDispatchByteLimit` are sliced into
    /// `slice-size`-aligned chunks; each chunk runs the original
    /// single-dispatch path and the chunk CRCs are folded together via
    /// `crc32Combine`.
    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>) throws -> UInt32 {
        let total = buffer.count
        if total == 0 { return 0 }
        guard let basePtr = buffer.baseAddress else { return 0 }

        // Round the chunk limit down to a multiple of `sliceSize` so the
        // kernel's per-slice walks don't straddle chunk boundaries —
        // otherwise the last slice in one chunk and the first slice in
        // the next would together cover one logical sliceSize, but the
        // host-side combine would treat them as two slices.
        let chunkLimit = max(sliceSize, (Self.perDispatchByteLimit / sliceSize) * sliceSize)

        if total <= chunkLimit {
            // Single-dispatch fast path — preserves the original
            // behaviour for sub-1-GiB buffers.
            return try crc32OneDispatch(basePtr: basePtr, total: total)
        }

        // Multi-dispatch path: per-chunk CRC, combine via crc32_combine.
        var combined: UInt32 = 0
        var firstChunk = true
        var off = 0
        while off < total {
            let chunkLen = min(chunkLimit, total - off)
            let chunkCrc = try crc32OneDispatch(
                basePtr: basePtr.advanced(by: off),
                total: chunkLen
            )
            if firstChunk {
                combined = chunkCrc
                firstChunk = false
            } else {
                combined = crc32Combine(
                    crc1: combined,
                    crc2: chunkCrc,
                    len2: UInt(chunkLen)
                )
            }
            off += chunkLen
        }
        return combined
    }

    /// Original single-dispatch implementation. Caller is responsible
    /// for keeping `total ≤ perDispatchByteLimit` so the kernel's `uint`
    /// indexing and `MTLDevice.maxBufferLength` both stay in range.
    private func crc32OneDispatch(basePtr: UnsafePointer<UInt8>,
                                  total: Int) throws -> UInt32 {
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
        for i in 1..<numSlices {
            let sliceLen = min(sliceSize, total - i * sliceSize)
            combined = crc32Combine(crc1: combined, crc2: slicePtr[i], len2: UInt(sliceLen))
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
