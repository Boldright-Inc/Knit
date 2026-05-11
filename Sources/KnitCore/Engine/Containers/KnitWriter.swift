import Foundation
import Darwin   // writev(2), iovec, IOV_MAX — for the chunked-write path

/// Streaming writer for the `.knit` container format. See `KnitFormat` for
/// the exact byte layout — this class is the encoder side of that
/// specification.
///
/// Writes are append-only and serial: each `writeEntry` immediately emits
/// a complete entry to disk, the entry count accumulator is bumped, and
/// `close()` finalises with the footer. Designed to be invoked from a
/// single owning task; if multiple producers ever need to feed it, wrap
/// in a serial actor.
public final class KnitWriter {
    /// Per-entry metadata. The corresponding fields land in the
    /// `[name_len][name][mode][mod_unix][is_directory]` portion of the
    /// entry header (see `KnitFormat.swift`).
    public struct EntryHeader: Sendable {
        public let name: String
        public let modificationDate: Date
        public let unixMode: UInt16
        public let isDirectory: Bool
    }

    /// Per-entry compressed payload. `blockData` is the concatenation of
    /// `blockLengths.count` independent zstd frames; the lengths array
    /// lets the reader compute each frame's byte offset without parsing
    /// any zstd headers.
    public struct EntryPayload: Sendable {
        public let blockSize: UInt32
        public let uncompressedSize: UInt64
        public let crc32: UInt32
        public let blockLengths: [UInt32]
        public let blockData: Data
    }

    fileprivate let handle: FileHandle
    fileprivate var currentOffset: UInt64 = 0
    fileprivate var totalEntries: UInt64 = 0
    private var closed = false
    fileprivate var entryInProgress: Bool = false

