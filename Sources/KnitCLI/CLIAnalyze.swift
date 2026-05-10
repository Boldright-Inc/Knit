import Foundation
import KnitCore

/// Formats a `StageAnalytics.Snapshot` into a multi-line block
/// rendered to stderr at the end of a `pack` or `unpack` invocation
/// when the hidden `--analyze` flag is set.
///
/// The output is meant to be copy-pasted back to the maintainer as
/// raw evidence about where wall-clock time (and how much CPU time)
/// is going on the user's host. Format goals (in order):
///   1. Greppable: stable column layout, no ANSI escapes.
///   2. Self-explanatory: each row's % of the relevant denominator
///      is right next to it.
///   3. Diff-friendly: stable ordering and units across runs, so
///      before/after pairs can be eyeballed without lining up
///      lines manually.
///
/// **Safety note**: this file deliberately *avoids* `String(format:)`
/// for `String` arguments. `%@` and `%-20s` look convenient but treat
/// the argument as an Objective-C `NSString` (with a bridge that can
/// be invalidated mid-call) and a UTF-8 C-string pointer respectively;
/// passing a Swift `String` directly is undefined behaviour on Apple
/// platforms and segfaulted on long runs (PR #19's release build
/// crashed at the very first stage row of an 80 GB unpack analyse,
/// fixed in PR #21). We use Swift string interpolation for any
/// `String` payload, and keep `String(format:)` only for genuinely
/// numeric specifiers (`%f`, `%d`, `%x`).
///
/// The pack-side renderer separates **wall stages** (`parallel.compress`,
/// `archive.write` — these sum toward total wall) from **cumulative
/// CPU stages** (`compute.entropy`, `compute.crc`, `compute.compress` —
/// these are summed across all workers and intentionally exceed wall
/// time, since that's what tells us how much CPU work GPU offload of
/// that stage could absorb). The unpack-side stages are all wall.
enum CLIAnalyze {

    // MARK: - Decode (unpack)

    /// Decode-side breakdown rendered by `unpack --analyze`. All stages
    /// are wall-time and sum toward `decoder wall`.
    static func renderUnpack(_ snap: StageAnalytics.Snapshot,
                             extractElapsed: TimeInterval,
                             bytesOut: UInt64,
                             entries: Int) -> String {
        var out = ""
        out += "\n=== analyze: unpack ===\n"
        out += "  total wall:                \(formatSeconds(extractElapsed))\n"
        out += "  decoder wall:              \(formatSeconds(snap.totalWall))\n"
        out += "  entries:                   \(entries)\n"
        out += "  bytes out:                 \(formatBytesDecimal(bytesOut))" +
               " (\(formatThroughput(bytes: bytesOut, seconds: extractElapsed)))\n"
        out += "  batches:                   \(snap.batchCount)\n"
        if snap.batchCount > 0 {
            let avgBytes = Double(snap.totalBatchBytes) / Double(snap.batchCount)
            out += "  avg batch size:            " +
                   String(format: "%8.2f", avgBytes / (1024 * 1024)) + " MiB\n"
        }
        out += "  GPU fallback blocks:       \(snap.fallbackBlocks)\n"

        out += "\n  per-stage wall (decoder, sums to ~decoder wall):\n"
        let denom = max(snap.totalWall, 0.000_001)
        var accountedFor: TimeInterval = 0
        for stage in snap.stages {
            accountedFor += stage.seconds
            out += renderStageRow(name: stage.name,
                                  seconds: stage.seconds,
                                  denom: denom,
                                  batchCount: snap.batchCount)
        }
        let unaccounted = max(0, snap.totalWall - accountedFor)
        out += renderStageRow(name: "(unaccounted)",
                              seconds: unaccounted,
                              denom: denom,
                              batchCount: 0)
        out += "\n"
        return out
    }

    // MARK: - Encode (pack)

