import Foundation
import CDeflate

/// Top-level extractor for `.zip` archives. Mirrors `KnitExtractor`
/// (on the `.knit` side) — same mixed-granularity orchestration, same
/// `SafePath` zip-slip defence, same `--analyze`-driven instrumentation
/// vocabulary so a `knit unzip --analyze` run produces output that can
/// be lined up against `knit unpack --analyze` rows directly.
///
/// **Position in the bigger plan.** This PR's purpose is to give Knit a
/// CPU baseline `unzip` so `--analyze` can be collected on real ZIP
/// workloads. The Rule 4.1 decision-table outcome on that data is the
/// gate for any future GPU-decode work — see `docs` and CLAUDE.md
/// "Investigated, no-go" for why GPU acceleration of DEFLATE itself is
/// unlikely to win on Apple Silicon. The CPU baseline is the
/// deliverable; the bench data is the verification.
///
/// **Mixed-granularity parallelism (CLAUDE.md Rule 5.2 / KnitExtractor
/// shape):**
///
///   * **Large entries** (≥ 16 MiB): serial across entries with
///     intra-entry parallelism for CRC verify on `.stored` payloads.
///     Memory stays bounded for 100 GB+ single files (e.g. a Parallels
///     VM image ZIP'd as `.stored`).
///   * **Small entries**: gathered into batches and extracted across
///     workers in parallel via `concurrentMap`. Each worker opens its
///     own FD, libdeflate-decompresses (when `.deflate`) or
///     memcpy-streams (when `.stored`) its entry.
public final class ZipExtractor {

    /// Aggregate result returned to the CLI. `entries` equals the
    /// number of entries written (directories included); `bytesOut`
    /// totals the uncompressed payload size.
    public struct Stats: Sendable {
        public let entries: Int
        public let bytesOut: UInt64
        public let elapsed: TimeInterval
    }

    /// When true (the default), each extracted entry is CRC32-verified
    /// against the value recorded in the central directory. Set to
    /// `false` via `--no-post-verify` (symmetric to `KnitExtractor`'s
    /// `postWriteVerify`) — `.deflate` decode already implicitly
    /// catches length mismatches (libdeflate's `LIBDEFLATE_SHORT_OUTPUT`),
    /// so opting out of the CRC pass only loses the "disk lost bytes
    /// after my write(2) returned" defence which APFS + NVMe already
    /// cover at the FS/controller level. PR #75 documented the
    /// equivalent trade-off on `.knit`.
    public var postVerify: Bool

    /// Optional progress sink. Receives one `advance(by:)` call per
    /// extracted entry, in uncompressed-byte units.
    public var progressReporter: ProgressReporter?

    /// Number of worker threads for entry-level parallelism. Defaults
    /// to `activeProcessorCount`. Inner parallelism (parallel CRC on
    /// large `.stored` entries) reuses the same concurrency knob.
    public var concurrency: Int

    /// Optional per-stage timing accumulator. Same accumulator type as
    /// `KnitExtractor.analytics` (32-shard sharded `record()`); when
    /// nil, the hot path pays nothing. Stage labels:
    ///
    ///   * `parallel.decode`   — libdeflate cumulative wall (workers).
    ///   * `crc.verify`        — post-decompress CRC walk wall.
    ///   * `sink.write`        — output FD `write(2)` wall.
    ///   * `staging.alloc`     — per-entry output buffer alloc + free.
    ///
    /// These deliberately reuse the names from the `.knit` decode side
    /// (CLAUDE.md "Decode (HybridZstdBatchDecoder)" stage table) so the
    /// renderer doesn't need a separate ZIP-specific format.
    public var analytics: StageAnalytics?

    public init(postVerify: Bool = true,
                progressReporter: ProgressReporter? = nil,
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                analytics: StageAnalytics? = nil) {
        self.postVerify = postVerify
        self.progressReporter = progressReporter
        self.concurrency = max(1, concurrency)
        self.analytics = analytics
    }

    /// Mirrors `KnitExtractor.largeEntryThreshold`. Entries below this
    /// take the parallel-across-entries batch path; entries at or
    /// above take the serial path with intra-entry parallelism for
    /// the CRC walk.
    private static let largeEntryThreshold: UInt64 = 16 * 1024 * 1024

    /// Defensive cap on `.deflate` entries. libdeflate has no
    /// streaming API; one entry = one contiguous output buffer.
    /// Allocating arbitrarily large buffers risks OOM on base
    /// Apple Silicon (Rule 4.4: 8 GB RAM is the design target).
    /// 4 GiB is a generous ceiling — well above realistic compressed
    /// entries (Knit's writer steers high-entropy files to `.stored`
    /// via the probe, so we shouldn't normally see multi-GB
    /// `.deflate` entries from Knit-produced archives).
    ///
    /// Hitting this cap throws `unsupported`, giving the user a
    /// clear error message rather than a silent allocator failure.
    private static let maxDeflateEntrySize: UInt64 = 4 * 1024 * 1024 * 1024