    /// Truncates `url` and writes the file header immediately so that a
    /// subsequent `close()` produces a valid (if empty) archive even if
    /// no entries are added.
    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw KnitError.ioFailure(path: url.path, message: "cannot open for writing")
        }
        self.handle = h
        // PR #68: bypass the page cache for sustained multi-GB writes
        // (same rationale as ZipWriter — see CLAUDE.md Rule 3.2).
        // Without F_NOCACHE the kernel's writeback path fills RAM to
        // ~50% with dirty pages and engages the memory compressor,
        // throttling write throughput by 100× on large archives.
        // Best-effort; harmless on filesystems that don't honour it.
        _ = fcntl(h.fileDescriptor, F_NOCACHE, 1)
        try writeHeader()
    }

    deinit {
        if !closed { try? handle.close() }
    }

    /// Emit one full entry from a fully-buffered payload. Convenience
    /// shim around the streaming API for callers that already hold the
    /// complete compressed result in memory (e.g. tests, small entries).
    /// New code on the compressor side uses `beginStreamingEntry(...)`
    /// to keep peak memory bounded — see `KnitCompressor`.
    public func writeEntry(header: EntryHeader, payload: EntryPayload) throws {
        let streaming = try beginStreamingEntry(
            header: header,
            uncompressedSize: payload.uncompressedSize,
            blockSize: payload.blockSize,
            numBlocks: UInt32(payload.blockLengths.count)
        )
        var off = 0
        for len in payload.blockLengths {
            let frameLen = Int(len)
            // Per-block sub-data view — pulled out of the contiguous
            // `payload.blockData` buffer without copying.
            let frame = payload.blockData.subdata(in: off..<(off + frameLen))
            try streaming.writeBlock(frame)
            off += frameLen
        }
        try streaming.finish(crc32: payload.crc32)
    }

    /// Begin a streaming entry. The entry header is committed to disk
    /// immediately, with `compressed_size`, `crc32`, and `block_lengths[]`
    /// reserved as zero-filled placeholders. The caller writes block
    /// frames one at a time via the returned `StreamingEntry`; on
    /// `finish(crc32:)` the placeholders are seek-back-patched.
    ///
    /// Memory usage during a streaming entry is bounded by however many
    /// frames the caller chooses to hold in flight at once — the writer
    /// itself never buffers anything beyond the current `Data` argument.
    public func beginStreamingEntry(header: EntryHeader,
                                    uncompressedSize: UInt64,
                                    blockSize: UInt32,
                                    numBlocks: UInt32) throws -> StreamingEntry {
        precondition(!closed, "beginStreamingEntry on closed KnitWriter")
        precondition(!entryInProgress,
                     "beginStreamingEntry called while another streaming entry is open")

        var buf = Data()
        buf.appendLE(KnitFormat.entryMarker)
        let nameBytes = Array(header.name.utf8)
        buf.appendLE(UInt16(nameBytes.count))
        buf.append(contentsOf: nameBytes)
        buf.appendLE(header.unixMode)
        // Negative epoch values would underflow UInt64; clamp to 0 (1970-01-01).
        buf.appendLE(UInt64(max(0, Int(header.modificationDate.timeIntervalSince1970))))
        buf.append(header.isDirectory ? 1 : 0)
        buf.appendLE(blockSize)
        buf.appendLE(uncompressedSize)

        // Track the offsets of fields we'll patch after streaming completes.
        let entryStart = currentOffset
        let compressedSizeOffset = entryStart + UInt64(buf.count)
        buf.appendLE(UInt64(0))                         // compressed_size placeholder
        let crc32Offset = entryStart + UInt64(buf.count)
        buf.appendLE(UInt32(0))                         // crc32 placeholder
        buf.appendLE(numBlocks)
        let lengthsOffset = entryStart + UInt64(buf.count)
        // Reserve the block_lengths array. Even at 256 MiB blocks /
        // 256 PiB max entry, this is only `maxBlocksPerEntry × 4` bytes
        // = 16 MiB worst case.
        let lengthsBytes = Int(numBlocks) * 4
        if lengthsBytes > 0 {
            buf.append(Data(count: lengthsBytes))       // zero-filled placeholder
        }

        try handle.write(contentsOf: buf)
        currentOffset += UInt64(buf.count)
        entryInProgress = true

        return StreamingEntry(
            writer: self,
            entryStart: entryStart,
            compressedSizeOffset: compressedSizeOffset,
            crc32Offset: crc32Offset,
            lengthsOffset: lengthsOffset,
            totalBlocks: Int(numBlocks)
        )
    }

    /// Append the archive footer and close the file. Safe to call once
    /// per writer; subsequent calls are no-ops.
    public func close() throws {
        guard !closed else { return }
        var footer = Data()
        footer.appendLE(KnitFormat.footerMarker)
        footer.appendLE(totalEntries)
        footer.appendLE(KnitFormat.archiveVersion)
        try handle.write(contentsOf: footer)
        try handle.close()
        closed = true
    }

    private func writeHeader() throws {
        var head = Data()
        head.appendLE(KnitFormat.headerMagic)
        head.appendLE(KnitFormat.version)
        head.appendLE(UInt16(0))                  // flags (reserved for future use)
        head.appendLE(UInt64(0))                  // reserved padding to align entry markers
        try handle.write(contentsOf: head)
        currentOffset += UInt64(head.count)
    }
}

extension KnitWriter {

    /// Streaming handle for one in-progress `.knit` entry.
    ///
    /// Returned from `beginStreamingEntry(...)`. The caller writes block
    /// frames in input order via `writeBlock(_:)` and finalises the
    /// entry with `finish(crc32:)`. The writer holds no compressed-block
    /// data of its own — once `writeBlock` returns, the bytes are
    /// flushed to the underlying file handle and the caller's `Data`
    /// reference can be released.
    ///
    /// On `finish(...)`, three placeholder fields are seek-back patched:
    /// `compressed_size`, `crc32`, and `block_lengths[]`. The cursor is
    /// then restored to the end of the entry's data so the next
    /// `beginStreamingEntry` continues at the right offset.
    public final class StreamingEntry {
        fileprivate weak var writer: KnitWriter?
        private let entryStart: UInt64
        private let compressedSizeOffset: UInt64
        private let crc32Offset: UInt64
        private let lengthsOffset: UInt64
        private let totalBlocks: Int
        private var blocksWritten: Int = 0
        private var blockLengths: [UInt32] = []
        private var compressedBytes: UInt64 = 0
        private var finished: Bool = false

