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
//   2. Launch the bundled `knit <subcmd> ... --progress-json`
//      as a `Process`. Its stderr is a `Pipe` we read line-by-line.
//      The CLI path is resolved by `locateKnitCLI()` in main.swift
//      and prefers the binary embedded in
//      Knit.app/Contents/Resources/bin/ so the GUI never accidentally
//      invokes a stale system-wide install.
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
                // `--no-post-verify` (PR #75 flag, default-on
                // when not passed): skip the post-write CRC re-read
                // pass for every extracted entry. The decode-side
                // per-batch CRC inside `HybridZstdBatchDecoder`
                // still runs and catches every realistic failure
                // mode (decoder bug, memory corruption, GPU kernel
                // miscompute); the post-write pass only catches
                // "the kernel returned from write(2) but the byte
                // landed wrong on disk" — effectively impossible on
                // APFS (block-level checksum) + modern NVMe
                // (controller-side ECC). A `sample` trace of an
                // 80 GB `.pvm.knit` extract on M5 Max showed 96 %
                // of unpack wall in `MetalCRC32.crc32 ->
                // waitUntilCompleted` for this exact post-write
                // pass; the CLI exposes the flag specifically so
                // GUI callers can opt out without losing the
                // decoder-side correctness check.
                return Run(
                    executableURL: knitURL,
                    args: ["unpack", archive.path,
                           "-o", dir.path,
                           "--no-post-verify",
                           "--progress-json"],
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

    /// Custom always-visible progress window. The published NSProgress
    /// is best-effort (the system widget may or may not appear); the
    /// ProgressWindow is guaranteed visible.
    private let window = ProgressWindow()

    /// Aggregate counters for the ProgressWindow's render. NSProgress
    /// itself tracks the same numbers, but observing it via KVO from
    /// Swift is awkward — we update these in `applyProgressLine`.
    private var totalBytes: UInt64 = 0
    private var processedBytes: UInt64 = 0
    private var lastETASeconds: Double = .infinity

    /// Per-input child progresses + their subprocesses. Keyed by
    /// index into `operation.plannedRuns()`.
    ///
    /// Post-PR-#58 hotfix: there is at most ONE entry here at any
    /// time — runs are executed serially (see `pendingRuns`). The map
    /// shape is retained to keep the index-keyed cleanup paths in
    /// `handleChildExit` unchanged, but it now functions as a singleton.
    ///
    /// PR #67: also holds the `NDJSONLineParser` so `handleChildExit`
    /// can pull captured stderr text out of it for the failure alert.
    /// Nil for runs without `--progress-json` (the `/usr/bin/unzip`
    /// fallback path).
    private var children: [Int: (progress: Progress,
                                  process: Process,
                                  parser: NDJSONLineParser?)] = [:]

    /// Runs that haven't been launched yet. Drained one-at-a-time by
    /// `launchNextIfNeeded()` from `start()` and from `handleChildExit`.
    ///
    /// **Why serial, not parallel:** Earlier revisions launched every
    /// run in `start()`'s `for`-loop synchronously, producing one
    /// concurrent `knit` subprocess per input. When a Finder Quick
    /// Action is invoked on a multi-file selection, `"$@"` in the
    /// `.workflow` shell script expands to every selected path, all
    /// of which `parseQuickActionArgs` accepts via the greedy
    /// `--inputs` clause. A 500-file selection therefore produced
    /// 500 concurrent `knit pack` subprocesses inside a single
    /// Knit.app — each mmap'ing its input, each spinning up its own
    /// worker pool with per-worker block buffers — easily exhausting
    /// system memory and crashing the host. (Reported during PR #58
    /// smoke testing.) Knit CLI already saturates all cores via its
    /// internal worker pool, so parallelising across inputs delivered
    /// zero throughput win for the risk it carried. One subprocess at
    /// a time is strictly better.
    private var pendingRuns: [(Int, Run)] = []

    private let lock = NSLock()
    private var pendingCount = 0
    private var anyFailureMessage: String?
    private var cancelled = false

    /// Cross-Knit.app-instance serialisation lock. Quick Actions
    /// spawn fresh Knit.app instances via `open -n -a`, so the
    /// within-instance `pendingRuns` queue (PR #58) doesn't help
    /// across instances. Two simultaneous Quick Actions on the
    /// user's 80 GB Parallels VM corpus produced concurrent
    /// subprocesses that hit SIGKILL (jetsam under memory pressure)
    /// and ENOSPC (racing for ~160 GB of disk). The lock acquires
    /// before each `subprocess.run()` and releases on subprocess
    /// exit — coordinating all running Knit.app's on the host so
    /// only one knit/zip CLI runs at a time. PR #79
    private let crossLock = CrossInstanceLock()

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

        // Custom-window cancel goes through the same path so partial
        // outputs are wiped uniformly regardless of which UI surface
        // the user clicked. Dispatched off the main queue because
        // handleCancel does SIGTERM bookkeeping.
        window.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.handleCancel()
            }
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
        pendingRuns = Array(runs.enumerated())
        lock.unlock()

        // Configure the custom progress window with the first run's
        // metadata — for a multi-input batch this is approximate
        // (only the first input's name shows in the title), but
        // batch compresses are uncommon enough that handling them
        // perfectly isn't worth the layout cost.
        let first = runs.first!
        let verb: ProgressWindow.Verb
        switch operation {
        case .packToKnit, .zipParallel: verb = .compressing
        case .extractArchive:           verb = .extracting
        }
        let outputForWindow = (verb == .compressing) ? first.outputURL : nil
        window.configure(sourceURL: first.sourceURL,
                          outputURL: outputForWindow,
                          verb: verb)
        window.show()

        parentProgress.publish()

        // Launch the first run. Subsequent runs follow sequentially
        // via `handleChildExit` → `launchNextIfNeeded`. See the
        // `pendingRuns` doc-block for the rationale (PR #58 hotfix:
        // parallel launch crashed Macs on multi-file Quick Action
        // selections).
        launchNextIfNeeded()
    }

    /// Pop the next queued run and launch it. No-op when the queue is
    /// empty (we've reached the last run, or `start()` got nothing to
    /// do). Called from `start()` for the first run and from
    /// `handleChildExit` for every subsequent one.
    private func launchNextIfNeeded() {
        lock.lock()
        guard !pendingRuns.isEmpty else {
            lock.unlock()
            return
        }
        let next = pendingRuns.removeFirst()
        lock.unlock()
        launchChild(index: next.0, run: next.1)
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

        // The parser is stored on the children-map entry so
        // handleChildExit can read its capturedText for the failure
        // alert. Nil when there's no JSON channel to parse (unzip
        // fallback) — stderr is drained without text capture in that
        // case.
        let parser: NDJSONLineParser? = run.progressJSON ? NDJSONLineParser() : nil

        lock.lock()
        children[index] = (child, proc, parser)
        lock.unlock()

        if let parser = parser {
            // ndjson lines come on stderr (the CLI writes the final
            // summary to stdout, progress to stderr — same split as
            // the human-facing text bar). Non-JSON lines (real error
            // output) are captured inside the parser and surfaced via
            // `capturedTextSnapshot()` on failure.
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

        // PR #79: acquire the cross-Knit.app-instance lock before
        // spawning the subprocess. Non-blocking attempt first; if
        // another Knit.app is running, switch the panel to a
        // "Waiting…" state and acquire on a background queue so the
        // main thread stays responsive. The lock is released in
        // `handleChildExit` after the subprocess terminates.
        if crossLock.tryAcquire() {
            startSubprocess(proc: proc, index: index, run: run, child: child)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.window.showWaitingForLock(elapsedSeconds: 0)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let acquired = self.crossLock.acquireBlocking(
                    cancelCheck: {
                        self.lock.lock()
                        let c = self.cancelled
                        self.lock.unlock()
                        return c
                    },
                    progressCallback: { elapsed in
                        DispatchQueue.main.async { [weak self] in
                            self?.window.showWaitingForLock(elapsedSeconds: elapsed)
                        }
                    }
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if acquired {
                        self.startSubprocess(proc: proc, index: index,
                                             run: run, child: child)
                    } else {
                        // Cancelled while waiting — surface as
                        // a launch error so the rest of the cleanup
                        // path (unpublish, deletePartialOutput,
                        // handleChildExit bookkeeping) runs as
                        // normal.
                        child.completedUnitCount = child.totalUnitCount
                        child.unpublish()
                        let err = NSError(
                            domain: "Knit", code: -1,
                            userInfo: [NSLocalizedDescriptionKey:
                                "Cancelled while waiting for another Knit operation to finish"]
                        )
                        self.handleChildExit(index: index, process: proc,
                                             outputURL: run.outputURL,
                                             launchError: err)
                    }
                }
            }
        }
    }

    /// Final-stage subprocess launch. Split out of `launchChild`
    /// because the cross-instance-lock path may need to defer the
    /// actual `proc.run()` to a later main-queue tick (PR #79).
    private func startSubprocess(proc: Process, index: Int,
                                  run: Run, child: Progress) {
        // PR #79: cancel-during-acquire race window. If the user
        // clicked the panel's Cancel button between the background
        // queue's `acquireBlocking` returning true and this
        // continuation running on the main queue, `handleCancel`
        // already snapshotted `children` for SIGTERM but the proc
        // wasn't running yet (`isRunning == false` skipped it).
        // Starting it now would spawn an orphan that's no longer
        // cancellable from the panel. Refuse early and route through
        // the standard cleanup path so the lock is released and the
        // unfinished entry is unpublished correctly.
        lock.lock()
        let isCancelled = self.cancelled
        lock.unlock()
        if isCancelled {
            child.completedUnitCount = child.totalUnitCount
            child.unpublish()
            let err = NSError(
                domain: "Knit", code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Cancelled before subprocess launch"]
            )
            handleChildExit(index: index, process: proc,
                            outputURL: run.outputURL,
                            launchError: err)
            return
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

        // Update aggregate counters for the custom window. With one
        // run (the typical Quick Action case) these track the run
        // directly; with multiple runs the aggregate is approximate
        // but still useful — the bar reflects total work done across
        // the batch.
        lock.lock()
        if totalBytes < json.total {
            totalBytes = max(totalBytes, json.total)
        }
        processedBytes = max(processedBytes, json.processed)
        // ETA is taken straight from the freshest tick — close enough
        // for the user's "is this going to take a while?" question.
        // The CLI's ProgressReporter already throttles ETA to "stable
        // after 0.5 % of work done", so even sub-second snapshots
        // here are reasonable.
        lastETASeconds = json.etaSeconds
        let processedSnapshot = processedBytes
        let totalSnapshot = totalBytes
        let eta = lastETASeconds
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.window.update(processed: processedSnapshot,
                                  total: totalSnapshot,
                                  etaSeconds: eta)
        }
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
        // PR #79: release the cross-Knit.app-instance lock as the
        // very first thing in this handler, before any other
        // bookkeeping. Holding it across the bookkeeping would
        // serialise unrelated cleanup work against any waiting
        // Knit.app. Safe to release unconditionally: the
        // `crossLock.release()` call is a no-op if we never
        // acquired it (e.g. a `launchError` from the
        // pre-`tryAcquire` setup path), and idempotent across
        // accidental double-calls.
        crossLock.release()

        lock.lock()
        let entry = children[index]
        children.removeValue(forKey: index)
        let cancelled = self.cancelled
        let pending = pendingCount - 1
        pendingCount = pending
        let status = process.terminationStatus
        let reason = process.terminationReason
        if launchError != nil || (status != 0 && !cancelled) {
            // PR #67: build a useful failure message instead of the
            // cryptic "knit exited with status N".
            //
            //  * Distinguish a Swift runtime trap (terminationReason ==
            //    .uncaughtSignal, status == signal number — e.g.
            //    SIGTRAP=5 from a precondition or force-unwrap) from a
            //    clean exit code (.exit, status == app-chosen).
            //  * Append the most recent non-JSON lines the CLI wrote
            //    to stderr (typically the actual error text like
            //    "knit: cannot create output: …"), so the user sees
            //    why the operation failed without having to fetch a
            //    crash report or re-run from a terminal.
            let baseMsg: String
            if let err = launchError as NSError? {
                baseMsg = err.localizedDescription
            } else {
                switch reason {
                case .uncaughtSignal:
                    baseMsg = "knit was terminated by signal \(status) (\(Self.signalName(status)))"
                case .exit:
                    baseMsg = "knit exited with status \(status)"
                @unknown default:
                    baseMsg = "knit exited with status \(status)"
                }
            }
            let captured = entry?.parser?.capturedTextSnapshot() ?? []
            // Take only the tail — earlier non-JSON output is usually
            // benign banner / probe-init text; the last few lines are
            // where the real failure cause sits.
            let tail = Array(captured.suffix(8))
            if tail.isEmpty {
                anyFailureMessage = baseMsg
            } else {
                anyFailureMessage = baseMsg + "\n\n" + tail.joined(separator: "\n")
            }
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
        } else {
            // Serial execution: kick the next queued run now that this
            // one is done. If `pendingRuns` is empty (the failure path
            // hit, but other workers are still in flight from a prior
            // parallel-launch revision), this is a no-op.
            launchNextIfNeeded()
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
            // Dismiss the custom progress window before any alert
            // so the alert isn't competing with the panel for focus.
            self.window.dismiss()
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
        // Drain remaining queued runs so `launchNextIfNeeded` (called
        // from the terminated child's `handleChildExit`) becomes a
        // no-op. Without this, cancelling part-way through a batch
        // would still march on through the rest of the queue.
        let drained = pendingRuns.count
        pendingRuns.removeAll()
        // Each cancelled-from-queue entry still counts toward
        // pendingCount; decrement so finishAll fires once the
        // currently-running child exits rather than waiting forever.
        pendingCount -= drained
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

    /// Map a POSIX signal number to its canonical mnemonic for the
    /// failure-alert text. Used when `Process.terminationReason ==
    /// .uncaughtSignal` so a Swift runtime trap shows as e.g. "signal
    /// 5 (SIGTRAP)" instead of the cryptic "exited with status 5".
    /// PR #67.
    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGHUP:  return "SIGHUP"
        case SIGINT:  return "SIGINT"
        case SIGQUIT: return "SIGQUIT"
        case SIGILL:  return "SIGILL"
        case SIGTRAP: return "SIGTRAP"   // Swift runtime trap (precondition fail, force-unwrap nil, integer overflow, fatalError)
        case SIGABRT: return "SIGABRT"   // assertion / abort()
        case SIGBUS:  return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGSYS:  return "SIGSYS"
        case SIGPIPE: return "SIGPIPE"
        case SIGTERM: return "SIGTERM"
        case SIGKILL: return "SIGKILL"
        default:      return "signal \(sig)"
        }
    }
}

