import Foundation

/// Streaming ZIP archive writer with ZIP64 support.
///
/// Designed to be invoked from a serial actor — the public methods are
/// non-isolated, but callers must serialize access externally (the file
/// handle is shared mutable state).
///
/// Layout produced:
///
///     [LFH 1][data 1][LFH 2][data 2] ...
///     [Central Directory entries]
///     [ZIP64 EOCD record]   (always emitted; harmless for small archives)
///     [ZIP64 EOCD locator]
///     [EOCD record]
public final class ZipWriter {

    // MARK: - Public types

    public struct EntryDescriptor: Sendable {
        public let name: String              // forward-slash separated, no leading slash
        public let modificationDate: Date
        public let unixMode: UInt16          // POSIX mode bits, 0o644 etc.
        public let isDirectory: Bool

        public init(name: String,
                    modificationDate: Date = Date(),
                    unixMode: UInt16 = 0o644,
                    isDirectory: Bool = false) {
            self.name = name
            self.modificationDate = modificationDate
            self.unixMode = unixMode
            self.isDirectory = isDirectory
        }
    }

    public struct EntryResult: Sendable {
        public let descriptor: EntryDescriptor
        public let method: CompressionMethod
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
    }

    /// Payload source for `writeEntry`. PR #70: split between
    /// `.data` (compressed output already produced in memory — small
    /// for a typical compress-then-store ZIP, since the codec shrunk
    /// the bytes) and `.mapped` (raw mmap of the input file, used
    /// when the entry will be written `.stored` so we can stream
    /// straight from the page cache to the FD without an 80 GB
    /// `Data(bytes:count:)` `vm_copy` first).
    ///
    /// `@unchecked Sendable` because the .mapped case carries a
    /// `MappedFile` (a `final class @unchecked Sendable`) — sending
    /// the enum across actor boundaries is safe by the same
    /// rationale as the class itself.
    public enum Payload: @unchecked Sendable {
        /// In-memory payload (DEFLATE output, small entries, etc.).
        case data(Data)
        /// Stream the entry's bytes directly from a memory-mapped
        /// input. The MappedFile is retained for the duration of
        /// the write — no intermediate Data copy.
        case mapped(MappedFile)

        /// Number of payload bytes the writer will emit.
        var byteCount: Int {
            switch self {
            case .data(let d):     return d.count
            case .mapped(let m):   return m.buffer.count
            }
        }
    }

    // MARK: - State

