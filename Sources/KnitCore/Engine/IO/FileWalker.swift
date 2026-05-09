import Foundation

public struct FileEntry: Sendable {
    public let absoluteURL: URL
    public let relativePath: String       // forward-slash, used as ZIP entry name
    public let size: UInt64
    public let isDirectory: Bool
    public let modificationDate: Date
    public let unixMode: UInt16
}

public enum FileWalker {

    /// Enumerate files under `root`. If `root` is a single file, returns one entry.
    public static func enumerate(_ rawRoot: URL) throws -> [FileEntry] {
        let fm = FileManager.default
        // Resolve symlinks once so the prefix we strip below matches the URLs the
        // enumerator hands back (on macOS /tmp is a symlink to /private/tmp).
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
        // Add the root directory itself as a ZIP entry.
        results.append(try makeEntry(absolute: root, relative: rootName + "/", isDirectoryOverride: true))

        for case let rawURL as URL in it {
            let url = rawURL.resolvingSymlinksInPath()
            // url.path begins with root.path + "/" — strip that prefix.
            guard url.path.count > baseLen + 1 else { continue }
            let suffix = String(url.path.dropFirst(baseLen + 1))
            let rel = rootName + "/" + suffix
            let entry = try makeEntry(absolute: url, relative: rel)
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