    public func extract(archive: URL, to destDir: URL) throws -> Stats {
        let reader = try ZipReader(url: archive)

        analytics?.startWallClock()

        // Pre-create destination root + every parent directory in a
        // single serial pass before parallel extract. Same APFS
        // b-tree-contention rationale as `KnitExtractor` (PR #31).
        _ = POSIXFile.mkdirParents(destDir.path)
        let destDirPath = destDir.path

        let entries = reader.entries
        var perEntryOutPaths: [String] = []
        perEntryOutPaths.reserveCapacity(entries.count)
        var parentPaths: Set<String> = []
        for entry in entries {
            let outPath = try SafePath.resolvePath(name: entry.name,
                                                    into: destDirPath)
            perEntryOutPaths.append(outPath)
            if entry.isDirectory {
                parentPaths.insert(outPath)
            }
            if let slash = outPath.lastIndex(of: "/") {
                parentPaths.insert(String(outPath[..<slash]))
            }
        }
        for parentPath in parentPaths {
            _ = POSIXFile.mkdirParents(parentPath)
        }

        let start = ContinuousClock.now
        var bytesOut: UInt64 = 0

        // Capture into locals for the @Sendable closure (Rule 1.1).
        let readerLocal = reader
        let analyticsLocal = analytics
        let reporter = progressReporter
        let postVerifyLocal = postVerify
        let outerConcurrency = self.concurrency

        var i = 0
        while i < entries.count {
            let entry = entries[i]

            // Large entry: serial across entries, parallel within.
            if !entry.isDirectory && entry.uncompressedSize >= Self.largeEntryThreshold {
                try Self.extractOne(
                    reader: readerLocal,
                    entry: entry,
                    outPath: perEntryOutPaths[i],
                    concurrency: outerConcurrency,
                    analytics: analyticsLocal,
                    postVerify: postVerifyLocal
                )
                reporter?.advance(by: entry.uncompressedSize)
                bytesOut += entry.uncompressedSize
                readerLocal.releaseInputPagesFor(entry)
                i += 1
                continue
            }

            // Run of small entries (and directories). Batch via
            // concurrentMap. Each worker uses its own FD + decompressor.
            var j = i
            let maxBatch = max(outerConcurrency * 4, 8)
            while j < entries.count
                && (j - i) < maxBatch
                && (entries[j].isDirectory
                    || entries[j].uncompressedSize < Self.largeEntryThreshold) {
                j += 1
            }
            let batch = Array(entries[i..<j])
            let batchOutPaths = Array(perEntryOutPaths[i..<j])

            let _: [UInt64] = try concurrentMap(
                Array(batch.indices),
                concurrency: outerConcurrency
            ) { k in
                let e = batch[k]
                try Self.extractOne(
                    reader: readerLocal,
                    entry: e,
                    outPath: batchOutPaths[k],
                    // Inner concurrency = 1 — the outer batch saturates
                    // the worker pool, intra-entry parallel CRC would
                    // just over-subscribe GCD.
                    concurrency: 1,
                    analytics: analyticsLocal,
                    postVerify: postVerifyLocal
                )
                reporter?.advance(by: e.uncompressedSize)
                readerLocal.releaseInputPagesFor(e)
                return e.uncompressedSize
            }

            for e in batch {
                bytesOut += e.uncompressedSize
            }
            i = j
        }

        let elapsed = ContinuousClock.now - start
        return Stats(
            entries: entries.count,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }

    // MARK: - Per-entry extraction

    /// Extract one entry to `outPath`. Routes by compression method:
    ///   * directory: `mkdir` + chmod + mtime.
    ///   * `.stored`:  stream from input mmap to output FD (no decode).
    ///   * `.deflate`: alloc output buffer of exact uncompressed size,
    ///                 libdeflate-decompress, write to output FD.
    /// CRC verify (when enabled) uses `parallelCRC32` so the inner
    /// concurrency budget is spent productively on large `.stored`
    /// entries.
    fileprivate static func extractOne(reader: ZipReader,
                                       entry: ZipEntry,
                                       outPath: String,
                                       concurrency: Int,
                                       analytics: StageAnalytics?,
                                       postVerify: Bool) throws {
        if entry.isDirectory {
            _ = POSIXFile.mkdirParents(outPath)
            _ = outPath.withCString { chmod($0, mode_t(entry.unixMode)) }
            POSIXFile.setMTime(
                path: outPath,
                secondsSince1970: Int64(entry.modificationDate.timeIntervalSince1970)
            )
            return
        }

        // Parent-dir safety net (same as KnitReader). Lookup is a
        // single byte-slice + stat; on the pre-created tree this is a
        // cheap no-op.
        if let lastSlash = outPath.lastIndex(of: "/") {
            let parentPath = String(outPath[..<lastSlash])
            if !parentPath.isEmpty {
                _ = POSIXFile.mkdirParents(parentPath)
            }
        }

        let outHandle = try POSIXFile.openForWriting(outPath,
                                                     mode: mode_t(entry.unixMode))
        _ = outPath.withCString { chmod($0, mode_t(entry.unixMode)) }
        // Rule 3.2 / PR #68: bypass the page cache. Without F_NOCACHE
        // an 80 GB `.stored` unzip would fill ~50 % of RAM with dirty
        // pages and risk the same vm_remap accumulation that bit the
        // pack path (Rule 3.1 / PR #17). Best-effort.
        _ = fcntl(outHandle.fileDescriptor, F_NOCACHE, 1)
        defer { try? outHandle.close() }

        let payload = try reader.payload(for: entry)

        switch entry.method {
        case .stored:
            // No decode. Stream straight from mmap to FD in 64 MiB
            // chunks (matches ZipWriter's `payloadWriteChunkSize` —
            // PR #73 NVMe-queue-depth calibration). Each chunk's
            // input mmap range is released via `MADV_DONTNEED`
            // after write (PR #76 unpack-side mirror).
            //
            // CRC verify is the parallelCRC32 walk over the freshly
            // written output (re-read via a transient mmap on the
            // output path so the verifier sees what landed on disk).
            // For the within-entry parallel CRC to actually parallelise
            // we pass the outer concurrency through — when called from
            // the small-batch path this is 1 (already saturated) and
            // we fall through to the single-threaded libdeflate CRC
            // (still hardware-accelerated, ~7 GB/s).
            let writeStart = ContinuousClock.now
            try storedStreamCopy(payload: payload, outHandle: outHandle)
            analytics?.record(stage: "sink.write",
                              seconds: (ContinuousClock.now - writeStart).timeIntervalSeconds)

            if postVerify {
                let crcStart = ContinuousClock.now
                try verifyCRC(entry: entry, outPath: outPath, concurrency: concurrency)
                analytics?.record(stage: "crc.verify",
                                  seconds: (ContinuousClock.now - crcStart).timeIntervalSeconds)
            }

        case .deflate:
            // Defensive size cap (see `maxDeflateEntrySize` doc-block).
            guard entry.uncompressedSize <= maxDeflateEntrySize else {
                throw KnitError.unsupported(
                    "zip: entry '\(entry.name)' uncompressed size \(entry.uncompressedSize) " +
                    "exceeds the \(maxDeflateEntrySize)-byte cap for libdeflate one-shot decode")
            }

            let allocStart = ContinuousClock.now
            // Allocate exactly the expected uncompressed size — that
            // makes libdeflate's `out_nbytes_avail` strict (no
            // `actual_out_nbytes_ret`), so a CD-vs-stream mismatch
            // throws at decode time rather than during a separate
            // length check (CPUDeflateDecoder doc-block has the
            // rationale).
            let outCount = Int(entry.uncompressedSize)
            let outBuf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: outCount)
            defer { outBuf.deallocate() }
            // No need to zero-fill — libdeflate writes exactly
            // outCount bytes on success.
            analytics?.record(stage: "staging.alloc",
                              seconds: (ContinuousClock.now - allocStart).timeIntervalSeconds)

            let decodeStart = ContinuousClock.now
            let decoder = CPUDeflateDecoder()
            try decoder.decompress(input: payload, into: outBuf)
            analytics?.record(stage: "parallel.decode",
                              seconds: (ContinuousClock.now - decodeStart).timeIntervalSeconds)

            if postVerify {
                let crcStart = ContinuousClock.now
                let computed = parallelCRC32(
                    UnsafeBufferPointer(outBuf),
                    using: CPUDeflate(),
                    concurrency: concurrency
                )
                analytics?.record(stage: "crc.verify",
                                  seconds: (ContinuousClock.now - crcStart).timeIntervalSeconds)
                if computed != entry.crc32 {
                    throw KnitError.integrity(
                        "zip: CRC mismatch for '\(entry.name)': " +
                        "expected 0x\(String(entry.crc32, radix: 16)), " +
                        "got 0x\(String(computed, radix: 16))")
                }
            }

            // Write the decompressed buffer to the output FD. Single
            // `write(2)` for entries under the 64 MiB chunk size,
            // otherwise chunked to keep NVMe queue depth fed (PR #73
            // rationale). Wrapping the buffer with
            // `Data(bytesNoCopy:..., deallocator: .none)` is safe here
            // because the FD has F_NOCACHE — Rule 3.1 addendum / PR
            // #71.
            let writeStart = ContinuousClock.now
            try writeDecompressedBuffer(outBuf, to: outHandle)
            analytics?.record(stage: "sink.write",
                              seconds: (ContinuousClock.now - writeStart).timeIntervalSeconds)
        }

        // Stamp mtime while the FD is still open (cheaper than
        // utimes-by-path) — PR #82 / KnitReader symmetric.
        POSIXFile.setMTime(
            fd: outHandle.fileDescriptor,
            secondsSince1970: Int64(entry.modificationDate.timeIntervalSince1970)
        )
    }

