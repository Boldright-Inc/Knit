import Foundation

/// A backend that compresses a buffer with raw DEFLATE (RFC 1951).
public protocol DeflateBackend: Sendable {
    var name: String { get }

    /// Compress raw bytes. Returns the produced DEFLATE stream as `Data`.
    /// `level` follows libdeflate semantics (0..12).
    func compress(_ input: UnsafeBufferPointer<UInt8>, level: Int32) throws -> Data
}

/// Computes a CRC-32 checksum (IEEE 802.3 / zlib).
public protocol CRC32Computing: Sendable {
    func crc32(_ buffer: UnsafeBufferPointer<UInt8>, seed: UInt32) -> UInt32
}
