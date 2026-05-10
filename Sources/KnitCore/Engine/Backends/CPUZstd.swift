import Foundation
import CZstd
import CDeflate

/// A backend that compresses contiguous chunks (blocks) into independent
/// zstd frames. The `.knit` container relies on this property: each block
/// is a complete, self-describing zstd frame that can be decoded in
/// isolation, enabling random-access seeking and trivially parallel
/// decompression.
///
/// Concatenated zstd frames are also a valid zstd stream, so a `.knit`
/// payload section can be piped straight into `zstd -d` and will decode as
/// one logical output (the same way multiple gzip members chain).
public protocol BlockBackend: Sendable {
    var name: String { get }

    /// Compress one block into a single complete zstd frame.
    func compressBlock(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data
}

/// CPU zstd via the vendored libzstd. CRC32 lives on the same type because
/// `KnitCompressor` requires both protocols on its backend (the writer
/// needs per-entry CRC alongside the codec).
public struct CPUZstd: BlockBackend, CRC32Computing {
    public let name = "cpu-zstd"
    public init() {}

    public func compressBlock(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data {
        if input.count == 0 { return Data() }
        // ZSTD_compressBound is tight (input + ~14 bytes), so one-shot
        // sizing avoids the retry-on-overflow loop that streaming APIs need.
        let bound = ZSTD_compressBound(input.count)
        var out = Data(count: bound)
        let produced: Int = out.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Int in
            guard let outPtr = buf.baseAddress else { return 0 }
            return ZSTD_compress(outPtr, bound, input.baseAddress, input.count, level)
        }
        if ZSTD_isError(produced) != 0 {
            let cstr = ZSTD_getErrorName(produced)
            let msg = cstr.map { String(cString: $0) } ?? "unknown"
            throw KnitError.codecFailure("zstd: \(msg)")
        }
        out.removeSubrange(produced..<out.count)
        return out
    }

    public func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32 = 0) -> UInt32 {
        UInt32(libdeflate_crc32(UInt32(seed), buffer.baseAddress, buffer.count))
    }
}

/// Splits an input buffer into fixed-size blocks, compresses each in
/// parallel using a `BlockBackend`, and returns the concatenated frames
/// plus the per-block compressed sizes.
///
/// `blockSizes` is what makes the random-access decode possible: the
/// `.knit` reader uses it to compute each block's offset inside the
/// payload section without parsing any zstd frames first.
public struct ParallelBlockCompressor {

    public struct Output {
        public var combined: Data
        /// Compressed bytes per block, in input order. Sum equals
        /// `combined.count`; written into the `.knit` entry header.
        public var blockSizes: [UInt32]
        public var totalIn: UInt64
        public var totalOut: UInt64
    }

    public let backend: BlockBackend
    public let blockSize: Int
    public let concurrency: Int

    public init(backend: BlockBackend,
                blockSize: Int = 1 * 1024 * 1024,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.backend = backend
        self.blockSize = blockSize
        self.concurrency = max(1, concurrency)
    }

    public func compress(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Output {
        try compress(input, level: level, perBlockLevels: nil)
    }

    /// Compress with optional per-block compression-level overrides.
    ///
    /// When `perBlockLevels` is supplied (one entry per block), each block is
    /// compressed at its own level — typically used to downgrade
    /// already-incompressible blocks to lvl=1 since lvl≥3's match search is
    /// pure overhead on high-entropy data.
    public func compress(_ input: UnsafeBufferPointer<UInt8>,
                         level: Int32,
                         perBlockLevels: [Int32]?) throws -> Output {
        if input.count == 0 {
            return Output(combined: Data(), blockSizes: [], totalIn: 0, totalOut: 0)
        }

        var slices: [(Int, Int)] = []
        var off = 0
        while off < input.count {
            let len = min(blockSize, input.count - off)
            slices.append((off, len))
            off += len
        }

        if let pbl = perBlockLevels, pbl.count != slices.count {
            throw KnitError.codecFailure(
                "perBlockLevels count (\(pbl.count)) != slice count (\(slices.count))"
            )
        }

        let basePtr = SendableRawPointer(input.baseAddress!)
        let backend = self.backend
        let pbl = perBlockLevels

        let frames: [Data] = try concurrentMap(
            Array(slices.enumerated()),
            concurrency: concurrency
        ) { item in
            let (idx, slice) = item
            let p = basePtr.value.advanced(by: slice.0)
            let lvl = pbl?[idx] ?? level
            return try backend.compressBlock(
                UnsafeBufferPointer(start: p, count: slice.1),
                level: lvl
            )
        }

        var combined = Data()
        var sizes: [UInt32] = []
        sizes.reserveCapacity(frames.count)
        for f in frames {
            sizes.append(UInt32(f.count))
            combined.append(f)
        }
        return Output(
            combined: combined,
            blockSizes: sizes,
            totalIn: UInt64(input.count),
            totalOut: UInt64(combined.count)
        )
    }
}