    /// `.stored` entry copy. Stream `payload` (a slice of the input
    /// mmap) to `outHandle` in 64 MiB chunks. Each chunk gets a
    /// post-write `MADV_DONTNEED` hint on its input mmap range so
    /// large `.stored` entries don't accumulate ~80 GB of resident
    /// input pages — mirrors `ZipWriter.writeRawChunkedMapped` (PR
    /// #76 unpack-side).
    fileprivate static func storedStreamCopy(payload: UnsafeBufferPointer<UInt8>,
                                             outHandle: FileHandle) throws {
        guard let base = payload.baseAddress, payload.count > 0 else { return }
        let chunkSize = 64 * 1024 * 1024
        if payload.count <= chunkSize {
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                count: payload.count,
                deallocator: .none
            )
            try outHandle.write(contentsOf: data)
            return
        }
        var offset = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            let chunkPtr = base.advanced(by: offset)
            let chunkLen = end - offset
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: chunkPtr),
                count: chunkLen,
                deallocator: .none
            )
            try outHandle.write(contentsOf: data)
            _ = madvise(UnsafeMutableRawPointer(mutating: chunkPtr),
                        chunkLen,
                        MADV_DONTNEED)
            offset = end
        }
    }

    /// Write a decompressed in-memory buffer to the output FD. Same
    /// 64 MiB chunking as the `.stored` path — keeps the write loop's
    /// behaviour identical regardless of method, and matches the
    /// post-PR-#73 syscall-byte-budget tuning the ZipWriter side uses.
    fileprivate static func writeDecompressedBuffer(_ buf: UnsafeMutableBufferPointer<UInt8>,
                                                    to outHandle: FileHandle) throws {
        guard let base = buf.baseAddress, buf.count > 0 else { return }
        let chunkSize = 64 * 1024 * 1024
        if buf.count <= chunkSize {
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(base),
                count: buf.count,
                deallocator: .none
            )
            try outHandle.write(contentsOf: data)
            return
        }
        var offset = 0
        while offset < buf.count {
            let end = min(offset + chunkSize, buf.count)
            let chunkPtr = base.advanced(by: offset)
            let chunkLen = end - offset
            let data = Data(
                bytesNoCopy: UnsafeMutableRawPointer(chunkPtr),
                count: chunkLen,
                deallocator: .none
            )
            try outHandle.write(contentsOf: data)
            offset = end
        }
    }

    /// Re-map the freshly written output file read-only and CRC32 it.
    /// `parallelCRC32` short-circuits to a single libdeflate call
    /// below the 64 MiB threshold; above it, the work is split across
    /// `concurrency` workers (see `CRC32Combine.swift`). For the
    /// small-batch path (`concurrency = 1`) this just runs the
    /// hardware-CRC walk on one core.
    fileprivate static func verifyCRC(entry: ZipEntry,
                                      outPath: String,
                                      concurrency: Int) throws {
        guard entry.uncompressedSize > 0 else {
            if entry.crc32 != 0 {
                throw KnitError.integrity(
                    "zip: CRC mismatch for '\(entry.name)': " +
                    "expected 0x\(String(entry.crc32, radix: 16)), file is empty")
            }
            return
        }
        let outMap = try MappedFile(path: outPath)
        let computed = parallelCRC32(outMap.buffer,
                                     using: CPUDeflate(),
                                     concurrency: concurrency)
        if computed != entry.crc32 {
            throw KnitError.integrity(
                "zip: CRC mismatch for '\(entry.name)': " +
                "expected 0x\(String(entry.crc32, radix: 16)), " +
                "got 0x\(String(computed, radix: 16))")
        }
    }
}
