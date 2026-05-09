import Foundation

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
