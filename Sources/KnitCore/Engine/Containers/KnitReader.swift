import Foundation
import CZstd

public struct KnitArchive {
    public let entries: [KnitEntry]
}

public struct KnitEntry: Sendable {
    public let name: String
    public let modificationDate: Date
    public let unixMode: UInt16
    public let isDirectory: Bool
    public let blockSize: UInt32
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let crc32: UInt32
    public let blockLengths: [UInt32]
    public let dataOffset: UInt64       // absolute offset of first compressed byte
}

/// Reader for .knit files. Parses headers via mmap, decompresses entries lazily.
public final class KnitReader {
    private let mapped: MappedFile
    public let archive: KnitArchive

    public init(url: URL) throws {
        self.mapped = try MappedFile(url: url)
        let buf = mapped.buffer

        var cursor = ReadCursor(buffer: buf)

        // Header
        let magic = try cursor.readUInt32()
        guard magic == KnitFormat.headerMagic else {
            throw KnitError.formatError(".knit: bad magic 0x\(String(magic, radix: 16))")
        }
        let version = try cursor.readUInt16()
        guard version == KnitFormat.version else {
            throw KnitError.unsupported(".knit version \(version) (this build supports \(KnitFormat.version))")
        }
        _ = try cursor.readUInt16()      // flags
        _ = try cursor.readUInt64()      // reserved

        var entries: [KnitEntry] = []
        while true {
            let marker = try cursor.peekUInt32()
            if marker == KnitFormat.footerMarker { break }
            guard marker == KnitFormat.entryMarker else {
                throw KnitError.formatError(".knit: unexpected marker 0x\(String(marker, radix: 16)) at \(cursor.offset)")
            }
            _ = try cursor.readUInt32()  // consume entry marker

            let nameLen = try cursor.readUInt16()
            let name = try cursor.readUTF8(length: Int(nameLen))
            let mode = try cursor.readUInt16()
            let modUnix = try cursor.readUInt64()
            let isDir = try cursor.readUInt8() != 0
            let blockSize = try cursor.readUInt32()
            guard blockSize == 0 || (blockSize > 0 && blockSize <= KnitFormat.maxBlockSize) else {
                throw KnitError.formatError(
                    ".knit: block_size out of range (\(blockSize), max \(KnitFormat.maxBlockSize))"
                )
            }
            let uncompressed = try cursor.readUInt64()
            let compressed = try cursor.readUInt64()
            let crc = try cursor.readUInt32()
            let numBlocks = try cursor.readUInt32()
            // numBlocks is bounded both by the per-archive block_lengths array
            // (4 bytes each) and the cursor's `ensure` check below; cap it here
            // so we don't reserve gigabytes for a hostile UInt32.
            guard numBlocks <= UInt32(KnitFormat.maxBlocksPerEntry) else {
                throw KnitError.formatError(".knit: num_blocks too large (\(numBlocks))")
            }
            var blockLens: [UInt32] = []
            blockLens.reserveCapacity(Int(numBlocks))
            for _ in 0..<numBlocks {
                blockLens.append(try cursor.readUInt32())
            }
            let dataOff = UInt64(cursor.offset)
            // `compressed` is wire-supplied UInt64. Reject anything that can't
            // fit in Int to avoid `Int(_:)` trapping on hostile input.
            guard compressed <= UInt64(Int.max) else {
                throw KnitError.formatError(".knit: compressed size out of range")
            }
            try cursor.skip(Int(compressed))

            entries.append(KnitEntry(
                name: name,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(modUnix)),
                unixMode: mode,
                isDirectory: isDir,
                blockSize: blockSize,
                uncompressedSize: uncompressed,
                compressedSize: compressed,
                crc32: crc,
                blockLengths: blockLens,
                dataOffset: dataOff
            ))
        }

        // Footer
        _ = try cursor.readUInt32()  // footer marker
        _ = try cursor.readUInt64()  // total entries
        let archiveVer = try cursor.readUInt32()
        guard archiveVer == KnitFormat.archiveVersion else {
            throw KnitError.unsupported(".knit archive version \(archiveVer)")
        }

