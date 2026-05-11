import Foundation
import Darwin

/// Resolved metadata for one entry in the input tree. The same struct is
/// used by both ZIP and `.knit` writers; `relativePath` is shaped to be
/// directly usable as an archive entry name (forward slashes, no leading
/// slash, directories end with "/").
public struct FileEntry: Sendable {
    public let absoluteURL: URL
    /// Forward-slash separated, written as-is into the archive's entry name.
    public let relativePath: String
    public let size: UInt64
    public let isDirectory: Bool
    public let modificationDate: Date
    public let unixMode: UInt16
}

/// Walks an input directory tree and produces a deterministic list of
/// `FileEntry` values for the compressors to consume. The traversal is:
///
///   - **Hidden-file-including by default** (since v3): matches the
///     standard tar / zip / `ditto` / `7z` policy of "archive what's
///     there, faithfully". Older builds of `knit` defaulted to
///     `.skipsHiddenFiles`, which silently dropped `.git/`, `.DS_Store`,
///     `.vscode/`, etc. — surprising for any user expecting tar-style
///     behaviour. Pass `excludeHidden: true` to opt back into the
///     stricter policy (for distribution-style archives where hidden
///     metadata shouldn't leak).
///   - **Symlink-skipping**: symbolic links inside the tree are *always*
///     ignored. Following them risks (a) reading attacker-placed files
///     outside the input root and (b) producing entry names that escape
///     the input prefix when the link target lives elsewhere. The
///     `.knit` v1 format also has no symlink record type, so faithful
///     round-tripping isn't possible even if we wanted it. Symlink
///     handling can be revisited with a `.knit` v2 format change.
///   - **Single-file friendly**: passing a regular file returns one entry.
///
/// When a `WalkSkipCollector` is supplied (driven by `pack --analyze` /
/// `zip --analyze`), every item the walker chooses not to include is
/// recorded with its reason (hidden / symlink), bytes, and item count
/// — so the user can see exactly *what* was left out without diffing
/// `du` against the produced archive.
public enum FileWalker {

    /// Enumerate files under `root`. If `root` is a single file, returns
    /// a one-element list rather than complaining about it not being a
    /// directory.
    ///
    /// - Parameters:
    ///   - rawRoot: the input directory or file to walk.
    ///   - excludeHidden: when true, items with `kCFURLIsHiddenKey` set
    ///     (POSIX dot-prefix or `chflags hidden`) are filtered out and
    ///     hidden directories are not descended into. Defaults to
    ///     `false` — the tar-compatible policy. Pass `true` for
    ///     distribution-style archives.
    ///   - skipCollector: when non-nil, the walker records every item
    ///     it chose to skip (hidden, when `excludeHidden` is true, and
    ///     always-skipped symlinks regardless of flags) into the
    ///     collector. The CLI's `--analyze` flag wires one of these
    ///     up so the user sees the skip ledger in the analyse block.
    public static func enumerate(
        _ rawRoot: URL,
        excludeHidden: Bool = false,
        skipCollector: WalkSkipCollector? = nil
    ) throws -> [FileEntry] {
        let fm = FileManager.default
        // Resolve symlinks on the *root* once so the prefix we strip
        // below matches the URLs the enumerator hands back. We use
        // realpath(3) instead of `URL.resolvingSymlinksInPath()`
        // because the two disagree on macOS 26 Tahoe's volume
        // layout: `resolvingSymlinksInPath` started returning
        // `/tmp/...` unchanged on this version, but
        // `FileManager.enumerator` still yields its children via
        // `/private/tmp/...` (the firmlinked form). When `baseLen`
        // is computed from the *unresolved* root and the enumerator
        // hands back the *resolved* form, the string-prefix strip in
        // the loop below produces nonsense relative paths — e.g.
        // packing `/tmp/foo/src` had entries appearing as
        // `src/foo/src/file_0.bin` instead of `src/file_0.bin`. The
        // C `realpath` function always follows symlinks via the
        // kernel, so its output is the canonical form FileManager
        // also uses internally.
        let root = realpathURL(rawRoot)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else {
            throw KnitError.ioFailure(path: root.path, message: "not found")
        }
        if !isDir.boolValue {
            return [try makeEntry(absolute: root, relative: root.lastPathComponent)]
        }

        var results: [FileEntry] = []
        let baseLen = root.path.count
        let rootName = root.lastPathComponent

        // We no longer pass `.skipsHiddenFiles` at the enumerator level —
        // we filter manually so the skip collector can record what got
        // dropped (and so the new "include hidden by default" semantics
        // are honoured).
        let neededKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
        ]
        guard let it = fm.enumerator(at: root,
                                     includingPropertiesForKeys: neededKeys,
                                     options: []) else {
            throw KnitError.ioFailure(path: root.path, message: "cannot enumerate")
        }
        // Always include the root directory itself as an explicit entry —
        // ZIP readers expect to see it for proper directory reconstruction.
        results.append(try makeEntry(absolute: root,
                                     relative: rootName + "/",
                                     isDirectoryOverride: true))

