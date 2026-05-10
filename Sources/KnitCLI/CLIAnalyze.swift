import Foundation
import KnitCore

/// Formats a `DecodeAnalytics.Snapshot` into a multi-line block
/// rendered to stderr at the end of an `unpack` invocation when the
/// hidden `--analyze` flag is set.
///
/// The output is meant to be copy-pasted back to the maintainer as
/// raw evidence about where wall-clock time is going on the user's
/// host. Format goals (in order):
///   1. Greppable: stable column layout, no ANSI escapes.
///   2. Self-explanatory: each row's % of `total wall` is right
///      next to it, so you can see at a glance which stage dominates.
///   3. Diff-friendly: stable ordering and units across runs, so
///      before/after pairs can be eyeballed without lining up
///      lines manually.
enum CLIAnalyze {

    static func render(_ snap: DecodeAnalytics.Snapshot,
                       extractElapsed: TimeInterval,
                       bytesOut: UInt64,
                       entries: Int) -> String {
        var out = ""
        out += "\n=== analyze: unpack ===\n"
        out += String(format: "  total wall:                %8.3f s\n", extractElapsed)
        out += String(format: "  decoder wall:              %8.3f s\n", snap.totalWall)
        out += "  entries:                   \(entries)\n"
        out += String(format: "  bytes out:                 %@ (%@)\n",
                      formatBytesDecimal(bytesOut),
                      formatThroughput(bytesOut: bytesOut, seconds: extractElapsed))
        out += "  batches:                   \(snap.batchCount)\n"
        if snap.batchCount > 0 {
            let avgBytes = Double(snap.totalBatchBytes) / Double(snap.batchCount)
            out += String(format: "  avg batch size:            %8.2f MiB\n",
                          avgBytes / (1024 * 1024))
        }
        out += "  GPU fallback blocks:       \(snap.fallbackBlocks)\n"

        out += "\n  per-stage wall (decoder, sums to ~decoder wall):\n"
        let denom = max(snap.totalWall, 0.000_001)
        var accountedFor: TimeInterval = 0
        for stage in snap.stages {
            accountedFor += stage.seconds
            let pct = stage.seconds / denom * 100
            let perBatch: String
            if snap.batchCount > 0 {
                let ms = stage.seconds * 1000.0 / Double(snap.batchCount)
                perBatch = String(format: " (%.2f ms/batch)", ms)
            } else {
                perBatch = ""
            }
            out += String(format: "    %-20s  %8.3f s  %5.1f %%%@\n",
                          stage.name, stage.seconds, pct, perBatch)
        }
        let unaccounted = max(0, snap.totalWall - accountedFor)
        let unaccPct = unaccounted / denom * 100
        out += String(format: "    %-20s  %8.3f s  %5.1f %%\n",
                      "(unaccounted)", unaccounted, unaccPct)
        out += "\n"
        return out
    }

    private static func formatBytesDecimal(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1_000_000_000 {
            return String(format: "%.2f GB", v / 1_000_000_000)
        }
        if v >= 1_000_000 {
            return String(format: "%.2f MB", v / 1_000_000)
        }
        if v >= 1_000 {
            return String(format: "%.2f KB", v / 1_000)
        }
        return String(format: "%.0f B", v)
    }

    private static func formatThroughput(bytesOut: UInt64, seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "?" }
        let mbps = Double(bytesOut) / 1_000_000 / seconds
        if mbps >= 1000 {
            return String(format: "%.2f GB/s", mbps / 1000)
        }
        return String(format: "%.0f MB/s", mbps)
    }
}
