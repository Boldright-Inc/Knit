import Foundation
import CDeflate
import CZstd

public enum Knit {
    public static let version = "0.1.0-dev"

    public static func libdeflateVersion() -> String {
        // libdeflate doesn't expose a runtime version symbol; pinned via Scripts/fetch-vendor.sh
        "1.22"
    }

    public static func zstdVersion() -> String {
        guard let cstr = ZSTD_versionString() else { return "unknown" }
        return String(cString: cstr)
    }
}
