import Foundation

/// One match candidate produced by the GPU LZ77 search kernel. Multiple
/// candidates per input position are returned (top-K by score); the CPU
/// emitter picks the best one consistent with libzstd's match-quality
/// envelope and produces the final libzstd-format frame.
///
/// Layout chosen so 16 bytes packs naturally on Apple GPUs (16-byte
/// vector loads are cheap; the kernel emits these into a UMA buffer
/// that the CPU emitter reads directly with no transfer cost).
public struct MatchCandidate: Sendable, Equatable {
    /// Input offset (start of the matching span in the source block).
    public let position: UInt32
    /// Match offset (back-reference distance).
    public let offset: UInt32
    /// Match length in bytes.
    public let length: UInt16
    /// Heuristic score (higher = better). Used by the CPU emitter to
    /// pick among the top-K candidates per position.
    public let score: UInt16

    public init(position: UInt32, offset: UInt32, length: UInt16, score: UInt16) {
        self.position = position
        self.offset = offset
        self.length = length
        self.score = score
    }
}

/// Protocol for GPU-assisted LZ77 match search on the encode side.
///
/// On Apple Silicon's UMA, the candidates buffer can be written by the
/// GPU and read directly by the CPU emitter — there's no transfer tax
/// between the two stages, which is why this hybrid pipeline (GPU
/// match-search + CPU entropy coding + bitstream emission) is
/// efficient here in a way it wouldn't be on a discrete-GPU PCIe link.
///
/// Output is libzstd-format compatible: the CPU emitter consumes the
/// candidates and produces frames decodable by `ZSTD_decompress`. The
/// GPU heuristic may pick different matches than libzstd's internal
/// algorithm, so per-block compression ratio can vary by ±2% — but
/// correctness is asserted via differential decode (decoded output
/// equals the input, not byte-equal to libzstd's compressed output).
public protocol BlockEncodeAssist: Sendable {

    var name: String { get }
    var supportsGPU: Bool { get }

    /// Populate match candidates for `input` into the caller-provided
    /// `candidates` buffer. Returns the number of usable candidates
    /// written (≤ candidates.count). The CPU emitter scores them and
    /// emits the libzstd-compatible frame.
    ///
    /// Implementations must bounds-check writes against
    /// `candidates.count` defensively — over-running the buffer is the
    /// classic GPU-codec memory-corruption vector.
    func findMatches(_ input: UnsafeBufferPointer<UInt8>,
                     level: Int32,
                     candidates: UnsafeMutableBufferPointer<MatchCandidate>) throws -> Int
}
