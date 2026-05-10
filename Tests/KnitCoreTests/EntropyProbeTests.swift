import XCTest
import Foundation
@testable import KnitCore

/// Verifies the entropy probe (CPU and GPU paths) produces correct
/// Shannon-entropy estimates and that the GPU and CPU implementations agree.
final class EntropyProbeTests: XCTestCase {

    // MARK: - Math correctness

    func testShannonEntropyForUniform() {
        // 256 distinct bytes, exactly equal counts -> entropy = 8 bits/byte.
        var bytes = [UInt8]()
        bytes.reserveCapacity(256)
        for i in 0..<256 { bytes.append(UInt8(i)) }
        bytes.withUnsafeBufferPointer { buf in
            let h = EntropyMath.shannonEntropy(of: buf.baseAddress!, count: buf.count)
            XCTAssertEqual(h, 8.0, accuracy: 0.001)
        }
    }

    func testShannonEntropyForSingleByte() {
        // All bytes the same -> entropy = 0.
        let bytes = [UInt8](repeating: 0x42, count: 4096)
        bytes.withUnsafeBufferPointer { buf in
            let h = EntropyMath.shannonEntropy(of: buf.baseAddress!, count: buf.count)
            XCTAssertEqual(h, 0.0, accuracy: 0.001)
        }
    }

    func testShannonEntropyForBinary() {
        // Two values, equal frequency -> entropy = 1 bit/byte.
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in 0..<bytes.count where i.isMultiple(of: 2) { bytes[i] = 1 }
        bytes.withUnsafeBufferPointer { buf in
            let h = EntropyMath.shannonEntropy(of: buf.baseAddress!, count: buf.count)
            XCTAssertEqual(h, 1.0, accuracy: 0.001)
        }
    }

    // MARK: - CPU probe

    func testCPUProbeMultipleBlocks() throws {
        // 3 blocks: each filled with constant -> entropy = 0 each.
        let blockSize = 1024
        var bytes = [UInt8]()
        for v: UInt8 in [0xAA, 0xBB, 0xCC] {
            bytes.append(contentsOf: [UInt8](repeating: v, count: blockSize))
        }
        let cpu = CPUEntropyProbe()
        let results = try bytes.withUnsafeBufferPointer { buf in
            try cpu.probe(buf, blockSize: blockSize)
        }
        XCTAssertEqual(results.count, 3)
        for r in results {
            XCTAssertEqual(r.entropy, 0.0, accuracy: 0.001)
            XCTAssertEqual(r.byteCount, blockSize)
            XCTAssertFalse(r.isLikelyIncompressible)
        }
    }

