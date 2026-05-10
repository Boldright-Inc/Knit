import Foundation
import CZstd

/// CPU-side zstd decoder, wrapping libzstd's `ZSTD_decompress`.
///
/// Serves two roles:
///   1. The unconditional baseline `BlockDecoding` conformer — always
///      available, used wherever GPU decode isn't applicable or has
///      fallen back.
///   2. The correctness oracle for the future `MetalZstdLiteralDecoder`
///      — differential tests assert byte-equality between the two
///      paths' outputs.
///
/// Stateless: each `decodeBlock` allocates no per-instance resources,
/// so the same instance can be shared across worker threads safely.
public struct CPUZstdDecoder: BlockDecoding {
    public let name = "cpu-zstd-decoder"
    public let supportsGPU = false

    public init() {}

    public func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                            into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        guard let inPtr = frame.baseAddress, let outPtr = output.baseAddress else {
            return 0
        }
        let produced = ZSTD_decompress(outPtr, output.count, inPtr, frame.count)
        if ZSTD_isError(produced) != 0 {
            let cstr = ZSTD_getErrorName(produced)
            let msg = cstr.map { String(cString: $0) } ?? "unknown"
            throw KnitError.codecFailure("zstd decode: \(msg)")
        }
        return produced
    }
}
