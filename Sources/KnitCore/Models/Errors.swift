import Foundation

/// All errors raised by KnitCore. Cases are deliberately coarse-grained:
/// callers typically want to surface the message and bail out, not branch
/// on the specific failure mode. Rendering goes through
/// `CustomStringConvertible` so CLI output and tests stay consistent.
public enum KnitError: Error, CustomStringConvertible, Sendable {
    /// Filesystem-level failure. `path` is whichever file the underlying
    /// `open`/`read`/`write`/`mmap` call referred to; `message` carries the
    /// `strerror`-style detail.
    case ioFailure(path: String, message: String)
    /// A codec-internal allocation (libdeflate compressor, Metal buffer,
    /// etc.) returned NULL. Almost always indicates we asked for an
    /// implausibly large buffer or the system is out of memory.
    case allocationFailure(String)
    /// libdeflate / libzstd / zlib reported an error. The string is the
    /// codec's own `error_name` where available.
    case codecFailure(String)
    /// On-disk archive layout is invalid (bad magic, truncated, fields out
    /// of range). Also raised by `SafePath` for hostile entry names.
    case formatError(String)
    /// Feature requested by the user or implied by the archive header that
    /// this build doesn't implement — e.g. a `.knit` from a future format
    /// version, or a Metal function we couldn't compile.
    case unsupported(String)
    /// CRC32 / size-cap mismatch detected during extraction. Strong signal
    /// the archive was corrupted in transit or tampered with.
    case integrity(String)
    /// User-initiated cancellation. Currently unused but reserved for the
    /// upcoming progress/cancellation hook.
    case cancelled

    public var description: String {
        switch self {
        case .ioFailure(let path, let msg): return "I/O error at \(path): \(msg)"
        case .allocationFailure(let msg):   return "Allocation failed: \(msg)"
        case .codecFailure(let msg):        return "Codec error: \(msg)"
        case .formatError(let msg):         return "Format error: \(msg)"
        case .unsupported(let msg):         return "Unsupported: \(msg)"
        case .integrity(let msg):           return "Integrity check failed: \(msg)"
        case .cancelled:                    return "Operation cancelled"
        }
    }
}
