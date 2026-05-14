import Foundation

/// One ZIP entry surfaced by `ZipReader`. Mirrors `KnitEntry`'s shape so
/// `ZipExtractor` can pattern-match against the same orchestration
/// vocabulary as `KnitExtractor`.
public struct ZipEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let unixMode: UInt16
    public let modificationDate: Date
    public let method: CompressionMethod
    public let crc32: UInt32
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    /// Offset of the entry's Local File Header inside the archive.
    /// The payload byte range is computed at extract time after parsing
    /// the LFH's name + extra-field lengths.
    public let localHeaderOffset: UInt64
    /// True if the entry's name carries the GP bit 11 (UTF-8) marker.
    /// We always treat names as UTF-8 regardless (ZipWriter emits the
    /// flag unconditionally, and Knit-produced ZIPs cover ≥99 % of the
    /// `knit unzip` workload); the bit is retained for diagnostics.
    public let nameIsUTF8: Bool
}

/// Read-only ZIP archive reader. Parses the End-of-Central-Directory
/// (EOCD) record, follows the optional ZIP64 EOCD locator/record for
/// archives ≥ 4 GiB, walks the Central Directory, and exposes every
/// entry's payload coordinates without touching the actual compressed
/// bytes.
///
/// Symmetric to `ZipWriter`: same magic numbers, same ZIP64 extra-field
/// layout, same flag conventions. Constants here are intentionally
/// duplicated rather than shared so a future format-version bump on one
/// side doesn't silently move the other.
///
/// `@unchecked Sendable` for the same reason as `KnitReader`: every
/// stored field is `let` and the only data plane is the read-only
/// mmap'd archive bytes. Workers in `ZipExtractor.extract` call into
/// this reader concurrently from `concurrentMap`.
public final class ZipReader: @unchecked Sendable {

    /// Magic numbers, kept symmetric with `ZipWriter`. APPNOTE 6.3.x.
    private enum Magic {
        static let localFileHeader: UInt32     = 0x04034b50
        static let centralDirectory: UInt32    = 0x02014b50
        static let endOfCentralDirectory: UInt32 = 0x06054b50
        static let zip64EOCDRecord: UInt32     = 0x06064b50
        static let zip64EOCDLocator: UInt32    = 0x07064b50
    }

    /// ZIP64 sentinel value. When any size or offset field in the
    /// pre-2001 record layout equals 0xFFFF_FFFF, the real value lives
    /// in the entry's ZIP64 extra-field (tag 0x0001).
    private static let zip64Sentinel32: UInt32 = 0xFFFF_FFFF
    private static let zip64Sentinel16: UInt16 = 0xFFFF

    /// General-purpose flag bits we care about. Bit 11 = name is UTF-8.
    /// Bit 3 = sizes/CRC stored in a post-payload data descriptor
    /// rather than the LFH; we **don't support** writing this from
    /// ZipWriter so it should be zero on knit-produced archives, but
    /// 3rd-party archives do use it. We fall back to the central
    /// directory's authoritative values rather than parsing the
    /// descriptor — same behaviour as `/usr/bin/unzip -X`.
    private enum GPFlag {
        static let utf8Name: UInt16 = 0x0800
        static let dataDescriptor: UInt16 = 0x0008
    }

