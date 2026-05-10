import Foundation

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
///   - **Hidden-file-skipping**: dotfiles are excluded by default
///     (matches `ditto`/Archive Utility behaviour).
///   - **Symlink-skipping**: symbolic links inside the tree are ignored
///     entirely. Following them risks (a) reading attacker-placed files
///     outside the input root and (b) producing entry names that escape
///     the input prefix when the link target lives elsewhere.
///   - **Single-file friendly**: passing a regular file returns one entry.
public enum FileWalker {

    /// Enumerate files under `root`. If `root` is a single file, returns
    /// a one-element list rather than complaining about it not being a
    /// directory.
    public static func enumerate(_ rawRoot: URL) throws -> [FileEntry] {
        let fm = FileManager.default
        // Resolve symlinks on the *root* once so the prefix we strip
        // below matches the URLs the enumerator hands back (on macOS
        // /tmp is itself a symlink to /private/tmp). Note: we only
        // resolve at the root; per-entry symlinks are still skipped.
        let root = rawRoot.resolvingSymlinksInPath()
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

        guard let it = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else {
            throw KnitError.ioFailure(path: root.path, message: "cannot enumerate")
        }
        // Always include the root directory itself as an explicit entry —
        // ZIP readers expect to see it for proper directory reconstruction.
        results.append(try makeEntry(absolute: root, relative: rootName + "/", isDirectoryOverride: true))

        for case let rawURL as URL in it {
            // Skip symbolic links: resolving them would (a) potentially read
            // attacker-placed files outside the input tree (e.g. /etc/passwd)
            // and (b) corrupt the relative-path computation below if the link
            // target lives outside `root`.
            let resourceValues = try? rawURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true { continue }

            // Relative path is computed from rawURL (pre-link-resolution) so a
            // hidden symlink inside the tree can't escape the prefix.
            guard rawURL.path.count > baseLen + 1 else { continue }
            let suffix = String(rawURL.path.dropFirst(baseLen + 1))
            let rel = rootName + "/" + suffix
            let entry = try makeEntry(absolute: rawURL, relative: rel)
            results.append(entry)
        }
        return results
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
}
