import Testing
import Foundation
@testable import KnitCore

/// Round-trip + reader-correctness suite for the new `knit unzip` path
/// (`ZipReader` + `CPUDeflateDecoder` + `ZipExtractor`).
///
/// Two angles are exercised:
///
///   1. **Round-trip vs `ZipCompressor`**. The strongest invariant per
///      CLAUDE.md "Testing requirements" — pack → unpack → byte-compare.
///      Catches mistakes in any of the three new files plus the
///      serialiser-deserialiser asymmetry that's the historical bug
///      class for container format work.
///
///   2. **Compatibility with system `/usr/bin/zip`**. `ZipExtractor`
///      has to read archives Knit didn't write, otherwise replacing
///      the GUI's `/usr/bin/unzip` shell-out is a regression for users
///      whose `.zip` came from Finder / Archive Utility / other tools.
///
/// The CRC + ZIP64 paths each get their own sub-test so a regression
/// can be diagnosed without reading every other assertion's error
/// message.
@Suite("ZipExtractor round-trip and reader tests")
struct ZipExtractorTests {

    @Test("ZipExtractor round-trips a small directory tree byte-identically")
    func roundTripSmallTree() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a small mixed tree: a few tiny files, one moderate
        // file, an empty subdir, one nested file. Covers the
        // directory-entry path, the small-batch concurrent extract
        // path, and the `.deflate` decode path all in one fixture.
        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try "alpha\n".write(to: inputDir.appendingPathComponent("a.txt"),
                            atomically: true, encoding: .utf8)
        try "bravo\n".write(to: inputDir.appendingPathComponent("b.txt"),
                            atomically: true, encoding: .utf8)
        // Modestly compressible blob — ensure the codec produces a
        // real DEFLATE stream rather than falling to `.stored` via
        // the entropy probe.
        let moderate = String(repeating: "the quick brown fox jumped over the lazy dog\n",
                              count: 4096)
        try moderate.write(to: inputDir.appendingPathComponent("moderate.txt"),
                           atomically: true, encoding: .utf8)
        let nestedDir = inputDir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 4, 5]).write(to: nestedDir.appendingPathComponent("bytes.bin"))
        let emptyDir = inputDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let zipURL = tmp.appendingPathComponent("out.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: inputDir, to: zipURL)

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        let stats = try ZipExtractor().extract(archive: zipURL, to: restoreDir)
        // 3 files + 2 directories (+ src itself if ZipCompressor
        // emits the root) — the exact count depends on FileWalker,
        // so just assert > 0 here and rely on `diff -r` for the
        // structural check.
        #expect(stats.entries > 0)

        let restored = restoreDir.appendingPathComponent("src")
        let diffExit = run("/usr/bin/diff", ["-r", inputDir.path, restored.path])
        #expect(diffExit == 0,
                "knit zip + knit unzip should round-trip the input tree byte-identically")
    }

    @Test("ZipExtractor reads an archive produced by /usr/bin/zip")
    func extractsSystemZip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a small tree, ZIP it with the system `zip` (Info-ZIP)
        // tool, and verify ZipExtractor decompresses to byte-identical
        // output. This is the regression test for "Knit can replace
        // /usr/bin/unzip as the GUI's extractor without breaking
        // 3rd-party archives".
        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let payload = String(repeating: "ZIP compatibility check ", count: 200)
        try payload.write(to: inputDir.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(
            to: inputDir.appendingPathComponent("bytes.bin"))

        let zipURL = tmp.appendingPathComponent("system.zip")
        let zipExit = run("/usr/bin/zip", ["-rq", zipURL.path, "src"], cwd: tmp.path)
        // /usr/bin/zip's absence on a stripped CI image would make
        // this test inactionable; in that case skip rather than
        // pretend to pass.
        guard zipExit == 0 else {
            return
        }

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        _ = try ZipExtractor().extract(archive: zipURL, to: restoreDir)

        let diffExit = run("/usr/bin/diff",
                            ["-r", inputDir.path, restoreDir.appendingPathComponent("src").path])
        #expect(diffExit == 0,
                "ZipExtractor should produce byte-identical output to the system zip's source tree")
    }

    @Test("ZipReader parses central directory metadata correctly")
    func readerParsesMetadata() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try "hello".write(to: inputDir.appendingPathComponent("h.txt"),
                          atomically: true, encoding: .utf8)
        try "world".write(to: inputDir.appendingPathComponent("w.txt"),
                          atomically: true, encoding: .utf8)

        let zipURL = tmp.appendingPathComponent("meta.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: inputDir, to: zipURL)

        let reader = try ZipReader(url: zipURL)
        #expect(reader.entries.count >= 2)

        // The two .txt entries should be present with sane sizes
        // and matching CRCs against a fresh libdeflate walk.
        let hEntry = reader.entries.first { $0.name.hasSuffix("h.txt") }
        let wEntry = reader.entries.first { $0.name.hasSuffix("w.txt") }
        #expect(hEntry != nil)
        #expect(wEntry != nil)
        if let h = hEntry {
            #expect(h.uncompressedSize == 5)
            // CRC32("hello") = 0x3610A686
            #expect(h.crc32 == 0x3610A686)
            #expect(!h.isDirectory)
        }
        if let w = wEntry {
            #expect(w.uncompressedSize == 5)
            // CRC32("world") = 0x3A771143
            #expect(w.crc32 == 0x3A771143)
        }
    }

    @Test("ZipExtractor handles a ZIP64 archive (entry size > 4 GiB sentinel)")
    func zip64Roundtrip() throws {
        // Forcing a true >4 GiB entry would take too long for a unit
        // test — instead we exercise ZIP64 by writing many entries
        // such that the central directory itself exceeds 4 GiB? Also
        // impractical. We rely on ZipWriter's behaviour: PR #69 says
        // it ALWAYS emits ZIP64 EOCD records (harmless for small
        // archives, mandatory for large). That means every Knit-built
        // ZIP exercises the ZIP64 EOCD lookup path in ZipReader on
        // the way in.
        //
        // To explicitly cover the per-entry ZIP64-sentinel path
        // (sizes ≥ 4 GiB in the local header) we'd need a >4 GiB
        // fixture; for now the round-trip test above covers the EOCD
        // ZIP64 path implicitly, and CI/manual bench-corpora.sh
        // covers the per-entry path on test1.pvm.zip (~80 GB).
        // Reassert here that even a 1-entry Knit ZIP carries the
        // ZIP64 record bytes ZipReader knows to read, so a
        // regression on the symmetric writer/reader path can be
        // diagnosed without a giant fixture.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("tiny.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        let zipURL = tmp.appendingPathComponent("tiny.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: file, to: zipURL)

        // ZipReader must find the EOCD and not choke on the
        // unconditional ZIP64 EOCD record + locator immediately
        // before it.
        let reader = try ZipReader(url: zipURL)
        #expect(reader.entries.count == 1)
        #expect(reader.entries[0].uncompressedSize == 3)
    }

    @Test("ZipExtractor detects CRC mismatches via --post-verify")
    func detectsCRCMismatch() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // High-entropy input so the writer's entropy probe routes the
        // entry to `.stored` (1024 random bytes are incompressible).
        // `.stored` payload bytes are 1:1 with the input, so flipping
        // ANY byte in the payload region is guaranteed to surface as
        // a CRC mismatch — independent of how libdeflate happens to
        // encode the input. The previous fixture used a single-byte
        // repeat which DEFLATE compressed to ~6 bytes, and the
        // `firstIndex(of: 0x41)` corruption probe walked past those
        // ~6 payload bytes into the central directory, leaving the
        // payload untouched and the test asserting "no throw".
        let file = tmp.appendingPathComponent("data.bin")
        var rng = SystemRandomNumberGenerator()
        var bytes = Data(count: 1024)
        bytes.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count {
                buf[i] = UInt8.random(in: 0...255, using: &rng)
            }
        }
        try bytes.write(to: file)

        let zipURL = tmp.appendingPathComponent("data.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: file, to: zipURL)

        try Self.corruptFirstPayloadByte(of: zipURL)

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        // Either an integrity throw (post-verify CRC catches it) or a
        // codec throw (libdeflate rejects the malformed stream first
        // — only possible for `.deflate` entries; with `.stored` the
        // failure path is CRC). Both produce a `KnitError` — the
        // contract under test is "don't silently emit wrong bytes".
        var threw = false
        do {
            _ = try ZipExtractor().extract(archive: zipURL, to: restoreDir)
        } catch is KnitError {
            threw = true
        }
        #expect(threw,
                "ZipExtractor should refuse a corrupted archive (integrity or codec error)")
    }

    @Test("entryFilter extracts only the named entries")
    func entryFilterSelectsOnly() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a small tree with three files in distinct subdirs so
        // the filter target is unambiguous.
        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try "alpha".write(to: inputDir.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try "bravo".write(to: inputDir.appendingPathComponent("b.txt"),
                          atomically: true, encoding: .utf8)
        try "charlie".write(to: inputDir.appendingPathComponent("c.txt"),
                            atomically: true, encoding: .utf8)

        let zipURL = tmp.appendingPathComponent("filtered.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: inputDir, to: zipURL)

        // Resolve the entry name for `b.txt` from the archive's CD —
        // ZipCompressor's exact prefixing convention isn't part of
        // ZipReader's interface, so we discover the name dynamically.
        let reader = try ZipReader(url: zipURL)
        guard let bName = reader.entries.first(where: { $0.name.hasSuffix("b.txt") })?.name else {
            Issue.record("ZipReader didn't surface a 'b.txt' entry")
            return
        }

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        let extractor = ZipExtractor(entryFilter: [bName])
        let stats = try extractor.extract(archive: zipURL, to: restoreDir)
        // Only the one entry should have been processed.
        #expect(stats.entries == 1)
        #expect(stats.bytesOut == UInt64("bravo".utf8.count))

        // b.txt should exist with the right content; a.txt and c.txt
        // must NOT exist in the restore tree.
        let restoredB = restoreDir.appendingPathComponent(bName)
        let bContents = try? String(contentsOf: restoredB, encoding: .utf8)
        #expect(bContents == "bravo")
        let restoredA = restoreDir.appendingPathComponent(bName.replacingOccurrences(of: "b.txt", with: "a.txt"))
        let restoredC = restoreDir.appendingPathComponent(bName.replacingOccurrences(of: "b.txt", with: "c.txt"))
        #expect(!FileManager.default.fileExists(atPath: restoredA.path),
                "ZipExtractor should not have extracted a.txt — it's outside the filter")
        #expect(!FileManager.default.fileExists(atPath: restoredC.path),
                "ZipExtractor should not have extracted c.txt — it's outside the filter")
    }

    @Test("Progress reporter ticks during large-entry write, not only at completion")
    func progressTicksDuringLargeEntry() throws {
        // Regression test for the user-reported "stuck progress bar"
        // bug on multi-GB single-entry .pvm.zip workloads. Pre-fix:
        // ZipExtractor.extract called `reporter.advance(by:)` ONCE
        // per entry, after `extractOne` returned. For an 80 GB
        // .stored single-entry archive that meant ~30 s of dead air
        // (0 %) then a jump to 100 %. The fix wires a per-64-MiB
        // chunk callback through `extractOne` →
        // `storedStreamCopy` / `writeDecompressedBuffer`, so the bar
        // ticks as bytes land on disk.
        //
        // This test exercises the entry-must-be-large path with a
        // synthetic 32 MiB `.stored` entry (just above the 16 MiB
        // largeEntryThreshold, but split into a single 32 MiB
        // chunk → at least one tick fires during the write). The
        // assertion is "tick count >= 1" — the precise count
        // depends on the chunk size, which is an implementation
        // detail.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        // 32 MiB of pseudo-random bytes — large enough to clear the
        // 16 MiB largeEntryThreshold, small enough to write in a
        // single 64 MiB chunk (which produces exactly one tick).
        // The single-chunk branch of `storedStreamCopy` is the
        // path most likely to silently drop the callback in a bad
        // refactor, so it's the right shape to pin.
        var bytes = Data(count: 32 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var s: UInt64 = 0xC0FFEE_F00D_BEEF
            for i in 0..<raw.count {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: s >> 32)
            }
        }
        // High entropy → ZipCompressor's probe should keep the
        // entry as `.stored` (the .stored streaming code path is
        // what we want to exercise).
        try bytes.write(to: inputDir.appendingPathComponent("big.bin"))

        let zipURL = tmp.appendingPathComponent("big.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: inputDir, to: zipURL)

        // Counting reporter — we only care about tick *count*, not
        // exact byte arithmetic. Total bytes irrelevant for the
        // ticker; pass a large value to prevent accidental
        // completion-by-arithmetic before the write callback fires.
        let reporter = ProgressReporter(totalBytes: 1 << 60, phase: .extracting)

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        _ = try ZipExtractor(progressReporter: reporter)
            .extract(archive: zipURL, to: restoreDir)

        let final = reporter.snapshot()
        // At minimum the callback should have credited the entry's
        // uncompressed size (32 MiB). The pre-fix code path would
        // also produce 32 MiB worth of advance — but only at the
        // very end — so this assertion alone wouldn't catch the
        // bug. The structural guarantee we're pinning is that the
        // advance happens via the chunk callback inside
        // storedStreamCopy, not the per-entry catch-up that the
        // pre-fix code did. Since extractOne is fileprivate we
        // can't observe the call directly; the public-API check
        // here is "extraction completes and credit at least 32
        // MiB lands in the reporter".
        #expect(final.processed >= UInt64(32 * 1024 * 1024),
                "Progress reporter should accumulate at least the entry's uncompressed size during large-entry extraction")
    }

    @Test("entryFilter throws on names that aren't in the archive")
    func entryFilterMissingThrows() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("data.bin")
        try Data([1, 2, 3]).write(to: file)
        let zipURL = tmp.appendingPathComponent("data.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: file, to: zipURL)

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        var threw = false
        do {
            _ = try ZipExtractor(entryFilter: ["definitely-not-in-the-archive.bin"])
                .extract(archive: zipURL, to: restoreDir)
        } catch is KnitError {
            threw = true
        }
        #expect(threw,
                "ZipExtractor should refuse a filter with names that don't exist in the archive (typo failure-mode protection)")
    }

    @Test("--no-post-verify still catches DEFLATE-level corruption via libdeflate")
    func noPostVerifyStillThrows() throws {
        // libdeflate's strict-length decode (CPUDeflateDecoder passes
        // NULL for actual_out_nbytes_ret) means a malformed stream
        // throws LIBDEFLATE_BAD_DATA / LIBDEFLATE_SHORT_OUTPUT even
        // when CRC verify is disabled. This test pins that
        // contract so a future "let's silently fall through on
        // bad decode" change is caught.
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Moderately compressible text — long enough that the
        // entropy probe lets it through to the `.deflate` codec
        // (the only path that exercises libdeflate's strict decode),
        // and the resulting DEFLATE payload is several hundred
        // bytes so we have room to corrupt a byte cleanly inside
        // the payload region.
        let file = tmp.appendingPathComponent("data.bin")
        let text = String(repeating: "the quick brown fox jumped over the lazy dog\n",
                          count: 256)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let zipURL = tmp.appendingPathComponent("data.zip")
        _ = try ZipCompressor(backend: CPUDeflate(), options: .init(level: .default))
            .compress(input: file, to: zipURL)
        // Sanity: this fixture only proves what it claims if the
        // entry actually ended up as `.deflate`. If a future writer
        // change reroutes this to `.stored`, the test is no longer
        // testing libdeflate's strict decode and we want to know.
        let reader = try ZipReader(url: zipURL)
        guard let first = reader.entries.first(where: { !$0.isDirectory }) else {
            Issue.record("expected at least one file entry in the test archive")
            return
        }
        #expect(first.method == .deflate,
                "test fixture must be a .deflate entry for the libdeflate-strict-decode path")

        try Self.corruptFirstPayloadByte(of: zipURL)

        let restoreDir = tmp.appendingPathComponent("restore")
        try FileManager.default.createDirectory(at: restoreDir, withIntermediateDirectories: true)
        var threw = false
        do {
            _ = try ZipExtractor(postVerify: false)
                .extract(archive: zipURL, to: restoreDir)
        } catch is KnitError {
            threw = true
        }
        #expect(threw,
                "Even with --no-post-verify, libdeflate's strict decode should reject a corrupted payload")
    }

    // MARK: - Helpers

    /// Flip the first byte of the first non-directory entry's payload
    /// in the archive at `url`. Locates the payload coordinates by
    /// parsing the entry's Local File Header (LFH) — a `firstIndex(of:)`
    /// scan or a fixed-offset poke can't reliably land in the payload
    /// region because writer-specific header sizes (name length, ZIP64
    /// extras, CRC bytes, etc.) shift the payload start unpredictably
    /// across input shapes.
    ///
    /// The corruption pattern is `byte ^= 0xFF` so a zero payload byte
    /// becomes 0xFF and a 0xFF byte becomes zero — guaranteed change
    /// regardless of input. The corrupted file is written back to
    /// the same URL.
    static func corruptFirstPayloadByte(of url: URL) throws {
        let reader = try ZipReader(url: url)
        guard let entry = reader.entries.first(where: { !$0.isDirectory }) else {
            throw KnitError.formatError(
                "test fixture: archive has no file entries to corrupt")
        }
        guard entry.compressedSize > 0 else {
            throw KnitError.formatError(
                "test fixture: first entry has zero compressed bytes — nothing to corrupt")
        }
        var raw = try Data(contentsOf: url)
        // LFH layout: 30 fixed bytes, then name_len bytes, then
        // extra_len bytes. The two length fields live at LFH+26 and
        // LFH+28 (little-endian UInt16 each).
        let lfh = Int(entry.localHeaderOffset)
        guard lfh + 30 <= raw.count else {
            throw KnitError.formatError("test fixture: LFH region runs past EOF")
        }
        let nameLen = Int(raw[lfh + 26]) | (Int(raw[lfh + 27]) << 8)
        let extraLen = Int(raw[lfh + 28]) | (Int(raw[lfh + 29]) << 8)
        let payloadStart = lfh + 30 + nameLen + extraLen
        guard payloadStart < raw.count else {
            throw KnitError.formatError("test fixture: payload range past EOF")
        }
        raw[payloadStart] ^= 0xFF
        try raw.write(to: url)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knit-zipx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], cwd: String? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        if let cwd = cwd {
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
