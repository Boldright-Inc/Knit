import Foundation

/// Validates archive entry names before joining them onto a destination
/// directory. Rejects anything that could escape `destDir` (zip-slip),
/// dereference unexpected paths, or break URL parsing.
enum SafePath {

    /// Returns a destination URL that is guaranteed to be inside `destDir`,
    /// or throws `KnitError.formatError` if `name` is not safe.
    ///
    /// Validation is purely lexical: a name with no absolute prefix, no NUL,
    /// no empty leading segment, and no `..` component cannot escape `destDir`
    /// when joined via `appendingPathComponent`. We deliberately avoid
    /// `standardizedFileURL` here because its symlink-resolution behavior on
    /// not-yet-existing destination paths is inconsistent across macOS
    /// versions and would reject legitimate entries.
    static func resolve(name: String, into destDir: URL) throws -> URL {
        try validate(name: name)
        return destDir.appendingPathComponent(name)
    }

    /// Byte-preserving String variant of `resolve`. Returns a path
    /// `String` instead of a `URL`. Use this when the caller needs
    /// to pass the result to a POSIX syscall (`open(2)` /
    /// `mkdir(2)`) and must preserve the entry name's exact UTF-8
    /// bytes — going through `URL.appendingPathComponent` /
    /// `URL.path` applies NFD canonical decomposition on macOS,
    /// which silently changes non-ASCII filenames (e.g. Japanese
    /// `プ` U+30D7 → `フ゜` U+30D5 + U+309A) and breaks round-trip
    /// equality with the source disk. See `POSIXFile.swift`'s
    /// header for the full analysis. PR #82.
    ///
    /// Validation is identical to `resolve` — the same lexical
    /// rules guarantee the result cannot escape `destDirPath`.
    static func resolvePath(name: String, into destDirPath: String) throws -> String {
        try validate(name: name)
        return POSIXFile.joinPath(destDirPath, name)
    }

    /// Shared lexical validation for `resolve` and `resolvePath`.
    private static func validate(name: String) throws {
        if name.isEmpty {
            throw KnitError.formatError("archive entry has empty name")
        }
        if name.contains("\0") {
            throw KnitError.formatError("archive entry name contains NUL")
        }
        if name.hasPrefix("/") {
            throw KnitError.formatError("archive entry name is absolute: \(name)")
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts {
            if part == ".." {
                throw KnitError.formatError("archive entry name contains '..': \(name)")
            }
        }
    }
}