    /// Encode-side breakdown rendered by `pack --analyze`. Splits
    /// wall stages from cumulative-CPU stages so the % column has a
    /// meaningful denominator for each. The cumulative-CPU section
    /// is the one that decides which stage is worth GPU-offloading:
    /// the bigger the CPU number, the more work the spare GPU could
    /// absorb if it took over that stage (e.g. wiring `MetalCRC32`
    /// into `compute.crc`, building Phase 1a GPU LZ77 to absorb
    /// `compute.compress`).
    static func renderPack(_ snap: StageAnalytics.Snapshot,
                           packElapsed: TimeInterval,
                           bytesIn: UInt64,
                           bytesOut: UInt64,
                           entries: Int) -> String {
        var out = ""
        out += "\n=== analyze: pack ===\n"
        out += "  total wall:                \(formatSeconds(packElapsed))\n"
        out += "  encoder wall:              \(formatSeconds(snap.totalWall))\n"
        out += "  entries:                   \(entries)\n"
        out += "  bytes in:                  \(formatBytesDecimal(bytesIn))" +
               " (\(formatThroughput(bytes: bytesIn, seconds: packElapsed)))\n"
        let ratio = bytesIn > 0 ? Double(bytesOut) / Double(bytesIn) * 100 : 0
        out += "  bytes out:                 \(formatBytesDecimal(bytesOut))" +
               " (ratio " + String(format: "%5.1f", ratio) + " %)\n"
        out += "  batches:                   \(snap.batchCount)\n"
        if snap.batchCount > 0 {
            let avgBytes = Double(snap.totalBatchBytes) / Double(snap.batchCount)
            out += "  avg batch size:            " +
                   String(format: "%8.2f", avgBytes / (1024 * 1024)) + " MiB\n"
        }

        // Stable partition: wall stages first (sum toward encoder wall),
        // CPU stages second (sum across workers, exceed wall by design).
        let wallStageNames: Set<String> = ["parallel.compress", "archive.write"]
        let wallStages = snap.stages.filter { wallStageNames.contains($0.name) }
        let cpuStages  = snap.stages.filter { !wallStageNames.contains($0.name) }

        out += "\n  per-stage wall (encoder, sums to ~encoder wall):\n"
        let wallDenom = max(snap.totalWall, 0.000_001)
        var accountedFor: TimeInterval = 0
        for stage in wallStages {
            accountedFor += stage.seconds
            out += renderStageRow(name: stage.name,
                                  seconds: stage.seconds,
                                  denom: wallDenom,
                                  batchCount: snap.batchCount)
        }
        let unaccounted = max(0, snap.totalWall - accountedFor)
        out += renderStageRow(name: "(unaccounted)",
                              seconds: unaccounted,
                              denom: wallDenom,
                              batchCount: 0)

        if !cpuStages.isEmpty {
            // % within this section is each CPU stage's share of the
            // total per-block CPU work measured (sum of compute.* values),
            // so the percentages add up to 100 % and you can read off
            // "GPU offload of this row would absorb XX % of the
            // measured per-block CPU work".
            let cpuTotal = cpuStages.reduce(0) { $0 + $1.seconds }
            out += "\n  cumulative CPU time across workers (per-block compute):\n"
            out += "    (sum: " + String(format: "%.3f", cpuTotal) +
                   " s — exceeds wall by design; this is what GPU offload could absorb)\n"
            let cpuDenom = max(cpuTotal, 0.000_001)
            for stage in cpuStages {
                out += renderStageRow(name: stage.name,
                                      seconds: stage.seconds,
                                      denom: cpuDenom,
                                      batchCount: snap.batchCount)
            }
        }

        out += "\n"
        return out
    }

    // MARK: - Shared helpers

    private static func renderStageRow(name: String,
                                       seconds: TimeInterval,
                                       denom: TimeInterval,
                                       batchCount: Int) -> String {
        // String column rendered via Swift padding rather than `%-20s`
        // — see the safety note on this file. `%5.1f` and `%8.3f`
        // remain safe because they consume Double, not a pointer.
        let pad = name.padding(toLength: 20, withPad: " ", startingAt: 0)
        let pct = denom > 0 ? seconds / denom * 100 : 0
        let perBatch: String
        if batchCount > 0 {
            let ms = seconds * 1000.0 / Double(batchCount)
            perBatch = " (" + String(format: "%.2f", ms) + " ms/batch)"
        } else {
            perBatch = ""
        }
        return "    " + pad +
            "  " + String(format: "%8.3f", seconds) + " s" +
            "  " + String(format: "%5.1f", pct) + " %" +
            perBatch + "\n"
    }

    private static func formatSeconds(_ s: TimeInterval) -> String {
        return String(format: "%8.3f", s) + " s"
    }

    private static func formatBytesDecimal(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1_000_000_000 {
            return String(format: "%.2f", v / 1_000_000_000) + " GB"
        }
        if v >= 1_000_000 {
            return String(format: "%.2f", v / 1_000_000) + " MB"
        }
        if v >= 1_000 {
            return String(format: "%.2f", v / 1_000) + " KB"
        }
        return String(format: "%.0f", v) + " B"
    }

    private static func formatThroughput(bytes: UInt64, seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "?" }
        let mbps = Double(bytes) / 1_000_000 / seconds
        if mbps >= 1000 {
            return String(format: "%.2f", mbps / 1000) + " GB/s"
        }
        return String(format: "%.0f", mbps) + " MB/s"
    }
}
