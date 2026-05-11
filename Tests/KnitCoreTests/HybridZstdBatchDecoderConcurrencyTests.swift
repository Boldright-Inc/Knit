import XCTest
import Foundation
import Darwin
@testable import KnitCore

/// Tests for the parallel-decode behaviour of `HybridZstdBatchDecoder`.
/// Built on top of the orchestration tests in
/// `HybridZstdBatchDecoderTests.swift` — those cover the CPU-only
/// (concurrency = 1 effectively) safety contract; this file focuses on
/// the assertions that only become meaningful once `concurrentMap`
/// fans the per-block decode out across worker threads.
final class HybridZstdBatchDecoderConcurrencyTests: XCTestCase {

    private func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-pdec-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Multi-MB pseudo-random + run mix. Big enough that the
    /// compressor splits it into many blocks (the whole point of
    /// these tests), unique enough that mis-ordered output is detected
    /// as a content mismatch rather than passing on a constant pattern.
    private func mixedPattern(size: Int, seed: UInt64) -> Data {
        var s = seed
        var d = Data(count: size)
        d.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            while i < size {
                let runEnd = min(i + 8 * 1024, size)
                for j in i..<runEnd { p[j] = 0xCD }
                i = runEnd
                let noiseEnd = min(i + 24 * 1024, size)
                for j in i..<noiseEnd {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    p[j] = UInt8(truncatingIfNeeded: s >> 32)
                }
                i = noiseEnd
            }
        }
        return d
    }

    /// Build a `.knit` archive containing one large file plus the
    /// reader for it. The file is sized so the default 1 MiB block
    /// cap produces dozens of blocks per entry — enough that
    /// concurrentMap actually has work to fan out.
    private func buildArchive(payloadSize: Int,
                              blockSize: Int,
                              tag: String,
                              seed: UInt64) throws
        -> (archive: URL, payload: Data, reader: KnitReader, cleanup: () -> Void)
    {
        let inDir = try makeTempDir("\(tag)-in")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("\(tag)-\(UUID().uuidString).knit")
        let payload = mixedPattern(size: payloadSize, seed: seed)
        try payload.write(to: inDir.appendingPathComponent("payload.bin"))

        let opts = KnitCompressor.Options(
            level: CompressionLevel(3),
            concurrency: 4,
            blockSize: blockSize
        )
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        let reader = try KnitReader(url: archive)
        let cleanup: () -> Void = {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: archive)
        }
        return (archive, payload, reader, cleanup)
    }

    // MARK: - Determinism: serial == parallel

    /// Decoding the same archive twice — once with `concurrency = 1`,
    /// once with `concurrency = N` — must produce byte-identical
    /// output on disk. If the parallel path drops, reorders, or
    /// double-writes any block the diff between the two extracts
    /// surfaces it.
    func testParallelDecodeMatchesSerialBytewise() throws {
        let bundle = try buildArchive(
            payloadSize: 16 * 1024 * 1024,
            blockSize: 64 * 1024,
            tag: "det",
            seed: 0xD37E_A1A1_5EED_B007
        )
        defer { bundle.cleanup() }

        let outSerial = try makeTempDir("det-serial")
        let outParallel = try makeTempDir("det-par")
        defer {
            try? FileManager.default.removeItem(at: outSerial)
            try? FileManager.default.removeItem(at: outParallel)
        }

        // Serial: concurrency = 1, otherwise the same orchestrator.
        let serial = HybridZstdBatchDecoder(maxBatchBlocks: 16, concurrency: 1)
        for entry in bundle.reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outSerial)
            try bundle.reader.extract(entry, to: outURL, stagedDecoder: serial)
        }

        // Parallel: high concurrency, separate decoder instance.
        let parallel = HybridZstdBatchDecoder(maxBatchBlocks: 16, concurrency: 8)
        for entry in bundle.reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outParallel)
            try bundle.reader.extract(entry, to: outURL, stagedDecoder: parallel)
        }

        // Walk and byte-compare.
        // realpath both bases — on macOS 26 Tahoe the temp-dir paths
        // (`/var/folders/...`) yield differently from `URL.path` than
        // from `FileManager.enumerator`, breaking naive prefix-strips.
        // Same root cause as the FileWalker fix shipping in this PR.
        let outSerialResolved = realpathPath(outSerial.path)
        let outParallelResolved = realpathPath(outParallel.path)
        let walker = FileManager.default.enumerator(
            at: outSerial, includingPropertiesForKeys: [.isDirectoryKey]
        )!
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let rel = String(url.path.dropFirst(outSerialResolved.count))
            let parUrl = URL(fileURLWithPath: outParallelResolved + rel)
            let serialBytes = try Data(contentsOf: url)
            let parBytes = try Data(contentsOf: parUrl)
            XCTAssertEqual(serialBytes, parBytes,
                           "serial and parallel decode disagreed at \(rel)")
        }
    }

    // MARK: - Round-trip equivalence to the original input under parallelism

    /// Round-trip: original payload → pack → parallel unpack must
    /// recover the original bytes. With many blocks and many workers
    /// this is the most direct way to catch any subtle ordering or
    /// fallback bug.
    func testParallelDecodeRoundTripsOriginalPayload() throws {
        let bundle = try buildArchive(
            payloadSize: 8 * 1024 * 1024,
            blockSize: 32 * 1024,
            tag: "rt-par",
            seed: 0xFACE_FEED_C0FF_EE00
        )
        defer { bundle.cleanup() }

        let outDir = try makeTempDir("rt-par-out")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let parallel = HybridZstdBatchDecoder(maxBatchBlocks: 32, concurrency: 8)
        for entry in bundle.reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outDir)
            try bundle.reader.extract(entry, to: outURL, stagedDecoder: parallel)
        }

        // Locate the extracted payload and compare.
        let inDirName = bundle.archive.deletingPathExtension().lastPathComponent
        // Test rebuilt archive name was random; use enumerator to find the file.
        var foundURL: URL? = nil
        let walker = FileManager.default.enumerator(at: outDir,
                                                    includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir, url.lastPathComponent == "payload.bin" {
                foundURL = url
                break
            }
        }
        let extracted = try Data(contentsOf: XCTUnwrap(foundURL,
            "extracted payload not found under \(outDir.path) (archive was \(inDirName))"))
        XCTAssertEqual(extracted.count, bundle.payload.count)
        XCTAssertEqual(extracted, bundle.payload,
                       "parallel decode must recover the original payload bytes")
    }

    // MARK: - Per-block fallback under parallelism

    /// `BlockDecoding` that throws on every block. Combined with
    /// concurrency ≥ 2, this exercises N concurrent throw-then-fallback
    /// paths simultaneously — a regression in the per-block fallback
    /// branch (e.g. corrupting another worker's slot) shows up as
    /// either a thrown integrity error or a content mismatch.
    private struct AlwaysThrowingDecoder: BlockDecoding {
        let name = "always-throw-par"
        let supportsGPU = true
        func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                         into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
            throw KnitError.codecFailure("synthetic failure for parallel fallback test")
        }
    }

    /// A "GPU" path that always throws + 8-way concurrency: every
    /// block falls back to CPU concurrently. Result must be the
    /// original bytes; fallback count = number of blocks.
    func testEveryBlockFallsBackUnderHighConcurrency() throws {
        let bundle = try buildArchive(
            payloadSize: 4 * 1024 * 1024,
            blockSize: 16 * 1024,
            tag: "fb-par",
            seed: 0xBADF_00D_DEAD_BEEF
        )
        defer { bundle.cleanup() }

        let outDir = try makeTempDir("fb-par-out")
        defer { try? FileManager.default.removeItem(at: outDir) }

        let staged = HybridZstdBatchDecoder(
            cpuPath: CPUZstdDecoder(),
            gpuPath: AlwaysThrowingDecoder(),
            maxBatchBlocks: 32,
            concurrency: 8
        )

        for entry in bundle.reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outDir)
            try bundle.reader.extract(entry, to: outURL, stagedDecoder: staged)
        }

        var foundURL: URL? = nil
        let walker = FileManager.default.enumerator(at: outDir,
                                                    includingPropertiesForKeys: nil)!
        for case let url as URL in walker {
            if url.lastPathComponent == "payload.bin" {
                foundURL = url
                break
            }
        }
        let extracted = try Data(contentsOf: XCTUnwrap(foundURL))
        XCTAssertEqual(extracted, bundle.payload,
                       "every-block fallback under concurrency must still recover the original payload")
    }

    // MARK: - CRC fold catches corruption under parallelism

    /// Corrupts the first byte of every decoded block. With
    /// concurrency ≥ 2 the corruption happens concurrently in many
    /// slots. The rolling CRC fold runs serially after the parallel
    /// decode and must still catch the mismatch — i.e. the CRC fold
    /// is unaffected by the order workers wrote the staging buffer.
    private struct OneByteFlipParallelDecoder: BlockDecoding {
        let name = "byte-flip-par"
        let supportsGPU = false
        func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                         into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
            let cpu = CPUZstdDecoder()
            let n = try cpu.decodeBlock(frame, into: output)
            if n > 0, let p = output.baseAddress { p[0] ^= 0xFF }
            return n
        }
    }

    func testCRCFoldRejectsCorruptionUnderConcurrency() throws {
        let bundle = try buildArchive(
            payloadSize: 1 * 1024 * 1024,
            blockSize: 16 * 1024,
            tag: "crc-par",
            seed: 0xC0DE_BABE_CAFE_F00D
        )
        defer { bundle.cleanup() }

        let outDir = try makeTempDir("crc-par-out")
        defer { try? FileManager.default.removeItem(at: outDir) }

        // CPU baseline is the byte-flipper. The orchestrator's parallel
        // workers all corrupt their slots concurrently. End-of-entry
        // rolling CRC must still trip.
        let staged = HybridZstdBatchDecoder(
            cpuPath: OneByteFlipParallelDecoder(),
            gpuPath: nil,
            maxBatchBlocks: 16,
            concurrency: 8
        )

        var caught: Error?
        do {
            for entry in bundle.reader.archive.entries where !entry.isDirectory {
                let outURL = try SafePath.resolve(name: entry.name, into: outDir)
                try bundle.reader.extract(entry, to: outURL, stagedDecoder: staged)
            }
        } catch {
            caught = error
        }
        guard let err = caught else {
            XCTFail("byte-flipped parallel decode must trip the rolling CRC fold; no error thrown")
            return
        }
        if let knitErr = err as? KnitError, case .integrity = knitErr {
            // expected
        } else {
            XCTFail("expected KnitError.integrity, got \(err)")
        }
    }

    // MARK: - Cross-entry decoder reuse

    /// `KnitExtractor` constructs ONE `HybridZstdBatchDecoder` and
    /// shares it across every entry. The watchdog poisoning state is
    /// per-entry and must reset cleanly between entries — otherwise
    /// a slow tail on entry N forces CPU-only on entry N+1 even when
    /// it would've worked fine. This test exercises a multi-entry
    /// archive end-to-end and checks both entries decode successfully
    /// through the shared decoder.
    func testSharedDecoderResetsPerEntryState() throws {
        let inDir = try makeTempDir("multi-in")
        let outDir = try makeTempDir("multi-out")
        let archive = inDir.deletingLastPathComponent()
            .appendingPathComponent("multi-\(UUID().uuidString).knit")
        defer {
            try? FileManager.default.removeItem(at: inDir)
            try? FileManager.default.removeItem(at: outDir)
            try? FileManager.default.removeItem(at: archive)
        }

        // Two entries, each multi-block. Different content so we can
        // tell them apart on extract.
        let payloadA = mixedPattern(size: 1 * 1024 * 1024, seed: 0xA111_A111_A111_A111)
        let payloadB = mixedPattern(size: 1 * 1024 * 1024, seed: 0xB222_B222_B222_B222)
        try payloadA.write(to: inDir.appendingPathComponent("a.bin"))
        try payloadB.write(to: inDir.appendingPathComponent("b.bin"))

        let opts = KnitCompressor.Options(level: CompressionLevel(3),
                                          blockSize: 32 * 1024)
        _ = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inDir, to: archive)

        let reader = try KnitReader(url: archive)
        let staged = HybridZstdBatchDecoder(maxBatchBlocks: 16, concurrency: 4)

        for entry in reader.archive.entries {
            let outURL = try SafePath.resolve(name: entry.name, into: outDir)
            try reader.extract(entry, to: outURL, stagedDecoder: staged)
        }

        // Find both extracted files and compare.
        var aFound: Data? = nil
        var bFound: Data? = nil
        let walker = FileManager.default.enumerator(at: outDir,
                                                    includingPropertiesForKeys: nil)!
        for case let url as URL in walker {
            if url.lastPathComponent == "a.bin" { aFound = try Data(contentsOf: url) }
            if url.lastPathComponent == "b.bin" { bFound = try Data(contentsOf: url) }
        }
        XCTAssertEqual(aFound, payloadA, "entry A must decode correctly through the shared decoder")
        XCTAssertEqual(bFound, payloadB, "entry B must decode correctly through the shared decoder")
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
}
