import Foundation
import CDeflate

/// CPU-side DEFLATE backed by libdeflate.
///
/// libdeflate is the fastest single-threaded DEFLATE encoder publicly
/// available — typically 2–3× faster per core than zlib at equivalent
/// ratios. The trade-off: it has no streaming/flush API, so we use it for
/// per-entry compression of fully-buffered inputs (the common case for
/// directory archiving). For single-huge-file workloads the parallel zlib
/// path (`ParallelDeflate`) is preferred.
///
/// Compressor handles are stateful but cheap to allocate. Each call
/// allocates a fresh compressor; if a future caller wants to amortise that
/// over many tiny buffers, pool with `libdeflate_alloc_compressor` once and
/// reuse via `libdeflate_deflate_compress` on the same handle.
public struct CPUDeflate: DeflateBackend, CRC32Computing {
    public let name = "cpu-libdeflate"
    public init() {}

    public func compress(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data {
        guard let compressor = libdeflate_alloc_compressor(level) else {
            throw KnitError.allocationFailure("libdeflate_alloc_compressor")
        }
        defer { libdeflate_free_compressor(compressor) }
        return try compressOnce(compressor: compressor, input: input)
    }

    /// Hardware-accelerated CRC32 via libdeflate's NEON / pclmulqdq paths.
    /// On Apple Silicon this hits the dedicated CRC32 instruction and runs
    /// at ~5–8 GB/s on a single P-core.
    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32 = 0) -> UInt32 {
        UInt32(libdeflate_crc32(UInt32(seed), buffer.baseAddress, buffer.count))
    }
}

extension CPUDeflate {
    /// One-shot compression with a worst-case-sized output buffer. We size
    /// to libdeflate's published bound and then trim — this is preferable
    /// to retrying with a larger buffer on overflow because the bound is
    /// already tight (`input.count + small overhead`).
    fileprivate func compressOnce(
        compressor: OpaquePointer,
        input: UnsafeBufferPointer<UInt8>
    ) throws -> Data {
        let bound = libdeflate_deflate_compress_bound(compressor, input.count)
        var out = Data(count: bound)
        let produced: Int = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int in
            guard let outPtr = outBuf.baseAddress else { return 0 }
            return libdeflate_deflate_compress(
                compressor,
                input.baseAddress,
                input.count,
                outPtr,
                bound
            )
        }
        if produced == 0 {
            // libdeflate returns 0 only when the output didn't fit, which
            // shouldn't happen given we sized to its own published bound.
            // Treat as a hard codec failure rather than a retry case.
            throw KnitError.codecFailure("libdeflate_deflate_compress returned 0")
        }
        out.removeSubrange(produced..<out.count)
        return out
    }
}
