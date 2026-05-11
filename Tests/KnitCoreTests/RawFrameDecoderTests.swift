import XCTest
@testable import KnitCore
@testable import CZstd

/// PR #74. Verifies that `RawFrameDecoder`'s inline fast path produces
/// byte-identical output to libzstd's full decoder on the frame shapes
/// it claims to handle (Raw_Block / RLE_Block / mixed of those), and
/// correctly punts to `needsFullDecoder` on the shapes it doesn't
/// (Compressed_Block, malformed frames).
final class RawFrameDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Encode `bytes` with libzstd at the given level (default 3 —
    /// matches KnitWriter's default). Returns the encoded frame.
    private func encode(_ bytes: [UInt8], level: Int32 = 3) -> [UInt8] {
        let bound = ZSTD_compressBound(bytes.count)
        var out = [UInt8](repeating: 0, count: bound)
        let written = bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                ZSTD_compress(dst.baseAddress, bound,
                              src.baseAddress, src.count,
                              level)
            }
        }
        XCTAssertFalse(ZSTD_isError(written) != 0,
                       "ZSTD_compress error: \(String(cString: ZSTD_getErrorName(written)))")
        out.removeLast(out.count - written)
        return out
    }

    /// Decode `frame` with libzstd; used as the ground-truth reference.
    private func libzstdDecode(_ frame: [UInt8], expectedSize: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: expectedSize)
        let written = frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                ZSTD_decompress(dst.baseAddress, expectedSize,
                                src.baseAddress, src.count)
            }
        }
        XCTAssertEqual(written, expectedSize,
                       "libzstd reference decode produced \(written) bytes, expected \(expectedSize)")
        return out
    }

    private func decodeViaFastPath(_ frame: [UInt8], expectedSize: Int) -> RawFrameDecoder.Result {
        var out = [UInt8](repeating: 0, count: expectedSize)
        return frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                RawFrameDecoder.decode(frame: src, destination: dst)
            }
        }
    }

    private func decodeViaFastPathReturningBytes(_ frame: [UInt8], expectedSize: Int) -> (RawFrameDecoder.Result, [UInt8]) {
        var out = [UInt8](repeating: 0, count: expectedSize)
        let result = frame.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                RawFrameDecoder.decode(frame: src, destination: dst)
            }
        }
        return (result, out)
    }

    // MARK: - Tests

    /// Random / high-entropy data → libzstd emits Raw_Block frames.
    /// The fast path must produce byte-identical output to libzstd.
    func testRandomDataMatchesLibzstd() {
        var rng = SystemRandomNumberGenerator()
        for size in [1, 7, 1024, 1024 * 1024 - 13, 4 * 1024 * 1024 + 17] {
            var bytes = [UInt8](repeating: 0, count: size)
            for i in 0..<size { bytes[i] = UInt8.random(in: 0...255, using: &rng) }

            let frame = encode(bytes, level: 3)
            let reference = libzstdDecode(frame, expectedSize: size)
            let (result, decoded) = decodeViaFastPathReturningBytes(frame, expectedSize: size)

            switch result {
            case .decoded(let count):
                XCTAssertEqual(count, size,
                               "Decoded byte count mismatch at size=\(size)")
                XCTAssertEqual(decoded, reference,
                               "Fast-path output diverged from libzstd at size=\(size)")
                XCTAssertEqual(decoded, bytes,
                               "Round-trip mismatch at size=\(size)")
            case .needsFullDecoder:
                // libzstd MIGHT have produced Compressed_Block at small
                // sizes where it found patterns even in random data —
                // not an error, but skip the equality check for this
                // sample.
                continue
            case .parseError:
                XCTFail("Parse error at size=\(size)")
            }
        }
    }

    /// Run-length data → libzstd may emit RLE_Block frames. The fast
    /// path handles those identically to Raw_Block.
    func testRLEDataMatchesLibzstd() {
        for symbol in [UInt8(0), 0x42, 0xFF] {
            for size in [1, 100, 65536, 4 * 1024 * 1024 + 13] {
                let bytes = [UInt8](repeating: symbol, count: size)
                let frame = encode(bytes, level: 3)
                let reference = libzstdDecode(frame, expectedSize: size)
                let (result, decoded) = decodeViaFastPathReturningBytes(frame, expectedSize: size)

                switch result {
                case .decoded(let count):
                    XCTAssertEqual(count, size,
                                   "Decoded byte count mismatch at size=\(size), symbol=\(symbol)")
                    XCTAssertEqual(decoded, reference,
                                   "Fast-path output diverged from libzstd (size=\(size), symbol=\(symbol))")
                case .needsFullDecoder:
                    // Acceptable — libzstd may have emitted a
                    // Compressed_Block for the repeated bytes instead
                    // of RLE_Block (depends on level / heuristics).
                    continue
                case .parseError:
                    XCTFail("Parse error (size=\(size), symbol=\(symbol))")
                }
            }
        }
    }

    /// Text data → libzstd emits Compressed_Block frames. The fast
    /// path must punt to `needsFullDecoder` (not silently produce
    /// wrong output).
    func testCompressedFrameReturnsNeedsFullDecoder() {
        let text = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 4096)
        let bytes = Array(text.utf8)
        let frame = encode(bytes, level: 3)

        let result = decodeViaFastPath(frame, expectedSize: bytes.count)
        switch result {
        case .needsFullDecoder:
            // Expected. The fast path correctly recognised that this
            // frame has at least one Compressed_Block and bailed out.
            break
        case .decoded:
            XCTFail("Fast path claimed to decode a Compressed_Block frame; this is unsafe — would produce garbage output")
        case .parseError:
            XCTFail("Fast path raised parseError on a well-formed compressed frame")
        }
    }

    /// Empty input → libzstd produces a frame with a single Last_Block
    /// Raw_Block of size 0. The fast path must handle it cleanly.
    func testEmptyInput() {
        let frame = encode([], level: 3)
        let (result, decoded) = decodeViaFastPathReturningBytes(frame, expectedSize: 0)
        switch result {
        case .decoded(let count):
            XCTAssertEqual(count, 0)
            XCTAssertEqual(decoded.count, 0)
        case .needsFullDecoder:
            // libzstd may emit an unusual frame for empty input — not
            // a failure, just routes through the full decoder.
            break
        case .parseError:
            XCTFail("Fast path raised parseError on libzstd's empty-frame output")
        }
    }

    /// Malformed input → parseError. Smoke test for bounds checking
    /// inside the parser.
    func testMalformedFrameReturnsParseError() {
        // Less than the 4-byte magic.
        let tiny: [UInt8] = [0xFD, 0x2F]
        let (r1, _) = decodeViaFastPathReturningBytes(tiny, expectedSize: 16)
        XCTAssertTrue({ if case .parseError = r1 { return true }; return false }(),
                      "Expected .parseError on 2-byte input")

        // Valid magic but truncated frame header.
        let truncated: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00]   // magic + 1 byte of header, nothing else
        let (r2, _) = decodeViaFastPathReturningBytes(truncated, expectedSize: 16)
        XCTAssertTrue({ if case .parseError = r2 { return true }; return false }(),
                      "Expected .parseError on truncated header")

        // Not a zstd frame at all.
        let notZstd = [UInt8](repeating: 0xAB, count: 64)
        let (r3, _) = decodeViaFastPathReturningBytes(notZstd, expectedSize: 16)
        XCTAssertTrue({ if case .parseError = r3 { return true }; return false }(),
                      "Expected .parseError on non-zstd input (wrong magic)")
    }

    /// The fast path is only meant to short-circuit; on a frame it
    /// can't fully decode (Compressed_Block present) it must not
    /// leave partial garbage that would mislead a caller that fails
    /// to handle .needsFullDecoder. The destination buffer is
    /// allowed to be in any state on early-return, but the
    /// `.needsFullDecoder` signal must be unambiguous so the caller
    /// always falls back.
    func testMixedFrameReturnsNeedsFullDecoder() {
        // Build a payload that's likely to produce a mix of block
        // types: repeated header + random tail. Use level=22 to
        // encourage the encoder to emit Compressed_Blocks.
        var bytes = [UInt8](repeating: 0x55, count: 1024)
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<8192 {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        let frame = encode(bytes, level: 22)

        let result = decodeViaFastPath(frame, expectedSize: bytes.count)
        switch result {
        case .needsFullDecoder:
            break  // expected
        case .decoded:
            // libzstd happened to choose all-Raw for this particular
            // payload — not a failure of our fast path, just a missed
            // opportunity to exercise the Compressed_Block branch on
            // this input. Re-run with a payload that definitely
            // contains Compressed_Blocks is covered by
            // testCompressedFrameReturnsNeedsFullDecoder.
            break
        case .parseError:
            XCTFail("Fast path raised parseError on well-formed mixed frame")
        }
    }
}
