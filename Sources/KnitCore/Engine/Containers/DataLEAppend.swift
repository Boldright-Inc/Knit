import Foundation

/// Little-endian byte serialisation used by both the ZIP and `.knit`
/// writers. Both formats are little-endian on the wire (ZIP because PKZIP
/// originated on x86 DOS; `.knit` for symmetry and zero-cost loads on
/// arm64 / x86_64 hosts). `.littleEndian` on `FixedWidthInteger` is a
/// no-op on little-endian hosts but stays correct if we ever build for
/// big-endian.
extension Data {
    mutating func appendLE(_ v: UInt8) {
        self.append(v)
    }
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buf in self.append(contentsOf: buf) }
    }
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buf in self.append(contentsOf: buf) }
    }
    mutating func appendLE(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { buf in self.append(contentsOf: buf) }
    }
}
