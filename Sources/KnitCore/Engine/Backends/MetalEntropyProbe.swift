import Foundation
import Metal

/// GPU-accelerated compressibility probe.
///
/// For each block in the input, dispatches one threadgroup that builds a
/// 256-bin byte histogram in threadgroup memory using atomic adds. Shannon
/// entropy is computed on the host from the histograms — this is O(256) per
/// block and trivial compared to the histogram phase.
///
/// On Apple Silicon the input buffer is aliased into Metal via the same
/// `bytesNoCopy` trick used by `MetalCRC32`, so unified memory makes this
/// effectively a "free" pass over data the CPU would otherwise have to walk
/// itself before deciding whether to compress.
public final class MetalEntropyProbe: EntropyProbing, @unchecked Sendable {

    public let name = "metal-entropy"

    /// Buffers smaller than this fall back to CPU — GPU dispatch overhead
    /// (~100 µs end-to-end on M-series) dominates the work otherwise.
    public static let minBufferForGPU: Int = 256 * 1024

    private let context: MetalContext
    private let pipeline: MTLComputePipelineState

    public init?() {
        guard let ctx = MetalContext() else { return nil }
        do {
            self.pipeline = try ctx.makePipeline("byte_histogram")
        } catch {
            return nil
        }
        self.context = ctx
    }

    public func probe(_ buffer: UnsafeBufferPointer<UInt8>,
                      blockSize: Int) throws -> [EntropyResult] {
        guard let base = buffer.baseAddress, buffer.count > 0, blockSize > 0 else {
            return []
        }
        // Below the dispatch-amortization threshold, defer to CPU. Same code
        // path; the result format is identical.
        if buffer.count < Self.minBufferForGPU {
            return try CPUEntropyProbe().probe(buffer, blockSize: blockSize)
        }

        let total = buffer.count
        let numBlocks = (total + blockSize - 1) / blockSize

        // Page-aligned input gets `bytesNoCopy` (zero-copy on UMA); otherwise
        // use the copying path. Mirrors MetalCRC32's strategy.
        let inBuf = try makeInputBuffer(base: base, total: total)

        let histogramBytes = numBlocks * 256 * MemoryLayout<UInt32>.stride
        guard let outBuf = context.device.makeBuffer(
            length: histogramBytes,
            options: .storageModeShared
        ) else {
            throw KnitError.allocationFailure("Metal entropy histogram buffer")
        }

        var params = ProbeParams(
            totalBytes: UInt32(total),
            blockSize: UInt32(blockSize),
            numBlocks: UInt32(numBlocks)
        )

        guard let cmd = context.queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw KnitError.codecFailure("Metal entropy command encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inBuf, offset: 0, index: 0)
        enc.setBuffer(outBuf, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<ProbeParams>.stride, index: 2)

        // 256-thread group lets each lane own one of the 256 bins for the
        // zero/flush phases; histogram phase is strided so this size is fine
        // across block sizes too.
        let tgSize = MTLSize(width: 256, height: 1, depth: 1)
        let grid = MTLSize(width: numBlocks, height: 1, depth: 1)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tgSize)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let histPtr = outBuf.contents().bindMemory(to: UInt32.self, capacity: numBlocks * 256)
        var results: [EntropyResult] = []
        results.reserveCapacity(numBlocks)
        var bins = [UInt32](repeating: 0, count: 256)
        for b in 0..<numBlocks {
            for i in 0..<256 { bins[i] = histPtr[b * 256 + i] }
            let len = min(blockSize, total - b * blockSize)
            let h = EntropyMath.shannonEntropy(histogram: bins, total: len)
            results.append(EntropyResult(entropy: h, byteCount: len))
        }
        return results
    }

    private func makeInputBuffer(base: UnsafePointer<UInt8>, total: Int) throws -> MTLBuffer {
        let pageSize = UInt(getpagesize())
        let pageMask = pageSize &- 1
        let raw = UnsafeRawPointer(base)
        let addrAligned = (UInt(bitPattern: raw) & pageMask) == 0
        let lengthAligned = (UInt(total) & pageMask) == 0

        if addrAligned && lengthAligned {
            let mutable = UnsafeMutableRawPointer(mutating: raw)
            if let b = context.device.makeBuffer(
                bytesNoCopy: mutable,
                length: total,
                options: .storageModeShared,
                deallocator: nil
            ) {
                return b
            }
        }
        guard let b = context.device.makeBuffer(
            bytes: base, length: total, options: .storageModeShared
        ) else {
            throw KnitError.allocationFailure("Metal entropy input buffer")
        }
        return b
    }
}

private struct ProbeParams {
    var totalBytes: UInt32
    var blockSize: UInt32
    var numBlocks: UInt32
}

/// Auto-selecting probe: prefers Metal when available, falls back to CPU.
/// Stateless and cheap to construct.
public struct AutoEntropyProbe: EntropyProbing {
    public var name: String { backend.name }
    private let backend: any EntropyProbing

    public init() {
        if let gpu = MetalEntropyProbe() {
            self.backend = gpu
        } else {
            self.backend = CPUEntropyProbe()
        }
    }

    public func probe(_ buffer: UnsafeBufferPointer<UInt8>,
                      blockSize: Int) throws -> [EntropyResult] {
        try backend.probe(buffer, blockSize: blockSize)
    }
}
