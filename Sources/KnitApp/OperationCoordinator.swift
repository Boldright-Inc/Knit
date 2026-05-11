// OperationCoordinator — drives one knit subprocess from Knit.app
// and surfaces its progress through a published `NSProgress` so
// macOS (Finder, the menu-bar progress widget) shows native UI
// instead of a Terminal window.
//
// One coordinator per operation. The owner (AppDelegate) keeps
// coordinators in an array; when the array empties, Knit.app exits.
//
// Flow:
//   1. Configure an `NSProgress` with `kind = .file`, the output
//      file URL, and a file-operation kind. `publish()` makes
//      Finder decorate the output file's icon while the operation
//      runs and (system-defined) show a floating progress widget.
//   2. Launch `/usr/local/bin/knit <subcmd> ... --progress-json`
//      as a `Process`. Its stderr is a `Pipe` we read line-by-line.
//   3. Each line is one JSON object. Parse `processed` and update
//      `progress.completedUnitCount`. Total is `total` from the
//      first line (it's constant across the run).
//   4. On the line with `done == true`, the operation finished
//      from the codec's perspective. Wait for the process to
//      actually exit, then call the completion handler.
//   5. NSProgress's user-driven Cancel button fires
//      `cancellationHandler`, which sends SIGTERM to the subprocess
//      and deletes the partial output file.
//
// PR #57.

import AppKit
import Foundation

/// One supported operation. Maps to a knit CLI subcommand + args.
enum KnitOperation: Sendable {
    case packToKnit(inputs: [URL], outputDir: URL?, level: Int)
    case zipParallel(inputs: [URL], outputDir: URL?, level: Int)
    case extractArchive(inputs: [URL], outputDir: URL?)
}

/// One subprocess invocation derived from a `KnitOperation`. The
/// `executableURL` is the actual binary to spawn — usually the knit
/// CLI we located at startup, but `/usr/bin/unzip` for `.zip` extract
/// (knit's CLI is `.knit`-only). `progressJSON == true` means
/// `--progress-json` is on the args list and the parent should parse
/// ndjson off stderr; `false` (unzip path) means the NSProgress stays
/// indeterminate until the subprocess exits.
struct Run {
    let executableURL: URL
    let args: [String]
    let outputURL: URL
    let sourceURL: URL
    let phase: Progress.FileOperationKind
    let progressJSON: Bool
}

extension KnitOperation {
    /// Returns one `Run` per input file. We spawn one subprocess per
    /// input so each gets its own NSProgress (and Finder decorates
    /// each output icon independently). The CLI executable URL must
    /// be supplied by the caller because `KnitOperation` doesn't
    /// know where the install put `knit`.
    func plannedRuns(knitURL: URL) -> [Run] {
        switch self {
        case let .packToKnit(inputs, outputDir, level):
            return inputs.map { input in
                let outURL = OperationCoordinator.defaultOutputURL(
                    for: input, suffix: ".knit", outputDir: outputDir)
                let args = ["pack", input.path,
                            "-o", outURL.path,
                            "--level", "\(level)",
                            "--progress-json"]
                return Run(executableURL: knitURL, args: args,
                           outputURL: outURL, sourceURL: input,
                           phase: .compressing, progressJSON: true)
            }
        case let .zipParallel(inputs, outputDir, level):
            return inputs.map { input in
                let outURL = OperationCoordinator.defaultOutputURL(
                    for: input, suffix: ".zip", outputDir: outputDir)
                let args = ["zip", input.path,
                            "-o", outURL.path,
                            "--parallel",
                            "--level", "\(level)",
                            "--progress-json"]
                return Run(executableURL: knitURL, args: args,
                           outputURL: outURL, sourceURL: input,
                           phase: .compressing, progressJSON: true)
            }
        case let .extractArchive(inputs, outputDir):
            return inputs.map { archive in
                let dir = outputDir ?? archive.deletingLastPathComponent()
                let lower = archive.path.lowercased()
                if lower.hasSuffix(".zip") {
                    // `/usr/bin/unzip` is the system fallback for .zip
                    // archives — `knit unpack` is .knit-only. unzip
                    // doesn't produce a machine-readable progress
                    // stream, so the NSProgress for this run stays
                    // indeterminate (the bar shows a spinner-style
                    // animation) until the subprocess exits.
                    return Run(
                        executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
                        args: ["-q", "-o", archive.path, "-d", dir.path],
                        outputURL: archive, sourceURL: archive,
                        phase: .copying, progressJSON: false)
                }
                return Run(
                    executableURL: knitURL,
                    args: ["unpack", archive.path,
                           "-o", dir.path, "--progress-json"],
                    outputURL: archive, sourceURL: archive,
                    phase: .copying, progressJSON: true)
            }
        }
    }
}

