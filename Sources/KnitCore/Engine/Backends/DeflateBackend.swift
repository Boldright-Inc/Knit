import Foundation

/// A backend that compresses a contiguous buffer with raw DEFLATE
/// (RFC 1951 — no zlib or gzip wrapper). Implementations: `CPUDeflate`
/// (libdeflate, single-threaded but fastest per-core) and `ParallelDeflate`
/// (system zlib stitched together via `Z_SYNC_FLUSH`, multi-core).
///
/// All conformers must be `Sendable`: ZipCompressor fans out across a
/// concurrent map and shares a single backend instance across worker
/// threads.
public protocol DeflateBackend: Sendable {
    /// Human-readable identifier surfaced in logs and benchmarks.
    var name: String { get }

    /// Compress `input` and return the produced raw DEFLATE bytes. `level`
    /// follows libdeflate semantics (0..12); callers should pass through
    /// `CompressionLevel.clampedForDeflate()` rather than a raw integer.
    func compress(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data
}

/// Computes a CRC-32 checksum using the IEEE 802.3 / zlib polynomial
/// (0xEDB88320 reflected). Both the ZIP local file header and the `.knit`
/// per-entry header record this exact CRC. `seed` allows incremental
/// computation: pass 0 for a fresh CRC, or the result of a previous call to
/// continue across discontiguous chunks.
public protocol CRC32Computing: Sendable {
    func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32) -> UInt32
}