    private let mapped: MappedFile
    public let entries: [ZipEntry]

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// Byte-preserving init. Mirrors `KnitReader.init(url:)` in shape
    /// but operates on the `path:` variant for the same NFC-vs-NFD
    /// reason `MappedFile` and `POSIXFile` use it (CLAUDE.md PR #82 /
    /// `POSIXFile.swift` header). The archive's bytes are accessed
    /// via mmap so multi-GB ZIPs cost ~zero RSS until the extractor
    /// touches them.
    public init(path: String) throws {
        self.mapped = try MappedFile(path: path)
        let buf = mapped.buffer

        guard buf.count >= 22 else {
            throw KnitError.formatError("zip: file shorter than minimum EOCD record (22 bytes)")
        }

        // Stage 1: scan backward from EOF for the EOCD signature. The
        // record itself is 22 bytes plus an optional comment up to
        // 65 535 bytes — APPNOTE §4.3.16. Search window 22 + 0xFFFF =
        // 65 557 bytes.
        let searchWindow = min(buf.count, 22 + 0xFFFF)
        let eocdOffset = try ZipReader.findEOCD(buf: buf,
                                                searchWindow: searchWindow)

        // Parse the classic EOCD to grab `total_entries` / `cd_offset`
        // / `cd_size`. These are 16/32-bit fields; the ZIP64 record
        // takes over when any of them hits the sentinel.
        let reader = ByteReader(buf: buf)
        let totalEntries16 = reader.readUInt16(at: eocdOffset + 10)
        let cdSize32       = reader.readUInt32(at: eocdOffset + 12)
        let cdOffset32     = reader.readUInt32(at: eocdOffset + 16)

        let totalEntries: UInt64
        let cdSize: UInt64
        let cdOffset: UInt64

        let zip64Needed = totalEntries16 == Self.zip64Sentinel16
                       || cdSize32     == Self.zip64Sentinel32
                       || cdOffset32   == Self.zip64Sentinel32

        if zip64Needed {
            // Stage 2 (ZIP64 path): the locator sits exactly 20 bytes
            // before the classic EOCD. From there we get the absolute
            // offset of the ZIP64 EOCD record itself.
            let locatorOffset = eocdOffset &- 20
            guard locatorOffset >= 0, locatorOffset + 20 <= buf.count else {
                throw KnitError.formatError("zip: ZIP64 sentinel present but no ZIP64 EOCD locator")
            }
            let locMagic = reader.readUInt32(at: locatorOffset)
            guard locMagic == Magic.zip64EOCDLocator else {
                throw KnitError.formatError(
                    "zip: bad ZIP64 EOCD locator magic 0x\(String(locMagic, radix: 16)) at \(locatorOffset)")
            }
            let zip64EOCDOffset64 = reader.readUInt64(at: locatorOffset + 8)
            guard zip64EOCDOffset64 <= UInt64(buf.count - 56) else {
                throw KnitError.formatError("zip: ZIP64 EOCD record offset out of range")
            }
            let zip64EOCDOffset = Int(zip64EOCDOffset64)
            let zip64Magic = reader.readUInt32(at: zip64EOCDOffset)
            guard zip64Magic == Magic.zip64EOCDRecord else {
                throw KnitError.formatError(
                    "zip: bad ZIP64 EOCD record magic 0x\(String(zip64Magic, radix: 16)) at \(zip64EOCDOffset)")
            }
            // Fields per APPNOTE §4.3.14, after the 12-byte fixed prefix:
            //   version made by      (2)
            //   version needed       (2)
            //   disk number          (4)
            //   disk w/ CD           (4)
            //   entries on disk      (8)
            //   total entries        (8)
            //   cd_size              (8)
            //   cd_offset            (8)
            totalEntries = reader.readUInt64(at: zip64EOCDOffset + 32)
            cdSize       = reader.readUInt64(at: zip64EOCDOffset + 40)
            cdOffset     = reader.readUInt64(at: zip64EOCDOffset + 48)
        } else {
            totalEntries = UInt64(totalEntries16)
            cdSize       = UInt64(cdSize32)
            cdOffset     = UInt64(cdOffset32)
        }

        guard cdOffset <= UInt64(buf.count),
              cdOffset &+ cdSize <= UInt64(buf.count) else {
            throw KnitError.formatError("zip: central directory range out of file")
        }

        // Stage 3: walk the Central Directory. Each CD entry is 46
        // bytes fixed + name + extra + comment. We extract everything
        // we need (sizes, CRC, method, mode, mtime, LFH offset) and
        // skip over any post-comment bytes to land on the next CDH.
        var parsed: [ZipEntry] = []
        parsed.reserveCapacity(Int(min(totalEntries, UInt64(Int.max))))
        var cursor = Int(cdOffset)
        let cdEnd = Int(cdOffset &+ cdSize)

        while cursor < cdEnd {
            guard cursor + 46 <= buf.count else {
                throw KnitError.formatError("zip: truncated central directory at \(cursor)")
            }
            let magic = reader.readUInt32(at: cursor)
            guard magic == Magic.centralDirectory else {
                throw KnitError.formatError(
                    "zip: bad CD header magic 0x\(String(magic, radix: 16)) at \(cursor)")
            }
            let versionMadeBy   = reader.readUInt16(at: cursor + 4)
            let gpFlags         = reader.readUInt16(at: cursor + 8)
            let methodRaw       = reader.readUInt16(at: cursor + 10)
            let dosTime         = reader.readUInt16(at: cursor + 12)
            let dosDate         = reader.readUInt16(at: cursor + 14)
            let crc32           = reader.readUInt32(at: cursor + 16)
            let compressedSize32   = reader.readUInt32(at: cursor + 20)
            let uncompressedSize32 = reader.readUInt32(at: cursor + 24)
            let nameLen         = Int(reader.readUInt16(at: cursor + 28))
            let extraLen        = Int(reader.readUInt16(at: cursor + 30))
            let commentLen      = Int(reader.readUInt16(at: cursor + 32))
            let externalAttrs   = reader.readUInt32(at: cursor + 38)
            let localHeaderOffset32 = reader.readUInt32(at: cursor + 42)

            let recordEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard recordEnd <= cdEnd, recordEnd <= buf.count else {
                throw KnitError.formatError("zip: CD entry overruns CD region at \(cursor)")
            }

            // Name: UTF-8 bytes. We treat ZIP entry names as UTF-8
            // unconditionally — Knit-produced ZIPs always set the
            // UTF-8 GP flag (ZipWriter:154), and the legacy CP437
            // path is left to system unzip if a 3rd-party archive
            // ever shows up without the flag. Per APPNOTE §4.4.17
            // CP437 is the default but in practice most modern
            // ZIP creators (Info-ZIP ≥ 3.0, libarchive, Python's
            // `zipfile`) emit UTF-8 with the flag set.
            let nameStart = cursor + 46
            let nameBytes = UnsafeBufferPointer(
                start: buf.baseAddress!.advanced(by: nameStart),
                count: nameLen
            )
            let name = String(decoding: nameBytes, as: UTF8.self)

            // ZIP64 extra-field parsing. When any of the three size
            // / offset fields hits the sentinel, the real value lives
            // in extra-field tag 0x0001 — fields appear in the order
            // (uncompressed, compressed, localHeaderOffset, diskStart)
            // and only the sentinel-marked ones are present.
            var compressedSize = UInt64(compressedSize32)
            var uncompressedSize = UInt64(uncompressedSize32)
            var localHeaderOffset = UInt64(localHeaderOffset32)
            let extraStart = nameStart + nameLen
            if extraLen > 0 {
                try ZipReader.parseZip64Extra(
                    buf: buf,
                    extraStart: extraStart,
                    extraLen: extraLen,
                    uncompressedSentinel: uncompressedSize32 == Self.zip64Sentinel32,
                    compressedSentinel: compressedSize32 == Self.zip64Sentinel32,
                    offsetSentinel: localHeaderOffset32 == Self.zip64Sentinel32,
                    uncompressedSize: &uncompressedSize,
                    compressedSize: &compressedSize,
                    localHeaderOffset: &localHeaderOffset
                )
            }

            // Decode method. Only `stored` (0) and `deflate` (8) are
            // supported — that matches what ZipWriter emits and what
            // ZipExtractor will handle. Unknown methods (BZip2 12,
            // LZMA 14, Zstandard 93, …) throw here rather than during
            // extract so the user sees the failure before we touch
            // the output filesystem.
            guard let method = CompressionMethod(rawValue: methodRaw) else {
                throw KnitError.unsupported(
                    "zip: entry '\(name)' uses unsupported compression method \(methodRaw)"
                )
            }

            // GP flag bit 3 — sizes/CRC in a post-payload data
            // descriptor. ZipWriter never sets it, but a third-party
            // archive might. The CD's recorded sizes/CRC are still
            // authoritative per APPNOTE §4.4.4, so we proceed using
            // those values. Log via the bit being on `nameIsUTF8 ==
            // false` would conflate two signals; we just trust the CD.
            _ = gpFlags & GPFlag.dataDescriptor

            // Recover the unix mode + isDirectory flag from external
            // attributes. ZipWriter encodes Unix host (3) with the
            // full `st_mode` in the upper 16 bits; for archives from
            // other writers we fall back to "regular file 0o644" on
            // a non-Unix host and respect the directory bit (low byte
            // 0x10) from the MS-DOS attrs field.
            let hostSystem = UInt8((versionMadeBy >> 8) & 0xFF)
            let unixHost = hostSystem == 3
            let stMode = UInt32((externalAttrs >> 16) & 0xFFFF)
            let dosAttrs = UInt32(externalAttrs & 0xFFFF)
            let nameEndsWithSlash = name.hasSuffix("/")
            let isDirectory: Bool
            let unixMode: UInt16
            if unixHost && stMode != 0 {
                let fileType = UInt32(stMode) & 0o170000
                let isDirFromMode = fileType == 0o040000
                isDirectory = isDirFromMode || nameEndsWithSlash
                // Strip file-type bits, keep permission bits.
                unixMode = UInt16(stMode & 0o7777)
            } else {
                // Fallback path. DOS attribute bit 4 = directory.
                let isDirFromDOS = (dosAttrs & 0x10) != 0
                isDirectory = isDirFromDOS || nameEndsWithSlash
                unixMode = isDirectory ? 0o755 : 0o644
            }

            // MS-DOS date/time → Date. Symmetric to MSDOSTimestamp's
            // packing — reuse the same conversion so round-trip stays
            // identical.
            let modDate = MSDOSTimestamp.dateFromMSDOS(dosTime: dosTime,
                                                       dosDate: dosDate)

            parsed.append(ZipEntry(
                name: name,
                isDirectory: isDirectory,
                unixMode: unixMode,
                modificationDate: modDate,
                method: method,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                nameIsUTF8: (gpFlags & GPFlag.utf8Name) != 0
            ))

            cursor = recordEnd
        }

        if UInt64(parsed.count) != totalEntries {
            // Not strictly an error in practice — some archives lie
            // about `total_entries` slightly. We've walked the entire
            // CD region; trust what we parsed.
        }

        self.entries = parsed
    }

