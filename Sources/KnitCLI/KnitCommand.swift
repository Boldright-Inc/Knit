// CLI front-end for KnitCore. Five subcommands:
//
//   info        — environment + linked codec versions
//   metal-info  — Metal device probe and a CRC32 self-test
//   zip         — produce a standard ZIP (DEFLATE)
//   pack        — produce a .knit (block-parallel zstd)
//   unpack      — extract a .knit archive (CRC-verified)
//
// Argument parsing is delegated to swift-argument-parser. Each subcommand
// is responsible only for translating flags into a `KnitCore` invocation
// and printing the resulting stats — all real work lives in KnitCore.

import Foundation
import ArgumentParser
import KnitCore

@main
struct KnitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "knit",
        abstract: "Knit — fast ZIP/.knit compression for Apple Silicon.",
        version: Knit.version,
        subcommands: [Info.self, Zip.self, Pack.self, Unpack.self, MetalInfo.self]
    )
}

extension KnitCommand {
    struct Info: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Print version and codec library info."
        )

        func run() throws {
            print("Knit \(Knit.version)")
            print("  libdeflate: \(Knit.libdeflateVersion())")
            print("  zstd:       \(Knit.zstdVersion())")
            print("  cores:      \(ProcessInfo.processInfo.activeProcessorCount)")
        }
    }

    struct Zip: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "zip",
            abstract: "Compress a file or directory into a standard ZIP (DEFLATE)."
        )

        @Argument(help: "Input file or directory.")
        var input: String

        @Option(name: .shortAndLong, help: "Output .zip path. Defaults to <input>.zip.")
        var output: String?

        @Option(name: .shortAndLong, help: "Compression level 0..12 (libdeflate).")
        var level: Int = 6

        @Option(help: "Compression concurrency. Defaults to active core count.")
        var jobs: Int?

        @Flag(name: .long, help: "Use chunk-parallel zlib backend (faster on few large files).")
        var parallel: Bool = false

        @Option(help: "Chunk size in KB for --parallel backend.")
        var chunkKb: Int = 1024

        @Flag(name: .long,
              help: "Render a GPU-accelerated compressibility heatmap after the run.")
        var heatmap: Bool = false

        @Option(name: .long,
                help: "Also save the heatmap as a PPM image (open with Preview.app).")
        var heatmapImage: String?

        @Flag(name: .long,
              help: "Disable the entropy pre-screening pass (debugging).")
        var noEntropyProbe: Bool = false

        @Flag(name: .long,
              help: "Force the live progress bar on (overrides the default TTY-based detection).")
        var progress: Bool = false

        @Flag(name: .customLong("no-progress"),
              help: "Suppress the live progress bar even when stderr is a terminal.")
        var noProgress: Bool = false

        @Flag(name: .customLong("progress-json"),
              help: ArgumentHelp(
                "Emit ndjson progress on stderr instead of the text bar. Used by Knit.app to drive an NSProgress.",
                visibility: .private))
        var progressJSON: Bool = false

        @Flag(name: .customLong("exclude-hidden"),
              help: "Skip hidden items (.git, .DS_Store, anything with the macOS hidden flag). Default is to include them, matching tar/zip.")
        var excludeHidden: Bool = false

        func run() throws {
            let inputURL = URL(fileURLWithPath: input).standardizedFileURL
            let outputURL = URL(fileURLWithPath: output ?? "\(input).zip").standardizedFileURL

            let cores = jobs ?? ProcessInfo.processInfo.activeProcessorCount
            let recorder: HeatmapRecorder? = (heatmap || heatmapImage != nil)
                ? HeatmapRecorder() : nil
            let needReporter = CLIProgress.shouldHaveReporter(
                progress: progress, noProgress: noProgress, progressJSON: progressJSON)
            let totalBytes = needReporter ? (try? CLIProgress.totalUncompressedBytes(at: inputURL, excludeHidden: excludeHidden)) ?? 0 : 0
            let reporter: ProgressReporter? = needReporter
                ? ProgressReporter(totalBytes: totalBytes, phase: .zipping) : nil
            let printer = CLIProgress.makePrinter(
                reporter: reporter, progress: progress,
                noProgress: noProgress, progressJSON: progressJSON)
            printer?.start()
            defer {
                reporter?.finish()
                printer?.waitUntilFlushed()
            }
            let opts = ZipCompressor.Options(
                level: CompressionLevel(level),
                concurrency: cores,
                heatmapRecorder: recorder,
                entropyProbeEnabled: !noEntropyProbe,
                progressReporter: reporter,
                excludeHidden: excludeHidden
            )
            let backend: DeflateBackend & CRC32Computing = parallel
                ? ParallelDeflate(chunkSize: chunkKb * 1024, concurrency: cores)
                : CPUDeflate()
            let compressor = ZipCompressor(backend: backend, options: opts)

            let stats = try compressor.compress(input: inputURL, to: outputURL)
            // Stop the printer thread BEFORE the result `print(...)`s so its
            // progress line and the result summary don't interleave (otherwise
            // the printer's last poll fires after the summary, painting a
            // stale 100% bar below the result block). `finish` + `wait` are
            // both idempotent, so the `defer` further up still works as a
            // safety net for the throw path.
            reporter?.finish()
            printer?.waitUntilFlushed()
            let mb = Double(stats.bytesIn) / 1_000_000
            print(String(format: "  entries: %d", stats.entriesWritten))
            print(String(format: "  in:    %10.2f MB", mb))
            print(String(format: "  out:   %10.2f MB", Double(stats.bytesOut) / 1_000_000))
            print(String(format: "  ratio: %10.2f%%", stats.ratio * 100))
            print(String(format: "  time:  %10.3f s", stats.elapsed))
            print(String(format: "  speed: %10.2f MB/s", stats.inputThroughputMBPerSec))

            try emitHeatmap(recorder: recorder,
                            archiveURL: outputURL,
                            elapsed: stats.elapsed,
                            sizeMB: mb)
        }
    }

    struct Pack: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pack",
            abstract: "Compress to Knit's high-speed .knit format (zstd block-parallel)."
        )

        @Argument(help: "Input file or directory.")
        var input: String

        @Option(name: .shortAndLong, help: "Output .knit path. Defaults to <input>.knit.")
        var output: String?

        @Option(name: .shortAndLong, help: "zstd compression level 1..22.")
        var level: Int = 3

        @Option(help: "Compression concurrency. Defaults to active core count.")
        var jobs: Int?

        @Option(help: "Block size in KB (each block is one zstd frame).")
        var blockKb: Int = 1024

        @Flag(name: .long,
              help: "Render a GPU-accelerated compressibility heatmap after the run.")
        var heatmap: Bool = false

        @Option(name: .long,
                help: "Also save the heatmap as a PPM image (open with Preview.app).")
        var heatmapImage: String?

        @Flag(name: .long,
              help: "Disable the entropy pre-screening pass (debugging).")
        var noEntropyProbe: Bool = false

        @Flag(name: .long,
              help: "Force the live progress bar on (overrides the default TTY-based detection).")
        var progress: Bool = false

        @Flag(name: .customLong("no-progress"),
              help: "Suppress the live progress bar even when stderr is a terminal.")
        var noProgress: Bool = false

        @Flag(name: .customLong("progress-json"),
              help: ArgumentHelp(
                "Emit ndjson progress on stderr instead of the text bar. Used by Knit.app to drive an NSProgress.",
                visibility: .private))
        var progressJSON: Bool = false

        @Flag(name: .customLong("analyze"),
              help: ArgumentHelp("Print encoder per-stage timing breakdown to stderr (internal).",
                                 visibility: .private))
        var analyze: Bool = false

        @Flag(name: .customLong("exclude-hidden"),
              help: "Skip hidden items (.git, .DS_Store, anything with the macOS hidden flag). Default is to include them, matching tar/zip.")
        var excludeHidden: Bool = false

        func run() throws {
            let inputURL = URL(fileURLWithPath: input).standardizedFileURL
            let outputURL = URL(fileURLWithPath: output ?? "\(input).knit").standardizedFileURL
            let cores = jobs ?? ProcessInfo.processInfo.activeProcessorCount

            let recorder: HeatmapRecorder? = (heatmap || heatmapImage != nil)
                ? HeatmapRecorder() : nil
            let needReporter = CLIProgress.shouldHaveReporter(
                progress: progress, noProgress: noProgress, progressJSON: progressJSON)
            let totalBytes = needReporter ? (try? CLIProgress.totalUncompressedBytes(at: inputURL, excludeHidden: excludeHidden)) ?? 0 : 0
            let reporter: ProgressReporter? = needReporter
                ? ProgressReporter(totalBytes: totalBytes, phase: .packing) : nil
            let printer = CLIProgress.makePrinter(
                reporter: reporter, progress: progress,
                noProgress: noProgress, progressJSON: progressJSON)
            printer?.start()
            defer {
                reporter?.finish()
                printer?.waitUntilFlushed()
            }
            // `--analyze` instruments the encoder. Same accumulator
            // type as `unpack --analyze`; the renderer separates wall
            // stages from cumulative-CPU stages so the % column has a
            // meaningful denominator for each. We also wire a
            // `WalkSkipCollector` under analyse so the output answers
            // "where did the size delta vs Finder come from?" (hidden
            // dirs like `.git/`, symlinks).
            let analytics: StageAnalytics? = analyze ? StageAnalytics() : nil
            let walkSkipCollector: WalkSkipCollector? = analyze ? WalkSkipCollector() : nil
            let opts = KnitCompressor.Options(
                level: CompressionLevel(level),
                concurrency: cores,
                blockSize: blockKb * 1024,
                heatmapRecorder: recorder,
                entropyProbeEnabled: !noEntropyProbe,
                progressReporter: reporter,
                stageAnalytics: analytics,
                excludeHidden: excludeHidden,
                walkSkipCollector: walkSkipCollector
            )
            let compressor = KnitCompressor(backend: CPUZstd(), options: opts)
            let stats = try compressor.compress(input: inputURL, to: outputURL)
            // Drain the printer thread before the result summary — see the
            // matching comment in the `Zip` subcommand for rationale.
            reporter?.finish()
            printer?.waitUntilFlushed()

            let mb = Double(stats.bytesIn) / 1_000_000
            print(String(format: "  entries: %d", stats.entriesWritten))
            print(String(format: "  in:    %10.2f MB", mb))
            print(String(format: "  out:   %10.2f MB", Double(stats.bytesOut) / 1_000_000))
            print(String(format: "  ratio: %10.2f%%", stats.ratio * 100))
            print(String(format: "  time:  %10.3f s", stats.elapsed))
            print(String(format: "  speed: %10.2f MB/s", stats.inputThroughputMBPerSec))

            try emitHeatmap(recorder: recorder,
                            archiveURL: outputURL,
                            elapsed: stats.elapsed,
                            sizeMB: mb)

            if let analytics = analytics {
                let snap = analytics.snapshot()
                let walkReport = walkSkipCollector?.snapshot()
                let report = CLIAnalyze.renderPack(snap,
                                                   packElapsed: stats.elapsed,
                                                   bytesIn: stats.bytesIn,
                                                   bytesOut: stats.bytesOut,
                                                   entries: stats.entriesWritten,
                                                   walkSkip: walkReport)
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }

    struct MetalInfo: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "metal-info",
            abstract: "Probe the Metal device and run a CRC32 self-test on a 64 MB buffer."
        )

        func run() throws {
            guard let ctx = MetalContext() else {
                print("No Metal device available.")
                throw ExitCode(1)
            }
            print("Device:            \(ctx.device.name)")
            print("Unified memory:    \(ctx.device.hasUnifiedMemory)")
            print("Max threadgroup:   \(ctx.device.maxThreadgroupMemoryLength) bytes")
            print("Recommended max:   \(ctx.device.recommendedMaxWorkingSetSize / 1_000_000) MB")

            guard let crcGPU = MetalCRC32() else {
                print("MetalCRC32 init failed.")
                return
            }
            // Build a deterministic 64MB pattern.
            let size = 64 * 1024 * 1024
            var data = Data(count: size)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<size { p[i] = UInt8(i & 0xFF) }
            }

            let cpuStart = ContinuousClock.now
            let cpu = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
                let buf = UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    count: raw.count)
                return CPUDeflate().crc32(buf, seed: 0)
            }
            let cpuElapsed = (ContinuousClock.now - cpuStart).timeIntervalSeconds

            let gpuStart = ContinuousClock.now
            let gpu = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in
                let buf = UnsafeBufferPointer(
                    start: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    count: raw.count)
                return try crcGPU.crc32(buf)
            }
            let gpuElapsed = (ContinuousClock.now - gpuStart).timeIntervalSeconds

            print(String(format: "CPU CRC32: 0x%08x  (%.3f s, %.0f MB/s)",
                         cpu, cpuElapsed, Double(size) / 1_000_000 / cpuElapsed))
            print(String(format: "GPU CRC32: 0x%08x  (%.3f s, %.0f MB/s)",
                         gpu, gpuElapsed, Double(size) / 1_000_000 / gpuElapsed))
            if cpu == gpu {
                print("Match: ✓")
            } else {
                print("Match: ✗ (CRCs disagree — possible kernel bug)")
            }
        }
    }

    struct Unpack: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unpack",
            abstract: "Extract a .knit archive."
        )

        @Argument(help: "Input .knit file.")
        var input: String

        @Option(name: .shortAndLong, help: "Output directory. Defaults to current directory.")
        var output: String = "."

        @Flag(name: .long,
              help: "Disable GPU-accelerated CRC32 verification (forces CPU verify).")
        var noGpuVerify: Bool = false

        @Flag(name: .long,
              help: "Force the live progress bar on (overrides the default TTY-based detection).")
        var progress: Bool = false

        @Flag(name: .customLong("no-progress"),
              help: "Suppress the live progress bar even when stderr is a terminal.")
        var noProgress: Bool = false

        @Flag(name: .customLong("progress-json"),
              help: ArgumentHelp(
                "Emit ndjson progress on stderr instead of the text bar. Used by Knit.app to drive an NSProgress.",
                visibility: .private))
        var progressJSON: Bool = false

        @Flag(name: .customLong("analyze"),
              help: ArgumentHelp("Print decode-stage timing breakdown to stderr (internal).",
                                 visibility: .private))
        var analyze: Bool = false

        func run() throws {
            let inputURL = URL(fileURLWithPath: input).standardizedFileURL
            let outURL = URL(fileURLWithPath: output).standardizedFileURL
            let needReporter = CLIProgress.shouldHaveReporter(
                progress: progress, noProgress: noProgress, progressJSON: progressJSON)
            // Total uncompressed bytes for the progress bar are read out
            // of the .knit footer so we don't need a second SSD pass.
            let totalBytes: UInt64
            if needReporter {
                totalBytes = (try? CLIProgress.totalUncompressedBytesInKnit(at: inputURL)) ?? 0
            } else {
                totalBytes = 0
            }
            let reporter: ProgressReporter? = needReporter
                ? ProgressReporter(totalBytes: totalBytes, phase: .extracting) : nil
            let printer = CLIProgress.makePrinter(
                reporter: reporter, progress: progress,
                noProgress: noProgress, progressJSON: progressJSON)
            printer?.start()
            defer {
                reporter?.finish()
                printer?.waitUntilFlushed()
            }
            // `--analyze` is a hidden flag for diagnosing where decode
            // wall time is going on a user's host. When set, we hand a
            // `StageAnalytics` accumulator to the extractor; after the
            // extract finishes we render its snapshot to stderr. The
            // numbers tell us which decode stage the spare GPU should
            // accelerate next (CRC fold? literal Huffman? write
            // overlap?). Without this flag the decoder pays no
            // instrumentation cost.
            let analytics: StageAnalytics? = analyze ? StageAnalytics() : nil
            // Phase 1b.0 spike accumulator. Constructed alongside the
            // stage accumulator so they share the `--analyze` gate;
            // every block's zstd frame gets walked by the literal
            // classifier inside the parallel decode worker. The
            // classifier never throws and the cost is small enough
            // that `parallel.decode` wall should not regress
            // measurably — to be confirmed by the bench-corpora.sh
            // diff in the PR description.
            let literalTypeAnalytics: LiteralTypeAnalytics? = analyze ? LiteralTypeAnalytics() : nil
            let extractor = KnitExtractor(useGPUVerify: !noGpuVerify,
                                          progressReporter: reporter,
                                          analytics: analytics,
                                          literalTypeAnalytics: literalTypeAnalytics)
            let stats = try extractor.extract(archive: inputURL, to: outURL)
            // Drain the printer thread before the result summary — see the
            // matching comment in the `Zip` subcommand for rationale.
            reporter?.finish()
            printer?.waitUntilFlushed()
            print(String(format: "  entries: %d", stats.entries))
            print(String(format: "  out:   %10.2f MB", Double(stats.bytesOut) / 1_000_000))
            print(String(format: "  time:  %10.3f s", stats.elapsed))
            let verifier = stats.gpuVerifyUsed ? "GPU (Metal)" : "CPU (libdeflate)"
            print("  verify: \(verifier)")
            if let analytics = analytics {
                let snap = analytics.snapshot()
                let report = CLIAnalyze.renderUnpack(snap,
                                                     extractElapsed: stats.elapsed,
                                                     bytesOut: stats.bytesOut,
                                                     entries: stats.entries)
                FileHandle.standardError.write(Data(report.utf8))
            }
            if let literalTypeAnalytics = literalTypeAnalytics {
                let snap = literalTypeAnalytics.snapshot()
                let report = CLIAnalyze.renderUnpackLiteralTypes(snap)
                FileHandle.standardError.write(Data(report.utf8))
            }
        }
    }
}

