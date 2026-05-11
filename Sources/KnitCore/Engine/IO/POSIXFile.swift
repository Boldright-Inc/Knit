// POSIXFile — byte-preserving filesystem helpers that bypass
// Foundation's NFD canonical-decomposition normalization of path
// components.
//
// Why
// ---
// macOS Foundation's `URL` and `FileManager.{createFile,createDirectory}`
// APIs apply NFD (canonical decomposed) normalization to path strings
// before invoking the underlying `open(2)` / `mkdir(2)` syscalls. This
// is a legacy carry-over from HFS+, which stored names in NFD on disk
// and required application-level conversion at file-creation time.
// APFS volumes preserve whatever bytes the syscall receives — they
// don't normalize on the FS side — so Foundation's transparent
// NFD'ing is now a source of round-trip drift rather than a
// compatibility win.
//
// Empirically (M5 Max, macOS 26.4.1):
//   * `URL(fileURLWithPath: "<NFC path>").path` → returns NFD bytes
//   * `dir.appendingPathComponent("<NFC name>").path` → returns NFD bytes
//   * `FileManager.createFile(atPath: nfcPath)` → on-disk NFD bytes
//   * `FileManager.createDirectory(at: url, ...)` → on-disk NFD bytes
//
// In contrast:
//   * Raw `open(2)` / `mkdir(2)` with NFC-bytes `withCString` → NFC preserved
//   * `FileManager.enumerator`'s yielded URLs for existing NFC files →
//     `.path` returns NFC (because the path comes from the kernel
//     `readdir` bytes, not from a `String → URL → String` round-trip)
//
// The asymmetry was hidden in Knit's pack/unpack pipeline because pack
// reads names from `FileManager.enumerator` (preserves on-disk NFC)
// and writes them verbatim into the `.knit` archive as UTF-8. Unpack
// reads those NFC bytes back from the archive, builds a destination
// `URL` from them (NFD'd), and writes via `FileManager.createFile`
// (NFD again). The round-trip drift surfaced on test2/'s 87k-entry
// tree where Japanese filenames like `スタンプ.txt` (NFC, U+30D7)
// roundtripped as `スタンプ.txt` (NFD, U+30D5 + U+309A) — visually
// identical, byte-different. `diff -r original/ restored/` flagged
// every such file as "Only in" on both sides.
//
// Fix
// ---
// Replace the Foundation calls in the unpack write path with raw
// POSIX syscalls and byte-preserving String concatenation. The
// archive's UTF-8 bytes for the entry name flow through Swift's
// UTF-8-internal `String` and out via `withCString` to the kernel
// without ever round-tripping through `URL`. Net effect: the
// on-disk filename bytes after unpack match the on-disk filename
// bytes before pack, exactly.
//
// PR #82.

import Foundation
import Darwin

enum POSIXFile {

    /// Recursive `mkdir -p`. Creates every missing intermediate
    /// directory along `path`. Each segment's UTF-8 bytes flow
    /// directly to `mkdir(2)` via `withCString` — no Foundation
    /// path-component bridging in the middle, so NFC byte form
    /// is preserved on the on-disk inode. Returns `true` on
    /// success or if the path already exists as a directory.
    @discardableResult
    static func mkdirParents(_ path: String) -> Bool {
        // Build a stack of nonexistent ancestors so we can mkdir
        // them in root-to-leaf order. Walking with String byte
        // slicing (lastIndex(of: "/") + slice) avoids any
        // NSString-based path-component API — every one of those
        // would re-normalize on macOS.
        var pending: [String] = []
        var cursor = path
        while cursor.count > 0 && cursor != "/" {
            // Use `lstat` (which doesn't share its name with the
            // `stat` struct in Swift's Darwin module — calling
            // `Darwin.stat(...)` confuses the type inferencer
            // between the function and the struct initializer).
            // Semantics are identical for our purpose: we just want
            // to know whether something exists at this path, and
            // whether it's already a directory.
            var st = stat()
            let r: Int32 = cursor.withCString { lstat($0, &st) }
            if r == 0 {
                // Found an existing ancestor — break out of the
                // discovery loop and fall through to the mkdir
                // pass. If it isn't a directory, fail up front;
                // pack would have intended a directory at this
                // position.
                let kind = UInt32(st.st_mode) & UInt32(S_IFMT)
                if kind != UInt32(S_IFDIR) { return false }
                break
            }
            pending.append(cursor)
            guard let slash = cursor.lastIndex(of: "/") else { break }
            if slash == cursor.startIndex {
                // Reached "/foo" → parent is "/". Don't try to
                // mkdir the root.
                break
            }
            cursor = String(cursor[..<slash])
        }
        for p in pending.reversed() {
            let r = p.withCString { mkdir($0, 0o755) }
            if r != 0 && errno != EEXIST {
                return false
            }
        }
        return true
    }

    /// Open `path` for writing, creating + truncating if needed.
    /// Returns a `FileHandle` that takes ownership of the fd
    /// (`closeOnDealloc: true`). Byte-preserving — `path`'s UTF-8
    /// bytes go straight to `open(2)`.
    static func openForWriting(_ path: String,
                                mode: mode_t = 0o644) throws -> FileHandle {
        let fd = path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC, mode) }
        if fd < 0 {
            let saved = errno
            let msg = String(cString: strerror(saved))
            throw KnitError.ioFailure(path: path, message: "open failed: \(msg)")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Apply a modification timestamp to a file via `futimes(2)`.
    /// `seconds` is whole-seconds-since-1970 (the precision the
    /// `.knit` format stores). Both atime and mtime are set to the
    /// same value — by convention most archivers don't distinguish
    /// the two when restoring.
    static func setMTime(fd: Int32, secondsSince1970: Int64) {
        let secs = time_t(secondsSince1970)
        var tv = [
            timeval(tv_sec: secs, tv_usec: 0),
            timeval(tv_sec: secs, tv_usec: 0),
        ]
        _ = futimes(fd, &tv)
    }

    /// Apply a modification timestamp to a path via `utimes(2)`.
    /// Used for directories where no fd is held. Same semantics as
    /// `setMTime(fd:secondsSince1970:)`.
    static func setMTime(path: String, secondsSince1970: Int64) {
        let secs = time_t(secondsSince1970)
        var tv = [
            timeval(tv_sec: secs, tv_usec: 0),
            timeval(tv_sec: secs, tv_usec: 0),
        ]
        _ = path.withCString { utimes($0, &tv) }
    }

    /// Concatenate a directory path with an archive entry name in
    /// a byte-preserving way. Equivalent to `dir + "/" + name` —
    /// pulled out into a helper purely so the call sites read
    /// declaratively ("compose a destination path") rather than
    /// inline-stringly. Trims a trailing slash on `dir` if present
    /// so `dir == "/tmp/foo/"` and `dir == "/tmp/foo"` produce
    /// identical results.
    static func joinPath(_ dir: String, _ name: String) -> String {
        if dir.hasSuffix("/") {
            return dir + name
        } else {
            return dir + "/" + name
        }
    }
}