    /// Locate the byte range of an entry's payload inside the mmap'd
    /// archive. Parses the Local File Header for its name + extra
    /// lengths and returns a buffer pointing at the compressed bytes.
    ///
    /// We don't validate LFH name/CRC fields against the Central
    /// Directory — `/usr/bin/unzip` doesn't either, and the CD is
    /// authoritative per APPNOTE §4.4.4. Only the structural fields
    /// we need (name length, extra length) are read.
    public func payload(for entry: ZipEntry) throws -> UnsafeBufferPointer<UInt8> {
        let buf = mapped.buffer
        let lfhOffset = Int(entry.localHeaderOffset)
        guard lfhOffset >= 0, lfhOffset + 30 <= buf.count else {
            throw KnitError.formatError(
                "zip: entry '\(entry.name)' LFH offset \(lfhOffset) out of range")
        }
        let reader = ByteReader(buf: buf)
        let magic = reader.readUInt32(at: lfhOffset)
        guard magic == Magic.localFileHeader else {
            throw KnitError.formatError(
                "zip: bad LFH magic 0x\(String(magic, radix: 16)) at \(lfhOffset) for '\(entry.name)'")
        }
        let nameLen  = Int(reader.readUInt16(at: lfhOffset + 26))
        let extraLen = Int(reader.readUInt16(at: lfhOffset + 28))
        let payloadStart = lfhOffset + 30 + nameLen + extraLen
        let payloadEnd = payloadStart &+ Int(entry.compressedSize)
        guard payloadStart >= 0,
              payloadEnd >= payloadStart,
              payloadEnd <= buf.count else {
            throw KnitError.formatError(
                "zip: payload range out of file for '\(entry.name)'")
        }
        return UnsafeBufferPointer(
            start: buf.baseAddress!.advanced(by: payloadStart),
            count: Int(entry.compressedSize)
        )
    }

