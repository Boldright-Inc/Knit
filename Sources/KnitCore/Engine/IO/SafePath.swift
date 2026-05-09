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

        return destDir.appendingPathComponent(name)
    }
}