        self.archive = KnitArchive(entries: entries)
    }

    /// Decompress an entry into an output URL on disk.
    public func extract(_ entry: KnitEntry, to outURL: URL) throws {
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: outURL,
                                                    withIntermediateDirectories: true)
            return
        }

        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer { try? outHandle.close() }

        var srcOffset = Int(entry.dataOffset)
        var totalDecompressed: UInt64 = 0

        let blockCap = max(Int(entry.blockSize), 1)
        for blockLen in entry.blockLengths {
            let inLen = Int(blockLen)
            let inPtr = mapped.pointer.advanced(by: srcOffset)

            // zstd frames are self-describing; we decode each frame fully.
            let frameSize = ZSTD_getFrameContentSize(inPtr, inLen)
            if frameSize == ZSTD_CONTENTSIZE_ERROR {
                throw KnitError.codecFailure("zstd: frame content size error")
            }
            // Allocate output buffer. Cap to block_size so a hostile frame
            // header can't trigger a multi-GB allocation (DoS).
            let outCapacity: Int
            if frameSize == ZSTD_CONTENTSIZE_UNKNOWN {
                outCapacity = blockCap
            } else {
                let declared = Int(clamping: frameSize)
                guard declared <= blockCap else {
                    throw KnitError.formatError(
                        ".knit: block frame too large (\(declared) > \(blockCap))"
                    )
                }
                outCapacity = declared
            }
            var outBuf = Data(count: outCapacity)
            let produced: Int = outBuf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let p = raw.baseAddress else { return 0 }
                return ZSTD_decompress(p, outCapacity, inPtr, inLen)
            }
            if ZSTD_isError(produced) != 0 {
                let cstr = ZSTD_getErrorName(produced)
                let msg = cstr.map { String(cString: $0) } ?? "unknown"
                throw KnitError.codecFailure("zstd decode: \(msg)")
            }
            outBuf.removeSubrange(produced..<outBuf.count)

            // Defense in depth: if a malformed entry claims a small
            // `uncompressedSize` but the frames decompress to more, abort
            // before we keep writing to disk.
            totalDecompressed += UInt64(produced)
            if totalDecompressed > entry.uncompressedSize {
                throw KnitError.integrity(
                    "size overrun in \(entry.name): exceeded declared \(entry.uncompressedSize) bytes"
                )
            }

            try outHandle.write(contentsOf: outBuf)
            srcOffset += inLen
        }

        if totalDecompressed != entry.uncompressedSize {
            throw KnitError.integrity(
                "size mismatch for \(entry.name): expected \(entry.uncompressedSize), got \(totalDecompressed)"
            )
        }
    }
}

// MARK: - Cursor

private struct ReadCursor {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int = 0

    mutating func peekUInt32() throws -> UInt32 {
        try ensure(4)
        return loadLE(at: offset)
    }
    mutating func readUInt8() throws -> UInt8 {
        try ensure(1)
        let v = buffer[offset]
        offset += 1
        return v
    }
    mutating func readUInt16() throws -> UInt16 {
        try ensure(2)
        let lo = UInt16(buffer[offset])
        let hi = UInt16(buffer[offset + 1])
        offset += 2
        return lo | (hi << 8)
    }
    mutating func readUInt32() throws -> UInt32 {
        try ensure(4)
        let v: UInt32 = loadLE(at: offset)
        offset += 4
        return v
    }
    mutating func readUInt64() throws -> UInt64 {
        try ensure(8)
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(buffer[offset + i]) << (8 * i)
        }
        offset += 8
        return v
    }
    mutating func readUTF8(length: Int) throws -> String {
        try ensure(length)
        let bytes = UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: offset),
                                        count: length)
        offset += length
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func skip(_ n: Int) throws {
        try ensure(n)
        offset += n
    }
    private func loadLE(at idx: Int) -> UInt32 {
        let b0 = UInt32(buffer[idx])
        let b1 = UInt32(buffer[idx + 1])
        let b2 = UInt32(buffer[idx + 2])
        let b3 = UInt32(buffer[idx + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    private func ensure(_ n: Int) throws {
        if offset + n > buffer.count {
            throw KnitError.formatError(".knit: unexpected end of file at \(offset) (need \(n))")
        }
    }
}
