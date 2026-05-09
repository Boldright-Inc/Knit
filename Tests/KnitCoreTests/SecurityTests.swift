import XCTest
import Foundation
@testable import KnitCore

/// Regression tests for security-sensitive code paths in KnitCore.
final class SecurityTests: XCTestCase {

    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knit-sec-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - SafePath

    func testSafePathRejectsAbsolute() throws {
        let dest = try makeTempDir("abs")
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try SafePath.resolve(name: "/etc/passwd", into: dest))
    }

    func testSafePathRejectsDotDot() throws {
        let dest = try makeTempDir("dotdot")
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try SafePath.resolve(name: "../escape", into: dest))
        XCTAssertThrowsError(try SafePath.resolve(name: "a/../../escape", into: dest))
        XCTAssertThrowsError(try SafePath.resolve(name: "a/b/../../../escape", into: dest))
    }

    func testSafePathRejectsNULAndEmpty() throws {
        let dest = try makeTempDir("nul")
        defer { try? FileManager.default.removeItem(at: dest) }
        XCTAssertThrowsError(try SafePath.resolve(name: "", into: dest))
        XCTAssertThrowsError(try SafePath.resolve(name: "ok\0name", into: dest))
    }

    func testSafePathAcceptsNormalNames() throws {
        let dest = try makeTempDir("ok")
        defer { try? FileManager.default.removeItem(at: dest) }
        let resolved = try SafePath.resolve(name: "sub/dir/file.txt", into: dest)
        XCTAssertTrue(resolved.path.hasPrefix(dest.standardizedFileURL.path),
                      "resolved path must live under dest: \(resolved.path)")
    }

    // MARK: - KnitReader malformed archives

    /// Build the smallest possible .knit with one entry, given caller-controlled
    /// header fields. Skips writing zstd payload bytes when `compressedSize==0`.
    private func makeKnit(
        entryName: String,
        blockSize: UInt32,
        uncompressedSize: UInt64,
        compressedSize: UInt64,
        numBlocks: UInt32,
        payload: Data = Data()
    ) -> Data {
        var d = Data()
        // Header
        d.appendLE(KnitFormat.headerMagic)
        d.appendLE(KnitFormat.version)
        d.appendLE(UInt16(0))       // flags
        d.appendLE(UInt64(0))       // reserved
        // Entry
        d.appendLE(KnitFormat.entryMarker)
        let nameBytes = Array(entryName.utf8)
        d.appendLE(UInt16(nameBytes.count))
        d.append(contentsOf: nameBytes)
        d.appendLE(UInt16(0o644))   // mode
        d.appendLE(UInt64(0))       // mod_unix
        d.appendLE(UInt8(0))        // is_directory
        d.appendLE(blockSize)
        d.appendLE(uncompressedSize)
        d.appendLE(compressedSize)
        d.appendLE(UInt32(0))       // crc32
        d.appendLE(numBlocks)
        for _ in 0..<numBlocks { d.appendLE(UInt32(0)) }
        d.append(payload)
        // Footer
        d.appendLE(KnitFormat.footerMarker)
        d.appendLE(UInt64(1))
        d.appendLE(KnitFormat.archiveVersion)
        return d
    }

    func testReaderRejectsCompressedSizeOutOfRange() throws {
        let archive = makeKnit(
            entryName: "f",
            blockSize: 1024,
            uncompressedSize: 0,
            compressedSize: UInt64.max,   // hostile: exceeds Int.max
            numBlocks: 0
        )
        let path = try makeTempDir("compsize").appendingPathComponent("a.knit")
        try archive.write(to: path)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        XCTAssertThrowsError(try KnitReader(url: path)) { err in
            guard case KnitError.formatError = err else {
                return XCTFail("expected formatError, got \(err)")
            }
        }
    }

    func testReaderRejectsBlockSizeAboveCap() throws {
        let archive = makeKnit(
            entryName: "f",
            blockSize: KnitFormat.maxBlockSize &+ 1,
            uncompressedSize: 0,
            compressedSize: 0,
            numBlocks: 0
        )
        let path = try makeTempDir("blocksize").appendingPathComponent("a.knit")
        try archive.write(to: path)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        XCTAssertThrowsError(try KnitReader(url: path)) { err in
            guard case KnitError.formatError = err else {
                return XCTFail("expected formatError, got \(err)")
            }
        }
    }

    func testExtractorRejectsZipSlipName() throws {
        let archive = makeKnit(
            entryName: "../../../tmp/knit-pwned",
            blockSize: 0,
            uncompressedSize: 0,
            compressedSize: 0,
            numBlocks: 0
        )
        let dir = try makeTempDir("slip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archivePath = dir.appendingPathComponent("a.knit")
        try archive.write(to: archivePath)

        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try KnitExtractor().extract(archive: archivePath, to: outDir)) { err in
            guard case KnitError.formatError = err else {
                return XCTFail("expected formatError, got \(err)")
            }
        }
        // Ensure no escape file was created
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/knit-pwned"))
    }

    // MARK: - Empty file roundtrip

    /// F6 regression: ZipCompressor used to force-unwrap `buf.baseAddress!`
    /// for empty files, which crashes because `MappedFile.buffer` returns
    /// `start: nil` for zero-length files.
    func testZipCompressorHandlesEmptyFile() throws {
        let dir = try makeTempDir("zip-empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputDir = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try Data().write(to: inputDir.appendingPathComponent("empty.bin"))
        try Data("hi".utf8).write(to: inputDir.appendingPathComponent("hi.txt"))

        let archive = dir.appendingPathComponent("out.zip")
        let opts = ZipCompressor.Options(level: .default, concurrency: 1)
        let stats = try ZipCompressor(backend: CPUDeflate(), options: opts)
            .compress(input: inputDir, to: archive)
        XCTAssertGreaterThan(stats.entriesWritten, 0)
        XCTAssertGreaterThan(stats.bytesOut, 0)
    }

    func testEmptyFilePackUnpackRoundtrip() throws {
        let dir = try makeTempDir("empty")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputDir = dir.appendingPathComponent("in")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let emptyFile = inputDir.appendingPathComponent("empty.bin")
        try Data().write(to: emptyFile)
        let regularFile = inputDir.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: regularFile)

        let archive = dir.appendingPathComponent("out.knit")
        let opts = KnitCompressor.Options(level: .default, concurrency: 1, blockSize: 1024)
        let stats = try KnitCompressor(backend: CPUZstd(), options: opts)
            .compress(input: inputDir, to: archive)
        XCTAssertGreaterThan(stats.entriesWritten, 0)

        let outDir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = try KnitExtractor().extract(archive: archive, to: outDir)

        // Verify both files round-tripped.
        let extractedEmpty = outDir.appendingPathComponent("in").appendingPathComponent("empty.bin")
        let extractedHello = outDir.appendingPathComponent("in").appendingPathComponent("hello.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extractedEmpty.path))
        XCTAssertEqual(try Data(contentsOf: extractedEmpty), Data())
        XCTAssertEqual(try Data(contentsOf: extractedHello), Data("hello".utf8))
    }

    // MARK: - Symlink skip

    func testFileWalkerSkipsSymlinks() throws {
        let dir = try makeTempDir("link")
        defer { try? FileManager.default.removeItem(at: dir) }

        let real = dir.appendingPathComponent("real.txt")
        try Data("real".utf8).write(to: real)

        // Create an absolute-target symlink that points OUTSIDE the input tree.
        let outsideTarget = dir.appendingPathComponent("..").standardizedFileURL
            .appendingPathComponent("knit-walker-outside-\(UUID().uuidString).txt")
        try Data("outside".utf8).write(to: outsideTarget)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideTarget)

        let entries = try FileWalker.enumerate(dir)
        let names = entries.map { $0.relativePath }
        XCTAssertTrue(names.contains { $0.hasSuffix("real.txt") })
        XCTAssertFalse(names.contains { $0.hasSuffix("link.txt") },
                       "symlinks must not appear in the entry list")
    }
}
