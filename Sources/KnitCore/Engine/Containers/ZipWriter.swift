import Foundation

/// Streaming ZIP archive writer with ZIP64 support.
///
/// Designed to be invoked from a serial actor — the public methods are
/// non-isolated, but callers must serialize access externally (the file
/// handle is shared mutable state).
///
/// Layout produced:
///
///     [LFH 1][data 1][LFH 2][data 2] ...
///     [Central Directory entries]
///     [ZIP64 EOCD record]   (always emitted; harmless for small archives)
///     [ZIP64 EOCD locator]
///     [EOCD record]
public final class ZipWriter {

    // MARK: - Public types

    public struct EntryDescriptor: Sendable {
        public let name: String              // forward-slash separated, no leading slash
        public let modificationDate: Date
        public let unixMode: UInt16          // POSIX mode bits, 0o644 etc.
        public let isDirectory: Bool

        public init(name: String,
                    modificationDate: Date = Date(),
                    unixMode: UInt16 = 0o644,
                    isDirectory: Bool = false) {
            self.name = name
            self.modificationDate = modificationDate
            self.unixMode = unixMode
            self.isDirectory = isDirectory
        }
    }

    public struct EntryResult: Sendable {
        public let descriptor: EntryDescriptor
        public let method: CompressionMethod
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
    }

    // MARK: - State