        /// Pending compressed-block frames awaiting drain to the
        /// underlying FD. Each `writeBlock` appends to this list;
        /// it flushes via one `writev(2)` syscall when the size or
        /// iovec-count threshold is reached, and again unconditionally
        /// at `finish(crc32:)` before the seek-back patches.
        ///
        /// **Why we batch — PR #77.** A `sample` trace of an 80 GB
        /// `.pvm` pack on M5 Max showed 70.6 % of main-thread wall
        /// in kernel `write(2)` calls — one syscall per ~1 MiB
        /// compressed block, ~80 000 syscalls total. With
        /// F_NOCACHE on the writer FD (PR #68), each write goes
        /// straight to the NVMe controller's DRAM cache; the
        /// controller achieves peak throughput only when its
        /// command queue stays deep (Apple SSDs scale near-linearly
        /// up to QD=64). Issuing 1 MiB writes synchronously kept
        /// the controller at effectively QD=1, capping sustained
        /// write throughput at ~3.9 GB/s vs the ~5-6 GB/s the SSD
        /// is capable of via APFS + F_NOCACHE.
        ///
        /// **Why `writev` instead of memcpy-into-one-`Data`.**
        /// Concatenating frames into one contiguous buffer before
        /// calling `write` would add ~2.7 s of memcpy wall on an
        /// 80 GB pack (one full extra pass over compressed bytes
        /// at ~30 GB/s) — close to the entire predicted wall-clock
        /// win. `writev(2)` gathers an array of memory regions in
        /// a single syscall with zero userspace copies.
        ///
        /// **Lifetime contract.** `flushPending()` bridges each
        /// pending `Data` to an `NSData` before extracting iovec
        /// pointers. `NSData.bytes` is formally guaranteed valid
        /// for the NSData's lifetime (unlike
        /// `Data.withUnsafeBytes`'s closure-only validity, which
        /// dangles for `Data`'s inline-storage path when the
        /// payload fits in ~14 bytes — see the comment in
        /// `flushPending()` for the failure mode). Bridging is
        /// O(1) for the common heap-stored case (1 MiB+ blocks)
        /// and bounded to ≲ 14 bytes copy for the inline case.
        private var pendingFrames: [Data] = []
        private var pendingBytes: Int = 0

        /// Byte threshold that triggers a `flushPending()` call
        /// inside `writeBlock`. 32 MiB is large enough to drive
        /// NVMe at deep queue depth (matches the `64 MiB` ZipWriter
        /// PR #73 picked for the analogous problem on `.stored`
        /// payloads, halved because here we typically flush more
        /// often via `finish()` at entry boundaries) and small
        /// enough that the pending buffer's peak memory stays
        /// bounded per worker.
        fileprivate static let flushBytesThreshold = 32 * 1024 * 1024

        /// Iovec-count cap that ALSO triggers a flush. `IOV_MAX`
        /// is 1024 on Darwin; we cap at 512 to leave headroom and
        /// to bound the per-syscall iovec-build cost. For the
        /// default 1 MiB blocks the byte threshold trips first
        /// (32 iovecs); the cap matters only for unusually small
        /// blocks (e.g. `--block-size 64K` would emit 512 frames
        /// per 32 MiB).
        fileprivate static let flushIOVecMax = 512

        fileprivate init(writer: KnitWriter,
                         entryStart: UInt64,
                         compressedSizeOffset: UInt64,
                         crc32Offset: UInt64,
                         lengthsOffset: UInt64,
                         totalBlocks: Int) {
            self.writer = writer
            self.entryStart = entryStart
            self.compressedSizeOffset = compressedSizeOffset
            self.crc32Offset = crc32Offset
            self.lengthsOffset = lengthsOffset
            self.totalBlocks = totalBlocks
            self.blockLengths.reserveCapacity(totalBlocks)
        }

