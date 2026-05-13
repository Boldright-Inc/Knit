import Foundation

/// Result of probing one block of input data for compressibility.
public struct EntropyResult: Sendable, Equatable {
    /// Shannon entropy in bits per byte, in the range [0, 8].
    public let entropy: Float
    /// Number of input bytes covered by this result.
    public let byteCount: Int

    /// Heuristic: anything at or above this entropy is treated as
    /// "essentially incompressible" — already-compressed media (JPEG/MP4),
    /// encrypted blobs, PRNG output, etc. The threshold is intentionally a
    /// hair below the 8.0 theoretical maximum since real high-entropy
    /// payloads rarely hit a perfectly uniform distribution.
    public static let incompressibleThreshold: Float = 7.5

    public var isLikelyIncompressible: Bool {
        entropy >= Self.incompressibleThreshold
    }
}

/// Block-level compressibility probe. Implementations may run on the GPU
/// (`MetalEntropyProbe`) or CPU (`CPUEntropyProbe`).
public protocol EntropyProbing: Sendable {
    var name: String { get }

    /// Compute per-block entropy. The buffer is split into `blockSize`-byte
    /// slices; the last slice may be shorter. Returns one `EntropyResult`
    /// per slice, in order.
    ///
    /// `onProgress` (PR #71) fires periodically during the probe with the
    /// number of input bytes processed since the last call. For
    /// `MetalEntropyProbe` that's once per Metal dispatch (each dispatch
    /// covers ≤ UInt32.max bytes since PR #61); for `CPUEntropyProbe`
    /// that's once per block batch on the parallel path or once per
    /// block on the serial path. Callers wire it into the
    /// `ProgressReporter` so a multi-GB probe phase (e.g. ZIPping an
    /// 80 GB Parallels VM image — the probe runs on the entire entry
    /// before the codec decision is made) ticks the bar instead of
    /// sitting silent for seconds. Pass `nil` to disable.
    func probe(_ buffer: UnsafeBufferPointer<UInt8>,
               blockSize: Int,
               onProgress: (@Sendable (UInt64) -> Void)?) throws -> [EntropyResult]
}

extension EntropyProbing {
    /// Default-arg version of `probe` — preserves the two-argument call
    /// sites that don't care about per-dispatch progress.
    public func probe(_ buffer: UnsafeBufferPointer<UInt8>,
                      blockSize: Int) throws -> [EntropyResult] {
        try probe(buffer, blockSize: blockSize, onProgress: nil)
    }

    /// Probe the full buffer as one block. Convenience for callers that just
    /// want a single up-front decision (e.g. ZIP per-entry method choice).
    public func probeWhole(_ buffer: UnsafeBufferPointer<UInt8>) throws -> EntropyResult {
        if buffer.count == 0 {
            return EntropyResult(entropy: 0, byteCount: 0)
        }
        let results = try probe(buffer, blockSize: buffer.count, onProgress: nil)
        return results.first ?? EntropyResult(entropy: 0, byteCount: buffer.count)
    }
}

/// CPU implementation: pure Swift histogram + Shannon entropy. Always
/// available; the fallback when no Metal device is present and the path
/// `MetalEntropyProbe` itself takes for buffers below its
/// dispatch-amortisation threshold (256 KiB).
///
/// Internally parallel: when the input has multiple blocks, blocks are
/// scored across worker threads via `concurrentMap` instead of a serial
/// loop. The serial implementation that lived here through PR #19 was a
/// real regression vector once `StreamingBlockCompressor` (PR #23) moved
/// the entropy work *out* of per-worker closures and onto the
/// orchestrator thread: a 32-block batch that fell back to the CPU
/// probe would suddenly take 32× the time it did before, because the
/// 16-way parallelism the per-worker version had was gone. Parallelising
/// the probe internally restores parity for that fallback path while
/// preserving the GPU-amortisation win for large batches.
public struct CPUEntropyProbe: EntropyProbing {
    public let name = "cpu-entropy"

    /// Concurrency cap for `concurrentMap`. Defaults to the host's
    /// active processor count; callers running tests or already-
    /// parallel-elsewhere code can pass `1` to force serial.
    public let concurrency: Int

    public init(concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.concurrency = max(1, concurrency)
    }

    /// Below this many blocks the dispatch overhead of `concurrentMap`
    /// dominates the wins from parallelism, so we run serial. The
    /// per-block histogram is ~0.4 ms on a P-core for 1 MiB; dispatch
    /// + lock acquisition costs ~10 µs each. Crossing over above
    /// 4 blocks keeps the serial path for tiny batches (which is most
    /// of the small-file workload's batches anyway).
    private static let parallelThreshold: Int = 4

