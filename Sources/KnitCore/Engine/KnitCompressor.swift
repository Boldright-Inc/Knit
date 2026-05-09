import Foundation

public final class KnitCompressor: Sendable {

    public struct Options: Sendable {
        public var level: CompressionLevel
        public var concurrency: Int
        public var blockSize: Int

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    blockSize: Int = Int(KnitFormat.defaultBlockSize)) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.blockSize = blockSize
        }
    }

    private let backend: BlockBackend
    private let crc: CRC32Computing
    private let options: Options

    public init(backend: BlockBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.crc = backend
        self.options = options
    }

    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(input)
        let writer = try KnitWriter(url: output)
        let start = ContinuousClock.now

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        for entry in entries {
            let header = KnitWriter.EntryHeader(
                name: entry.relativePath,
                modificationDate: entry.modificationDate,
                unixMode: entry.unixMode,
                isDirectory: entry.isDirectory
            )

            let payload: KnitWriter.EntryPayload
            if entry.isDirectory {
                payload = KnitWriter.EntryPayload(
                    blockSize: 0,
                    uncompressedSize: 0,
                    crc32: 0,
                    blockLengths: [],
                    blockData: Data()
                )
            } else {
                let mapped = try MappedFile(url: entry.absoluteURL)
                let buf = mapped.buffer
                let crcVal = buf.count == 0 ? 0 : crc.crc32(buf, seed: 0)

                let pbc = ParallelBlockCompressor(
                    backend: backend,
                    blockSize: options.blockSize,
                    concurrency: options.concurrency
                )
                let blockOut = try pbc.compress(buf, level: options.level.clampedForZstd())

                payload = KnitWriter.EntryPayload(
                    blockSize: UInt32(options.blockSize),
                    uncompressedSize: UInt64(buf.count),
                    crc32: crcVal,
                    blockLengths: blockOut.blockSizes,
                    blockData: blockOut.combined
                )
            }

            try writer.writeEntry(header: header, payload: payload)
            bytesIn  += payload.uncompressedSize
            bytesOut += UInt64(payload.blockData.count)
        }

        try writer.close()
        let elapsed = ContinuousClock.now - start
        return CompressionStats(
            entriesWritten: entries.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }
}
