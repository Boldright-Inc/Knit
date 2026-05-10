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

    fileprivate let handle: FileHandle
    fileprivate var currentOffset: UInt64 = 0
    fileprivate var totalEntries: UInt64 = 0
    private var closed = false
    fileprivate var entryInProgress: Bool = false

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

    /// Emit one full entry from a fully-buffered payload. Convenience
    /// shim around the streaming API for callers that already hold the
    /// complete compressed result in memory (e.g. tests, small entries).
    /// New code on the compressor side uses `beginStreamingEntry(...)`
    /// to keep peak memory bounded — see `KnitCompressor`.
    public func writeEntry(header: EntryHeader, payload: EntryPayload) throws {
        let streaming = try beginStreamingEntry(
            header: header,
            uncompressedSize: payload.uncompressedSize,
            blockSize: payload.blockSize,
            numBlocks: UInt32(payload.blockLengths.count)
        )
        var off = 0
        for len in payload.blockLengths {
            let frameLen = Int(len)
            // Per-block sub-data view — pulled out of the contiguous
            // `payload.blockData` buffer without copying.
            let frame = payload.blockData.subdata(in: off..<(off + frameLen))
            try streaming.writeBlock(frame)
            off += frameLen
        }
        try streaming.finish(crc32: payload.crc32)
    }

    /// Begin a streaming entry. The entry header is committed to disk
    /// immediately, with `compressed_size`, `crc32`, and `block_lengths[]`
    /// reserved as zero-filled placeholders. The caller writes block
    /// frames one at a time via the returned `StreamingEntry`; on
    /// `finish(crc32:)` the placeholders are seek-back-patched.
    ///
    /// Memory usage during a streaming entry is bounded by however many
    /// frames the caller chooses to hold in flight at once — the writer
    /// itself never buffers anything beyond the current `Data` argument.
    public func beginStreamingEntry(header: EntryHeader,
                                    uncompressedSize: UInt64,
                                    blockSize: UInt32,
                                    numBlocks: UInt32) throws -> StreamingEntry {
        precondition(!closed, "beginStreamingEntry on closed KnitWriter")
        precondition(!entryInProgress,
                     "beginStreamingEntry called while another streaming entry is open")

        var buf = Data()
        buf.appendLE(KnitFormat.entryMarker)
        let nameBytes = Array(header.name.utf8)
        buf.appendLE(UInt16(nameBytes.count))
        buf.append(contentsOf: nameBytes)
        buf.appendLE(header.unixMode)
        // Negative epoch values would underflow UInt64; clamp to 0 (1970-01-01).
        buf.appendLE(UInt64(max(0, Int(header.modificationDate.timeIntervalSince1970))))
        buf.append(header.isDirectory ? 1 : 0)
        buf.appendLE(blockSize)
        buf.appendLE(uncompressedSize)

        // Track the offsets of fields we'll patch after streaming completes.
        let entryStart = currentOffset
        let compressedSizeOffset = entryStart + UInt64(buf.count)
        buf.appendLE(UInt64(0))                         // compressed_size placeholder
        let crc32Offset = entryStart + UInt64(buf.count)
        buf.appendLE(UInt32(0))                         // crc32 placeholder
        buf.appendLE(numBlocks)
        let lengthsOffset = entryStart + UInt64(buf.count)
        // Reserve the block_lengths array. Even at 256 MiB blocks /
        // 256 PiB max entry, this is only `maxBlocksPerEntry × 4` bytes
        // = 16 MiB worst case.
        let lengthsBytes = Int(numBlocks) * 4
        if lengthsBytes > 0 {
            buf.append(Data(count: lengthsBytes))       // zero-filled placeholder
        }

        try handle.write(contentsOf: buf)
        currentOffset += UInt64(buf.count)
        entryInProgress = true

        return StreamingEntry(
            writer: self,
            entryStart: entryStart,
            compressedSizeOffset: compressedSizeOffset,
            crc32Offset: crc32Offset,
            lengthsOffset: lengthsOffset,
            totalBlocks: Int(numBlocks)
        )
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
        currentOffset += UInt64(head.count)
    }
}

extension KnitWriter {

