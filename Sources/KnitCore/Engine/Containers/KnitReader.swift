import Foundation
import CZstd
import CDeflate

public struct KnitArchive {
    public let entries: [KnitEntry]
}

public struct KnitEntry: Sendable {
    public let name: String
    public let modificationDate: Date
    public let unixMode: UInt16
    public let isDirectory: Bool
    public let blockSize: UInt32
    public let uncompressedSize: UInt64
    public let compressedSize: UInt64
    public let crc32: UInt32
    public let blockLengths: [UInt32]
    public let dataOffset: UInt64       // absolute offset of first compressed byte
}

/// Reader for .knit files. Parses headers via mmap, decompresses entries lazily.
///
/// `@unchecked Sendable` because every stored field is `let` and behaviourally
/// read-only after `init`: `mapped` is `MappedFile`'s `@unchecked Sendable`
/// view of `PROT_READ` mmap pages (no data races on read-only memory), and
/// `archive` is a Sendable-by-fields struct. `extract(...)` opens its own
/// per-call `FileHandle` and writes only to the caller-supplied output URL —
/// no shared mutable state, so `KnitExtractor` can call it concurrently from
/// multiple workers when running entry-level parallelism (PR equivalent of
/// PR #27 on the unpack side).
public final class KnitReader: @unchecked Sendable {
    private let mapped: MappedFile
    public let archive: KnitArchive

    public init(url: URL) throws {
        self.mapped = try MappedFile(url: url)
        let buf = mapped.buffer

        var cursor = ReadCursor(buffer: buf)

        // Header
        let magic = try cursor.readUInt32()
        guard magic == KnitFormat.headerMagic else {
            throw KnitError.formatError(".knit: bad magic 0x\(String(magic, radix: 16))")
        }
        let version = try cursor.readUInt16()
        guard version == KnitFormat.version else {
            throw KnitError.unsupported(".knit version \(version) (this build supports \(KnitFormat.version))")
        }
        _ = try cursor.readUInt16()      // flags
        _ = try cursor.readUInt64()      // reserved

        var entries: [KnitEntry] = []
        while true {
            let marker = try cursor.peekUInt32()
            if marker == KnitFormat.footerMarker { break }
            guard marker == KnitFormat.entryMarker else {
                throw KnitError.formatError(".knit: unexpected marker 0x\(String(marker, radix: 16)) at \(cursor.offset)")
            }
            _ = try cursor.readUInt32()  // consume entry marker

            let nameLen = try cursor.readUInt16()
            let name = try cursor.readUTF8(length: Int(nameLen))
            let mode = try cursor.readUInt16()
            let modUnix = try cursor.readUInt64()
            let isDir = try cursor.readUInt8() != 0
            let blockSize = try cursor.readUInt32()
            guard blockSize == 0 || (blockSize > 0 && blockSize <= KnitFormat.maxBlockSize) else {
                throw KnitError.formatError(
                    ".knit: block_size out of range (\(blockSize), max \(KnitFormat.maxBlockSize))"
                )
            }
            let uncompressed = try cursor.readUInt64()
            let compressed = try cursor.readUInt64()
            let crc = try cursor.readUInt32()
            let numBlocks = try cursor.readUInt32()
            // numBlocks is bounded both by the per-archive block_lengths array
            // (4 bytes each) and the cursor's `ensure` check below; cap it here
            // so we don't reserve gigabytes for a hostile UInt32.
            guard numBlocks <= UInt32(KnitFormat.maxBlocksPerEntry) else {
                throw KnitError.formatError(".knit: num_blocks too large (\(numBlocks))")
            }
            var blockLens: [UInt32] = []
            blockLens.reserveCapacity(Int(numBlocks))
            for _ in 0..<numBlocks {
                blockLens.append(try cursor.readUInt32())
            }
            let dataOff = UInt64(cursor.offset)
            // `compressed` is wire-supplied UInt64. Reject anything that can't
            // fit in Int to avoid `Int(_:)` trapping on hostile input.
            guard compressed <= UInt64(Int.max) else {
                throw KnitError.formatError(".knit: compressed size out of range")
            }
            try cursor.skip(Int(compressed))

            entries.append(KnitEntry(
                name: name,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(modUnix)),
                unixMode: mode,
                isDirectory: isDir,
                blockSize: blockSize,
                uncompressedSize: uncompressed,
                compressedSize: compressed,
                crc32: crc,
                blockLengths: blockLens,
                dataOffset: dataOff
            ))
        }

