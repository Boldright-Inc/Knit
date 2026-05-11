import XCTest
import Foundation
@testable import KnitCore

/// Smoke tests for the per-chunk progress callback wired into
/// `ParallelDeflate.compress(_:level:onProgress:)` (PR #54).
///
/// User report: `knit zip --progress` of a single large file showed 0 %
/// for the entire codec pass, then jumped to 100 % at the end. Root
/// cause was `ZipCompressor.prepare` calling `reporter?.advance` only
/// once per entry — the bar's intermediate states never fired because
/// `backend.compress(_:level:)` is a single black-box call per entry,
/// not a per-chunk loop. The fix added a new
/// `compress(_:level:onProgress:)` protocol method that the parallel
/// backend overrides to fire the callback after each chunk completes.
///
/// These tests verify the callback shape without going through the
/// printer thread (which polls at 0.5 s and can't see sub-second
/// operations on an M5 Max). The callback firing is the bug surface;
/// whether the printer renders the intermediate state is a separate
/// timing concern.
final class ParallelDeflateProgressTests: XCTestCase {

    /// Highly compressible 16 MiB input with a 1 MiB chunk size should
    /// fire the callback 16 times — one per chunk — and the bytes
    /// summed across calls must equal the input size.
    func testParallelDeflateFiresProgressPerChunk() throws {
        // 16 MiB of zeros — chunkSize defaults to 1 MiB.
        let inputSize = 16 * 1024 * 1024
        let input = Data(repeating: 0, count: inputSize)
        let backend = ParallelDeflate(chunkSize: 1 * 1024 * 1024, concurrency: 4)

        let acc = ProgressAccumulator()
        _ = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let typed = raw.bindMemory(to: UInt8.self)
            return try backend.compress(typed, level: 6) { bytes in
                acc.record(bytes)
            }
        }
        let (callCount, totalBytes) = acc.snapshot()

        XCTAssertEqual(callCount, 16,
                       "ParallelDeflate should fire onProgress once per chunk")
        XCTAssertEqual(totalBytes, UInt64(inputSize),
                       "Sum of per-chunk byte counts should equal input.count")
    }

    /// Even with a single chunk (input smaller than chunkSize), the
    /// callback must still fire once — otherwise small entries
    /// wouldn't tick at all under the new wiring.
    func testParallelDeflateFiresProgressOnSingleChunk() throws {
        let inputSize = 64 * 1024  // 64 KiB, below the 1 MiB chunk size
        let input = Data(repeating: 0x41, count: inputSize)
        let backend = ParallelDeflate(chunkSize: 1 * 1024 * 1024, concurrency: 4)

        let acc = ProgressAccumulator()
        _ = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let typed = raw.bindMemory(to: UInt8.self)
            return try backend.compress(typed, level: 6) { bytes in
                acc.record(bytes)
            }
        }
        let (callCount, totalBytes) = acc.snapshot()

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(totalBytes, UInt64(inputSize))
    }

    /// Empty input: backend short-circuits to an empty result. The
    /// callback must not fire (no work happened).
    func testParallelDeflateNoProgressOnEmptyInput() throws {
        let backend = ParallelDeflate(chunkSize: 1 * 1024 * 1024, concurrency: 4)
        let acc = ProgressAccumulator()
        let empty = [UInt8]()
        _ = try empty.withUnsafeBufferPointer { typed in
            try backend.compress(typed, level: 6) { bytes in
                acc.record(bytes)
            }
        }
        XCTAssertEqual(acc.snapshot().callCount, 0)
    }

    /// Single-threaded `CPUDeflate` falls back to the protocol-extension
    /// default: one callback at the very end with the full input size.
    /// This matches the old per-entry granularity and is the correct
    /// behaviour for a backend that has no internal chunking.
    func testCPUDeflateFiresProgressOnceAtEnd() throws {
        let inputSize = 4 * 1024 * 1024
        let input = Data(repeating: 0x42, count: inputSize)
        let backend = CPUDeflate()

        let acc = ProgressAccumulator()
        _ = try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let typed = raw.bindMemory(to: UInt8.self)
            return try backend.compress(typed, level: 6) { bytes in
                acc.record(bytes)
            }
        }
        let (callCount, totalBytes) = acc.snapshot()

        XCTAssertEqual(callCount, 1,
                       "Single-threaded backend fires onProgress exactly once at the end")
        XCTAssertEqual(totalBytes, UInt64(inputSize))
    }
}

/// Lock-protected counter shared with the `@Sendable` progress
/// callback. The closure runs concurrently in `ParallelDeflate`'s
/// worker threads, and Swift 6's strict-concurrency analyser refuses
/// to let it mutate test-local `var`s. Using a class with explicit
/// locking is the standard escape hatch (CLAUDE.md Rule 1.3).
private final class ProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var bytes: UInt64 = 0

    func record(_ n: UInt64) {
        lock.lock()
        count += 1
        bytes += n
        lock.unlock()
    }

    func snapshot() -> (callCount: Int, totalBytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (count, bytes)
    }
}
