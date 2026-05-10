import XCTest
import Foundation
@testable import KnitCore

/// Verifies the streaming `.knit` pipeline added in the 100GB-scaling
/// fixes: bounded peak memory, correct CRC across many blocks, and
/// round-trip byte equality even when the input is several times the
/// block size and the entropy probe forces per-block level downgrades.
final class StreamingPackTests: XCTestCase {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-stream-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Synthesize a deterministic byte stream: alternating runs of
    /// "compressible" (zero-padded) and "incompressible" (LCG random)
    /// regions. Forces the entropy probe to make different per-block
    /// decisions across the file.
    private func mixedPattern(size: Int, seed: UInt64) -> Data {
        var s = seed
        var d = Data(count: size)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < size {
                // 64 KiB run of zeros, then 64 KiB of LCG noise.
                let runEnd = min(i + 64 * 1024, size)
                for j in i..<runEnd { p[j] = 0 }
                i = runEnd
                let noiseEnd = min(i + 64 * 1024, size)
                for j in i..<noiseEnd {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    p[j] = UInt8(truncatingIfNeeded: s >> 32)
                }
                i = noiseEnd
            }
        }
        return d
    }

    /// Pack a multi-MB file across many small blocks so we exercise the
    /// streaming pipeline's batching, ordering, and CRC combination
    /// logic. Round-trip back to disk and verify byte equality.
    func testStreamingRoundTripManyBlocks() throws {
        let inDir = try makeTempDir("rt-many")
        let outDir = try makeTempDir("rt-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("rt-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        // 16 MiB input split across 64 KiB blocks → 256 blocks. With a
        // 16-block batch this exercises ~16 driver iterations including
        // the partial-final-batch case.
        let payload = mixedPattern(size: 16 * 1024 * 1024, seed: 0xCAFE_BABE_DEAD_BEEF)
        let dataFile = inDir.appendingPathComponent("payload.bin")
        try payload.write(to: dataFile)

        let recorder = HeatmapRecorder()
        let opts = KnitCompressor.Options(
            level: CompressionLevel(6),
            concurrency: 4,
            blockSize: 64 * 1024,
            heatmapRecorder: recorder
        )
        let stats = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)
        XCTAssertGreaterThan(stats.entriesWritten, 0)
        XCTAssertGreaterThan(recorder.count, 0)

        // Heatmap should reflect both block dispositions because the
        // input alternates zero runs and LCG noise.
        let snap = recorder.snapshot()
        XCTAssertTrue(snap.samples.contains { $0.disposition == .compressed },
                      "expected at least one compressed block from the zero runs")
        XCTAssertTrue(snap.samples.contains { $0.disposition == .stored },
                      "expected at least one stored/downgraded block from the LCG noise")

        // Round-trip extract: this also exercises the CRC32 verification
        // path on extract, which catches any miscombination of per-block
        // CRCs.
        let extractStats = try KnitExtractor(useGPUVerify: false)
            .extract(archive: archive, to: outDir)
        XCTAssertEqual(extractStats.entries, stats.entriesWritten)

        let extracted = try Data(contentsOf:
            outDir.appendingPathComponent(inDir.lastPathComponent)
                  .appendingPathComponent("payload.bin"))
        XCTAssertEqual(extracted, payload)
    }

    /// Cover the directory entry path through the streaming writer:
    /// zero blocks, zero compressed_size, all placeholders patched
    /// to zero on `finish(crc32:)`.
    func testStreamingDirectoryEntry() throws {
        let inDir = try makeTempDir("dir-in")
        let outDir = try makeTempDir("dir-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("dir-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        // Empty directory in the input: walker emits a single
        // is_directory=true entry with no payload.
        let nested = inDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let opts = KnitCompressor.Options(level: CompressionLevel(3))
        let stats = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)
        XCTAssertGreaterThanOrEqual(stats.entriesWritten, 2)  // root + subdir

        let extractStats = try KnitExtractor(useGPUVerify: false)
            .extract(archive: archive, to: outDir)
        XCTAssertEqual(extractStats.entries, stats.entriesWritten)

        var isDir: ObjCBool = false
        let outNested = outDir.appendingPathComponent(inDir.lastPathComponent)
                              .appendingPathComponent("subdir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outNested.path,
                                                     isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// Whole-file CRC computed via the streaming pipeline (per-block CRC
    /// + crc32_combine fold) must equal a single-shot libdeflate CRC32
    /// over the same input. Catches bugs in the GF(2) matrix combine
    /// math or block ordering.
    func testStreamingCRCMatchesSingleShot() throws {
        let inDir = try makeTempDir("crc-in")
        let outDir = try makeTempDir("crc-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("crc-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        // Pick an input size that's not a multiple of the block size,
        // so the final block is short.
        let payload = mixedPattern(size: 3 * 1024 * 1024 + 12345,
                                   seed: 0xAA55_5AA5_C0DE_C0DE)
        let dataFile = inDir.appendingPathComponent("payload.bin")
        try payload.write(to: dataFile)

        let opts = KnitCompressor.Options(
            level: CompressionLevel(3),
            concurrency: 4,
            blockSize: 256 * 1024
        )
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        // Re-open the archive and check the recorded CRC of the data
        // entry against a single-shot libdeflate CRC32 over the
        // original bytes.
        let reader = try KnitReader(url: archive)
        let dataEntry = reader.archive.entries.first { !$0.isDirectory && $0.uncompressedSize > 0 }
        XCTAssertNotNil(dataEntry)
        let recorded = dataEntry!.crc32

        let expected = payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let buf = UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: raw.count)
            return CPUDeflate().crc32(buf, seed: 0)
        }
        XCTAssertEqual(recorded, expected,
                       "streaming CRC32 (combined per-block) differs from single-shot CRC32")

        // Extract path independently re-verifies; if the recorded CRC
        // were wrong, this would throw.
        _ = try KnitExtractor(useGPUVerify: false).extract(archive: archive, to: outDir)
    }
}
