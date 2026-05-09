import Foundation

public struct CompressionLevel: Sendable, Equatable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }

    public static let store    = CompressionLevel(0)   // no compression
    public static let fast     = CompressionLevel(1)
    public static let `default` = CompressionLevel(6)
    public static let best     = CompressionLevel(12)  // libdeflate max

    public func clampedForDeflate() -> Int32 {
        Int32(min(max(raw, 0), 12))
    }

    public func clampedForZstd() -> Int32 {
        // libzstd levels: 1..22 (negative levels exist but skip for now)
        Int32(min(max(raw, 1), 22))
    }
}

public enum CompressionMethod: UInt16, Sendable {
    /// ZIP method 0 — store
    case stored = 0
    /// ZIP method 8 — DEFLATE
    case deflate = 8
}
