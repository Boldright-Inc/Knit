import Foundation
import CDeflate
import CZstd

/// Top-level KnitCore namespace.
///
/// This module owns the compression engine: file walking, mmap I/O, the
/// DEFLATE / zstd backends, the ZIP and `.knit` container writers/readers,
/// and the Metal compute pipeline (CRC32 + entropy probe + heatmap).
///
/// `KnitCLI` wraps these as the user-facing `knit` command. `KnitApp` is a
/// tiny AppKit shim used by Finder Quick Actions and the document-icon
/// double-click handler.
public enum Knit {
    /// Single source of truth for the user-visible version string.
    /// Bumped manually on release; also surfaced via `knit info`.
    public static let version = "0.1.0-dev"

    /// libdeflate doesn't expose a runtime version symbol, so we report
    /// the version pinned by `Scripts/fetch-vendor.sh`. Keep in sync when
    /// upgrading the vendored sources.
    public static func libdeflateVersion() -> String {
        "1.22"
    }

    /// libzstd's runtime version string (e.g. "1.5.6").
    public static func zstdVersion() -> String {
        guard let cstr = ZSTD_versionString() else { return "unknown" }
        return String(cString: cstr)
    }
}
