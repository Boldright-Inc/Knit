import Foundation

/// Per-block compressibility evidence collected during a compression run.
/// Used both to drive the optional heatmap visualization and as a record
/// for ratio-prediction telemetry.
public struct HeatmapSample: Sendable {
    public enum Disposition: Sendable {
        /// Block was sent through the compressor and the codec produced a
        /// smaller output.
        case compressed
        /// Block was emitted verbatim — either pre-screened by the entropy
        /// probe as incompressible, or the compressor produced output >=
        /// the input.
        case stored
    }

    public let entropy: Float            // bits/byte, [0, 8]
    public let originalBytes: Int
    public let storedBytes: Int          // what actually went on disk
    public let disposition: Disposition

    public init(entropy: Float,
                originalBytes: Int,
                storedBytes: Int,
                disposition: Disposition) {
        self.entropy = entropy
        self.originalBytes = originalBytes
        self.storedBytes = storedBytes
        self.disposition = disposition
    }

    /// Per-block effective ratio (storedBytes / originalBytes), in [0, 1+].
    public var ratio: Float {
        guard originalBytes > 0 else { return 1.0 }
        return Float(storedBytes) / Float(originalBytes)
    }
}

/// Thread-safe collector handed to a compressor. The compressor records one
/// `HeatmapSample` per compression block; the CLI snapshots and renders at
/// the end of the run.
public final class HeatmapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [HeatmapSample] = []

    public init() {}

    public func record(_ sample: HeatmapSample) {
        lock.lock(); defer { lock.unlock() }
        samples.append(sample)
    }

    public func recordBatch(_ batch: [HeatmapSample]) {
        guard !batch.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        samples.append(contentsOf: batch)
    }

    public func snapshot() -> CompressibilityHeatmap {
        lock.lock(); defer { lock.unlock() }
        return CompressibilityHeatmap(samples: samples)
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }
}

/// Snapshot of all per-block samples plus convenience aggregates. The
/// renderer is decoupled — `render(...)` produces an ANSI-styled string and
/// `writePPM(...)` exports a portable colour image, independent of the
/// terminal.
public struct CompressibilityHeatmap: Sendable {

    public let samples: [HeatmapSample]

    public init(samples: [HeatmapSample]) {
        self.samples = samples
    }

    public var totalOriginalBytes: UInt64 {
        samples.reduce(0) { $0 + UInt64($1.originalBytes) }
    }
    public var totalStoredBytes: UInt64 {
        samples.reduce(0) { $0 + UInt64($1.storedBytes) }
    }
    public var meanEntropy: Float {
        guard !samples.isEmpty else { return 0 }
        // Byte-weighted mean — large blocks dominate, which is what the
        // user perceives as "the typical entropy of my archive".
        var num: Double = 0
        var den: Double = 0
        for s in samples {
            num += Double(s.entropy) * Double(s.originalBytes)
            den += Double(s.originalBytes)
        }
        return den > 0 ? Float(num / den) : 0
    }
    public var compressedBlockCount: Int {
        samples.filter { $0.disposition == .compressed }.count
    }
    public var storedBlockCount: Int {
        samples.count - compressedBlockCount
    }
    public var overallRatio: Float {
        guard totalOriginalBytes > 0 else { return 1.0 }
        return Float(totalStoredBytes) / Float(totalOriginalBytes)
    }
}
