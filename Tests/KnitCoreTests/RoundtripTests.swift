import Testing
import Foundation
@testable import KnitCore

@Suite("Knit roundtrip and codec tests")
struct RoundtripTests {

    @Test("ZIP round-trips a small file via system unzip")
    func zipRoundtripSingleFile() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("hello.txt")
        let payload = String(repeating: "hello, Knit! ", count: 1000)
        try payload.write(to: input, atomically: true, encoding: .utf8)

        let zipURL = tmp.appendingPathComponent("out.zip")
        let compressor = ZipCompressor(backend: CPUDeflate(),
                                       options: .init(level: .default))
        let stats = try compressor.compress(input: input, to: zipURL)
        #expect(stats.entriesWritten == 1)
        #expect(stats.bytesIn == UInt64(payload.utf8.count))

        // Verify with system unzip.
        let unzipExit = run("/usr/bin/unzip", ["-tq", zipURL.path])
        #expect(unzipExit == 0)
    }

    @Test("Parallel DEFLATE produces a valid stream that unzip accepts")
    func parallelDeflateRoundtrip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let input = tmp.appendingPathComponent("big.bin")
        let bytes = Data(repeating: 0x42, count: 8 * 1024 * 1024) // 8 MB of B
        try bytes.write(to: input)

        let zipURL = tmp.appendingPathComponent("out.zip")
        let backend = ParallelDeflate(chunkSize: 256 * 1024, concurrency: 4)
        let compressor = ZipCompressor(backend: backend, options: .init(level: .default))
        let stats = try compressor.compress(input: input, to: zipURL)
        #expect(stats.entriesWritten == 1)

        let unzipExit = run("/usr/bin/unzip", ["-tq", zipURL.path])
        #expect(unzipExit == 0)
    }

    @Test(".knit round-trips byte-identically")
    func bzxRoundtrip() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        for i in 0..<3 {
            let f = inputDir.appendingPathComponent("file_\(i).bin")
            let payload = Data(repeating: UInt8(i), count: 64 * 1024 + i)
            try payload.write(to: f)
        }

        let bzxURL = tmp.appendingPathComponent("out.knit")
        let comp = KnitCompressor(backend: CPUZstd(), options: .init(blockSize: 32 * 1024))
        _ = try comp.compress(input: inputDir, to: bzxURL)

        let restoreDir = tmp.appendingPathComponent("restore")
        _ = try KnitExtractor().extract(archive: bzxURL, to: restoreDir)

        let diffExit = run("/usr/bin/diff", ["-r", inputDir.path, restoreDir.appendingPathComponent("src").path])
        #expect(diffExit == 0)
    }

    @Test("CRC32 matches libdeflate against known vector")
    func crc32KnownVector() {
        // CRC32(IEEE) of "123456789" = 0xCBF43926
        let s = "123456789"
        let bytes = Array(s.utf8)
        let crc = bytes.withUnsafeBufferPointer { buf in
            CPUDeflate().crc32(buf, seed: 0)
        }
        #expect(crc == 0xCBF43926)
    }

    @Test("Metal CRC32 (when available) agrees with CPU CRC32")
    func metalCRC32MatchesCPU() throws {
        guard let gpu = MetalCRC32() else {
            // Allow CI environments without Metal.
            return
        }
        var data = Data(count: 1 * 1024 * 1024)
        for i in 0..<data.count { data[i] = UInt8(i & 0xFF) }
        let cpu = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let buf = UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: raw.count)
            return CPUDeflate().crc32(buf, seed: 0)
        }
        let gpuVal = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
            let buf = UnsafeBufferPointer(
                start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                count: raw.count)
            return try gpu.crc32(buf)
        }
        #expect(cpu == gpuVal)
    }

    // MARK: helpers

    private func makeTempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("knit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