    /// Streaming handle for one in-progress `.knit` entry.
    ///
    /// Returned from `beginStreamingEntry(...)`. The caller writes block
    /// frames in input order via `writeBlock(_:)` and finalises the
    /// entry with `finish(crc32:)`. The writer holds no compressed-block
    /// data of its own — once `writeBlock` returns, the bytes are
    /// flushed to the underlying file handle and the caller's `Data`
    /// reference can be released.
    ///
    /// On `finish(...)`, three placeholder fields are seek-back patched:
    /// `compressed_size`, `crc32`, and `block_lengths[]`. The cursor is
    /// then restored to the end of the entry's data so the next
    /// `beginStreamingEntry` continues at the right offset.
    public final class StreamingEntry {
        fileprivate weak var writer: KnitWriter?
        private let entryStart: UInt64
        private let compressedSizeOffset: UInt64
        private let crc32Offset: UInt64
        private let lengthsOffset: UInt64
        private let totalBlocks: Int
        private var blocksWritten: Int = 0
        private var blockLengths: [UInt32] = []
        private var compressedBytes: UInt64 = 0
        private var finished: Bool = false

        fileprivate init(writer: KnitWriter,
                         entryStart: UInt64,
                         compressedSizeOffset: UInt64,
                         crc32Offset: UInt64,
                         lengthsOffset: UInt64,
                         totalBlocks: Int) {
            self.writer = writer
            self.entryStart = entryStart
            self.compressedSizeOffset = compressedSizeOffset
            self.crc32Offset = crc32Offset
            self.lengthsOffset = lengthsOffset
            self.totalBlocks = totalBlocks
            self.blockLengths.reserveCapacity(totalBlocks)
        }

        /// Append one compressed block frame. Must be called exactly
        /// `numBlocks` times (or zero times for a directory entry)
        /// before `finish(crc32:)`.
        public func writeBlock(_ frame: Data) throws {
            guard let writer = writer else {
                throw KnitError.codecFailure("writeBlock after writer closed")
            }
            precondition(!finished, "writeBlock after finish")
            precondition(blocksWritten < totalBlocks,
                         "writeBlock called more times than declared numBlocks")
            try writer.handle.write(contentsOf: frame)
            writer.currentOffset += UInt64(frame.count)
            blockLengths.append(UInt32(frame.count))
            compressedBytes += UInt64(frame.count)
            blocksWritten += 1
        }

        /// Finalise the entry: patch `compressed_size`, `crc32`, and
        /// `block_lengths[]` in the previously-reserved header
        /// placeholders, then restore the file cursor to the end of the
        /// entry so subsequent writes append correctly.
        public func finish(crc32: UInt32) throws {
            guard let writer = writer else {
                throw KnitError.codecFailure("finish after writer closed")
            }
            precondition(!finished, "finish called twice on the same entry")
            precondition(blocksWritten == totalBlocks,
                         "finish called with \(blocksWritten)/\(totalBlocks) blocks written")

            // Remember the end of the data section; we'll seek back here
            // before returning so the next entry begins at the right
            // offset.
            let endOfEntry = writer.currentOffset

            // Patch compressed_size (UInt64 LE) at its reserved slot.
            try writer.handle.seek(toOffset: compressedSizeOffset)
            var csData = Data()
            csData.appendLE(compressedBytes)
            try writer.handle.write(contentsOf: csData)

            // Patch crc32 (UInt32 LE) at its reserved slot. The seek
            // after the compressed_size write is implicit in the
            // sequential layout of the header — but we re-seek
            // explicitly to be robust against any future field
            // re-ordering.
            try writer.handle.seek(toOffset: crc32Offset)
            var crcData = Data()
            crcData.appendLE(crc32)
            try writer.handle.write(contentsOf: crcData)

            // Patch the block_lengths array.
            if totalBlocks > 0 {
                try writer.handle.seek(toOffset: lengthsOffset)
                var lengthsData = Data()
                lengthsData.reserveCapacity(totalBlocks * 4)
                for len in blockLengths { lengthsData.appendLE(len) }
                try writer.handle.write(contentsOf: lengthsData)
            }

            // Restore the cursor to end-of-entry so the next entry
            // header starts at the right place.
            try writer.handle.seek(toOffset: endOfEntry)
            writer.currentOffset = endOfEntry
            writer.totalEntries += 1
            writer.entryInProgress = false
            finished = true
        }
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
