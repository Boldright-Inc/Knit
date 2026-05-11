import Foundation
import Darwin
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
    /// denominator for the `pack` and `zip` progress bars. Mirrors
    /// `FileWalker`'s policy so the bar's % is honest:
    ///   - by default includes hidden files (tar-compatible, matches
    ///     the default `FileWalker.enumerate`);
    ///   - when `excludeHidden` is true, skips items with
    ///     `kCFURLIsHiddenKey` set;
    ///   - always skips symlinks (the walker does too).
    /// Errors during the walk just halt the count — the printer
    /// renders bytes-only when the total comes back as 0.
    static func totalUncompressedBytes(at inputURL: URL,
                                       excludeHidden: Bool = false) throws -> UInt64 {
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
                                     includingPropertiesForKeys: [
                                        .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey, .isDirectoryKey,
                                     ],
                                     options: []) else {
            return 0
        }
        var total: UInt64 = 0
        while let next = it.nextObject() {
            guard let url = next as? URL else { continue }
            let rv = try? url.resourceValues(forKeys: [
                .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey, .isDirectoryKey,
            ])
            if rv?.isSymbolicLink == true { continue }
            if excludeHidden && rv?.isHidden == true {
                if rv?.isDirectory == true { it.skipDescendants() }
                continue
            }
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
    /// ~200 ms cadence. Uses `\r` to overwrite the previous line; emits
    /// a final newline on `waitUntilFlushed()` so subsequent stdout
    /// from the CLI doesn't visually merge with the bar.
    ///
    /// **Cadence note**: the default was 0.5 s through PR #54, which
    /// matched pigz / dd-style CLIs but missed sub-second operations
    /// entirely (only the 0% and 100% snapshots fired). The user
    /// reported "圧縮中なのかどうかわかりません" on Quick Action zips
    /// — fast operations completing in 0.3–1.0 s are exactly where
    /// base-Apple-Silicon (M1 / M2 base) users land for typical
    /// inputs. 0.2 s yields 1.5–5 intermediate ticks for those
    /// operations, which reads as "the bar is moving" instead of
    /// dead air. The terminal escape-sequence churn from 5 renders/s
    /// is invisible in practice. PR #55 set this; CLAUDE.md Rule 4.4
    /// explains the broader hardware-target reasoning.
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

        init(reporter: ProgressReporter, interval: TimeInterval = 0.2) {
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
        /// The output is sized to fit the terminal's actual column
        /// width so that `\r\033[2K` overwrite works correctly. If
        /// the output line is wider than the terminal, the terminal
        /// wraps it into two visible lines — and `\033[2K` only
        /// clears the *current* line, so the wrapped second row stays
        /// on screen and the next render appears below it. After
        /// ~10 renders the bar visually "accumulates" instead of
        /// updating in place (PR #48 user-reported regression). We
        /// avoid this by:
        ///
        ///   1. Querying terminal width via `ioctl(TIOCGWINSZ)`
        ///      (`terminalCols()`), falling back to 80 if stderr
        ///      isn't a TTY.
        ///   2. Shrinking the bar between 8 and 24 cells based on
        ///      remaining budget after the fixed columns.
        ///   3. Dropping optional columns (bytes, MB/s, ETA) when
        ///      the terminal is genuinely narrow.
        ///   4. As a last-resort safety net, truncating the visible
        ///      string to `cols - 1` so even a malformed budget never
        ///      wraps.
        ///
        /// Layout (full, when terminal is wide enough):
        ///
        ///     \r\033[2K  pack  [████████░░░░░░░░░░░░] 38.4%  3.21 GB / 8.4 GB  3210 MB/s  ETA 0:18
        ///
        /// Layout (narrow terminal, falls back to bar + pct only):
        ///
        ///     \r\033[2K  pack  [█████░░] 38.4%
        static func format(_ snap: ProgressReporter.Snapshot) -> String {
            let cols = max(40, terminalCols())
            let phase = snap.phase.rawValue.padding(toLength: 6,
                                                    withPad: " ",
                                                    startingAt: 0)
            let pct = snap.fraction.map { String(format: "%5.1f%%", $0 * 100) } ?? "  ?  "
            let processedHuman = humanBytes(snap.processed)
            let totalHuman = snap.total > 0 ? humanBytes(snap.total) : "?"
            let mbps = snap.bytesPerSecond / 1_000_000
            let mbpsStr = String(format: "%6.0f MB/s", mbps)
            let etaStr = renderETA(snap.etaSeconds)

            // Fixed prefix in visible chars: "  " + phase(6) + "  "
            // + bar (8…24 + brackets) + "  " + pct(6) = at least
            // 10 + 2 + 8 + 2 + 6 = 28 visible. Anything below that
            // and the rendered line stops being legible at a glance.
            let budget = cols - 1  // 1-char safety margin so wrap can't happen

            // Optional columns, in drop-order priority (last to drop first):
            //   * bytes column   ~ "  123.45 GB / 123.45 GB" = ~24 chars
            //   * MB/s column    ~ "  1234 MB/s"             = ~12 chars
            //   * ETA column     ~ "  ETA 12:34"             = ~11 chars
            let bytesCol = "  " + processedHuman + " / " + totalHuman
            let mbpsCol = "  " + mbpsStr
            let etaCol = "  ETA " + etaStr

            var showBytes = true
            var showMBPS = true
            var showETA = true
            var barWidth = 24

            func currentVisible() -> Int {
                // 2 spaces + phase(6) + 2 spaces + "[" + bar + "]" + 2 spaces + pct(6)
                //   + optional cols, where each is already prefixed with 2 spaces.
                var n = 2 + 6 + 2 + 1 + barWidth + 1 + 2 + 6
                if showBytes { n += bytesCol.count }
                if showMBPS  { n += mbpsCol.count }
                if showETA   { n += etaCol.count }
                return n
            }

            // Greedy: drop the lowest-priority column first, then shrink the bar.
            if currentVisible() > budget { showETA   = false }
            if currentVisible() > budget { showMBPS  = false }
            if currentVisible() > budget { showBytes = false }
            while currentVisible() > budget && barWidth > 8 {
                barWidth -= 2
            }

            let bar = renderBar(fraction: snap.fraction, width: barWidth)
            var visible = "  " + phase + "  " + bar + "  " + pct
            if showBytes { visible += bytesCol }
            if showMBPS  { visible += mbpsCol }
            if showETA   { visible += etaCol }

            // Last-resort truncation: if the budget math missed
            // anything (e.g. a multi-codepoint glyph in `humanBytes`
            // ever showing up), hard-cap at `budget`.
            if visible.count > budget {
                visible = String(visible.prefix(budget))
            }

            // \r to overwrite, ESC[2K clears the rest of the previous
            // line (handles the case where a shorter render follows a
            // longer one). ESC[2K only clears the *current* line — the
            // budget logic above is what guarantees the line doesn't
            // wrap onto a second visible row.
            return "\r\u{1B}[2K" + visible
        }

        /// Best-effort terminal width via `ioctl(TIOCGWINSZ)` on stderr.
        /// Returns 80 if stderr is not a tty (`ioctl` returns non-zero)
        /// or the kernel reports 0 columns (rare; happens on some
        /// pseudo-tty setups). 80 is the standard "looks fine in
        /// nearly every terminal" default.
        private static func terminalCols() -> Int {
            var ws = winsize()
            let fd = FileHandle.standardError.fileDescriptor
            if ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
                return Int(ws.ws_col)
            }
            return 80
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