    private let handle: FileHandle
    private var entries: [EntryResult] = []
    private var currentOffset: UInt64 = 0
    private var closed = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw KnitError.ioFailure(path: url.path, message: "cannot open for writing")
        }
        self.handle = h
        // PR #68 fix. Disable the page cache for the output FD —
        // matches the policy CLAUDE.md Rule 3.2 already documents for
        // unpack output FDs but which had never been applied to the
        // ZIP writer side. Without it, sustained multi-GB writes
        // (e.g. ZIPping an 80 GB Parallels VM image) fill the page
        // cache to ~50% of RAM, engage macOS's memory compressor, and
        // throttle write throughput to ~50 MB/s on an M5 Max whose
        // NVMe can otherwise sustain ~5 GB/s. F_NOCACHE makes writes
        // bypass the page cache and stream straight into the NVMe
        // controller's own DRAM cache, restoring near-line-rate
        // throughput.
        //
        // Best-effort: a filesystem that doesn't support direct I/O
        // (most don't reject this flag, but some external mounts
        // might) continues through the cached path unchanged — no
        // worse than pre-fix.
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
    }

    deinit {
        if !closed {
            try? handle.close()
        }
    }

    // MARK: - Writing

    /// Write a stored (uncompressed) or precompressed entry. The caller
    /// must have already produced the compressed bytes (or chosen `.stored`
    /// in which case `payload` is the raw data).
    ///
    /// `onProgress` fires repeatedly during the payload write — once per
    /// `~8 MiB` chunk for large payloads, or once at completion for small
    /// ones. The bytes reported are payload bytes actually written to the
    /// FileHandle, summing to `payload.count` over the call. Callers that
    /// don't want progress reporting can pass `nil` (or omit the arg) and
    /// the writer falls back to a single `handle.write(contentsOf:)`. PR
    /// #65: motivates the chunked path — a multi-gigabyte `.stored` entry
    /// (e.g. a Parallels VM image inside a ZIP) used to drain to disk
    /// silently while the progress bar sat at 100%; chunked progress lets
    /// the bar tick smoothly through the write phase.
    public func writeEntry(
        descriptor: EntryDescriptor,
        method: CompressionMethod,
        crc32: UInt32,
        uncompressedSize: UInt64,
        payload: Payload,
        onProgress: (@Sendable (UInt64) -> Void)? = nil
    ) throws {
        precondition(!closed, "writeEntry on closed ZipWriter")

        let offset = currentOffset
        let nameBytes = Array(descriptor.name.utf8)
        let ts = MSDOSTimestamp(date: descriptor.modificationDate)
        let payloadCount = payload.byteCount
        // ZIP64 is required if any size or offset doesn't fit in 32 bits.
        // We emit ZIP64 selectively per-entry: small entries stay in the
        // pre-2001 layout for maximum compatibility with older readers.
        let needsZip64 = uncompressedSize >= 0xFFFF_FFFF
                       || UInt64(payloadCount) >= 0xFFFF_FFFF
                       || offset >= 0xFFFF_FFFF

        var lfh = Data(capacity: 30 + nameBytes.count + (needsZip64 ? 20 : 0))
        lfh.appendLE(UInt32(0x04034b50))                               // LFH signature ("PK\x03\x04")
        // Version needed: 45 for ZIP64, 20 for the pre-2001 baseline.
        lfh.appendLE(UInt16(needsZip64 ? 45 : 20))
        // Flags: bit 11 declares the name is UTF-8 encoded. Required by
        // APPNOTE 6.3.x for any name outside the IBM Code Page 437 set;
        // we always emit UTF-8 so we always set the bit.
        lfh.appendLE(UInt16(0x0800))
        lfh.appendLE(method.rawValue)
        lfh.appendLE(ts.time)
        lfh.appendLE(ts.date)
        lfh.appendLE(crc32)
        // Size fields: when ZIP64 applies, both 32-bit fields are filled
        // with the sentinel 0xFFFF_FFFF and the real values live in the
        // ZIP64 extra-field that follows the file name.
        let compressedSize32 = needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(payloadCount)
        let uncompressedSize32 = needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(uncompressedSize)
        lfh.appendLE(compressedSize32)
        lfh.appendLE(uncompressedSize32)
        lfh.appendLE(UInt16(nameBytes.count))
        lfh.appendLE(UInt16(needsZip64 ? 20 : 0))                      // extra-field length
        lfh.append(contentsOf: nameBytes)
        if needsZip64 {
            // ZIP64 extended-information extra-field (APPNOTE §4.5.3):
            //   tag 0x0001, payload 16 bytes = uncompressedSize(8) + compressedSize(8).
            // Order matters — readers parse positionally based on which
            // sentinels were set above. Local headers don't carry the
            // local-header-offset field (that's central-directory only).
            lfh.appendLE(UInt16(0x0001))
            lfh.appendLE(UInt16(16))
            lfh.appendLE(uncompressedSize)
            lfh.appendLE(UInt64(payloadCount))
        }

        try writeRaw(lfh)
        switch payload {
        case .data(let d):
            try writeRawChunked(d, onProgress: onProgress)
        case .mapped(let m):
            try writeRawChunkedMapped(m, onProgress: onProgress)
        }

        entries.append(EntryResult(
            descriptor: descriptor,
            method: method,
            crc32: crc32,
            compressedSize: UInt64(payloadCount),
            uncompressedSize: uncompressedSize,
            localHeaderOffset: offset
        ))
    }

    /// Finalise the archive: write the Central Directory (CD), the ZIP64
    /// EOCD record + locator, and the classic EOCD record. ZIP64 records
    /// are emitted unconditionally — they're harmless for small archives
    /// and let us avoid a backward-rewind pass for ones that grew large.
    /// EOCD = "End Of Central Directory record".
    public func close() throws {
        guard !closed else { return }
        let cdStart = currentOffset

        for entry in entries {
            try writeRaw(makeCentralDirectoryHeader(entry))
        }
        let cdEnd = currentOffset
        let cdSize = cdEnd - cdStart

        try writeRaw(makeZip64EOCDRecord(cdSize: cdSize, cdOffset: cdStart, totalEntries: UInt64(entries.count)))
        // 56 = total bytes written by makeZip64EOCDRecord (12 byte fixed
        // prefix + 44 byte body). Hard-coded rather than derived because
        // the record format is fixed by spec.
        let zip64EocdOffset = currentOffset - 56
        try writeRaw(makeZip64EOCDLocator(zip64EocdOffset: zip64EocdOffset))
        try writeRaw(makeEOCDRecord(cdSize: cdSize, cdOffset: cdStart, totalEntries: entries.count))

        try handle.close()
        closed = true
    }

    // MARK: - Internals

    private func writeRaw(_ data: Data) throws {
        try handle.write(contentsOf: data)
        currentOffset += UInt64(data.count)
    }

    /// Write chunk size for the payload-drain path. Bumped 8 MiB → 64
    /// MiB in PR #73 — `sample`-trace evidence on the user's M5 Max,
    /// post-PR-#72 (parallel CRC), pinned the residual cost on the
    /// raw `write(2)` syscall: 100 % of main-thread time goes there,
    /// no userspace overhead left to shave. 64 MiB chunks cut the
    /// syscall count for an 80 GB write from ~10 000 → ~1 250 (a
    /// 0.5 s base-overhead reduction on its own) and give the kernel
    /// a longer contiguous range to drive into the NVMe queue, which
    /// matters for sustained throughput on the F_NOCACHE path
    /// (uncached writes hit the controller directly so queue depth +
    /// per-IO byte budget become the primary throttle, vs the cached
    /// path's coalescing-then-flush behaviour).
    ///
    /// Trade-off: progress callback fires ~50 times/sec at 3 GB/s
    /// (was ~370/sec with 8 MiB), still far above the 60 Hz the UI
    /// needs to look smooth — no perceptible regression on the
    /// progress bar's tick rate.
    fileprivate static let payloadWriteChunkSize: Int = 64 * 1024 * 1024

    /// PR #70. Stream a `MappedFile`'s mmap-backed bytes straight to
    /// the output FD in `payloadWriteChunkSize`-byte chunks. No intermediate `Data` copy —
    /// the previous `.stored`-entry path went through
    /// `Self.dataFromBuffer(buf)` → `Data(bytes:count:)` →
    /// `vm_copy(80 GB)`, which a `sample` trace of the user's M5 Max
    /// pinned at 100 % main-thread time when zipping a Parallels VM
    /// image. Replacing that with a direct write from the mmap
    /// region eliminates the 80 GB allocation and the vm_copy entirely.
    ///
    /// Each chunk is wrapped in a transient `Data(bytesNoCopy:..,
    /// deallocator: .none)` purely so we can call
    /// `FileHandle.write(contentsOf:)`. CLAUDE.md Rule 3.1 warns
    /// against this pattern for FILE WRITES through the page cache
    /// (vm_remap accumulates references on shared physical pages
    /// until `cpt_mapcnt` overflows the kernel's refcount). With
    /// PR #68's `F_NOCACHE` on the writer FD that path is bypassed
    /// — writes go straight to the NVMe controller, no page-cache
    /// aliasing, no vm_remap accumulation. Chunking also
    /// bounds the aliased range per syscall, so even in a
    /// degraded-fallback (no F_NOCACHE honoured) situation we'd
    /// accumulate vm_remap refs in proportion to chunk count, far
    /// below the overflow threshold.
    private func writeRawChunkedMapped(_ mapped: MappedFile,
                                        onProgress: (@Sendable (UInt64) -> Void)?) throws {
        let buf = mapped.buffer
        guard let base = buf.baseAddress, buf.count > 0 else {
            // Empty file: nothing to write, but the LFH already
            // declared zero payload bytes, so this is a valid result.
            return
        }
        let chunkSize = Self.payloadWriteChunkSize
        if onProgress == nil || buf.count <= chunkSize {
            // Single-shot path. Wrap the whole mmap as a no-copy Data
            // for the one write call. (For a small entry this matches
            // the original copying path's behaviour at lower cost.)
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                            count: buf.count,
                            deallocator: .none)
            try handle.write(contentsOf: data)
            currentOffset += UInt64(buf.count)
            onProgress?(UInt64(buf.count))
            return
        }
        var offset = 0
        while offset < buf.count {
            let end = min(offset + chunkSize, buf.count)
            let chunkPtr = base.advanced(by: offset)
            let written = end - offset
            let chunkData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: chunkPtr),
                                 count: written,
                                 deallocator: .none)
            try handle.write(contentsOf: chunkData)
            currentOffset += UInt64(written)
            onProgress?(UInt64(written))
            // PR #76 (companion to the pack-side fix in
            // StreamingBlockCompressor): release the just-written
            // input-mmap pages from kernel residency so a sustained
            // multi-GB write doesn't accumulate ~80 GB of resident
            // mmap → memory-compressor activity → vm_remap of
            // compressed pages → `cpt_mapcnt` refcount overflow →
            // kernel panic. Without this hint, the kernel keeps
            // sequential-read pages resident on M5 Max (128 GB RAM)
            // even with the MappedFile.swift MADV_SEQUENTIAL set at
            // open time — the SEQUENTIAL advice biases readahead but
            // doesn't actively evict.
            _ = madvise(UnsafeMutableRawPointer(mutating: chunkPtr),
                        written,
                        MADV_DONTNEED)
            offset = end
        }
        // Touching `mapped` here keeps the MappedFile alive for the
        // full loop. Without this the compiler is free to release the
        // last reference earlier (no further uses), which would
        // unmap the region mid-write and segfault. Explicit
        // `withExtendedLifetime` is the canonical pattern.
        withExtendedLifetime(mapped) {}
    }

    /// Chunked variant of `writeRaw` that fires `onProgress` after each
    /// `payloadWriteChunkSize` bytes have been written to disk. Used by
    /// `writeEntry` for the payload write (PR #65) so the progress bar
    /// ticks during the serial write phase of a ZIP build, instead of
    /// sitting at 100 % while a multi-gigabyte payload drains to NVMe.
    ///
    /// See `payloadWriteChunkSize`'s doc-block for the 8 MiB → 64 MiB
    /// rationale (PR #73).
    private func writeRawChunked(_ data: Data,
                                  onProgress: (@Sendable (UInt64) -> Void)?) throws {
        let chunkSize = Self.payloadWriteChunkSize
        // Fast path: no progress wanted or small payload — single write.
        if onProgress == nil || data.count <= chunkSize {
            try handle.write(contentsOf: data)
            currentOffset += UInt64(data.count)
            onProgress?(UInt64(data.count))
            return
        }
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            try handle.write(contentsOf: chunk)
            let written = UInt64(end - offset)
            currentOffset += written
            onProgress?(written)
            offset = end
        }
    }

    private func makeCentralDirectoryHeader(_ entry: EntryResult) -> Data {
        let nameBytes = Array(entry.descriptor.name.utf8)
        let ts = MSDOSTimestamp(date: entry.descriptor.modificationDate)
        let needsZip64 = entry.uncompressedSize >= 0xFFFF_FFFF
                       || entry.compressedSize >= 0xFFFF_FFFF
                       || entry.localHeaderOffset >= 0xFFFF_FFFF

        var extra = Data()
        if needsZip64 {
            extra.appendLE(UInt16(0x0001))
            // size = 24 (uncompressed 8 + compressed 8 + offset 8)
            extra.appendLE(UInt16(24))
            extra.appendLE(entry.uncompressedSize)
            extra.appendLE(entry.compressedSize)
            extra.appendLE(entry.localHeaderOffset)
        }

        // External attrs: high 16 bits = full POSIX `st_mode` (file-type
        // bits OR'd with permission bits), low 16 bits = MS-DOS file
        // attributes. ZIP spec §4.4.15: when `version made by`'s host
        // system is Unix (3), the upper 16 bits are interpreted as
        // `st_mode` per POSIX. That means strict readers (Claude's
        // skill loader, Python's `zipfile.ZipInfo.external_attr` clients,
        // libarchive's `bsdtar`, info-zip's `-X` mode) look at
        // `(externalAttrs >> 16) & S_IFMT` to determine entry type.
        // Without `S_IFDIR` / `S_IFREG` they fall back to host=2 (FAT)
        // semantics or refuse the archive outright.
        //
        // Pre-PR-#83 bug: only `entry.descriptor.unixMode` (the 9-bit
        // permission set, e.g. 0o755) was shifted into the upper 16
        // bits, so the file-type field read as `0o0000` — "unknown".
        // `unzip -v` rendered our directory entries as `?rwxr-xr-x`
        // (the `?` marking unknown type) instead of `drwxr-xr-x`.
        // macOS-built ZIPs of the same content correctly carried
        // `040755` (S_IFDIR | 0o755), so the Claude skill loader
        // accepted them but rejected ours despite byte-identical
        // payload content.
        let fileTypeBits: UInt32 = entry.descriptor.isDirectory
            ? 0o040000  // S_IFDIR
            : 0o100000  // S_IFREG
        let unixStMode = fileTypeBits | UInt32(entry.descriptor.unixMode)
        let externalAttrs: UInt32 = (unixStMode << 16)
            | (entry.descriptor.isDirectory ? 0x0010 : 0)
        let versionMadeBy: UInt16 = (3 /* unix */ << 8) | 63  // 6.3 of spec

        var cdh = Data()
        cdh.appendLE(UInt32(0x02014b50))                        // signature
        cdh.appendLE(versionMadeBy)
        cdh.appendLE(UInt16(needsZip64 ? 45 : 20))              // version needed
        cdh.appendLE(UInt16(0x0800))                            // flags
        cdh.appendLE(entry.method.rawValue)
        cdh.appendLE(ts.time)
        cdh.appendLE(ts.date)
        cdh.appendLE(entry.crc32)
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.compressedSize))
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.uncompressedSize))
        cdh.appendLE(UInt16(nameBytes.count))
        cdh.appendLE(UInt16(extra.count))
        cdh.appendLE(UInt16(0))                                 // file comment length
        cdh.appendLE(UInt16(0))                                 // disk number start
        cdh.appendLE(UInt16(0))                                 // internal attrs
        cdh.appendLE(externalAttrs)
        cdh.appendLE(needsZip64 ? UInt32(0xFFFF_FFFF) : UInt32(entry.localHeaderOffset))
        cdh.append(contentsOf: nameBytes)
        cdh.append(extra)
        return cdh
    }

    private func makeZip64EOCDRecord(cdSize: UInt64, cdOffset: UInt64, totalEntries: UInt64) -> Data {
        var d = Data()
        d.appendLE(UInt32(0x06064b50))             // zip64 EOCD record signature
        d.appendLE(UInt64(44))                     // size of zip64 EOCD record (excludes leading 12 bytes)
        d.appendLE(UInt16(45))                     // version made by
        d.appendLE(UInt16(45))                     // version needed
        d.appendLE(UInt32(0))                      // disk number
        d.appendLE(UInt32(0))                      // disk with start of CD
        d.appendLE(totalEntries)                   // entries on this disk
        d.appendLE(totalEntries)                   // total entries
        d.appendLE(cdSize)
        d.appendLE(cdOffset)
        return d
    }

    private func makeZip64EOCDLocator(zip64EocdOffset: UInt64) -> Data {
        var d = Data()
        d.appendLE(UInt32(0x07064b50))             // zip64 EOCD locator signature
        d.appendLE(UInt32(0))                      // disk with zip64 EOCD
        d.appendLE(zip64EocdOffset)
        d.appendLE(UInt32(1))                      // total disks
        return d
    }

    private func makeEOCDRecord(cdSize: UInt64, cdOffset: UInt64, totalEntries: Int) -> Data {
        let entriesField: UInt16 = totalEntries >= 0xFFFF ? 0xFFFF : UInt16(totalEntries)
        let cdSize32: UInt32 = cdSize >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdSize)
        let cdOffset32: UInt32 = cdOffset >= 0xFFFF_FFFF ? 0xFFFF_FFFF : UInt32(cdOffset)

        var d = Data()
        d.appendLE(UInt32(0x06054b50))             // EOCD signature
        d.appendLE(UInt16(0))                      // disk number
        d.appendLE(UInt16(0))                      // disk with CD
        d.appendLE(entriesField)                   // entries on this disk
        d.appendLE(entriesField)                   // total entries
        d.appendLE(cdSize32)
        d.appendLE(cdOffset32)
        d.appendLE(UInt16(0))                      // comment length
        return d
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
