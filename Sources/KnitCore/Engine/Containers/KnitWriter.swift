import Foundation

/// Streaming writer for the `.knit` container format. See `KnitFormat` for
/// the exact byte layout — this class is the encoder side of that
/// specification.
///
/// Writes are append-only and serial: each `writeEntry` immediately emits
/// a complete entry to disk, the entry count accumulator is bumped, and
/// `close()` finalises with the footer. Designed to be invoked from a
/// single owning task; if multiple producers ever need to feed it, wrap
/// in a serial actor.
public final class KnitWriter {
    /// Per-entry metadata. The corresponding fields land in the
    /// `[name_len][name][mode][mod_unix][is_directory]` portion of the
    /// entry header (see `KnitFormat.swift`).
    public struct EntryHeader: Sendable {
        public let name: String
        public let modificationDate: Date
        public let unixMode: UInt16
        public let isDirectory: Bool
    }

    /// Per-entry compressed payload. `blockData` is the concatenation of
    /// `blockLengths.count` independent zstd frames; the lengths array
    /// lets the reader compute each frame's byte offset without parsing
    /// any zstd headers.
    public struct EntryPayload: Sendable {
        public let blockSize: UInt32
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let blockLengths: [UInt32]
        public let blockData: Data
    }

    private let handle: FileHandle
    private var totalEntries: UInt64 = 0
    private var closed = false

    /// Truncates `url` and writes the file header immediately so that a
    /// subsequent `close()` produces a valid (if empty) archive even if
    /// no entries are added.
    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw KnitError.ioFailure(path: url.path, message: "cannot open for writing")
        }
        self.handle = h
        try writeHeader()
    }

    deinit {
        if !closed { try? handle.close() }
    }

    /// Emit one full entry: marker, name + metadata, block index, then the
    /// concatenated compressed block payload. Header and payload are
    /// written in two `write` calls — the second is potentially many MB,
    /// and splitting avoids an extra `Data` copy of the payload bytes.
    public func writeEntry(header: EntryHeader, payload: EntryPayload) throws {
        var buf = Data()
        buf.appendLE(KnitFormat.entryMarker)

        let nameBytes = Array(header.name.utf8)
        buf.appendLE(UInt16(nameBytes.count))
        buf.append(contentsOf: nameBytes)

        buf.appendLE(header.unixMode)
        // Negative epoch values would underflow UInt64; clamp to 0 (1970-01-01).
        buf.appendLE(UInt64(max(0, Int(header.modificationDate.timeIntervalSince1970))))
        buf.append(header.isDirectory ? 1 : 0)

        buf.appendLE(payload.blockSize)
        buf.appendLE(payload.uncompressedSize)
        buf.appendLE(UInt64(payload.blockData.count))   // compressed_size
        buf.appendLE(payload.crc32)
        buf.appendLE(UInt32(payload.blockLengths.count))

        for len in payload.blockLengths {
            buf.appendLE(len)
        }

        try handle.write(contentsOf: buf)
        try handle.write(contentsOf: payload.blockData)
        totalEntries += 1
    }

    /// Append the archive footer and close the file. Safe to call once
    /// per writer; subsequent calls are no-ops.
    public func close() throws {
        guard !closed else { return }
        var footer = Data()
        footer.appendLE(KnitFormat.footerMarker)
        footer.appendLE(totalEntries)
        footer.appendLE(KnitFormat.archiveVersion)
        try handle.write(contentsOf: footer)
        try handle.close()
        closed = true
    }

    private func writeHeader() throws {
        var head = Data()
        head.appendLE(KnitFormat.headerMagic)
        head.appendLE(KnitFormat.version)
        head.appendLE(UInt16(0))                  // flags (reserved for future use)
        head.appendLE(UInt64(0))                  // reserved padding to align entry markers
        try handle.write(contentsOf: head)
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