        // Footer
        _ = try cursor.readUInt32()  // footer marker
        _ = try cursor.readUInt64()  // total entries
        let archiveVer = try cursor.readUInt32()
        guard archiveVer == KnitFormat.archiveVersion else {
            throw KnitError.unsupported(".knit archive version \(archiveVer)")
        }

        self.archive = KnitArchive(entries: entries)
    }

    /// Decompress an entry into an output URL on disk and verify its CRC32
    /// against the value recorded in the archive header.
    ///
    /// The verifier accepts an optional `MetalCRC32` instance: when supplied
    /// and the entry is large enough to amortize a Metal dispatch, the
    /// post-write verification re-reads the freshly-written file via
    /// `MappedFile` (page-cache hot, effectively free) and runs the CRC on
    /// the GPU. Smaller entries fall through to libdeflate's CPU CRC32.
    ///
    /// `progressReporter`, if supplied, has `advance(by:)` called with the
    /// number of *uncompressed* bytes after each block is decompressed and
    /// written to disk.
    ///
    /// `stagedDecoder`, if supplied, routes the per-block decode through a
    /// `HybridZstdBatchDecoder` — the orchestration layer that the GPU
    /// codec roadmap (Phase 1b → 2) will plug GPU `BlockDecoding`
    /// implementations into. With a CPU-only `BlockDecoding` it behaves
    /// identically to the direct libzstd path apart from staging a batch
    /// of decoded bytes in RAM and folding their CRC before writing them
    /// to disk — that staging discipline is what makes the GPU path safe
    /// later. Pass `nil` (default) to use the existing direct-libzstd
    /// loop with no batching overhead.
    /// Legacy URL-based extract — wraps the byte-preserving String
    /// path variant by going through `outURL.path` (which
    /// NFD-normalizes on macOS, see `POSIXFile.swift` header for
    /// why). Fine for ASCII paths; for non-ASCII entry names use
    /// `extract(_:toPath:...)` directly. KnitExtractor uses the
    /// String variant; this overload exists for the existing test
    /// suite and any callers that already hold a URL.
    public func extract(_ entry: KnitEntry,
                        to outURL: URL,
                        gpuCRC: MetalCRC32? = nil,
                        progressReporter: ProgressReporter? = nil,
                        stagedDecoder: HybridZstdBatchDecoder? = nil,
                        postWriteVerify: Bool = true) throws {
        try extract(entry,
                    toPath: outURL.path,
                    gpuCRC: gpuCRC,
                    progressReporter: progressReporter,
                    stagedDecoder: stagedDecoder,
                    postWriteVerify: postWriteVerify)
    }

    /// Byte-preserving extract. `outPath`'s UTF-8 bytes flow
    /// straight to `open(2)` and `mkdir(2)` via POSIX, bypassing
    /// Foundation's NFD canonical-decomposition normalization of
    /// path strings. Required for round-tripping non-ASCII
    /// filenames (most notably Japanese, Korean, accented Latin
    /// scripts) without silently rewriting the on-disk encoding.
    /// See `POSIXFile.swift` for the full analysis. PR #82.
    public func extract(_ entry: KnitEntry,
                        toPath outPath: String,
                        gpuCRC: MetalCRC32? = nil,
                        progressReporter: ProgressReporter? = nil,
                        stagedDecoder: HybridZstdBatchDecoder? = nil,
                        postWriteVerify: Bool = true) throws {
        if entry.isDirectory {
            if !POSIXFile.mkdirParents(outPath) {
                throw KnitError.ioFailure(path: outPath, message: "could not create directory")
            }
            // PR #82: apply the archive's stored unixMode to the
            // directory we just created. `mkdir(2)` itself respects
            // the process umask, so calling `chmod(2)` afterwards
            // is the way to land the exact mode bits the archive
            // recorded. Pre-PR-#82 the legacy `FileManager.createDirectory`
            // path silently ignored `entry.unixMode` and let umask
            // pick — a round-trip drift for directories with
            // non-default modes (e.g. APFS-stored `0o700`
            // user-private dirs unpacking as `0o755`).
            _ = outPath.withCString { chmod($0, mode_t(entry.unixMode)) }
            // PR #82: stamp the directory's modification time from
            // the archive. Without this, freshly-unpacked dirs all
            // carry "now" mtime — losing the historical timestamp
            // that the .knit faithfully recorded.
            POSIXFile.setMTime(path: outPath,
                               secondsSince1970: Int64(entry.modificationDate.timeIntervalSince1970))
            return
        }

        // Parent-dir safety net. KnitExtractor.swift pre-creates
        // every parent path in a single serial pass before kicking
        // off the parallel-extract phase (to dodge APFS b-tree
        // contention on shared parent inodes), so this call is
        // expected to be a no-op for the common case. It catches
        // the edge case where the caller didn't run the pre-create
        // pass (tests, ad-hoc usage).
        if let lastSlash = outPath.lastIndex(of: "/") {
            let parentPath = String(outPath[..<lastSlash])
            if !parentPath.isEmpty {
                _ = POSIXFile.mkdirParents(parentPath)
            }
        }
        // PR #82: apply the archive's stored unixMode at open
        // time so the file lands with the original bits.
        // Pre-PR-#82 the legacy `FileManager.createFile` path
        // ignored `entry.unixMode` and used umask defaults —
        // a Parallels VM's `0o600` (private) image would unpack
        // as `0o644` (world-readable), a quiet security
        // round-trip regression. `O_CREAT`'s `mode_t` argument
        // is masked through umask, so we also call `chmod(2)`
        // afterwards to land the literal recorded bits.
        let outHandle = try POSIXFile.openForWriting(outPath,
                                                      mode: mode_t(entry.unixMode))
        _ = outPath.withCString { chmod($0, mode_t(entry.unixMode)) }
        defer { try? outHandle.close() }

        // Opt-in staged path: build (frame, uncompressedSize) per block
        // and hand the whole list to the hybrid decoder, which stages
        // each batch in RAM, folds CRC against the entry's recorded
        // value, and only then commits to disk via the sink. The
        // existing direct-libzstd loop below is the default and behaves
        // exactly as before.
        if let staged = stagedDecoder {
            try extractViaStagedDecoder(entry: entry,
                                        outHandle: outHandle,
                                        decoder: staged,
                                        progressReporter: progressReporter)
            // No `outHandle.synchronize()` here. Two reasons:
            //   1. macOS's unified buffer cache makes write↔mmap
            //      coherent on the same file without `fsync` —
            //      `verifyCRC` mmaps `outURL` on a fresh fd and the
            //      pages are visible regardless of whether dirty
            //      pages have hit NAND yet.
            //   2. `KnitReader.extract` has already set `F_NOCACHE`
            //      on `outHandle.fileDescriptor` (PR #17), so the
            //      writes go straight to the NVMe controller's
            //      DRAM cache rather than accumulating in the page
            //      cache. There is nothing for `fsync` to flush.
            // Each per-entry `synchronize()` cost ~30 µs of syscall
            // overhead — at 100 k tiny entries that's ~3 s of wall
            // time on the 9 GB github corpus, all spent waiting on
            // a no-op flush. Removed.
            //
            // PR #75: post-write verifyCRC is opt-out via the
            // `postWriteVerify` flag. The decode-side rolling CRC
            // (HybridZstdBatchDecoder.decode → expectedCRC32 check)
            // already verifies the decoded bytes against the
            // archive's stored CRC; re-reading the output file and
            // re-CRC'ing only catches disk-write corruption, which
            // on APFS + modern NVMe is effectively impossible (the
            // filesystem block-checksums independently). For large
            // entries the verifyCRC pass dominates wall (~60s of
            // ~88s on the user's 80 GB .pvm.knit), so skipping it
            // gives 2-3× speedup at the cost of dropping a
            // defence-in-depth layer most archive tools don't have.
            if postWriteVerify {
                try verifyCRC(entry: entry, outPath: outPath, gpuCRC: gpuCRC)
            }
            // PR #82: stamp the file's mtime from the archive
            // while the fd is still open. Must come AFTER writes
            // have completed (writes update mtime; setting before
            // would be overwritten) and ideally BEFORE close
            // (saves a path-lookup syscall vs `utimes`).
            POSIXFile.setMTime(fd: outHandle.fileDescriptor,
                               secondsSince1970: Int64(entry.modificationDate.timeIntervalSince1970))
            // PR #81: release the input-mmap pages this entry consumed.
            // See `releaseInputPagesFor(entry:)` doc-block for the
            // jetsam-prevention rationale (mirrors PR #76's pack-side
            // `MADV_DONTNEED` on the unpack input side).
            releaseInputPagesFor(entry: entry)
            return
        }

        var srcOffset = Int(entry.dataOffset)
        var totalDecompressed: UInt64 = 0

        let blockCap = max(Int(entry.blockSize), 1)
        for blockLen in entry.blockLengths {
            let inLen = Int(blockLen)
            let inPtr = mapped.pointer.advanced(by: srcOffset)

            // zstd frames are self-describing; we decode each frame fully.
            let frameSize = ZSTD_getFrameContentSize(inPtr, inLen)
            if frameSize == ZSTD_CONTENTSIZE_ERROR {
                throw KnitError.codecFailure("zstd: frame content size error")
            }
            // Allocate output buffer. Cap to block_size so a hostile frame
            // header can't trigger a multi-GB allocation (DoS).
            let outCapacity: Int
            if frameSize == ZSTD_CONTENTSIZE_UNKNOWN {
                outCapacity = blockCap
            } else {
                let declared = Int(clamping: frameSize)
                guard declared <= blockCap else {
                    throw KnitError.formatError(
                        ".knit: block frame too large (\(declared) > \(blockCap))"
                    )
                }
                outCapacity = declared
            }
            var outBuf = Data(count: outCapacity)
            let produced: Int = outBuf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let p = raw.baseAddress else { return 0 }
                return ZSTD_decompress(p, outCapacity, inPtr, inLen)
            }
            if ZSTD_isError(produced) != 0 {
                let cstr = ZSTD_getErrorName(produced)
                let msg = cstr.map { String(cString: $0) } ?? "unknown"
                throw KnitError.codecFailure("zstd decode: \(msg)")
            }
            outBuf.removeSubrange(produced..<outBuf.count)

            // Defense in depth: if a malformed entry claims a small
            // `uncompressedSize` but the frames decompress to more, abort
            // before we keep writing to disk.
            totalDecompressed += UInt64(produced)
            if totalDecompressed > entry.uncompressedSize {
                throw KnitError.integrity(
                    "size overrun in \(entry.name): exceeded declared \(entry.uncompressedSize) bytes"
                )
            }

            try outHandle.write(contentsOf: outBuf)
            srcOffset += inLen
            // One progress tick per block so the printer thread sees
            // smooth motion even for very large entries.
            progressReporter?.advance(by: UInt64(produced))
        }

        if totalDecompressed != entry.uncompressedSize {
            throw KnitError.integrity(
                "size mismatch for \(entry.name): expected \(entry.uncompressedSize), got \(totalDecompressed)"
            )
        }

        // PR #81: legacy non-staged path release. See the staged-path
        // call site and `releaseInputPagesFor` doc-block for rationale.
        releaseInputPagesFor(entry: entry)

        // No `outHandle.synchronize()` — see commentary on the staged
        // path above for the rationale (macOS unified buffer cache
        // makes write↔mmap coherent on the same file without fsync).
        // PR #75: post-write verify is opt-out — same rationale as
        // the staged path. See the staged-path doc-block for the
        // full trade-off discussion.
        if postWriteVerify {
            try verifyCRC(entry: entry, outPath: outPath, gpuCRC: gpuCRC)
        }
        // PR #82: stamp the file's mtime from the archive while
        // the fd is still open (legacy non-staged path —
        // identical to the staged-path call above).
        POSIXFile.setMTime(fd: outHandle.fileDescriptor,
                           secondsSince1970: Int64(entry.modificationDate.timeIntervalSince1970))
    }

    /// Drive the entry's decode through a `HybridZstdBatchDecoder`. The
    /// Release the input-mmap pages that backed `entry`'s compressed
    /// payload, hinting the kernel that the range is no longer needed.
    ///
    /// **Why — PR #81.** PR #76 added `madvise(MADV_DONTNEED)` on the
    /// pack/zip side to fix a `cpt_mapcnt` kernel panic on the user's
    /// 80 GB `.pvm` corpus: on memory-rich hosts (M5 Max 128 GB RAM)
    /// the kernel doesn't evict `MADV_SEQUENTIAL` input pages
    /// aggressively, the memory compressor opportunistically
    /// compresses cold pages, and `vm_remap` references on the
    /// resulting shared pages accumulate past the 11-bit cap.
    ///
    /// The unpack input side was overlooked in PR #76 because the
    /// post-#74 / post-#75 unpack wall on the same corpus was
    /// dominated by `MetalCRC32.waitUntilCompleted` (~96 % of
    /// main-thread wall) — the GPU verify pass forced the input
    /// mmap to stay resident through that whole 60 s wait. PR #77
    /// (`--no-post-verify` default-on for the GUI) cut that to ~0 %,
    /// which made the unpack work *faster* on the happy path —
    /// but also surfaced a NEW failure mode on the same memory-rich
    /// host: jetsam (signal 9) on workloads that previously
    /// happened to complete before pressure built up. Without
    /// `MADV_DONTNEED`, the 80 GB archive's pages stay resident for
    /// the entire (now-shorter) unpack window, and the residual
    /// mid-extract memory pressure tips the kernel into killing
    /// the process.
    ///
    /// Fix: hint per-entry release at the end of each `extract`
    /// call, matching what PR #76 does per-batch on the pack side.
    /// Best-effort — kernel may ignore on filesystems that don't
    /// honour the hint; no worse than pre-fix.
    private func releaseInputPagesFor(entry: KnitEntry) {
        let len = Int(entry.compressedSize)
        guard len > 0 else { return }
        let start = Int(entry.dataOffset)
        // Bounds-check against the mmap'd region; should always hold
        // since `init` walks the archive header end-to-end before
        // returning, but defend against a hostile entry header that
        // somehow slipped through.
        guard start >= 0, start + len <= mapped.count else { return }
        let basePtr = UnsafeMutableRawPointer(mutating: mapped.pointer)
        _ = madvise(basePtr.advanced(by: start), len, MADV_DONTNEED)
    }

    /// staged decoder's sink writes each decoded block to `outHandle`
    /// in input order, exactly like the direct-libzstd loop, except
    /// the orchestrator first verifies a per-batch CRC fold and only
    /// then commits. Identical on-disk output; one RAM-bounded staging
    /// step extra. The point of this path isn't faster CPU decoding —
    /// it's that the same orchestration is what plugs GPU
    /// `BlockDecoding` implementations in safely later.
    private func extractViaStagedDecoder(entry: KnitEntry,
                                         outHandle: FileHandle,
                                         decoder: HybridZstdBatchDecoder,
                                         progressReporter: ProgressReporter?) throws {
        // Build the per-block frame slices into the mmap'd archive.
        // Bounds-check `compressed_size` cumulatively so a hostile
        // header can't make us walk past the mapped buffer.
        let blockCap = max(Int(entry.blockSize), 1)
        var blocks: [UnsafeBufferPointer<UInt8>] = []
        var sizes: [Int] = []
        blocks.reserveCapacity(entry.blockLengths.count)
        sizes.reserveCapacity(entry.blockLengths.count)

        var srcOffset = Int(entry.dataOffset)
        var declaredRemaining = Int(min(entry.uncompressedSize, UInt64(Int.max)))
        for blockLen in entry.blockLengths {
            let inLen = Int(blockLen)
            let inPtr = mapped.pointer.advanced(by: srcOffset)
            blocks.append(UnsafeBufferPointer(start: inPtr, count: inLen))

            // Each block's declared uncompressed size is the lesser of
            // `block_size` and what's left of `uncompressed_size`.
            let outSize = min(blockCap, declaredRemaining)
            guard outSize >= 0 else {
                throw KnitError.formatError(
                    ".knit: block declared size underflow in \(entry.name)"
                )
            }
            sizes.append(outSize)
            declaredRemaining -= outSize
            srcOffset += inLen
        }

        // Bypass the macOS unified buffer cache for this output file.
        // Without this, an 80 GB unpack accumulates ~64 GB of dirty
        // page-cache pages before the kernel begins flushing, on top
        // of the ~50 GB the read-only mmap of the archive holds. On a
        // 128 GB M5 Max this exceeds RAM, the kernel engages its
        // page-compressor, and a per-task `cpt_mapcnt` reference
        // counter on shared compressed pages overflows under high
        // worker concurrency — kernel panic. With `F_NOCACHE` writes
        // go straight to the NVMe controller's own write cache, peak
        // RSS stays bounded, and the panic vector is closed.
        // Best-effort: a filesystem that doesn't support direct I/O
        // simply falls back to the cached path (no failure mode worse
        // than the pre-fix behaviour).
        _ = fcntl(outHandle.fileDescriptor, F_NOCACHE, 1)

        let stats = try decoder.decode(blocks: blocks,
                                       blockSizes: sizes,
                                       expectedCRC32: entry.crc32) { batchBytes in
            // PR #74: switch back to `Data(bytesNoCopy:..., deallocator:
            // .none)` to drop the per-batch memcpy.
            //
            // The historical reason for `Data(buffer:)` (the copying
            // form) was CLAUDE.md Rule 3.1's `cpt_mapcnt` panic: under
            // the cached-write path, Foundation's vm_remap aliasing
            // accumulated VM references on shared physical pages until
            // the kernel's per-task refcount overflowed. PR #17 added
            // the `Data(buffer:)` copy to dodge it.
            //
            // CLAUDE.md Rule 3.1 addendum (PR #71) documents that the
            // panic is specifically the page-cache code path's
            // optimisation. With `F_NOCACHE` on the writer FD (set a
            // few lines up — Rule 3.2 / PR #17), writes bypass the
            // page cache entirely; vm_remap doesn't fire; no
            // accumulation. Under those conditions `bytesNoCopy` is
            // safe, and PR #70 already leans on the same exemption
            // for the ZIP `.stored` mmap-streaming path.
            //
            // Sample-trace evidence for the rewrite: 5 % of unpack
            // wall on an 80 GB `.pvm.knit` was `Data.init(bytes:)` →
            // `_platform_memmove` (the staged-buffer copy here).
            // Eliminating it saves the same percentage of wall in
            // exchange for a single inline closure tweak.
            //
            // `withExtendedLifetime` ensures the underlying staging
            // buffer (owned by `HybridZstdBatchDecoder.decodeBatch`)
            // stays alive through the write call. The sink contract
            // already requires the caller not to retain `batchBytes`
            // past return, so this is belt-and-braces against future
            // refactors of the staging-buffer lifetime.
            let count = batchBytes.count
            if count > 0, let base = batchBytes.baseAddress {
                let aliased = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                    count: count,
                    deallocator: .none
                )
                try outHandle.write(contentsOf: aliased)
            }
            withExtendedLifetime(batchBytes) {}
            progressReporter?.advance(by: UInt64(count))
        }

        if stats.totalBytes != entry.uncompressedSize {
            throw KnitError.integrity(
                "size mismatch for \(entry.name): expected \(entry.uncompressedSize), got \(stats.totalBytes)"
            )
        }
    }

    /// Recompute the CRC32 of the just-written file and compare against
    /// the value baked into the archive header. Routes large entries to the
    /// optional GPU implementation.
    ///
    /// `outPath` is byte-preserving — see `POSIXFile.swift` /
    /// `MappedFile.init(path:)` for why we don't take a `URL`
    /// here (would NFD-normalize and miss NFC files we just wrote).
    /// PR #82.
    private func verifyCRC(entry: KnitEntry,
                           outPath: String,
                           gpuCRC: MetalCRC32?) throws {
        guard entry.uncompressedSize > 0 else {
            // Empty file: by .knit convention the stored CRC is 0.
            if entry.crc32 != 0 {
                throw KnitError.integrity(
                    "CRC mismatch for \(entry.name): expected 0x\(String(entry.crc32, radix: 16)), file is empty"
                )
            }
            return
        }

        let outMap = try MappedFile(path: outPath)
        let buf = outMap.buffer

        // Threshold mirrors MetalCRC32's documented amortization point —
        // dispatch overhead dominates for small buffers.
        let gpuMin = 4 * 1024 * 1024
        let computed: UInt32
        if let gpu = gpuCRC, buf.count >= gpuMin {
            computed = try gpu.crc32(buf)
        } else {
            computed = UInt32(libdeflate_crc32(0, buf.baseAddress, buf.count))
        }

        if computed != entry.crc32 {
            throw KnitError.integrity(
                "CRC mismatch for \(entry.name): expected 0x\(String(entry.crc32, radix: 16)), got 0x\(String(computed, radix: 16))"
            )
        }
    }
}

