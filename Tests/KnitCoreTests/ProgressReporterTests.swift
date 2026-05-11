import XCTest
import Foundation
@testable import KnitCore

final class ProgressReporterTests: XCTestCase {

    func testAdvanceAccumulates() {
        let r = ProgressReporter(totalBytes: 1_000, phase: .packing)
        r.advance(by: 100)
        r.advance(by: 250)
        let snap = r.snapshot()
        XCTAssertEqual(snap.processed, 350)
        XCTAssertEqual(snap.total, 1_000)
        XCTAssertEqual(snap.fraction!, 0.35, accuracy: 0.001)
    }

    func testFinishFlagFlips() {
        let r = ProgressReporter(totalBytes: 100, phase: .extracting)
        XCTAssertFalse(r.isFinished)
        r.finish()
        XCTAssertTrue(r.isFinished)
        // Idempotent.
        r.finish()
        XCTAssertTrue(r.isFinished)
    }

    func testFractionIsNilWhenTotalUnknown() {
        let r = ProgressReporter(totalBytes: 0, phase: .zipping)
        r.advance(by: 100)
        XCTAssertNil(r.snapshot().fraction)
    }

    func testFractionClampsAtOne() {
        // Defensive: if a caller miscounts and overshoots the announced
        // total, the bar shouldn't render >100%.
        let r = ProgressReporter(totalBytes: 100, phase: .packing)
        r.advance(by: 200)
        XCTAssertEqual(r.snapshot().fraction!, 1.0, accuracy: 0.001)
    }

    func testEtaInfiniteUntilProgressMeasurable() {
        let r = ProgressReporter(totalBytes: 1_000_000_000, phase: .packing)
        // No advance yet → fraction effectively 0 → ETA infinite.
        XCTAssertFalse(r.snapshot().etaSeconds.isFinite)
        r.advance(by: 50_000_000)        // 5%, well past the 0.5% gate
        XCTAssertTrue(r.snapshot().etaSeconds.isFinite)
    }

    func testConcurrentAdvanceIsThreadSafe() {
        let total: UInt64 = 10_000 * 8
        let r = ProgressReporter(totalBytes: total, phase: .packing)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<10_000 { r.advance(by: 1) }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(r.snapshot().processed, total)
    }
}
