import Foundation
import KnitCore

/// CLI-side helpers for the `--progress` flag: a printer thread that
/// renders a live single-line progress bar to stderr, plus utilities for
/// computing the input total-bytes denominator that the bar needs.
///
/// Lives in `KnitCLI` rather than `KnitCore` because progress *rendering*
/// is a CLI concern. `ProgressReporter` (in KnitCore) is the lock-protected
/// counter; the renderer just polls and formats.
enum CLIProgress {

    /// True iff stderr is currently attached to a terminal. Drives the
    /// CLI's default progress-bar policy: when the user runs
    /// `knit unpack big.knit` in a terminal we render the bar
    /// automatically (90 s of silence is bad UX); when stderr is piped
    /// into a log file or another process we stay quiet so the
    /// `\r`-overwriting line doesn't pollute the recipient. `--progress`
    /// and `--no-progress` flags override this.
    static var isInteractiveStderr: Bool {
        return isatty(FileHandle.standardError.fileDescriptor) != 0
    }

    /// Resolve whether a subcommand should display a live progress bar.
    /// Precedence (most specific wins):
    ///   1. `--no-progress`            → off (forced)
    ///   2. `--progress`               → on  (forced, even when piped)
    ///   3. neither                    → on iff stderr is a TTY
    /// Mutually-exclusive flags would be surprising, so when both are
    /// passed `--no-progress` wins and we silently honour it.
    static func shouldShowProgress(progress: Bool, noProgress: Bool) -> Bool {
        if noProgress { return false }
        if progress { return true }
        return isInteractiveStderr
    }

