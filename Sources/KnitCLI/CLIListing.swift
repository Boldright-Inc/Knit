import Foundation
import KnitCore

/// Renders an archive's entry table to stdout for the `--list` flag on
/// `knit unzip` and `knit unpack`. Listing is a metadata-only operation
/// — `ZipReader` / `KnitReader` parse the central directory / footer
/// via mmap and walk it without touching any compressed payload, so
/// even on a multi-GB archive `--list` completes in milliseconds and
/// uses negligible RSS.
///
/// Format mirrors `unzip -l` with two adjustments for tooling
/// friendliness:
///   * ISO-8601-shaped UTC timestamps (`yyyy-MM-dd HH:mm:ss`) so the
///     column is sortable and locale-independent. `unzip -l` uses
///     `MM-DD-YYYY` which is unparseable cross-locale.
///   * Right-aligned size column so `column -t` / `awk` can pick it
///     up without ambiguity.
///
/// Goes to stdout (not stderr — `--analyze` is stderr) so the table is
/// pipeable into `grep` / `awk` / `xargs` for selective entry
/// extraction workflows:
///
///     knit unzip --list big.zip \
///       | awk '$NF ~ /\.swift$/ {print $NF}' \
///       | xargs -I{} knit unzip big.zip --entry {} -o out/
enum CLIListing {

    /// One row in the entry table. Decoupled from `ZipEntry` /
    /// `KnitEntry` so the renderer can serve both formats and any
    /// future archive type without growing format-specific branches.
    struct Row: Sendable {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        let modificationDate: Date
    }

    /// Format `rows` into a human-readable table prefixed with the
    /// archive's path. Trailing newline included; the caller should
    /// pass the result to `print(..., terminator: "")` or write it
    /// directly to stdout.
    static func render(archivePath: String, rows: [Row]) -> String {
        // Lazily build the formatter — listing is rare enough that
        // we don't bother caching it on the type. ISO-8601 with
        // space-between-date-and-time matches the column we
        // documented in the file header.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")

        var out = ""
        out += "Archive: \(archivePath)\n"
        out += "       Size  Modified (UTC)         Name\n"
        out += "  ---------  -------------------    ----\n"
        var total: UInt64 = 0
        for row in rows {
            let sizeStr = Self.padLeft(String(row.size), width: 9)
            let dateStr = df.string(from: row.modificationDate)
            // Trailing slash on directory names so a quick `grep '/$'`
            // selects only directories — same convention `unzip -l`
            // uses for distinguishing entry kinds.
            let nameStr = row.isDirectory && !row.name.hasSuffix("/")
                ? row.name + "/"
                : row.name
            out += "  \(sizeStr)  \(dateStr)    \(nameStr)\n"
            total &+= row.size
        }
        out += "  ---------\n"
        out += "  \(Self.padLeft(String(total), width: 9))" +
               "                        \(rows.count) entries\n"
        return out
    }

    /// Right-pad with spaces to `width` columns. We don't use
    /// `String.padding(toLength:withPad:startingAt:)` because that
    /// only right-pads (whereas we want left-pad on a numeric
    /// column), and `String(format: "%9s", …)` is unsafe for Swift
    /// strings per CLAUDE.md Rule 2.1.
    private static func padLeft(_ s: String, width: Int) -> String {
        let need = max(0, width - s.count)
        return String(repeating: " ", count: need) + s
    }
}