// MARK: - Heatmap output helper

extension KnitCommand {
    /// Render the captured heatmap to stdout (and optionally a PPM file).
    /// Shared between the `zip` and `pack` subcommands.
    fileprivate static func emitHeatmap(recorder: HeatmapRecorder?,
                                        archiveURL: URL,
                                        elapsed: TimeInterval,
                                        sizeMB: Double) throws {
        guard let recorder = recorder, recorder.count > 0 else { return }
        let snapshot = recorder.snapshot()

        var rendererOpts = HeatmapRenderer.Options()
        rendererOpts.elapsedSeconds = elapsed
        rendererOpts.headerLines = [
            archiveURL.lastPathComponent,
            String(format: "%.2f MB  •  %d block samples", sizeMB, snapshot.samples.count),
        ]
        if let ctx = MetalContext() {
            let unified = ctx.device.hasUnifiedMemory ? "unified" : "discrete"
            rendererOpts.gpuDeviceLabel = "\(ctx.device.name)  (\(unified) memory)"
        }

        let renderer = HeatmapRenderer(heatmap: snapshot, options: rendererOpts)
        FileHandle.standardOutput.write(Data("\n".utf8))
        FileHandle.standardOutput.write(Data(renderer.renderANSI().utf8))
    }
}

extension KnitCommand.Zip {
    fileprivate func emitHeatmap(recorder: HeatmapRecorder?,
                                 archiveURL: URL,
                                 elapsed: TimeInterval,
                                 sizeMB: Double) throws {
        try KnitCommand.emitHeatmap(recorder: recorder,
                                    archiveURL: archiveURL,
                                    elapsed: elapsed,
                                    sizeMB: sizeMB)
        if let path = heatmapImage, let recorder = recorder, recorder.count > 0 {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let renderer = HeatmapRenderer(heatmap: recorder.snapshot())
            try renderer.writePPM(to: url)
            print("  heatmap image saved: \(url.path)")
        }
    }
}

extension KnitCommand.Pack {
    fileprivate func emitHeatmap(recorder: HeatmapRecorder?,
                                 archiveURL: URL,
                                 elapsed: TimeInterval,
                                 sizeMB: Double) throws {
        try KnitCommand.emitHeatmap(recorder: recorder,
                                    archiveURL: archiveURL,
                                    elapsed: elapsed,
                                    sizeMB: sizeMB)
        if let path = heatmapImage, let recorder = recorder, recorder.count > 0 {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let renderer = HeatmapRenderer(heatmap: recorder.snapshot())
            try renderer.writePPM(to: url)
            print("  heatmap image saved: \(url.path)")
        }
    }
}