    /// Recursively sum file sizes under `inputURL`. Used as the
    /// denominator for the `pack` and `zip` progress bars. Skips
    /// symlinks, matching `FileWalker`'s policy. Errors during the walk
    /// just halt the count — the printer renders bytes-only when the
    /// total comes back as 0.
    static func totalUncompressedBytes(at inputURL: URL) throws -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            return 0
        }
        if !isDir.boolValue {
            let attrs = try fm.attributesOfItem(atPath: inputURL.path)
            return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        }
        guard let it = fm.enumerator(at: inputURL,
                                     includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let url as URL in it {
            let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if rv?.isSymbolicLink == true { continue }
            if let size = rv?.fileSize { total &+= UInt64(size) }
        }
        return total
    }

    /// Sum of `uncompressedSize` across the entries in a `.knit`
    /// archive's footer. Used as the denominator for the `unpack`
    /// progress bar without needing to re-decompress anything.
    static func totalUncompressedBytesInKnit(at archiveURL: URL) throws -> UInt64 {
        let reader = try KnitReader(url: archiveURL)
        var total: UInt64 = 0
        for entry in reader.archive.entries {
            total &+= entry.uncompressedSize
        }
        return total
    }

    /// Background printer that renders one progress line to stderr at
    /// ~500 ms cadence. Uses `\r` to overwrite the previous line; emits
    /// a final newline on `waitUntilFlushed()` so subsequent stdout
    /// from the CLI doesn't visually merge with the bar.
    ///
    /// `@unchecked Sendable` because all mutable state
    /// (`threadDidExit`) is guarded by `doneCondition`; `thread` and
    /// `reporter`/`interval` are set once during `start()` from the
    /// owning thread and never mutated again.
    final class Printer: @unchecked Sendable {
        private let reporter: ProgressReporter
        private let interval: TimeInterval
        private var thread: Thread?
        private let doneCondition = NSCondition()
        private var threadDidExit = false

        init(reporter: ProgressReporter, interval: TimeInterval = 0.5) {
            self.reporter = reporter
            self.interval = interval
        }

        func start() {
            // Keep a strong self for the thread closure. The owning
            // CLI subcommand always survives long enough (it holds
            // `printer` for the duration of `run()` via `defer`), so
            // the strong capture can't extend lifetime in a meaningful
            // way — but it does eliminate the @Sendable diagnostic
            // around capturing `weak self`.
            let me = self
            let t = Thread {
                let r = me.reporter
                while !r.isFinished {
                    let snap = r.snapshot()
                    Self.write(line: Self.format(snap))
                    Thread.sleep(forTimeInterval: me.interval)
                }
                // One final render so the line shows the actual final
                // numbers (rather than whatever was on screen at the
                // last tick before `finish()` was called), then
                // terminate the line cleanly.
                let snap = r.snapshot()
                Self.write(line: Self.format(snap))
                Self.write(line: "\n")
                me.markExit()
            }
            t.start()
            self.thread = t
        }

        /// Block until the printer thread has emitted its final line.
        /// Defer-callable from `run()` — keeps the progress bar visible
        /// up to the moment the CLI starts printing the result summary.
        func waitUntilFlushed(timeout: TimeInterval = 1.0) {
            doneCondition.lock()
            defer { doneCondition.unlock() }
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !threadDidExit {
                if !doneCondition.wait(until: deadline) { break }
            }
        }

        private func markExit() {
            doneCondition.lock()
            threadDidExit = true
            doneCondition.broadcast()
            doneCondition.unlock()
        }

        // MARK: - Rendering

        private static func write(line: String) {
            FileHandle.standardError.write(Data(line.utf8))
        }

        /// Formats one snapshot as a single-line progress bar.
        ///
        /// Layout (88 cols max so it sits inside an 80-col terminal even
        /// after the leading `\r`):
        ///
        ///     \r  pack  [████████░░░░░░░░░░░░] 38.4%  3.21 GB/s   ETA 0:18
        static func format(_ snap: ProgressReporter.Snapshot) -> String {
            let phase = snap.phase.rawValue.padding(toLength: 6,
                                                    withPad: " ",
                                                    startingAt: 0)
            let mbps = snap.bytesPerSecond / 1_000_000
            let bar = renderBar(fraction: snap.fraction, width: 24)
            let pct = snap.fraction.map { String(format: "%5.1f%%", $0 * 100) } ?? "  ?  "
            let processedHuman = humanBytes(snap.processed)
            let totalHuman = snap.total > 0 ? humanBytes(snap.total) : "?"
            let eta = renderETA(snap.etaSeconds)

            // \r to overwrite, ESC[2K clears the rest of the previous line
            // (handles the case where a shorter render follows a longer one).
            let prefix = "\r\u{1B}[2K  "
            return prefix
                + phase
                + "  " + bar
                + "  " + pct
                + "  " + processedHuman + " / " + totalHuman
                + String(format: "  %6.0f MB/s", mbps)
                + "  ETA " + eta
        }

        private static func renderBar(fraction: Double?, width: Int) -> String {
            guard let f = fraction else {
                // Indeterminate — show an empty frame.
                return "[" + String(repeating: "·", count: width) + "]"
            }
            let filled = Int((f * Double(width)).rounded(.down))
            let clamped = max(0, min(width, filled))
            return "[" + String(repeating: "█", count: clamped)
                       + String(repeating: "░", count: width - clamped) + "]"
        }

        private static func renderETA(_ seconds: Double) -> String {
            if !seconds.isFinite { return "  ?  " }
            let s = Int(seconds.rounded())
            if s < 60   { return String(format: "%2ds", s) }
            if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
            let h = s / 3600
            let m = (s % 3600) / 60
            return String(format: "%d:%02d:%02d", h, m, s % 60)
        }

        private static func humanBytes(_ n: UInt64) -> String {
            // Decimal SI units to match macOS Finder's display.
            let units: [(Double, String)] = [
                (1_000_000_000_000, "TB"),
                (1_000_000_000,     "GB"),
                (1_000_000,         "MB"),
                (1_000,             "KB"),
            ]
            let v = Double(n)
            for (factor, unit) in units where v >= factor {
                return String(format: "%6.2f %@", v / factor, unit)
            }
            return String(format: "%6.0f B ", v)
        }
    }
}