        while let next = it.nextObject() {
            guard let rawURL = next as? URL else { continue }
            let rv = try? rawURL.resourceValues(forKeys: Set(neededKeys))

            // Compute relative path once for both the include and skip
            // paths.
            guard rawURL.path.count > baseLen + 1 else { continue }
            let suffix = String(rawURL.path.dropFirst(baseLen + 1))
            let rel = rootName + "/" + suffix

            // Symlinks: always skipped (security + format limitation).
            if rv?.isSymbolicLink == true {
                if let collector = skipCollector {
                    let bytes = (rv?.fileSize).map(UInt64.init) ?? 0
                    collector.record(.init(
                        relativePath: rel,
                        reason: .symlink,
                        bytes: bytes,
                        itemCount: 1
                    ))
                }
                continue
            }

            // Hidden filter: only when caller asks. We still record the
            // skip (and recursively size hidden directories) so the
            // analyse output can show *what* was hidden.
            if excludeHidden && rv?.isHidden == true {
                if let collector = skipCollector {
                    if rv?.isDirectory == true {
                        let stats = recursiveStat(of: rawURL)
                        collector.record(.init(
                            relativePath: rel + "/",
                            reason: .hidden,
                            bytes: stats.bytes,
                            itemCount: stats.items
                        ))
                    } else {
                        let bytes = (rv?.fileSize).map(UInt64.init) ?? 0
                        collector.record(.init(
                            relativePath: rel,
                            reason: .hidden,
                            bytes: bytes,
                            itemCount: 1
                        ))
                    }
                }
                // Don't descend into hidden directories — both for
                // performance (they could be huge: think `.git/objects`)
                // and to match the old `.skipsHiddenFiles` semantics.
                if rv?.isDirectory == true {
                    it.skipDescendants()
                }
                continue
            }

            let entry = try makeEntry(absolute: rawURL, relative: rel)
            results.append(entry)
        }
        return results
    }

    /// Walk a subtree and return its recursive size + item count. Used
    /// by the skip collector to report "you skipped a 1.5 GB hidden
    /// directory" rather than just "you skipped a directory" without
    /// any sense of scale.
    private static func recursiveStat(of root: URL) -> (bytes: UInt64, items: Int) {
        let fm = FileManager.default
        var bytes: UInt64 = 0
        var items: Int = 0
        guard let it = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                     options: []) else {
            return (0, 0)
        }
        for case let url as URL in it {
            items += 1
            if let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
               rv.isDirectory == false,
               let size = rv.fileSize {
                bytes &+= UInt64(size)
            }
        }
        return (bytes, items)
    }

    private static func makeEntry(
        absolute: URL,
        relative: String,
        isDirectoryOverride: Bool? = nil
    ) throws -> FileEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: absolute.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
        let isDir = isDirectoryOverride
            ?? ((attrs[.type] as? FileAttributeType) == .typeDirectory)

        var rel = relative
        if isDir, !rel.hasSuffix("/") { rel += "/" }

        return FileEntry(
            absoluteURL: absolute,
            relativePath: rel,
            size: size,
            isDirectory: isDir,
            modificationDate: modDate,
            unixMode: mode
        )
    }

    /// Canonicalize `url` via `realpath(3)` — follows every symlink,
    /// returns the kernel's resolved path. Falls back to the input
    /// URL unchanged when the path doesn't exist or realpath fails;
    /// the caller's `fileExists` check below catches the not-found
    /// case with a more specific error.
    ///
    /// Why this instead of `URL.resolvingSymlinksInPath()`: on macOS
    /// 26 Tahoe, `resolvingSymlinksInPath` started leaving the `/tmp`
    /// firmlink unresolved, but `FileManager.enumerator` continues
    /// to resolve it. The mismatch broke the prefix-stripping
    /// arithmetic that derives entry names from full paths.
    private static func realpathURL(_ url: URL) -> URL {
        let p = url.path
        // PATH_MAX on Darwin is 1024. Use a generous fixed buffer
        // so a single allocation covers every realistic input.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved: String? = p.withCString { cstr in
            guard let r = Darwin.realpath(cstr, &buf) else { return nil }
            return String(cString: r)
        }
        guard let resolved else { return url }
        return URL(fileURLWithPath: resolved)
    }
}
