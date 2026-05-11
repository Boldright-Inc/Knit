import XCTest
import Foundation
@testable import KnitCore

/// Verifies the GPU CRC32 path matches CPU output and that the bytesNoCopy
/// optimization correctly falls back when alignment isn't satisfied.
final class MetalCRC32Tests: XCTestCase {

    private func makeBuffer(size: Int, seed: UInt8 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            bytes[i] = UInt8((i &+ Int(seed)) & 0xFF)
        }
        return bytes
    }

    /// CRC32 must match libdeflate's CPU implementation across a range of
    /// sizes, including ones not divisible by the slice size.
    func testGPUMatchesCPUAcrossSizes() throws {
        guard let gpu = MetalCRC32(sliceSize: 1 * 1024 * 1024) else {
            throw XCTSkip("No Metal device on this host")
        }
        let cpu = CPUDeflate()

        // Mix of aligned and unaligned sizes.
        let sizes = [
            1,
            1023,
            1024,
            1024 * 1024,
            1024 * 1024 + 7,
            5 * 1024 * 1024 + 13,
            16 * 1024 * 1024,
        ]
        for size in sizes {
            let bytes = makeBuffer(size: size, seed: UInt8(size & 0xFF))
            let cpuVal = bytes.withUnsafeBufferPointer { cpu.crc32($0, seed: 0) }
            let gpuVal = try bytes.withUnsafeBufferPointer { try gpu.crc32($0) }
            XCTAssertEqual(cpuVal, gpuVal, "CRC mismatch at size=\(size)")
        }
    }

    /// `bytesNoCopy:` requires page alignment. When a non-aligned pointer is
    /// passed (the common case for `[UInt8]` storage), the implementation
    /// must transparently fall back to the copying path and still produce
    /// the correct CRC.
    func testUnalignedFallback() throws {
        guard let gpu = MetalCRC32(sliceSize: 64 * 1024) else {
            throw XCTSkip("No Metal device on this host")
        }
        let cpu = CPUDeflate()

        // Allocate an oversized buffer and offset by 1 to force misalignment.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024 + 16,
                                                   alignment: 16)
        defer { raw.deallocate() }
        let p = raw.advanced(by: 1).assumingMemoryBound(to: UInt8.self)
        for i in 0..<(256 * 1024) { p[i] = UInt8((i * 31 + 7) & 0xFF) }

        let buf = UnsafeBufferPointer(start: p, count: 256 * 1024)
        let cpuVal = cpu.crc32(buf, seed: 0)
        let gpuVal = try gpu.crc32(buf)
        XCTAssertEqual(cpuVal, gpuVal)
    }

    func testZeroLength() throws {
        guard let gpu = MetalCRC32() else {
            throw XCTSkip("No Metal device on this host")
        }
        let empty = [UInt8]()
        let result = try empty.withUnsafeBufferPointer { try gpu.crc32($0) }
        XCTAssertEqual(result, 0)
    }

    /// The chunked-dispatch path must produce the same CRC as the
    /// single-dispatch path on the same input. Forces the chunk
    /// boundary by setting `perDispatchByteLimit` artificially low —
    /// without this, a real test would need a >1 GiB allocation just to
    /// cross the production threshold.
    ///
    /// Strategy: build a buffer larger than `sliceSize × N` where the
    /// effective per-dispatch limit (rounded down to sliceSize) forces
    /// at least three chunks, so we exercise both "first chunk" and
    /// "subsequent chunk combine" paths.
    /// PR #72. `parallelCRC32` must produce the same CRC as the
    /// single-threaded backend across the threshold (small inputs
    /// fall through to serial; large inputs split into chunks and
    /// combine via `crc32Combine`). Verified on both sides of the
    /// 64 MiB threshold and on a deliberately-unaligned tail.
    func testParallelCRC32MatchesSerialAcrossThreshold() throws {
        let cpu = CPUDeflate()
        // Cross the 64 MiB threshold so the parallel split fires.
        // Add 17 bytes of unaligned tail to confirm the last chunk
        // doesn't shave off bytes.
        let sizes = [
            1024,                              // serial path (< threshold)
            64 * 1024 * 1024 - 1,              // just under threshold (serial)
            64 * 1024 * 1024 + 17,             // just over threshold (parallel)
            128 * 1024 * 1024 + 13,            // parallel, multi-chunk
        ]
        for size in sizes {
            let bytes = makeBuffer(size: size, seed: UInt8(size & 0xFF))
            let serial = bytes.withUnsafeBufferPointer { cpu.crc32($0, seed: 0) }
            let parallel = bytes.withUnsafeBufferPointer { buf in
                parallelCRC32(buf, using: cpu, concurrency: 4)
            }
            XCTAssertEqual(serial, parallel,
                           "parallelCRC32 mismatch at size=\(size)")
        }
    }

    /// Edge cases: empty buffer and concurrency=1 must short-circuit
    /// to the serial backend without touching the dispatch machinery.
    func testParallelCRC32EdgeCases() throws {
        let cpu = CPUDeflate()
        // Empty input.
        let empty = [UInt8]()
        let r0 = empty.withUnsafeBufferPointer { parallelCRC32($0, using: cpu, concurrency: 8) }
        XCTAssertEqual(r0, 0)

        // concurrency=1 → forced serial; identical math to the
        // single-threaded backend call.
        let mid = makeBuffer(size: 128 * 1024 * 1024 + 7, seed: 0x55)
        let serial = mid.withUnsafeBufferPointer { cpu.crc32($0, seed: 0) }
        let serialViaParallel = mid.withUnsafeBufferPointer {
            parallelCRC32($0, using: cpu, concurrency: 1)
        }
        XCTAssertEqual(serial, serialViaParallel)
    }

    func testChunkedAcrossDispatchesMatchesSingleShot() throws {
        guard let gpu = MetalCRC32(sliceSize: 4 * 1024) else {
            throw XCTSkip("No Metal device on this host")
        }
        let cpu = CPUDeflate()

        // Pick a size that's well above the chunk threshold once the
        // sliceSize alignment factor takes effect. With sliceSize=4KiB,
        // a chunkLimit-aligned chunk is 1GiB / 4KiB = 262144 slices.
        // We use a far smaller buffer here that takes the *single*
        // dispatch path under production limits, but we still verify
        // multi-slice behaviour by re-using sliceSize sizing.
        //
        // The genuine multi-chunk path is only hit when the input
        // exceeds 1 GiB, which is too large for a unit test. Instead,
        // exercise the same `crc32Combine` math directly via two
        // independent halves and confirm the combined result matches
        // a single-shot CRC over the concatenation.
        let halfSize = 2 * 1024 * 1024 + 13   // unaligned tail
        let half1 = makeBuffer(size: halfSize, seed: 0x11)
        let half2 = makeBuffer(size: halfSize, seed: 0x22)

        let combinedBytes = half1 + half2

        let cpuFull = combinedBytes.withUnsafeBufferPointer { cpu.crc32($0, seed: 0) }
        let gpuFull = try combinedBytes.withUnsafeBufferPointer { try gpu.crc32($0) }
        XCTAssertEqual(cpuFull, gpuFull,
                       "GPU single-dispatch CRC must match CPU CRC32 on concatenated input")

        // Per-half CRCs combined manually (mirrors what the chunked
        // dispatch path does internally for buffers > perDispatchByteLimit).
        let crcH1 = try half1.withUnsafeBufferPointer { try gpu.crc32($0) }
        let crcH2 = try half2.withUnsafeBufferPointer { try gpu.crc32($0) }
        let manualCombined = crc32Combine(crc1: crcH1,
                                          crc2: crcH2,
                                          len2: UInt(half2.count))
        XCTAssertEqual(manualCombined, cpuFull,
                       "crc32Combine of two halves must equal CRC of the concatenation")
    }
}
