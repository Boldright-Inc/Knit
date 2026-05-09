import Foundation

/// Memory-maps a file read-only via `mmap` and exposes it as an
/// `UnsafeBufferPointer<UInt8>`. Pages are demand-loaded by the OS, so
/// large files cost little RSS until touched.
final class MappedFile: @unchecked Sendable {
    let pointer: UnsafePointer<UInt8>
    let count: Int
    private let fd: Int32

    init(url: URL) throws {
        let path = url.path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
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
            // mmap of zero-length is invalid on macOS; return an empty view.
            self.fd = fd
            self.count = 0
            self.pointer = UnsafePointer<UInt8>(bitPattern: 1)!  // dummy non-null
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

        // Hint sequential access for large reads (avoids polluting page cache).
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

    var buffer: UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: count > 0 ? pointer : nil, count: count)
    }
}