    private let handle: FileHandle
    private var entries: [EntryResult] = []
    private var currentOffset: UInt64 = 0
    private var closed = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw KnitError.ioFailure(path: url.path, message: "cannot open for writing")
        }
        self.handle = h
    }

    deinit {
        if !closed {
            try? handle.close()
        }
    }

    // MARK: - Writing

    /// Write a stored (uncompressed) or precompressed entry. The caller
    /// must have already produced the compressed bytes (or chosen `.stored`
    /// in which case `payload` is the raw data).
    public func writeEntry(
        descriptor: EntryDescriptor,
        method: CompressionMethod,
        crc32: UInt32,
        uncompressedSize: UInt64,
        payload: Data
    ) throws {
        precondition(!closed, "writeEntry on closed ZipWriter")

        let offset = currentOffset
        let nameBytes = Array(descriptor.name.utf8)
        let ts = MSDOSTimestamp(date: descriptor.modificationDate)
        let needsZip64 = uncompressedSize >= 0xFFFF_FFFF
                       || UInt64(payload.count) >= 0xFFFF_FFFF
                       || offset >= 0xFFFF_FFFF

        var lfh = Data(capacity: 30 + nameBytes.count + (needsZip64 ? 20 : 0))
        lfh.appendLE(UInt32(0x04034b50))                               // signature
        lfh.appendLE(UInt16(needsZip64 ? 45 : 20))                     // version needed
        lfh.appendLE(UInt16(0x0800))                                   // flags: bit 11 = UTF-8 names
        lfh.appendLE(method.rawValue)
        lfh.appendLE(ts.time)
        lfh.appendLE(ts.date)
        lfh.appendLE(crc32)
        // Sizes — ZIP64 sentinels if oversized
        let compressedSize32 = needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(payload.count)
        let uncompressedSize32 = needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(uncompressedSize)
        lfh.appendLE(compressedSize32)
        lfh.appendLE(uncompressedSize32)
        lfh.appendLE(UInt16(nameBytes.count))
        lfh.appendLE(UInt16(needsZip64 ? 20 : 0))                      // extra length
        lfh.append(contentsOf: nameBytes)
        if needsZip64 {
            // ZIP64 extra: 0x0001, size 16, uncompressed (8), compressed (8)
            lfh.appendLE(UInt16(0x0001))
            lfh.appendLE(UInt16(16))
            lfh.appendLE(uncompressedSize)
            lfh.appendLE(UInt64(payload.count))
        }

        try writeRaw(lfh)
        try writeRaw(payload)

        entries.append(EntryResult(
            descriptor: descriptor,
            method: method,
            crc32: crc32,
            compressedSize: UInt64(payload.count),
            uncompressedSize: uncompressedSize,
            localHeaderOffset: offset
        ))
    }

    public func close() throws {
        guard !closed else { return }
        let cdStart = currentOffset

        for entry in entries {
            try writeRaw(makeCentralDirectoryHeader(entry))
        }
        let cdEnd = currentOffset
        let cdSize = cdEnd - cdStart

        // Always emit ZIP64 EOCD record + locator (cheap insurance for archives we
        // can't predict the size of upfront). Standard EOCD follows.
        try writeRaw(makeZip64EOCDRecord(cdSize: cdSize, cdOffset: cdStart, totalEntries: UInt64(entries.count)))
        let zip64EocdOffset = currentOffset - 56  // size of zip64 eocd record
        try writeRaw(makeZip64EOCDLocator(zip64EocdOffset: zip64EocdOffset))
        try writeRaw(makeEOCDRecord(cdSize: cdSize, cdOffset: cdStart, totalEntries: entries.count))

        try handle.close()
        closed = true
    }

    // MARK: - Internals

    private func writeRaw(_ data: Data) throws {
        try handle.write(contentsOf: data)
        currentOffset += UInt64(data.count)
    }

    private func makeCentralDirectoryHeader(_ entry: EntryResult) -> Data {
        let nameBytes = Array(entry.descriptor.name.utf8)
        let ts = MSDOSTimestamp(date: entry.descriptor.modificationDate)
        let needsZip64 = entry.uncompressedSize >= 0xFFFF_FFFF
                       || entry.compressedSize >= 0xFFFF_FFFF
                       || entry.localHeaderOffset >= 0xFFFF_FFFF

        var extra = Data()
        if needsZip64 {
            extra.appendLE(UInt16(0x0001))
            // size = 24 (uncompressed 8 + compressed 8 + offset 8)
            extra.appendLE(UInt16(24))
            extra.appendLE(entry.uncompressedSize)
            extra.appendLE(entry.compressedSize)
            extra.appendLE(entry.localHeaderOffset)
        }

        // External attrs: high 16 bits = unix mode, low 16 = MS-DOS
        let externalAttrs: UInt32 = (UInt32(entry.descriptor.unixMode) << 16)
            | (entry.descriptor.isDirectory ? 0x0010 : 0)
        let versionMadeBy: UInt16 = (3 /* unix */ << 8) | 63  // 6.3 of spec

        var cdh = Data()
        cdh.appendLE(UInt32(0x02014b50))                        // signature
        cdh.appendLE(versionMadeBy)
        cdh.appendLE(UInt16(needsZip64 ? 45 : 20))              // version needed
        cdh.appendLE(UInt16(0x0800))                            // flags
        cdh.appendLE(entry.method.rawValue)
        cdh.appendLE(ts.time)
        cdh.appendLE(ts.date)
        cdh.appendLE(entry.crc32)
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.compressedSize))
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.uncompressedSize))
        cdh.appendLE(UInt16(nameBytes.count))
        cdh.appendLE(UInt16(extra.count))
        cdh.appendLE(UInt16(0))                                 // file comment length
        cdh.appendLE(UInt16(0))                                 // disk number start
        cdh.appendLE(UInt16(0))                                 // internal attrs
        cdh.appendLE(externalAttrs)
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.localHeaderOffset))
        cdh.append(contentsOf: nameBytes)
        cdh.append(extra)
        return cdh
    }

    private func makeZip64EOCDRecord(cdSize: UInt64, cdOffset: UInt64, totalEntries: UInt64) -> Data {
        var d = Data()
        d.appendLE(UInt32(0x06064b50))             // zip64 EOCD record signature
        d.appendLE(UInt64(44))                     // size of zip64 EOCD record (excludes leading 12 bytes)
        d.appendLE(UInt16(45))                     // version made by
        d.appendLE(UInt16(45))                     // version needed
        d.appendLE(UInt32(0))                      // disk number
        d.appendLE(UInt32(0))                      // disk with start of CD
        d.appendLE(totalEntries)                   // entries on this disk
        d.appendLE(totalEntries)                   // total entries
        d.appendLE(cdSize)
        d.appendLE(cdOffset)
        return d
    }

    private func makeZip64EOCDLocator(zip64EocdOffset: UInt64) -> Data {
        var d = Data()
        d.appendLE(UInt32(0x07064b50))             // zip64 EOCD locator signature
        d.appendLE(UInt32(0))                      // disk with zip64 EOCD
        d.appendLE(zip64EocdOffset)
        d.appendLE(UInt32(1))                      // total disks
        return d
    }

    private func makeEOCDRecord(cdSize: UInt64, cdOffset: UInt64, totalEntries: Int) -> Data {
        let entriesField: UInt16 = totalEntries >= 0xFFFF ? 0xFFFF : UInt16(totalEntries)
        let cdSize32: UInt32 = cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize)
        let cdOffset32: UInt32 = cdOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdOffset)

        var d = Data()
        d.appendLE(UInt32(0x06054b50))             // EOCD signature
        d.appendLE(UInt16(0))                      // disk number
        d.appendLE(UInt16(0))                      // disk with CD
        d.appendLE(entriesField)                   // entries on this disk
        d.appendLE(entriesField)                   // total entries
        d.appendLE(cdSize32)
        d.appendLE(cdOffset32)
        d.appendLE(UInt16(0))                      // comment length
        return d
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
