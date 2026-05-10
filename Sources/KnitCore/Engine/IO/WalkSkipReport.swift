import Foundation

/// Aggregated report of items the file walker chose not to include in
/// the archive. Driven by the CLI's hidden `--analyze` flag — the
/// renderer dumps this so users can see exactly *what* was left out
/// (with sizes), instead of having to diff `du` against the produced
/// archive themselves.
///
/// Without this surface, a user packing their `~/Projects/foo/` would
/// see Finder report 9 GB but `knit pack` write a 7 GB archive and
/// have no idea why. Now `pack --analyze` answers that directly.
public struct WalkSkipReport: Sendable {

    public struct Entry: Sendable {
        /// Root-relative path of the skipped item. Directories include
        /// a trailing slash; symlinks are reported by their own path
        /// regardless of where they pointed.
        public let relativePath: String
        public let reason: Reason
        /// Recursive byte count for skipped directories; the file size
        /// for skipped files. Symlinks report 0 (the symlink record
        /// itself is tiny and the target wasn't followed).
        public let bytes: UInt64
        /// Recursive item count for skipped directories (1 for files,
        /// 0 for symlinks since the link itself is the only "item").
        public let itemCount: Int

        public init(relativePath: String,
                    reason: Reason,
                    bytes: UInt64,
                    itemCount: Int) {
            self.relativePath = relativePath
            self.reason = reason
            self.bytes = bytes
            self.itemCount = itemCount
        }
    }

    public enum Reason: String, Sendable {
        /// Item is hidden (POSIX dot-prefix or `kCFURLIsHiddenKey` set)
        /// and the caller asked the walker to filter hidden items.
        case hidden
        /// Item is a symbolic link. Always skipped regardless of caller
        /// flags — symlink target resolution would (a) potentially read
        /// attacker-placed files outside the input tree (zip-slip via
        /// symlink redirection) and (b) corrupt relative-path
        /// computation when the link target lives outside `root`.
        /// `.knit` v1 has no symlink record type either, so even if we
        /// wanted to include them we couldn't faithfully round-trip.
        case symlink
    }

    public let entries: [Entry]

    public func entries(reason: Reason) -> [Entry] {
        entries.filter { $0.reason == reason }
    }

    public func totalBytes(reason: Reason) -> UInt64 {
        entries(reason: reason).reduce(0) { $0 + $1.bytes }
    }

    public func totalItemCount(reason: Reason) -> Int {
        entries(reason: reason).reduce(0) { $0 + $1.itemCount }
    }
}

/// Lock-protected accumulator for `FileWalker` to populate as it walks.
/// Construct one when running `pack --analyze` (or
/// `zip --analyze`, when that lands), pass it into `FileWalker.enumerate`,
/// then snapshot it after the compress finishes for the renderer to
/// consume.
public final class WalkSkipCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [WalkSkipReport.Entry] = []

    public init() {}

    public func record(_ entry: WalkSkipReport.Entry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    public func snapshot() -> WalkSkipReport {
        lock.lock()
        defer { lock.unlock() }
        return WalkSkipReport(entries: entries)
    }
}