    public func probe(_ buffer: UnsafeBufferPointer<UInt8>,
                      blockSize: Int,
                      onProgress: (@Sendable (UInt64) -> Void)?) throws -> [EntropyResult] {
        guard let base = buffer.baseAddress, buffer.count > 0, blockSize > 0 else {
            return []
        }
        let total = buffer.count
        let numBlocks = (total + blockSize - 1) / blockSize

        // Trivial fast path: 1-3 blocks just run serially. Keeps the
        // single-block / small-batch case identical to the historical
        // implementation so nothing latent depends on a specific Float
        // computation order.
        if numBlocks < Self.parallelThreshold || concurrency <= 1 {
            return serialProbe(base: base, total: total, blockSize: blockSize,
                               onProgress: onProgress)
        }

        // Parallel path. Block N's input slice doesn't overlap with any
        // other's so workers don't need synchronization on the input
        // buffer; results are gathered in input order by `concurrentMap`.
        let basePtr = SendableRawPointer(base)
        let totalLen = total
        let blockLen = blockSize
        let indices = Array(0..<numBlocks)
        let results: [EntropyResult] = try concurrentMap(
            indices,
            concurrency: concurrency
        ) { i in
            let off = i * blockLen
            let len = min(blockLen, totalLen - off)
            let p = basePtr.value.advanced(by: off)
            let entropy = EntropyMath.shannonEntropy(of: p, count: len)
            // PR #71: per-block progress tick on the parallel path.
            // Order of `emit` is non-deterministic across workers, but
            // each worker contributes its block's byte count exactly
            // once, so the cumulative advance still sums to `total`.
            onProgress?(UInt64(len))
            // Hint the kernel that this block's input pages are done.
            // Same shape as the MetalEntropyProbe and parallelCRC32
            // sub-chunk loops; see those for the full rationale (200 GB
            // ZIP memory-error fix). Block sizes below 64 KiB don't
            // benefit (page granularity defeats the hint) — skip the
            // syscall there to keep CPU overhead bounded for
            // small-block callers.
            if len >= 64 * 1024 {
                _ = madvise(UnsafeMutableRawPointer(mutating: p),
                            len,
                            MADV_DONTNEED)
            }
            return EntropyResult(entropy: entropy, byteCount: len)
        }
        return results
    }

    /// The historical serial implementation, kept as the small-batch
    /// path. Identical math to the parallel branch — just the same loop
    /// the file shipped with through PR #19.
    private func serialProbe(base: UnsafePointer<UInt8>,
                             total: Int,
                             blockSize: Int,
                             onProgress: (@Sendable (UInt64) -> Void)?) -> [EntropyResult] {
        let numBlocks = (total + blockSize - 1) / blockSize
        var out: [EntropyResult] = []
        out.reserveCapacity(numBlocks)
        var off = 0
        while off < total {
            let len = min(blockSize, total - off)
            let entropy = EntropyMath.shannonEntropy(of: base.advanced(by: off), count: len)
            out.append(EntropyResult(entropy: entropy, byteCount: len))
            onProgress?(UInt64(len))
            off += len
        }
        return out
    }
}

/// Shared math primitives used by both CPU and GPU paths.
enum EntropyMath {

    /// Build a 256-bin histogram from a raw byte range. Single-threaded.
    static func histogram(of base: UnsafePointer<UInt8>, count: Int) -> [UInt32] {
        var hist = [UInt32](repeating: 0, count: 256)
        hist.withUnsafeMutableBufferPointer { dst in
            for i in 0..<count {
                dst[Int(base[i])] &+= 1
            }
        }
        return hist
    }

    /// Compute Shannon entropy (bits/byte) directly from a byte range.
    static func shannonEntropy(of base: UnsafePointer<UInt8>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        let hist = histogram(of: base, count: count)
        return shannonEntropy(histogram: hist, total: count)
    }

    /// Compute Shannon entropy from a populated 256-bin histogram. The
    /// `total` argument lets callers pass the byte count without having to
    /// reduce the histogram themselves.
    static func shannonEntropy(histogram: [UInt32], total: Int) -> Float {
        guard total > 0 else { return 0 }
        let inv = 1.0 / Float(total)
        var h: Float = 0
        for c in histogram where c != 0 {
            let p = Float(c) * inv
            // Foundation provides a Float-typed log2 overload on Darwin /
            // Linux; entropy precision at ~2 decimals is plenty for our
            // threshold decisions.
            h -= p * log2f(p)
        }
        // Numerical safety: clamp into [0, 8].
        if h < 0 { h = 0 }
        if h > 8 { h = 8 }
        return h
    }
}