// MARK: - Cursor

private struct ReadCursor {
    let buffer: UnsafeBufferPointer<UInt8>
    var offset: Int = 0

    mutating func peekUInt32() throws -> UInt32 {
        try ensure(4)
        return loadLE(at: offset)
    }
    mutating func readUInt8() throws -> UInt8 {
        try ensure(1)
        let v = buffer[offset]
        offset += 1
        return v
    }
    mutating func readUInt16() throws -> UInt16 {
        try ensure(2)
        let lo = UInt16(buffer[offset])
        let hi = UInt16(buffer[offset + 1])
        offset += 2
        return lo | (hi << 8)
    }
    mutating func readUInt32() throws -> UInt32 {
        try ensure(4)
        let v: UInt32 = loadLE(at: offset)
        offset += 4
        return v
    }
    mutating func readUInt64() throws -> UInt64 {
        try ensure(8)
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(buffer[offset + i]) << (8 * i)
        }
        offset += 8
        return v
    }
    mutating func readUTF8(length: Int) throws -> String {
        try ensure(length)
        let bytes = UnsafeBufferPointer(start: buffer.baseAddress!.advanced(by: offset),
                                        count: length)
        offset += length
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func skip(_ n: Int) throws {
        try ensure(n)
        offset += n
    }
    private func loadLE(at idx: Int) -> UInt32 {
        let b0 = UInt32(buffer[idx])
        let b1 = UInt32(buffer[idx + 1])
        let b2 = UInt32(buffer[idx + 2])
        let b3 = UInt32(buffer[idx + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    private func ensure(_ n: Int) throws {
        if offset + n > buffer.count {
            throw KnitError.formatError(".knit: unexpected end of file at \(offset) (need \(n))")
        }
    }
}
