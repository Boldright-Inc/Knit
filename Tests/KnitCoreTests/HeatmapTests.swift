import XCTest
import Foundation
@testable import KnitCore

/// Smoke tests for the heatmap recorder, ANSI renderer, and PPM exporter.
final class HeatmapTests: XCTestCase {

    private func sampleHeatmap() -> CompressibilityHeatmap {
        // Synthesize a mixed-entropy archive snapshot: half compressible
        // text-like blocks, half high-entropy noise blocks.
        var samples: [HeatmapSample] = []
        for i in 0..<32 {
            if i.isMultiple(of: 2) {
                samples.append(HeatmapSample(
                    entropy: 4.2,
                    originalBytes: 1_048_576,
                    storedBytes: 320_000,
                    disposition: .compressed
                ))
            } else {
                samples.append(HeatmapSample(
                    entropy: 7.95,
                    originalBytes: 1_048_576,
                    storedBytes: 1_048_580,
                    disposition: .stored
                ))
            }
        }
        return CompressibilityHeatmap(samples: samples)
    }

    // MARK: - Recorder

    func testRecorderIsThreadSafe() {
        let recorder = HeatmapRecorder()
        let group = DispatchGroup()
        for k in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<1_000 {
                    recorder.record(HeatmapSample(
                        entropy: Float(k) * 0.5,
                        originalBytes: 4096,
                        storedBytes: 2048,
                        disposition: .compressed
                    ))
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(recorder.count, 8 * 1_000)
        XCTAssertEqual(recorder.snapshot().samples.count, 8 * 1_000)
    }

    // MARK: - Aggregates

    func testAggregateMetrics() {
        let h = sampleHeatmap()
        XCTAssertEqual(h.samples.count, 32)
        XCTAssertEqual(h.compressedBlockCount, 16)
        XCTAssertEqual(h.storedBlockCount, 16)
        // Mean entropy should sit between 4.2 and 7.95 with byte-equal
        // weighting, hence ≈ 6.075.
        XCTAssertEqual(h.meanEntropy, (4.2 + 7.95) / 2, accuracy: 0.01)
        XCTAssertGreaterThan(h.totalOriginalBytes, 0)
        XCTAssertLessThan(h.overallRatio, 1.0)
    }

    // MARK: - ANSI renderer

    func testANSIRenderingHasContent() {
        let renderer = HeatmapRenderer(heatmap: sampleHeatmap())
        let s = renderer.renderANSI()
        XCTAssertFalse(s.isEmpty)
        // Box drawing top should be present.
        XCTAssertTrue(s.contains("╭"))
        XCTAssertTrue(s.contains("╯"))
        // 24-bit ANSI escape preamble.
        XCTAssertTrue(s.contains("\u{1B}[38;2;"))
        // Summary block keywords.
        XCTAssertTrue(s.contains("Compressed"))
        XCTAssertTrue(s.contains("Stored"))
        XCTAssertTrue(s.contains("Mean entropy"))
    }

    func testEmptyHeatmapRendersGracefully() {
        let renderer = HeatmapRenderer(heatmap: CompressibilityHeatmap(samples: []))
        let s = renderer.renderANSI()
        XCTAssertFalse(s.isEmpty)
        XCTAssertTrue(s.contains("(no compressible blocks recorded)"))
    }

    // MARK: - PPM exporter

    func testWritePPMProducesValidHeader() throws {
        let renderer = HeatmapRenderer(heatmap: sampleHeatmap())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("heatmap-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: url) }

        try renderer.writePPM(to: url, cellPx: 4, columns: 8)
        let data = try Data(contentsOf: url)

        // P6 magic + newline.
        XCTAssertGreaterThan(data.count, 16)
        XCTAssertEqual(data[0], 0x50)        // 'P'
        XCTAssertEqual(data[1], 0x36)        // '6'
        XCTAssertEqual(data[2], 0x0A)        // '\n'

        // Pixel payload: cellPx=4, cols=8, rows=ceil(32/8)=4 -> 32x16 px,
        // 32*16*3 = 1536 bytes after the ASCII header.
        XCTAssertGreaterThanOrEqual(data.count, 1536)
    }
}
