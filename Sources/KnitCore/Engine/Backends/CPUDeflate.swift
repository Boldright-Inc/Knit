import Foundation
import CDeflate

/// CPU-side DEFLATE backed by libdeflate.
///
/// libdeflate compressors are stateful but cheap to allocate. Each compression call
/// allocates a thread-local compressor; callers compressing many buffers in parallel
/// should ideally pool these — see `CPUDeflate.compressInChunks` below.
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

    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32 = 0) -> UInt32 {
        UInt32(libdeflate_crc32(UInt32(seed), buffer.baseAddress, buffer.count))
    }
}

extension CPUDeflate {
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
            // libdeflate returns 0 if the output didn't fit (shouldn't happen given bound).
            throw KnitError.codecFailure("libdeflate_deflate_compress returned 0")
        }
        out.removeSubrange(produced..<out.count)
        return out
    }
}