extension Progress.FileOperationKind {
    /// Custom "compressing" kind backed by the raw string Apple uses
    /// internally (`NSProgressFileOperationKindCompressing`). The
    /// public Foundation API exposes `.copying` /
    /// `.decompressingAfterDownloading` / `.receiving` / etc. but
    /// not `.compressing`. If macOS recognizes the raw value, the
    /// progress widget shows "Compressing X" verb; otherwise it
    /// falls back to the generic "Copying" rendering — same bar,
    /// different label. Either way the file-icon overlay still
    /// works because that's driven by `fileURLKey`, not the kind.
    static let compressing = Progress.FileOperationKind(
        rawValue: "NSProgressFileOperationKindCompressing"
    )
}

/// One operation. The owner constructs, starts, then awaits its
/// completion handler.
///
/// `@unchecked Sendable` because every mutation of internal state
/// happens under `lock` (the `children` map and the `cancelled` /
/// `pendingCount` / `anyFailureMessage` triplet) or on the main
/// queue (the `parentProgress` configuration before `start()`).
/// Swift 6's strict-concurrency analyser can't reason about that
/// pattern automatically; this is `CLAUDE.md` Rule 1.3's standard
/// escape hatch.
final class OperationCoordinator: NSObject, @unchecked Sendable {
    /// Result reported to the completion handler.
    enum Outcome: Sendable {
        case success
        case failure(message: String)
        case cancelled
    }

    private let operation: KnitOperation
    private let onAllDone: @Sendable () -> Void
    private let knitURL: URL

    /// Single source of truth for the parent NSProgress that
    /// represents the entire user-visible operation (one
    /// "Compressing 5 items" widget for a 5-file batch).
    private let parentProgress: Progress

    /// Per-input child progresses + their subprocesses. Keyed by
    /// index into `operation.plannedRuns()`.
    private var children: [Int: (progress: Progress, process: Process)] = [:]

    private let lock = NSLock()
    private var pendingCount = 0
    private var anyFailureMessage: String?
    private var cancelled = false

    init(operation: KnitOperation,
         knitURL: URL,
         onAllDone: @escaping @Sendable () -> Void) {
        self.operation = operation
        self.knitURL = knitURL
        self.onAllDone = onAllDone

        // Build the parent NSProgress that aggregates per-input
        // children. macOS uses `parentProgress.fileTotalCount`
        // and the sum of `completedUnitCount` to render the
        // "X of N items" widget.
        let runs = operation.plannedRuns(knitURL: knitURL)
        let totalBytes: Int64 = -1  // unknown until each child reports
        let parent = Progress(totalUnitCount: totalBytes)
        parent.kind = .file
        parent.isCancellable = true
        if runs.count > 1 {
            parent.setUserInfoObject(NSNumber(value: runs.count),
                                     forKey: .fileTotalCountKey)
        }
        if let phase = runs.first?.phase {
            parent.setUserInfoObject(phase.rawValue, forKey: .fileOperationKindKey)
        }
        if let first = runs.first {
            parent.setUserInfoObject(first.outputURL, forKey: .fileURLKey)
        }
        self.parentProgress = parent
        super.init()

        // Cancel from the widget's stop button propagates to each
        // child subprocess + cleans up partial outputs.
        parent.cancellationHandler = { [weak self] in
            self?.handleCancel()
        }
    }