        /// Append one compressed block frame. Must be called exactly
        /// `numBlocks` times (or zero times for a directory entry)
        /// before `finish(crc32:)`. Bytes are queued in
        /// `pendingFrames` and flushed via `writev(2)` when the
        /// threshold is hit or at `finish(crc32:)` time — the
        /// caller's `frame` `Data` can be released as soon as
        /// this method returns (its storage is retained by
        /// `pendingFrames` until flush). PR #77.
        public func writeBlock(_ frame: Data) throws {
            guard let writer = writer else {
                throw KnitError.codecFailure("writeBlock after writer closed")
            }
            precondition(!finished, "writeBlock after finish")
            precondition(blocksWritten < totalBlocks,
                         "writeBlock called more times than declared numBlocks")
            // Logical bookkeeping advances immediately so subsequent
            // `entryStart`-relative math (the patches in finish()) and
            // the writer's `currentOffset` model stay consistent; the
            // kernel cursor catches up when flushPending() runs.
            pendingFrames.append(frame)
            pendingBytes += frame.count
            writer.currentOffset += UInt64(frame.count)
            blockLengths.append(UInt32(frame.count))
            compressedBytes += UInt64(frame.count)
            blocksWritten += 1

            if pendingBytes >= Self.flushBytesThreshold
                || pendingFrames.count >= Self.flushIOVecMax {
                try flushPending()
            }
        }

        /// Drain `pendingFrames` to disk via one or more `writev(2)`
        /// calls. Called from `writeBlock` on threshold trips and
        /// unconditionally from `finish(crc32:)` before the
        /// seek-back patches — with F_NOCACHE the kernel doesn't
        /// buffer writes, so seeking before the flush would scribble
        /// the patches into a position the payload hasn't reached
        /// yet on disk. PR #77.
        private func flushPending() throws {
            guard let writer = writer else {
                throw KnitError.codecFailure("flushPending after writer closed")
            }
            guard !pendingFrames.isEmpty else { return }

            let fd = writer.handle.fileDescriptor

            // Bridge each pending Swift `Data` to `NSData`. We
            // need stable pointers (NSData.bytes is documented to
            // remain valid for the NSData's lifetime), whereas
            // `Data.withUnsafeBytes`'s pointer is formally valid
            // only inside the closure body. The escape works in
            // production where compressed blocks are ~1 MiB and
            // always heap-stored, but breaks for small payloads
            // (≲ 14 B) that hit `Data`'s inline-storage path —
            // the bytes live inside the `Data` struct, which is
            // a stack temporary during `for frame in pendingFrames`,
            // and the pointer dangles once the loop iteration
            // ends. Bridging forces inline-stored Data onto the
            // heap (small one-time copy, bounded to ≲ 14 B per
            // frame) and is O(1) for the common heap-stored case.
            let pinned: [NSData] = pendingFrames.map { $0 as NSData }

            try withExtendedLifetime(pinned) {
                var iovecs: [iovec] = []
                iovecs.reserveCapacity(pinned.count)
                for ns in pinned where ns.length > 0 {
                    iovecs.append(iovec(
                        iov_base: UnsafeMutableRawPointer(mutating: ns.bytes),
                        iov_len: ns.length
                    ))
                }
                if iovecs.isEmpty { return }

                // writev(2) is spec'd to return less than the
                // requested byte count on partial-write conditions
                // (rare on regular files but legal — e.g. signal
                // interruption). Loop until every iovec is drained,
                // advancing the iovec pointer/length in place to
                // skip already-written ranges. We also cap each
                // syscall's iovec count at IOV_MAX as a defensive
                // measure even though `flushIOVecMax` already
                // enforces a tighter bound at queueing time.
                try iovecs.withUnsafeMutableBufferPointer { iovBuf in
                    var iovStart = 0
                    while iovStart < iovBuf.count {
                        let count = Int32(min(iovBuf.count - iovStart, Int(IOV_MAX)))
                        let written = Darwin.writev(
                            fd,
                            iovBuf.baseAddress!.advanced(by: iovStart),
                            count
                        )
                        if written < 0 {
                            let saved = Darwin.errno
                            let msg = String(cString: strerror(saved))
                            throw KnitError.ioFailure(
                                path: "<knit-writer>",
                                message: "writev failed (errno=\(saved): \(msg))"
                            )
                        }
                        if written == 0 {
                            // Per POSIX, writev returning 0 on a
                            // regular file with positive iov_len is
                            // anomalous — typically ENOSPC manifests
                            // as -1 with errno set, but defend
                            // against an out-of-space race that
                            // surfaces as a zero-byte write.
                            throw KnitError.ioFailure(
                                path: "<knit-writer>",
                                message: "writev returned 0 (filesystem full?)"
                            )
                        }
                        // Advance past consumed iovecs. The kernel
                        // wrote `written` bytes contiguously from
                        // the front of the current iovec list.
                        var remaining = Int(written)
                        while remaining > 0 && iovStart < iovBuf.count {
                            let iov = iovBuf[iovStart]
                            if remaining >= iov.iov_len {
                                remaining -= iov.iov_len
                                iovStart += 1
                            } else {
                                // Partial iovec consumption — adjust
                                // its base/len in place for the next
                                // writev iteration.
                                iovBuf[iovStart].iov_base =
                                    iov.iov_base!.advanced(by: remaining)
                                iovBuf[iovStart].iov_len =
                                    iov.iov_len - remaining
                                remaining = 0
                            }
                        }
                    }
                }
            }

            pendingFrames.removeAll(keepingCapacity: true)
            pendingBytes = 0
        }

