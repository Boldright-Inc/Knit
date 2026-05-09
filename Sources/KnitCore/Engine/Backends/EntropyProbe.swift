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
    func probe(_ buffer: UnsafeBufferPointer<UInt8>,
               blockSize: Int) throws -> [EntropyResult]
}

extension EntropyProbing {
    /// Probe the full buffer as one block. Convenience for callers that just
    /// want a single up-front decision (e.g. ZIP per-entry method choice).
    public func probeWhole(_ buffer: UnsafeBufferPointer<UInt8>) throws -> EntropyResult {
        if buffer.count == 0 {
            return EntropyResult(entropy: 0, byteCount: 0)
        }
        let results = try probe(buffer, blockSize: buffer.count)
        return results.first ?? EntropyResult(entropy: 0, byteCount: buffer.count)
    }
}

/// CPU implementation: pure Swift histogram + Shannon entropy. Always
/// available; the fallback when no Metal device is present and the path
/// taken for buffers too small to amortize a GPU dispatch.
public struct CPUEntropyProbe: EntropyProbing {
    public let name = "cpu-entropy"
    public init() {}

    public func probe(_ buffer: UnsafeBufferPointer<UInt8>,
                      blockSize: Int) throws -> [EntropyResult] {
        guard let base = buffer.baseAddress, buffer.count > 0, blockSize > 0 else {
            return []
        }
        let total = buffer.count
        let numBlocks = (total + blockSize - 1) / blockSize
        var out: [EntropyResult] = []
        out.reserveCapacity(numBlocks)
        var off = 0
        while off < total {
            let len = min(blockSize, total - off)
            let entropy = EntropyMath.shannonEntropy(of: base.advanced(by: off), count: len)
            out.append(EntropyResult(entropy: entropy, byteCount: len))
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
