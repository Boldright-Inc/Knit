import Foundation

/// Thread-safe progress accumulator for long-running pack/unpack/zip
/// operations. The compressors and extractor `advance(by:)` after each
/// block writes; the CLI's printer thread polls `snapshot()` on a 500 ms
/// timer and emits a single overwrite line to stderr.
///
/// Memory cost is fixed (one lock + a few `UInt64`s) and the per-block
/// `advance` call is `O(1)`, so the reporter is cheap enough to leave
/// active for *every* pack/unpack run; the CLI only spawns the printer
/// thread when `--progress` is explicitly passed.
public final class ProgressReporter: @unchecked Sendable {

    /// Operation context surfaced in the progress line.
    public enum Phase: String, Sendable {
        case packing    = "pack"
        case extracting = "unpack"
        case zipping    = "zip"
    }

    public let phase: Phase

    private let lock = NSLock()
    private var bytesProcessed: UInt64 = 0
    private let totalBytes: UInt64
    private let startedAt: ContinuousClock.Instant
    private var finishedFlag: Bool = false

    public init(totalBytes: UInt64, phase: Phase) {
        self.phase = phase
        self.totalBytes = totalBytes
        self.startedAt = ContinuousClock.now
    }

    /// Record `n` more bytes of *uncompressed input* processed. Pack/zip
    /// callers update once per block written; unpack updates once per
    /// block decompressed.
    public func advance(by n: UInt64) {
        lock.lock(); defer { lock.unlock() }
        bytesProcessed &+= n
    }

    /// Mark the run finished. Idempotent; the printer thread observes
    /// this on its next poll and emits a final newline so the next
    /// stderr write doesn't overwrite the progress line.
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        finishedFlag = true
    }

    public var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finishedFlag
    }

    /// Immutable snapshot suitable for rendering. Computing
    /// `bytesPerSecond` and `etaSeconds` from this snapshot stays
    /// consistent across a single render call even if `advance(by:)`
    /// fires concurrently.
    public struct Snapshot: Sendable {
        public let processed: UInt64
        public let total: UInt64
        public let elapsed: TimeInterval
        public let phase: Phase

        /// 0…1 fraction. Returns `nil` when the total isn't known so
        /// the renderer can fall back to a spinner / byte counter.
        public var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1.0, Double(processed) / Double(total))
        }

        public var bytesPerSecond: Double {
            elapsed > 0 ? Double(processed) / elapsed : 0
        }

        /// Estimated remaining seconds. `.infinity` until at least 0.5%
        /// of the work has completed (avoids 99-day ETAs at startup).
        public var etaSeconds: Double {
            guard let f = fraction, f > 0.005 else { return .infinity }
            let totalEstimate = elapsed / f
            return max(0, totalEstimate - elapsed)
        }
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let elapsed = (ContinuousClock.now - startedAt).timeIntervalSeconds
        return Snapshot(
            processed: bytesProcessed,
            total: totalBytes,
            elapsed: elapsed,
            phase: phase
        )
    }
}
