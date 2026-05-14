import Foundation
import CDeflate

/// CPU-side DEFLATE **decoder** backed by libdeflate. Symmetric to
/// `CPUDeflate` on the compression side.
///
/// The libdeflate decompressor has no streaming/flush API — it
/// requires the entire compressed input in one contiguous buffer and
/// writes the entire decompressed output to another contiguous buffer.
/// That matches the ZIP per-entry model (each entry is one
/// self-contained DEFLATE stream) and makes the API trivially safe to
/// fan out across worker threads — each call allocates its own
/// decompressor handle and frees it on the way out.
///
/// `Sendable` because the struct holds no mutable state; every call
/// site of `decompress(...)` produces its own libdeflate handle.
public struct CPUDeflateDecoder: Sendable {
    public let name = "cpu-libdeflate-decoder"
    public init() {}

    /// Decompress a raw DEFLATE stream of exactly `expectedSize`
    /// uncompressed bytes from `input` into `output`. The caller is
    /// responsible for sizing `output` to `expectedSize` (the ZIP
    /// Central Directory's `uncompressed_size` is authoritative here).
    ///
    /// Returns the number of bytes actually written. Equal to
    /// `expectedSize` on success; throwing means the stream was
    /// malformed, truncated, or claimed a different uncompressed size
    /// than the ZIP header said.
    ///
    /// libdeflate semantics summary (from `libdeflate.h`):
    ///   - `out_nbytes_avail` is the exact expected uncompressed size.
    ///   - Pass `NULL` for `actual_out_nbytes_ret` (= "you must produce
    ///     exactly out_nbytes_avail bytes"). libdeflate then fails with
    ///     `LIBDEFLATE_SHORT_OUTPUT` if the stream decompresses to
    ///     fewer bytes, which catches the "CD lied about size" failure
    ///     mode at decode time rather than during a separate length
    ///     check.
    public func decompress(input: UnsafeBufferPointer<UInt8>,
                           into output: UnsafeMutableBufferPointer<UInt8>) throws {
        guard let dec = libdeflate_alloc_decompressor() else {
            throw KnitError.allocationFailure("libdeflate_alloc_decompressor")
        }
        defer { libdeflate_free_decompressor(dec) }

        // Empty input → empty output is a valid case (some ZIP creators
        // emit a zero-byte deflate stream for zero-byte entries; the
        // more common pattern is to use `.stored` instead, which we
        // also handle). libdeflate refuses to parse a zero-byte
        // DEFLATE buffer (returns BAD_DATA), so short-circuit here.
        if input.count == 0 && output.count == 0 {
            return
        }

        let result = libdeflate_deflate_decompress(
            dec,
            input.baseAddress, input.count,
            output.baseAddress, output.count,
            nil   // require exactly output.count bytes
        )
        switch result {
        case LIBDEFLATE_SUCCESS:
            return
        case LIBDEFLATE_BAD_DATA:
            throw KnitError.codecFailure("libdeflate: bad DEFLATE data")
        case LIBDEFLATE_SHORT_OUTPUT:
            throw KnitError.codecFailure(
                "libdeflate: stream decompressed to fewer than \(output.count) bytes")
        case LIBDEFLATE_INSUFFICIENT_SPACE:
            throw KnitError.codecFailure(
                "libdeflate: output overflowed \(output.count)-byte buffer")
        default:
            throw KnitError.codecFailure("libdeflate: result code \(result.rawValue)")
        }
    }
}
