import Testing
import Foundation
@testable import KnitCore

/// Tests for the `entryFilter` selective-extraction parameter on both
/// `ZipExtractor` (covered separately for shape in
/// `ZipExtractorTests`) and `KnitExtractor`. The two extractors share
/// the same filter contract — empty set throws, names not in archive
/// throw, only matching entries materialise — so a regression on one
/// side should immediately surface as a divergence between the
/// matched assertions in this file.
@Suite("Entry filter tests for KnitExtractor (.knit)")
struct KnitExtractorEntryFilterTests {

    @Test("entryFilter extracts only the named .knit entries")
    func extractsOnlyFilteredEntries() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try "alpha".write(to: inputDir.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try "bravo".write(to: inputDir.appendingPathComponent("b.txt"),
                          atomically: true, encoding: .utf8)
        try "charlie".write(to: inputDir.appendingPathComponent("c.txt"),
                            atomically: true, encoding: .utf8)

        let archive = tmp.appendingPathComponent("filtered.knit")
        _ = try KnitCompressor(backend: CPUZstd(),
                               options: .init(blockSize: 32 * 1024))
            .compress(input: inputDir, to: archive)

        // Discover the canonical entry name for `b.txt` from the
        // footer — KnitCompressor's prefixing convention isn't part of
        // the public surface, so we look it up dynamically.
        let reader = try KnitReader(url: archive)
        guard let bName = reader.archive.entries.first(where: { $0.name.hasSuffix("b.txt") })?.name else {
            Issue.record("KnitReader didn't surface a 'b.txt' entry")
            return
        }

        let restoreDir = tmp.appendingPathComponent("restore")
        let stats = try KnitExtractor(entryFilter: [bName])
            .extract(archive: archive, to: restoreDir)
        // Only one entry processed.
        #expect(stats.entries == 1)
        #expect(stats.bytesOut == UInt64("bravo".utf8.count))

        let restoredB = restoreDir.appendingPathComponent(bName)
        let bContents = try? String(contentsOf: restoredB, encoding: .utf8)
        #expect(bContents == "bravo")

        // Sibling entries must not have been materialised.
        let restoredA = restoreDir.appendingPathComponent(
            bName.replacingOccurrences(of: "b.txt", with: "a.txt"))
        let restoredC = restoreDir.appendingPathComponent(
            bName.replacingOccurrences(of: "b.txt", with: "c.txt"))
        #expect(!FileManager.default.fileExists(atPath: restoredA.path),
                "KnitExtractor should not have extracted a.txt — outside filter")
        #expect(!FileManager.default.fileExists(atPath: restoredC.path),
                "KnitExtractor should not have extracted c.txt — outside filter")
    }

    @Test("entryFilter throws on names that aren't in the .knit archive")
    func missingEntryThrows() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        try Data([1, 2, 3]).write(to: file)
        let archive = tmp.appendingPathComponent("data.knit")
        _ = try KnitCompressor(backend: CPUZstd(),
                               options: .init(blockSize: 32 * 1024))
            .compress(input: file, to: archive)

        let restoreDir = tmp.appendingPathComponent("restore")
        var threw = false
        do {
            _ = try KnitExtractor(entryFilter: ["nope.bin"])
                .extract(archive: archive, to: restoreDir)
        } catch is KnitError {
            threw = true
        }
        #expect(threw,
                "KnitExtractor should refuse a filter naming entries that don't exist")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knit-efilter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
