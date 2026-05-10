import Foundation

/// Orchestrator for the `.knit` path.
///
/// Unlike `ZipCompressor`, the entry-level loop here is **serial** because
/// `KnitWriter` is append-only and we want deterministic on-disk layout.
/// The parallelism instead happens *inside* each entry: a single large
/// file is split into many independent zstd-frame blocks, all of which
/// compress in parallel via `ParallelBlockCompressor`.
///
/// This shape suits the `.knit` use-case (often "one or a handful of very
/// large files") better than the ZIP shape (often "many small files").
public final class KnitCompressor: Sendable {

    public struct Options: Sendable {
        public var level: CompressionLevel
        public var concurrency: Int
        public var blockSize: Int
        /// Optional sink for per-block compressibility samples driving the
        /// heatmap visualization.
        public var heatmapRecorder: HeatmapRecorder?
        /// When true, blocks above the entropy threshold are compressed at
        /// lvl=1 even if the user requested higher — match search is pure
        /// overhead on incompressible data.
        public var entropyProbeEnabled: Bool

        public init(level: CompressionLevel = .default,
                    concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                    blockSize: Int = Int(KnitFormat.defaultBlockSize),
                    heatmapRecorder: HeatmapRecorder? = nil,
                    entropyProbeEnabled: Bool = true) {
            self.level = level
            self.concurrency = max(1, concurrency)
            self.blockSize = blockSize
            self.heatmapRecorder = heatmapRecorder
            self.entropyProbeEnabled = entropyProbeEnabled
        }
    }

    private let backend: BlockBackend
    private let crc: CRC32Computing
    private let options: Options
    private let probe: any EntropyProbing

    public init(backend: BlockBackend & CRC32Computing, options: Options = Options()) {
        self.backend = backend
        self.crc = backend
        self.options = options
        self.probe = AutoEntropyProbe()
    }

    public func compress(input: URL, to output: URL) throws -> CompressionStats {
        let entries = try FileWalker.enumerate(input)
        let writer = try KnitWriter(url: output)
        let start = ContinuousClock.now

        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0

        for entry in entries {
            let header = KnitWriter.EntryHeader(
                name: entry.relativePath,
                modificationDate: entry.modificationDate,
                unixMode: entry.unixMode,
                isDirectory: entry.isDirectory
            )

            let payload: KnitWriter.EntryPayload
            if entry.isDirectory {
                payload = KnitWriter.EntryPayload(
                    blockSize: 0,
                    uncompressedSize: 0,
                    crc32: 0,
                    blockLengths: [],
                    blockData: Data()
                )
            } else {
                let mapped = try MappedFile(url: entry.absoluteURL)
                let buf = mapped.buffer
                let crcVal = buf.count == 0 ? 0 : crc.crc32(buf, seed: 0)

                let pbc = ParallelBlockCompressor(
                    backend: backend,
                    blockSize: options.blockSize,
                    concurrency: options.concurrency
                )

                // Probe per-block entropy before invoking the codec. The
                // result feeds two independent decisions:
                //   1. Per-block level downgrade — incompressible blocks
                //      compress at lvl=1 regardless of user level, since
                //      lvl≥3 match search is pure overhead on noise.
                //   2. Heatmap sampling — every probed block contributes a
                //      coloured cell to the visualization.
                let baseLevel = options.level.clampedForZstd()
                var probeResults: [EntropyResult] = []
                if options.entropyProbeEnabled, buf.count > 0 {
                    probeResults = (try? probe.probe(buf, blockSize: options.blockSize)) ?? []
                }

                let perBlockLevels: [Int32]?
                if !probeResults.isEmpty, baseLevel > 1 {
                    perBlockLevels = probeResults.map { r in
                        r.isLikelyIncompressible ? Int32(1) : baseLevel
                    }
                } else {
                    perBlockLevels = nil
                }

                let blockOut = try pbc.compress(
                    buf,
                    level: baseLevel,
                    perBlockLevels: perBlockLevels
                )

                if let recorder = options.heatmapRecorder, !probeResults.isEmpty {
                    var batch: [HeatmapSample] = []
                    batch.reserveCapacity(probeResults.count)
                    let sizes = blockOut.blockSizes
                    for (i, r) in probeResults.enumerated() {
                        let stored = i < sizes.count ? Int(sizes[i]) : r.byteCount
                        let disposition: HeatmapSample.Disposition =
                            r.isLikelyIncompressible ? .stored : .compressed
                        batch.append(HeatmapSample(
                            entropy: r.entropy,
                            originalBytes: r.byteCount,
                            storedBytes: stored,
                            disposition: disposition
                        ))
                    }
                    recorder.recordBatch(batch)
                }

                payload = KnitWriter.EntryPayload(
                    blockSize: UInt32(options.blockSize),
                    uncompressedSize: UInt64(buf.count),
                    crc32: crcVal,
                    blockLengths: blockOut.blockSizes,
                    blockData: blockOut.combined
                )
            }

            try writer.writeEntry(header: header, payload: payload)
            bytesIn  += payload.uncompressedSize
            bytesOut += UInt64(payload.blockData.count)
        }

        try writer.close()
        let elapsed = ContinuousClock.now - start
        return CompressionStats(
            entriesWritten: entries.count,
            bytesIn: bytesIn,
            bytesOut: bytesOut,
            elapsed: elapsed.timeIntervalSeconds
        )
    }
}