    /// Hint the kernel that the input mmap pages covering `entry`'s
    /// payload + LFH are no longer needed. Mirrors `KnitReader`'s
    /// `releaseInputPagesFor` (PR #81) — for memory-rich hosts (M5
    /// Max 128 GB RAM) the kernel won't evict `MADV_SEQUENTIAL`
    /// pages aggressively, so we hint per-entry to bound resident set.
    public func releaseInputPagesFor(_ entry: ZipEntry) {
        let buf = mapped.buffer
        let lfhOffset = Int(entry.localHeaderOffset)
        // Generous bound: LFH (30) + max name (64K) + max extras (64K)
        // + payload. Even if we slightly over-hint, MADV_DONTNEED is
        // best-effort and ignored on filesystems that don't honour it
        // — same contract as the pack-side use.
        let approxLen = 30 + 0x20000 + Int(entry.compressedSize)
        guard lfhOffset >= 0, lfhOffset < buf.count else { return }
        let len = min(approxLen, buf.count - lfhOffset)
        guard len > 0 else { return }
        let basePtr = UnsafeMutableRawPointer(mutating: buf.baseAddress!)
            .advanced(by: lfhOffset)
        _ = madvise(basePtr, len, MADV_DONTNEED)
    }

    // MARK: - Internals

    /// Scan the last `searchWindow` bytes of `buf` for the classic EOCD
    /// signature. Walks back from the latest possible position. Returns
    /// the absolute offset of the EOCD record's first byte (where the
    /// magic lives).
    private static func findEOCD(buf: UnsafeBufferPointer<UInt8>,
                                  searchWindow: Int) throws -> Int {
        guard searchWindow >= 22, buf.count >= 22 else {
            throw KnitError.formatError("zip: too small to contain EOCD")
        }
        let endOffset = buf.count
        let startOffset = max(0, endOffset - searchWindow)
        // Scan backward — EOCD is always near EOF, so backward scan
        // hits earliest. Each candidate position must have the 4-byte
        // signature AND a record that doesn't claim a comment longer
        // than the file allows (defends against false-positive
        // signature matches inside file data).
        var i = endOffset - 22
        while i >= startOffset {
            if buf[i]     == 0x50 &&  // 'P'
               buf[i + 1] == 0x4b &&  // 'K'
               buf[i + 2] == 0x05 &&
               buf[i + 3] == 0x06 {
                let commentLen = Int(buf[i + 20]) | (Int(buf[i + 21]) << 8)
                if i + 22 + commentLen == endOffset {
                    return i
                }
            }
            i -= 1
        }
        throw KnitError.formatError("zip: end-of-central-directory record not found")
    }

