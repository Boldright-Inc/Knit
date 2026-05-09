import Foundation
import CZlibBridge
import CDeflate

/// Sendable wrapper for a raw pointer whose lifetime is managed externally.
struct SendableRawPointer: @unchecked Sendable {
    let value: UnsafePointer<UInt8>
    init(_ value: UnsafePointer<UInt8>) { self.value = value }
}

/// pigz-style parallel DEFLATE: split input into fixed-size chunks, compress
/// each chunk independently with zlib using `Z_SYNC_FLUSH`, and concatenate
/// the results. The final chunk uses `Z_FINISH`.
///
/// The output is a single, valid raw DEFLATE stream that any standard
/// decoder (zlib, libdeflate, unzip, etc.) can decompress as one logical unit.
public struct ParallelDeflate: DeflateBackend, CRC32Computing {
    public let name = "cpu-parallel-zlib"
    public let chunkSize: Int
    public let concurrency: Int

    public init(chunkSize: Int = 1 * 1024 * 1024,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.chunkSize = chunkSize
        self.concurrency = max(1, concurrency)
    }

    public func compress(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data {
        guard input.count > 0 else { return Data() }

        // zlib levels go 0..9; clamp from libdeflate range.
        let zlibLevel: Int32 = min(max(level, 0), 9)

        // Compute chunk slices.
        let total = input.count
        var slices: [(offset: Int, length: Int, isLast: Bool)] = []
        var off = 0
        while off < total {
            let len = min(chunkSize, total - off)
            slices.append((off, len, false))
            off += len
        }
        slices[slices.count - 1].isLast = true

        // The buffer is guaranteed alive for the duration of `compress(_:level:)`,
        // so passing the raw pointer across threads is safe — wrap it for Sendable.
        let basePtr = SendableRawPointer(input.baseAddress!)

        // Compress chunks in parallel
        let outputs: [Data] = try concurrentMap(slices, concurrency: concurrency) { slice in
            let chunkPtr = basePtr.value.advanced(by: slice.offset)
            return try Self.compressChunk(
                input: UnsafeBufferPointer(start: chunkPtr, count: slice.length),
                level: zlibLevel,
                isLast: slice.isLast
            )
        }

        // Concatenate
        var totalOut = 0
        for d in outputs { totalOut += d.count }
        var combined = Data(capacity: totalOut)
        for d in outputs { combined.append(d) }
        return combined
    }

    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32 = 0) -> UInt32 {
        UInt32(libdeflate_crc32(UInt32(seed), buffer.baseAddress, buffer.count))
    }

    private static func compressChunk(
        input: UnsafeBufferPointer<UInt8>,
        level: Int32,
        isLast: Bool
    ) throws -> Data {
        let bound = bzip_chunk_deflate_bound(level, input.count)
        var out = Data(count: bound)
        let mode: bzip_flush_mode_t = isLast ? BZIP_FLUSH_FINISH : BZIP_FLUSH_SYNC
        let produced: Int = out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Int in
            guard let outPtr = buf.baseAddress else { return -1 }
            return bzip_chunk_deflate(
                level,
                input.baseAddress, input.count,
                outPtr, bound,
                mode
            )
        }
        if produced < 0 {
            throw KnitError.codecFailure("zlib chunk deflate failed")
        }
        out.removeSubrange(produced..<out.count)
        return out
    }
}
