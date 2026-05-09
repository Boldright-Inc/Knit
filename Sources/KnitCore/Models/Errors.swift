import Foundation

public enum KnitError: Error, CustomStringConvertible, Sendable {
    case ioFailure(path: String, message: String)
    case allocationFailure(String)
    case codecFailure(String)
    case formatError(String)
    case unsupported(String)
    case integrity(String)
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