    /// Launch every input's subprocess and start reading its
    /// progress stream. Returns immediately; the completion handler
    /// fires from one of the readability-handler threads when the
    /// last subprocess wraps up.
    func start() {
        let runs = operation.plannedRuns(knitURL: knitURL)
        guard !runs.isEmpty else {
            // Nothing to do. Fire onAllDone on the main queue so the
            // app can decide whether to terminate.
            DispatchQueue.main.async { [onAllDone] in onAllDone() }
            return
        }

        lock.lock()
        pendingCount = runs.count
        lock.unlock()

        parentProgress.publish()

        // Spawn each subprocess. We don't serialise — Finder is fine
        // with multiple concurrent published progresses. For batch
        // compresses the user gets parallel speed-up.
        for (idx, run) in runs.enumerated() {
            launchChild(index: idx, run: run)
        }
    }

    // MARK: - Per-input subprocess

    private func launchChild(index: Int, run: Run) {
        let child = Progress(totalUnitCount: -1, parent: parentProgress, pendingUnitCount: 1)
        child.kind = .file
        child.isCancellable = true
        child.setUserInfoObject(run.phase.rawValue, forKey: .fileOperationKindKey)
        child.setUserInfoObject(run.outputURL, forKey: .fileURLKey)
        // Finder picks up the published child and decorates the
        // *outputURL*'s file icon with the progress overlay.
        child.publish()

        let proc = Process()
        proc.executableURL = run.executableURL
        proc.arguments = run.args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        lock.lock()
        children[index] = (child, proc)
        lock.unlock()

        if run.progressJSON {
            // ndjson lines come on stderr (the CLI writes the final
            // summary to stdout, progress to stderr — same split as
            // the human-facing text bar).
            let parser = NDJSONLineParser()
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                parser.feed(data) { line in
                    self?.applyProgressLine(line, to: child)
                }
            }
        } else {
            // Non-JSON subprocess (e.g. `/usr/bin/unzip`): just drain
            // stderr to /dev/null and leave the NSProgress
            // indeterminate. macOS shows a spinner-style animated bar
            // instead of a determinate filled bar; the file-icon
            // overlay still appears because `fileURLKey` is set.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
        }
        // Always drain stdout so the buffer doesn't fill up.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        proc.terminationHandler = { [weak self] p in
            // Close pipe handlers so they release the fds.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.handleChildExit(index: index, process: p,
                                   outputURL: run.outputURL)
        }

        do {
            try proc.run()
        } catch {
            // Couldn't launch — record failure and continue with the
            // others (if any).
            child.completedUnitCount = child.totalUnitCount
            child.unpublish()
            handleChildExit(index: index, process: proc,
                            outputURL: run.outputURL,
                            launchError: error)
        }
    }

    private func applyProgressLine(_ json: ProgressJSONLine, to child: Progress) {
        // First time we see a `total`, learn the unit count so the
        // widget can size its bar. `totalUnitCount = -1` means
        // "indeterminate"; switching to a positive value mid-flight
        // is fine.
        if child.totalUnitCount <= 0, json.total > 0 {
            child.totalUnitCount = Int64(json.total)
        }
        child.completedUnitCount = min(Int64(json.processed), max(child.totalUnitCount, 0))
        if json.done {
            // Don't unpublish here — the terminationHandler does that
            // after the process actually exits.
        }
    }

    // MARK: - Per-input completion

    private func handleChildExit(index: Int,
                                  process: Process,
                                  outputURL: URL,
                                  launchError: Error? = nil) {
        lock.lock()
        let entry = children[index]
        children.removeValue(forKey: index)
        let cancelled = self.cancelled
        let pending = pendingCount - 1
        pendingCount = pending
        let status = process.terminationStatus
        if launchError != nil || (status != 0 && !cancelled) {
            anyFailureMessage = (launchError as NSError?)?.localizedDescription
                ?? "knit exited with status \(status)"
        }
        lock.unlock()

        if let p = entry?.progress {
            p.unpublish()
        }

        // Cancel / failure → wipe the partial output so the user
        // doesn't see a half-written file in Finder.
        if cancelled || status != 0 || launchError != nil {
            try? FileManager.default.removeItem(at: outputURL)
        }

        if pending == 0 {
            finishAll()
        }
    }

    private func finishAll() {
        parentProgress.unpublish()

        lock.lock()
        let failureMessage = anyFailureMessage
        let wasCancelled = cancelled
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let msg = failureMessage, !wasCancelled {
                let alert = NSAlert()
                alert.messageText = "Knit"
                alert.informativeText = msg
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                _ = alert.runModal()
            }
            self.onAllDone()
        }
    }

    // MARK: - Cancellation

    private func handleCancel() {
        lock.lock()
        cancelled = true
        let snapshot = Array(children.values)
        lock.unlock()
        // SIGTERM each child. knit's signal handling is lazy — it
        // doesn't install a SIGTERM trap — but the kernel default
        // for SIGTERM is "exit", which is fine; the
        // terminationHandler runs as usual and cleans up.
        for entry in snapshot {
            if entry.process.isRunning {
                entry.process.terminate()
            }
        }
    }

    // MARK: - Helpers

    /// `<input>.knit` (or `.zip`) next to the input by default; or
    /// inside `outputDir` if the caller specified one.
    static func defaultOutputURL(for input: URL,
                                 suffix: String,
                                 outputDir: URL?) -> URL {
        let base = input.lastPathComponent
        if let dir = outputDir {
            return dir.appendingPathComponent("\(base)\(suffix)")
        }
        return input.deletingLastPathComponent()
            .appendingPathComponent("\(base)\(suffix)")
    }
}

