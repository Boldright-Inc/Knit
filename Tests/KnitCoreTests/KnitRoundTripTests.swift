import XCTest
import Foundation
@testable import KnitCore

/// Round-trip pack -> unpack with CRC32 verification on the extract side.
/// Catches regressions in the new entropy-probe-driven compression path and
/// the GPU-CRC32 verification wired into `KnitExtractor`.
final class KnitRoundTripTests: XCTestCase {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-rt-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pseudoRandom(_ size: Int, seed: UInt64) -> Data {
        var s = seed
        var d = Data(count: size)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<size {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: s >> 32)
            }
        }
        return d
    }

    func testPackUnpackPreservesContentsAndCRC() throws {
        let inDir = try makeTempDir("in")
        let outDir = try makeTempDir("out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("rt-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        // Mix of compressible and incompressible content. The entropy probe
        // should classify them differently and downgrade the random file
        // to lvl=1 internally.
        let textFile = inDir.appendingPathComponent("readme.txt")
        let textPayload = String(repeating: "Knit round-trip integrity test. ", count: 4096)
        try textPayload.write(to: textFile, atomically: true, encoding: .utf8)

        let randomFile = inDir.appendingPathComponent("random.bin")
        try pseudoRandom(512 * 1024, seed: 0xBEEF_DAD_CAFE).write(to: randomFile)

        let recorder = HeatmapRecorder()
        let opts = KnitCompressor.Options(
            level: CompressionLevel(6),
            blockSize: 64 * 1024,
            heatmapRecorder: recorder
        )
        let stats = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)
        XCTAssertGreaterThan(stats.entriesWritten, 0)
        XCTAssertGreaterThan(recorder.count, 0,
                             "entropy probe should have produced samples")

        // Heatmap should have at least one stored (high-entropy) block from
        // the random file.
        let snapshot = recorder.snapshot()
        XCTAssertTrue(snapshot.samples.contains { $0.disposition == .stored },
                      "expected at least one stored block from the PRNG file")
        XCTAssertTrue(snapshot.samples.contains { $0.disposition == .compressed },
                      "expected at least one compressed block from the text file")

        // Extract — this exercises the new CRC verification path.
        let extractStats = try KnitExtractor(useGPUVerify: true)
            .extract(archive: archive, to: outDir)
        XCTAssertEqual(extractStats.entries, stats.entriesWritten)

        // Confirm bytes round-trip exactly.
        let outText = try Data(contentsOf:
            outDir.appendingPathComponent(inDir.lastPathComponent)
                  .appendingPathComponent("readme.txt"))
        XCTAssertEqual(outText, textPayload.data(using: .utf8))

        let outRandom = try Data(contentsOf:
            outDir.appendingPathComponent(inDir.lastPathComponent)
                  .appendingPathComponent("random.bin"))
        XCTAssertEqual(outRandom.count, 512 * 1024)
    }

    func testCorruptCRCIsDetected() throws {
        let inDir = try makeTempDir("corrupt-in")
        let outDir = try makeTempDir("corrupt-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        let f = inDir.appendingPathComponent("payload.bin")
        try Data(repeating: 0x42, count: 4096).write(to: f)

        let opts = KnitCompressor.Options(level: CompressionLevel(3),
                                          blockSize: 4096)
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        // Flip one byte inside the compressed payload. Because the CRC is
        // computed over the *uncompressed* output, mutating any compressed
        // byte will (almost) always cause the decompressed bytes to differ
        // from the original — and thus the verifier should reject.
        var raw = try Data(contentsOf: archive)
        // Hit a byte well after the header but before the footer.
        let mid = raw.count / 2
        raw[mid] ^= 0xFF
        try raw.write(to: archive)

        XCTAssertThrowsError(
            try KnitExtractor(useGPUVerify: false).extract(archive: archive, to: outDir)
        )
    }
}