        /// Finalise the entry: patch `compressed_size`, `crc32`, and
        /// `block_lengths[]` in the previously-reserved header
        /// placeholders, then restore the file cursor to the end of the
        /// entry so subsequent writes append correctly.
        public func finish(crc32: UInt32) throws {
            guard let writer = writer else {
                throw KnitError.codecFailure("finish after writer closed")
            }
            precondition(!finished, "finish called twice on the same entry")
            precondition(blocksWritten == totalBlocks,
                         "finish called with \(blocksWritten)/\(totalBlocks) blocks written")

            // Drain any queued payload bytes before the seek-back
            // patches below — see `flushPending()` for the F_NOCACHE
            // ordering hazard (the patches would otherwise scribble
            // into the middle of unwritten payload). PR #77.
            try flushPending()

            // Remember the end of the data section; we'll seek back here
            // before returning so the next entry begins at the right
            // offset.
            let endOfEntry = writer.currentOffset

            // Patch compressed_size (UInt64 LE) at its reserved slot.
            try writer.handle.seek(toOffset: compressedSizeOffset)
            var csData = Data()
            csData.appendLE(compressedBytes)
            try writer.handle.write(contentsOf: csData)

            // Patch crc32 (UInt32 LE) at its reserved slot. The seek
            // after the compressed_size write is implicit in the
            // sequential layout of the header — but we re-seek
            // explicitly to be robust against any future field
            // re-ordering.
            try writer.handle.seek(toOffset: crc32Offset)
            var crcData = Data()
            crcData.appendLE(crc32)
            try writer.handle.write(contentsOf: crcData)

            // Patch the block_lengths array.
            if totalBlocks > 0 {
                try writer.handle.seek(toOffset: lengthsOffset)
                var lengthsData = Data()
                lengthsData.reserveCapacity(totalBlocks * 4)
                for len in blockLengths { lengthsData.appendLE(len) }
                try writer.handle.write(contentsOf: lengthsData)
            }

            // Restore the cursor to end-of-entry so the next entry
            // header starts at the right place.
            try writer.handle.seek(toOffset: endOfEntry)
            writer.currentOffset = endOfEntry
            writer.totalEntries += 1
            writer.entryInProgress = false
            finished = true
        }
    }
}

// Little-endian byte appenders are in DataLEAppend.swift.
