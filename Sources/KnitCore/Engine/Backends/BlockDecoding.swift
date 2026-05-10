import Foundation

/// Protocol implemented by codec backends that can decode a single
/// `.knit` block frame. Forms the abstraction layer that lets a future
/// `MetalZstdLiteralDecoder` (Phase 1b of the GPU codec roadmap) plug in
/// alongside the existing libzstd path without touching the orchestration
/// in `KnitReader` / `HybridZstdBatchDecoder`.
///
/// Conformers must be cheap to construct, eagerly compile any GPU
/// pipelines they need (so the construction-time fallback decision
/// happens before we start writing decoded data), and be **idempotent
/// on retry** — when a batch fails verification and the orchestrator
/// re-decodes via the CPU path, the original GPU instance must be safe
/// to reuse for subsequent batches.
public protocol BlockDecoding: Sendable {

    /// Human-readable identifier surfaced in logs and benchmarks.
    var name: String { get }

    /// Whether this implementation actually exercises the GPU. The
    /// orchestrator uses this to pick an instance: a CPU-only conformer
    /// always works as a fallback target; a GPU conformer is preferred
    /// when available and the input is large enough to amortize a
    /// dispatch.
    var supportsGPU: Bool { get }

    /// Decode a single zstd frame. The output buffer is pre-sized by the
    /// caller (typically at the block's declared `uncompressedSize`).
    /// Returns the number of bytes actually written.
    ///
    /// Throws if the input is malformed, exceeds output capacity, or
    /// hits an unsupported codec feature. The orchestrator catches the
    /// throw and re-runs the decode on a CPU fallback for that block.
    /// Implementations must therefore avoid destructive side-effects
    /// (e.g. partial writes to disk) before validating their inputs.
    func decodeBlock(_ frame: UnsafeBufferPointer<UInt8>,
                     into output: UnsafeMutableBufferPointer<UInt8>) throws -> Int
}
