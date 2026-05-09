import Foundation

public final class KnitExtractor {

    public struct Stats: Sendable {
        public let entries: Int
        public let bytesOut: UInt64
        public let elapsed: TimeInterval
    }

    public init() {}

    public func extract(archive: URL, to destDir: URL) throws -> Stats {
        let reader = try KnitReader(url: archive)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let start = ContinuousClock.now
        var bytesOut: UInt64 = 0
        for entry in reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: destDir)
            try reader.extract(entry, to: outURL)
            bytesOut += entry.uncompressedSize
        }
        let elapsed = ContinuousClock.now - start
        return Stats(
            entries: reader.archive.entries.count,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }
}