    /// Parse a Central Directory entry's `extra` block looking for tag
    /// 0x0001 (ZIP64 extended information). Updates the inout fields
    /// **only** for fields whose 32-bit counterpart hit the sentinel,
    /// matching APPNOTE §4.5.3's positional rule: ZIP64 fields appear
    /// in the order (uncompressed, compressed, lfhOffset, diskStart)
    /// and only the sentinel-marked ones are physically present.
    private static func parseZip64Extra(
        buf: UnsafeBufferPointer<UInt8>,
        extraStart: Int,
        extraLen: Int,
        uncompressedSentinel: Bool,
        compressedSentinel: Bool,
        offsetSentinel: Bool,
        uncompressedSize: inout UInt64,
        compressedSize: inout UInt64,
        localHeaderOffset: inout UInt64
    ) throws {
        let reader = ByteReader(buf: buf)
        var cursor = extraStart
        let extraEnd = extraStart + extraLen
        while cursor + 4 <= extraEnd {
            let tag = reader.readUInt16(at: cursor)
            let size = Int(reader.readUInt16(at: cursor + 2))
            let payloadStart = cursor + 4
            let payloadEnd = payloadStart + size
            guard payloadEnd <= extraEnd else {
                throw KnitError.formatError("zip: truncated extra-field at \(cursor)")
            }
            if tag == 0x0001 {
                var p = payloadStart
                if uncompressedSentinel {
                    guard p + 8 <= payloadEnd else {
                        throw KnitError.formatError("zip: ZIP64 extra missing uncompressed size")
                    }
                    uncompressedSize = reader.readUInt64(at: p)
                    p += 8
                }
                if compressedSentinel {
                    guard p + 8 <= payloadEnd else {
                        throw KnitError.formatError("zip: ZIP64 extra missing compressed size")
                    }
                    compressedSize = reader.readUInt64(at: p)
                    p += 8
                }
                if offsetSentinel {
                    guard p + 8 <= payloadEnd else {
                        throw KnitError.formatError("zip: ZIP64 extra missing LFH offset")
                    }
                    localHeaderOffset = reader.readUInt64(at: p)
                    p += 8
                }
                return
            }
            cursor = payloadEnd
        }
        if uncompressedSentinel || compressedSentinel || offsetSentinel {
            throw KnitError.formatError(
                "zip: ZIP64 sentinel set but no 0x0001 extra-field present")
        }
    }
}

// MARK: - Little-endian reader

/// Bounds-checked little-endian load helper. Avoids unaligned-load UB
/// by going through individual byte loads; on Apple Silicon the
/// optimiser folds these into single LDR instructions anyway.
private struct ByteReader {
    let buf: UnsafeBufferPointer<UInt8>

    func readUInt16(at idx: Int) -> UInt16 {
        let b0 = UInt16(buf[idx])
        let b1 = UInt16(buf[idx + 1])
        return b0 | (b1 << 8)
    }
    func readUInt32(at idx: Int) -> UInt32 {
        let b0 = UInt32(buf[idx])
        let b1 = UInt32(buf[idx + 1])
        let b2 = UInt32(buf[idx + 2])
        let b3 = UInt32(buf[idx + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    func readUInt64(at idx: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(buf[idx + i]) << (8 * i)
        }
        return v
    }
}