// MARK: - ndjson stream parser

/// One progress line off the CLI's `--progress-json` stream.
struct ProgressJSONLine {
    let phase: String
    let processed: UInt64
    let total: UInt64
    /// `.infinity` when the CLI emitted `etaSeconds: null` (initial
    /// snapshot, less than 0.5 % complete, or otherwise unknown).
    let etaSeconds: Double
    let done: Bool
}

/// Accumulates partial-line bytes between `readabilityHandler`
/// invocations and emits one parsed `ProgressJSONLine` per complete
/// `\n`-terminated chunk. `JSONSerialization.jsonObject(with:)` is
/// strict about input being a single complete JSON document, hence
/// the line-buffer instead of feeding it raw `Data`.
///
/// **PR #67 additions.** Lines that don't parse as JSON are no
/// longer silently dropped — they're collected in a bounded ring
/// buffer (`capturedText`), so when the CLI subprocess prints a
/// real error message to stderr alongside its `--progress-json`
/// stream, `OperationCoordinator` can surface that text in the
/// failure alert instead of leaving the user with a bare "knit
/// exited with status N".
final class NDJSONLineParser: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    /// Bounded buffer of non-JSON stderr lines seen so far. Trimmed
    /// to `maxCapturedLines` from the head; older entries are
    /// dropped on overflow so a runaway error spew can't grow
    /// memory unboundedly while still preserving the most recent
    /// (and usually most diagnostic) output.
    private var capturedText: [String] = []
    private let maxCapturedLines = 50

    /// Feed bytes from a pipe read. Calls `emit` once per complete
    /// JSON line, on whichever thread `feed` is called on (the
    /// readabilityHandler thread). Non-JSON lines are appended to
    /// `capturedText` instead. The caller is responsible for any
    /// cross-thread hand-off.
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
            } else if !lineBytes.isEmpty,
                      let text = String(data: Data(lineBytes), encoding: .utf8) {
                // Non-JSON text — usually a real error message from
                // the CLI ("knit: cannot open input: ..."). Keep
                // for the failure alert.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    capturedText.append(trimmed)
                    if capturedText.count > maxCapturedLines {
                        capturedText.removeFirst(capturedText.count - maxCapturedLines)
                    }
                }
            }
        }
        lock.unlock()
    }

    /// Snapshot of non-JSON lines seen so far, oldest first. Used by
    /// `OperationCoordinator.handleChildExit` to include the CLI's
    /// real error output in the failure alert.
    func capturedTextSnapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return capturedText
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
        // `etaSeconds` is either a number or JSON `null` (which
        // JSONSerialization decodes to `NSNull`). Treat null as
        // unknown — the ProgressWindow renders no ETA suffix when
        // the value is `.infinity`.
        let etaSeconds: Double
        if let n = obj["etaSeconds"] as? NSNumber {
            etaSeconds = n.doubleValue
        } else {
            etaSeconds = .infinity
        }
        return ProgressJSONLine(phase: phase, processed: processed,
                                total: total, etaSeconds: etaSeconds,
                                done: done)
    }
}