    func testCPUProbeRandomIsIncompressible() throws {
        // Pseudo-random pattern (not cryptographically random but high
        // enough entropy to clear the threshold).
        let n = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: n)
        var seed: UInt64 = 0xDEAD_BEEF_CAFE_BABE
        for i in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 32)
        }
        let cpu = CPUEntropyProbe()
        let result = try bytes.withUnsafeBufferPointer { buf in
            try cpu.probeWhole(buf)
        }
        XCTAssertGreaterThan(result.entropy, 7.5)
        XCTAssertTrue(result.isLikelyIncompressible)
    }

    // MARK: - GPU vs CPU agreement

    func testGPUAgreesWithCPU() throws {
        guard let gpu = MetalEntropyProbe() else {
            throw XCTSkip("No Metal device on this host")
        }
        let cpu = CPUEntropyProbe()

        // Mix of compressible (text-like) and incompressible (PRNG) data.
        let blockSize = 64 * 1024
        let numBlocks = 8
        var bytes = [UInt8](repeating: 0, count: blockSize * numBlocks)
        var seed: UInt64 = 0xC0FFEE_42_DEAD_BEEF
        for blk in 0..<numBlocks {
            let off = blk * blockSize
            if blk.isMultiple(of: 2) {
                // Constant block — entropy near 0
                for i in 0..<blockSize { bytes[off + i] = UInt8(blk) }
            } else {
                // PRNG block — entropy near 8
                for i in 0..<blockSize {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    bytes[off + i] = UInt8(truncatingIfNeeded: seed >> 32)
                }
            }
        }

        let cpuResults = try bytes.withUnsafeBufferPointer { buf in
            try cpu.probe(buf, blockSize: blockSize)
        }
        let gpuResults = try bytes.withUnsafeBufferPointer { buf in
            try gpu.probe(buf, blockSize: blockSize)
        }

        XCTAssertEqual(cpuResults.count, gpuResults.count)
        for (c, g) in zip(cpuResults, gpuResults) {
            XCTAssertEqual(c.byteCount, g.byteCount)
            XCTAssertEqual(c.entropy, g.entropy, accuracy: 0.005,
                           "GPU/CPU entropy mismatch: cpu=\(c.entropy) gpu=\(g.entropy)")
        }
    }

    func testZeroLengthBuffer() throws {
        let cpu = CPUEntropyProbe()
        let empty: [UInt8] = []
        let r = try empty.withUnsafeBufferPointer { try cpu.probe($0, blockSize: 1024) }
        XCTAssertTrue(r.isEmpty)
    }

    func testRaggedFinalBlock() throws {
        // Final block is shorter than blockSize.
        let blockSize = 1024
        let total = blockSize * 2 + 100
        var bytes = [UInt8](repeating: 0, count: total)
        for i in 0..<total { bytes[i] = UInt8(i & 0xFF) }
        let results = try bytes.withUnsafeBufferPointer { buf in
            try CPUEntropyProbe().probe(buf, blockSize: blockSize)
        }
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].byteCount, blockSize)
        XCTAssertEqual(results[1].byteCount, blockSize)
        XCTAssertEqual(results[2].byteCount, 100)
    }

    // MARK: - Parallel vs serial parity

    /// `CPUEntropyProbe` parallelises across blocks via `concurrentMap`
    /// when there are ≥ 4 blocks. The parallel and serial paths must
    /// produce byte-identical `[EntropyResult]` — same per-block
    /// `byteCount` AND same per-block `entropy` Float bits — otherwise
    /// the lvl=1 downgrade decisions inside
    /// `StreamingBlockCompressor` could diverge between fallback runs
    /// and PR #23's GPU path.
    func testCPUProbeParallelMatchesSerial() throws {
        // Mixed-content payload across 32 blocks: half text-ish (low
        // entropy), half pseudo-random (high entropy). 32 blocks > the
        // 4-block parallel threshold so the parallel path is exercised.
        let blockSize = 64 * 1024
        let numBlocks = 32
        let total = blockSize * numBlocks
        var bytes = [UInt8](repeating: 0, count: total)
        var seed: UInt64 = 0xA5A5_DEAD_BEEF_C0DE
        for i in 0..<total {
            if (i / blockSize) % 2 == 0 {
                bytes[i] = UInt8(0x40 &+ (i & 0x3F))
            } else {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[i] = UInt8(truncatingIfNeeded: seed >> 32)
            }
        }

        let serial = try bytes.withUnsafeBufferPointer { buf in
            try CPUEntropyProbe(concurrency: 1).probe(buf, blockSize: blockSize)
        }
        let parallel = try bytes.withUnsafeBufferPointer { buf in
            try CPUEntropyProbe(concurrency: 8).probe(buf, blockSize: blockSize)
        }

        XCTAssertEqual(serial.count, numBlocks)
        XCTAssertEqual(parallel.count, numBlocks)
        for i in 0..<numBlocks {
            XCTAssertEqual(serial[i].byteCount, parallel[i].byteCount,
                           "byteCount differs at block \(i)")
            // Float bit-for-bit equality: same input bytes through the
            // same `EntropyMath` math must produce the same Float.
            XCTAssertEqual(serial[i].entropy, parallel[i].entropy,
                           "entropy differs at block \(i): " +
                           "serial=\(serial[i].entropy), parallel=\(parallel[i].entropy)")
        }
    }

    /// Below the parallelism threshold the serial path is used. This
    /// pins the threshold's effect: a 3-block input takes the
    /// historical serial loop, not concurrentMap dispatch.
    func testCPUProbeSerialPathBelowThreshold() throws {
        let blockSize = 1024
        let total = blockSize * 3
        var bytes = [UInt8](repeating: 0, count: total)
        for i in 0..<total { bytes[i] = UInt8(i & 0xFF) }
        let results = try bytes.withUnsafeBufferPointer { buf in
            try CPUEntropyProbe(concurrency: 8).probe(buf, blockSize: blockSize)
        }
        XCTAssertEqual(results.count, 3)
        for r in results {
            XCTAssertEqual(r.byteCount, blockSize)
        }
    }
}
