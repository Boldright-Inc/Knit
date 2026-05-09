import Foundation

public final class KnitWriter {
    public struct EntryHeader: Sendable {
        public let name: String
        public let modificationDate: Date
        public let unixMode: UInt16
        public let isDirectory: Bool
    }

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

    public func writeEntry(header: EntryHeader, payload: EntryPayload) throws {
        var buf = Data()
        buf.appendLE(KnitFormat.entryMarker)

        let nameBytes = Array(header.name.utf8)
        buf.appendLE(UInt16(nameBytes.count))
        buf.append(contentsOf: nameBytes)

        buf.appendLE(header.unixMode)
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
        head.appendLE(UInt16(0))                  // flags
        head.appendLE(UInt64(0))                  // reserved
        try handle.write(contentsOf: head)
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