// MARK: - ndjson stream parser

/// One progress line off the CLI's `--progress-json` stream.
struct ProgressJSONLine {
    let phase: String
    let processed: UInt64
    let total: UInt64
    let done: Bool
}

/// Accumulates partial-line bytes between `readabilityHandler`
/// invocations and emits one parsed `ProgressJSONLine` per complete
/// `\n`-terminated chunk. `JSONSerialization.jsonObject(with:)` is
/// strict about input being a single complete JSON document, hence
/// the line-buffer instead of feeding it raw `Data`.
final class NDJSONLineParser: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    /// Feed bytes from a pipe read. Calls `emit` once per complete
    /// line, on whichever thread `feed` is called on (the
    /// readabilityHandler thread). The caller is responsible for
    /// any cross-thread hand-off.
    func feed(_ chunk: Data, emit: (ProgressJSONLine) -> Void) {
        lock.lock()
        pending.append(chunk)
        // Slice off any number of complete lines we have now.
        let newline: UInt8 = 0x0A
        while let idx = pending.firstIndex(of: newline) {
            let lineRange = pending.startIndex..<idx
            let lineBytes = pending[lineRange]
            // Drop the \n itself plus the line we just consumed.
            pending.removeSubrange(pending.startIndex...idx)
            if let parsed = Self.parseLine(Data(lineBytes)) {
                lock.unlock()
                emit(parsed)
                lock.lock()
            }
        }
        lock.unlock()
    }

    private static func parseLine(_ data: Data) -> ProgressJSONLine? {
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        let phase = (obj["phase"] as? String) ?? "?"
        let processed = (obj["processed"] as? NSNumber)?.uint64Value ?? 0
        let total = (obj["total"] as? NSNumber)?.uint64Value ?? 0
        let done = (obj["done"] as? Bool) ?? false
        return ProgressJSONLine(phase: phase, processed: processed,
                                total: total, done: done)
    }
}
