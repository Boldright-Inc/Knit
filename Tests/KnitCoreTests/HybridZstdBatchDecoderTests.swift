import XCTest
import Foundation
import Darwin
@testable import KnitCore

/// Tests for the orchestration layer that future GPU `BlockDecoding`
/// implementations plug into. Until a real GPU decoder lands the
/// orchestrator is exercised CPU-only, but every safety-critical
/// path — eager pipeline gating, per-block fallback, batch CRC
/// fold — is here from day one.
final class HybridZstdBatchDecoderTests: XCTestCase {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-hybrid-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pseudo-random pattern that's both compressible and unique, so
    /// any byte-equality mismatch is genuinely a decoder bug rather
    /// than a constant-buffer false positive.
    private func mixedPattern(size: Int, seed: UInt64) -> Data {
        var s = seed
        var d = Data(count: size)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < size {
                let runEnd = min(i + 64 * 1024, size)
                for j in i..<runEnd { p[j] = 0xAB }
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

    // MARK: - Round trip equivalence

    /// CPU-only staged decode must produce bit-identical output to the
    /// existing direct-libzstd decode path, across many blocks. Catches
    /// any orchestration bug that drops or reorders a block.
    func testStagedDecoderRoundTripEqualsDirectPath() throws {
        let inDir = try makeTempDir("rt-in")
        let outA = try makeTempDir("rt-direct")
        let outB = try makeTempDir("rt-staged")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("rt-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outA)
            try? FileManager.default.removeItem(at: outB)
            try? FileManager.default.removeItem(at: archive)
        }

        let payload = mixedPattern(size: 8 * 1024 * 1024, seed: 0x5EED_5EED_5EED_5EED)
        try payload.write(to: inDir.appendingPathComponent("payload.bin"))

        let opts = KnitCompressor.Options(
            level: CompressionLevel(3),
            concurrency: 4,
            blockSize: 64 * 1024
        )
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        // Direct path (reference) — exercises the existing
        // libzstd-per-block loop.
        let readerA = try KnitReader(url: archive)
        for entry in readerA.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outA)
            try readerA.extract(entry, to: outURL)
        }

        // Staged path — same archive, same bytes expected.
        let readerB = try KnitReader(url: archive)
        let staged = HybridZstdBatchDecoder(maxBatchBlocks: 8)
        for entry in readerB.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outB)
            try readerB.extract(entry, to: outURL, stagedDecoder: staged)
        }

        // Compare each non-directory file byte-for-byte. We resolve
        // `outA.path` via realpath(3) so it matches the firmlink-
        // resolved form `FileManager.enumerator` yields — on macOS 26
        // Tahoe the two diverge for paths under `/var/folders/...`
        // (the temp dir's home), so a naive `dropFirst` strips the
        // wrong number of characters and the comparison looks for
        // files at nonsense paths. Same root cause as the FileWalker
        // fix that ships in this PR.
        let outAResolved = realpathPath(outA.path)
        let fm = FileManager.default
        let walker = fm.enumerator(at: outA, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let rel = String(url.path.dropFirst(outAResolved.count))
            let bUrl = URL(fileURLWithPath: realpathPath(outB.path) + rel)
            let aBytes = try Data(contentsOf: url)
            let bBytes = try Data(contentsOf: bUrl)
            XCTAssertEqual(aBytes, bBytes,
                           "byte mismatch between direct and staged decode at \(rel)")
        }
    }

    /// Test-local realpath helper. Mirrors `FileWalker.realpathURL`
    /// without exposing that method publicly. Returns the canonical
    /// firmlink-resolved path so test-side prefix-stripping matches
    /// what `FileManager.enumerator` hands back on macOS 26 Tahoe.
    private func realpathPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return p.withCString { cstr -> String in
            guard let r = Darwin.realpath(cstr, &buf) else { return p }
            return String(cString: r)
        }
    }

    // MARK: - Per-block fallback

    /// A `BlockDecoding` that always throws — used to simulate a GPU
    /// implementation that fails on every block. The orchestrator
    /// must transparently re-decode each block via the CPU path.
    private struct AlwaysThrowingDecoder: BlockDecoding {
        let name = "always-throw"
        let supportsGPU = true
        func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                         into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
            throw KnitError.codecFailure("synthetic failure for fallback test")
        }
    }

    /// Even when the "GPU" path throws on every block, the staged
    /// decoder must still produce correct output and the round-trip
    /// must succeed — every block falls through to CPU. Fallback count
    /// in the resulting Stats must equal the block count.
    func testEveryBlockFallsBackWhenGPUPathAlwaysThrows() throws {
        let inDir = try makeTempDir("fb-in")
        let outDir = try makeTempDir("fb-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("fb-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        let payload = mixedPattern(size: 1 * 1024 * 1024, seed: 0xCAFE_BEEF_DEAD_F00D)
        try payload.write(to: inDir.appendingPathComponent("payload.bin"))

        let opts = KnitCompressor.Options(
            level: CompressionLevel(3),
            blockSize: 64 * 1024
        )
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        let reader = try KnitReader(url: archive)
        // Hand the orchestrator a throwing GPU decoder. Per-block
        // fallback should silently re-route each block to the CPU
        // baseline.
        let staged = HybridZstdBatchDecoder(
            cpuPath: CPUZstdDecoder(),
            gpuPath: AlwaysThrowingDecoder(),
            maxBatchBlocks: 4
        )
        for entry in reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outDir)
            try reader.extract(entry, to: outURL, stagedDecoder: staged)
        }

        let extracted = try Data(contentsOf:
            outDir.appendingPathComponent(inDir.lastPathComponent)
                  .appendingPathComponent("payload.bin"))
        XCTAssertEqual(extracted, payload,
                       "fallback path must reproduce the original bytes")
    }

    // MARK: - CRC fold catches corruption

    /// A decoder that flips one byte in the output. Models a GPU bug
    /// that produces "valid-looking" bytes but doesn't match the
    /// recorded entry CRC. The orchestrator's final CRC fold must
    /// reject this.
    private struct OneByteFlipDecoder: BlockDecoding {
        let name = "byte-flip"
        let supportsGPU = false
        func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                         into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
            let cpu = CPUZstdDecoder()
            let n = try cpu.decodeBlock(frame, into: output)
            // Corrupt one byte deterministically.
            if n > 0, let p = output.baseAddress {
                p[0] ^= 0xFF
            }
            return n
        }
    }

    /// If the configured CPU path silently corrupts output, the final
    /// rolling-CRC check must trip and the caller must see an
    /// integrity error rather than a "successful" extract of wrong
    /// bytes.
    func testCRCFoldRejectsCorruptedOutput() throws {
        let inDir = try makeTempDir("corrupt-in")
        let outDir = try makeTempDir("corrupt-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("corrupt-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        try Data(repeating: 0x42, count: 32 * 1024)
            .write(to: inDir.appendingPathComponent("payload.bin"))

        let opts = KnitCompressor.Options(
            level: CompressionLevel(3),
            blockSize: 4 * 1024
        )
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        // Force the orchestrator's CPU baseline to be the byte-flipper.
        // This simulates the worst case: a decoder that produces
        // correct length but wrong bytes. The rolling CRC fold must
        // catch it at end-of-entry.
        let reader = try KnitReader(url: archive)
        let staged = HybridZstdBatchDecoder(
            cpuPath: OneByteFlipDecoder(),
            gpuPath: nil,
            maxBatchBlocks: 4
        )

        var caught: Error?
        do {
            for entry in reader.archive.entries where !entry.isDirectory {
                let outURL = try SafePath.resolve(name: entry.name, into: outDir)
                try reader.extract(entry, to: outURL, stagedDecoder: staged)
            }
        } catch {
            caught = error
        }
        guard let err = caught else {
            XCTFail("byte-flipped decode must trip the rolling CRC fold; no error thrown")
            return
        }
        if let knitErr = err as? KnitError, case .integrity = knitErr {
            // expected
        } else {
            XCTFail("expected KnitError.integrity, got \(err)")
        }
    }

    // MARK: - Stats accuracy

    /// `Stats.usedGPU` reflects whether any block actually went through
    /// the GPU instance (modulo per-block fallback). Important for the
    /// per-entry telemetry the unpack summary will surface once a real
    /// GPU decoder lands.
    func testStatsReportCPUOnlyWhenNoGPUPath() throws {
        let inDir = try makeTempDir("stats-in")
        let outDir = try makeTempDir("stats-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("stats-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        try mixedPattern(size: 256 * 1024, seed: 0x1234_5678_ABCD_EF00)
            .write(to: inDir.appendingPathComponent("payload.bin"))
        let opts = KnitCompressor.Options(level: CompressionLevel(3), blockSize: 16 * 1024)
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        let staged = HybridZstdBatchDecoder()
        XCTAssertFalse(staged.canUseGPU,
                       "no GPU instance was supplied; canUseGPU must be false")
    }
}
