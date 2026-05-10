import Foundation

/// User-facing compression level, normalised to the libdeflate (0..12) range.
///
/// libdeflate accepts 0..12 while libzstd accepts 1..22, so the same `raw`
/// value means subtly different things to each backend. We keep one knob in
/// the public API and rely on `clampedForDeflate()` / `clampedForZstd()` to
/// translate per backend at the call site. The CLI exposes `--level` in
/// libdeflate units to keep documentation consistent.
public struct CompressionLevel: Sendable, Equatable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }

    /// Method 0 (ZIP `stored`). For zstd, clamps up to lvl=1 since libzstd
    /// has no "no compression" mode at the API level.
    public static let store    = CompressionLevel(0)
    /// Fastest non-zero level — DEFLATE lvl=1, zstd lvl=1 (`fast` strategy).
    public static let fast     = CompressionLevel(1)
    /// Balanced default — DEFLATE lvl=6 (zlib's classic default), the
    /// common bench-equivalent point against `pigz` and Archive Utility.
    public static let `default` = CompressionLevel(6)
    /// Maximum for the libdeflate range. zstd can go higher (up to 22) but
    /// the public API caps here to keep the level scale comparable.
    public static let best     = CompressionLevel(12)

    /// Clamp into libdeflate's 0..12 range.
    public func clampedForDeflate() -> Int32 {
        Int32(min(max(raw, 0), 12))
    }

    /// Clamp into libzstd's 1..22 range. Libzstd also accepts negative
    /// levels for ultra-fast modes, but those produce wildly different
    /// ratios and we don't want to surface them through a single knob.
    public func clampedForZstd() -> Int32 {
        Int32(min(max(raw, 1), 22))
    }
}

/// ZIP compression method codes as written into the local-file-header
/// `compression_method` field (PKWARE APPNOTE.TXT §4.4.5).
public enum CompressionMethod: UInt16, Sendable {
    /// ZIP method 0 — entry stored verbatim, no codec applied.
    case stored = 0
    /// ZIP method 8 — raw DEFLATE (RFC 1951), the universally supported
    /// compressed method.
    case deflate = 8
}
