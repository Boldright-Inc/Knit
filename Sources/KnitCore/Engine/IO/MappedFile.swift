import Foundation

/// Memory-maps a file read-only via `mmap` and exposes it as an
/// `UnsafeBufferPointer<UInt8>`. Pages are demand-loaded by the OS, so
/// large files cost little RSS until they're actually touched. The kernel
/// also handles read-ahead, which is what makes the compressor's
/// "fan out across cores" pattern feel like it has free I/O.
///
/// **Lifetime contract**: the buffer is valid only as long as the
/// `MappedFile` instance is alive. Workers that capture the pointer in a
/// `@Sendable` closure (e.g. via `SendableRawPointer`) must arrange for
/// the `MappedFile` to outlive the work.
///
/// `@unchecked Sendable` is correct here because the mapped region is
/// `PROT_READ` only — there are no data races on read-only memory.
public final class MappedFile: @unchecked Sendable {
    public let pointer: UnsafePointer<UInt8>
    public let count: Int
    private let fd: Int32

    public convenience init(url: URL) throws {
        // Legacy URL-based init. NFD-normalizes the path string via
        // `URL.path` on macOS — fine for ASCII paths (tests, the
        // common CLI case) but breaks for filenames with non-ASCII
        // characters where the on-disk encoding is NFC (e.g. files
        // unpacked via the PR #82 byte-preserving path). New code
        // should prefer `init(path:)` which preserves bytes verbatim.
        try self.init(path: url.path)
    }

    /// Byte-preserving mmap. `path`'s UTF-8 bytes flow straight to
    /// `open(2)` via `withCString` — no Foundation `URL`/`NSString`
    /// round-trip in the middle, so on-disk filenames with NFC bytes
    /// (the typical Unicode form for cross-platform filenames) are
    /// found rather than refused with ENOENT because Foundation
    /// helpfully NFD'd the lookup string. See `POSIXFile.swift`
    /// header for the full analysis. PR #82.
    public init(path: String) throws {
        let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
        if fd < 0 {
            throw KnitError.ioFailure(path: path, message: "open failed: \(String(cString: strerror(errno)))")
        }

        var stat = stat()
        if fstat(fd, &stat) < 0 {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw KnitError.ioFailure(path: path, message: "fstat failed: \(msg)")
        }
        let size = Int(stat.st_size)

        if size == 0 {
            // mmap of length 0 is EINVAL on macOS, so we model an empty
            // file specially. The dummy non-null pointer means downstream
            // `UnsafeBufferPointer(start: pointer, count: 0)` is valid;
            // the count==0 guard in `buffer` keeps callers from
            // dereferencing it.
            self.fd = fd
            self.count = 0
            self.pointer = UnsafePointer<UInt8>(bitPattern: 1)!
            return
        }

        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0) else {
            close(fd)
            throw KnitError.ioFailure(path: path, message: "mmap failed")
        }
        if mapped == MAP_FAILED {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw KnitError.ioFailure(path: path, message: "mmap failed: \(msg)")
        }

        // MADV_SEQUENTIAL tells the VM subsystem to aggressively read
        // ahead and discard already-touched pages — exactly the right
        // hint for a one-pass compressor walking the buffer linearly.
        // Without it the page cache fills up with bytes we'll never
        // re-read, evicting more useful entries.
        _ = madvise(mapped, size, MADV_SEQUENTIAL)

        self.fd = fd
        self.count = size
        self.pointer = UnsafePointer(mapped.assumingMemoryBound(to: UInt8.self))
    }

    deinit {
        if count > 0 {
            munmap(UnsafeMutableRawPointer(mutating: pointer), count)
        }
        close(fd)
    }

    public var buffer: UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: count > 0 ? pointer : nil, count: count)
    }
}
