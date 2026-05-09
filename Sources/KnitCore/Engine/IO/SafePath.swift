import Foundation

/// Validates archive entry names before joining them onto a destination
/// directory. Rejects anything that could escape `destDir` (zip-slip),
/// dereference unexpected paths, or break URL parsing.
enum SafePath {

    /// Returns a destination URL that is guaranteed to be inside `destDir`,
    /// or throws `KnitError.formatError` if `name` is not safe.
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

        let candidate = destDir.appendingPathComponent(name).standardizedFileURL
        let base = destDir.standardizedFileURL

        // Final containment check: the resolved candidate must live under base.
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let candidatePath = candidate.path
        if candidatePath != base.path && !candidatePath.hasPrefix(basePath) {
            throw KnitError.formatError("archive entry escapes destination: \(name)")
        }
        return candidate
    }
}
