// Knit.app — AppKit launcher that drives the knit CLI from Finder.
//
// Three roles:
//   1. Register the .knit UTI + document icon via the Info.plist.
//   2. Handle file-double-click + drag-onto-app → run `knit unpack`
//      and surface progress through a native NSProgress (which Finder
//      decorates the output's file icon with, plus shows in the menu-
//      bar progress widget).
//   3. Handle Quick Action invocations from
//      `Scripts/build-quick-actions.sh` → run `knit pack` / `knit zip`
//      / `knit unpack` with the same NSProgress wiring.
//
// PR #57: rewritten around `OperationCoordinator` + `NSProgress`.
// Previously Knit.app spawned Terminal.app and shoved an ANSI bar
// into it; the new flow stays GUI-side. The CLI still works
// standalone — Knit.app uses the hidden `--progress-json` flag to
// drive its own NSProgress.
//
// Compiled stand-alone via swiftc inside Scripts/build-app.sh —
// kept out of Package.swift so KnitCore doesn't gain an AppKit
// dependency.

import AppKit
import Foundation

/// `@unchecked Sendable` because the only mutation (`coordinators`,
/// `openFileEverFired`) happens on the main queue, and the only
/// off-main entry point is the `onAllDone` closure handed to each
/// coordinator — which immediately hops back to main before touching
/// any AppDelegate state. The Swift 6 strict-concurrency analyser
/// can't prove that statically; this annotation is the standard
/// `CLAUDE.md` Rule 1.3 escape hatch for "the invariant is enforced
/// by call-site discipline, not the type system".
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    /// Active operations. We stay alive while at least one is in
    /// flight, then `NSApp.terminate(nil)` once the array drains.
    private var coordinators: [OperationCoordinator] = []
    private var openFileEverFired = false

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // PR #58 bug: macOS Tahoe ALSO calls openFiles with every
        // string in `--args` whose syntax could pass as a path —
        // including the literal words "pack" / "unpack" / "zip" plus
        // the selected file. That caused a single Quick Action
        // invocation to fire one packToKnit (via parseQuickActionArgs
        // in didFinishLaunching) PLUS spurious extractArchive
        // subprocesses, producing parallel knit invocations and
        // a stream of "Extracting 'unpack'" / "Extracting 'zip'"
        // progress windows.
        //
        // PR #58 added a `--operation` argv guard here. That guard
        // is still the primary defence (Quick Action path through
        // didFinishLaunching is authoritative), but the user
        // reproduced the symptom on macOS 26 anyway — openFiles
        // had already been queued before the argv check could run
        // for at least one delivery, or the argv check was bypassed
        // by a delivery path we haven't characterised. Belt-and-
        // braces: even after the argv guard fires, filter the
        // filenames so that the words `pack` / `unpack` / `zip` /
        // `extract` and any path that does not exist on disk are
        // discarded. With the filter, the only thing that survives
        // is a real file the user actually intended to open.
        let filtered = Self.filterOpenFileDeliveries(filenames)
        if ProcessInfo.processInfo.arguments.contains("--operation") {
            // Tell LaunchServices we acknowledged the request — without
            // this it considers the open request unanswered and may
            // log warnings. We discard the filenames because the
            // Quick Action path through didFinishLaunching is the
            // authoritative source.
            NSApp.reply(toOpenOrPrint: .success)
            return
        }
        if filtered.isEmpty {
            // openFiles was called with nothing but reserved words or
            // non-existent paths — almost certainly a spurious macOS
            // Tahoe redelivery of `--args` strings. Don't start any
            // operation; just acknowledge.
            NSApp.reply(toOpenOrPrint: .success)
            return
        }
        openFileEverFired = true
        // openFiles is the LaunchServices entrypoint — double-click on
        // .knit / .zip, drag onto app icon, `open file.knit` from CLI.
        // Treat each as an extract operation.
        let urls = filtered.map { URL(fileURLWithPath: $0) }
        startOperation(.extractArchive(inputs: urls, outputDir: nil))
        NSApp.reply(toOpenOrPrint: .success)
    }

    /// macOS Tahoe redelivers `--args` strings to `openFiles` even when
    /// they were never intended as document paths. Drop:
    ///
    ///   1. Reserved Quick Action verbs (`pack` / `unpack` / `zip` /
    ///      `extract`) — those are never valid filenames in the Quick
    ///      Action shell-wrapper layout, so anything matching is
    ///      definitionally a spurious redelivery.
    ///   2. Paths that don't exist on disk — a real Finder double-click
    ///      always hands us an existing file, so a missing path is
    ///      another signal of a spurious string-as-path delivery.
    ///
    /// Applied in both openFiles and parseQuickActionArgs (Quick Action
    /// `--inputs` clause) for symmetry. Defensive against the next
    /// `--args`-string-as-document delivery quirk we haven't seen yet.
    static let reservedQuickActionVerbs: Set<String> = [
        "pack", "unpack", "zip", "extract",
    ]

    static func filterOpenFileDeliveries(_ filenames: [String]) -> [String] {
        let fm = FileManager.default
        return filenames.filter { name in
            if Self.reservedQuickActionVerbs.contains(name.lowercased()) {
                return false
            }
            return fm.fileExists(atPath: name)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Quick Action invocation path uses
        // `open -a Knit.app --args --operation pack ...`. ArgumentParser
        // would be overkill here — we hand-parse the small flag set.
        if let op = Self.parseQuickActionArgs() {
            openFileEverFired = true   // suppress the "drop a file" alert
            startOperation(op)
            return
        }

        // openFiles is delivered shortly after didFinishLaunching but
        // possibly slightly *after*, depending on Launch Services
        // scheduling. Give it 0.6 s to fire; if neither openFiles nor
        // Quick Action args showed up, the user double-clicked the
        // bare app icon — show the help alert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, !self.openFileEverFired else { return }
            self.showHelpAlert()
            NSApp.terminate(nil)
        }
    }

    // MARK: - Quick Action arg parsing

    /// Recognises:
    ///   --operation pack | zip | extract
    ///   --inputs <path>...
    ///   --output <dir>            (optional)
    ///   --level <int>             (optional, default 3 for pack, 6 for zip)
    ///
    /// `--inputs` consumes all following args until the next flag or
    /// end-of-args. This matches how the Quick Action's
    /// `open -a Knit.app --args ...` invocation lays out its tail.
    static func parseQuickActionArgs() -> KnitOperation? {
        // ProcessInfo skips argv[0] (the executable path); subsequent
        // entries are the --args payload we got from `open`.
        let raw = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var op: String?
        var inputs: [URL] = []
        var output: URL?
        var level: Int?
        var i = 0
        while i < raw.count {
            let a = raw[i]
            switch a {
            case "--operation":
                if i + 1 < raw.count {
                    op = raw[i + 1]
                    i += 2
                } else { i += 1 }
            case "--inputs":
                i += 1
                while i < raw.count && !raw[i].hasPrefix("--") {
                    // Defense-in-depth: drop reserved Quick Action
                    // verbs and non-existent paths before they reach
                    // the operation dispatcher. A correctly-formed
                    // Quick Action shell wrapper never puts these in
                    // `--inputs`, so anything matching is either a
                    // typo / mis-built workflow or a sign that argv
                    // got mangled by `open` (e.g. `--args` parsing
                    // drift between macOS versions).
                    let candidate = raw[i]
                    let isReserved = Self.reservedQuickActionVerbs
                        .contains(candidate.lowercased())
                    let exists = FileManager.default
                        .fileExists(atPath: candidate)
                    if !isReserved && exists {
                        inputs.append(URL(fileURLWithPath: candidate))
                    }
                    i += 1
                }
            case "--output":
                if i + 1 < raw.count {
                    output = URL(fileURLWithPath: raw[i + 1])
                    i += 2
                } else { i += 1 }
            case "--level":
                if i + 1 < raw.count, let n = Int(raw[i + 1]) {
                    level = n
                    i += 2
                } else { i += 1 }
            default:
                // Unknown flag/arg — skip. Includes Launch Services'
                // own injections like `-NSDocumentRevisionsDebugMode`.
                i += 1
            }
        }
        guard let op = op, !inputs.isEmpty else { return nil }
        // Defensive cap. The `--inputs` parser above is greedy until
        // the next `--` flag, and Finder Quick Actions expand `"$@"`
        // to every selected file — so a careless right-click on a
        // huge selection could yield hundreds-to-thousands of input
        // URLs. `OperationCoordinator` now executes runs serially
        // (one subprocess at a time), but capping here is defense in
        // depth: even if a future refactor accidentally re-introduces
        // parallel launch, the blast radius is bounded. 256 is well
        // above any plausible "select files in Finder and compress"
        // intent; users hitting this limit should pre-archive into a
        // folder first.
        let maxInputs = 256
        if inputs.count > maxInputs {
            FileHandle.standardError.write(Data(
                "Knit: too many inputs (\(inputs.count) > \(maxInputs)). Pre-archive into a folder and try again.\n".utf8))
            return nil
        }
        switch op {
        case "pack":
            return .packToKnit(inputs: inputs, outputDir: output, level: level ?? 3)
        case "zip":
            return .zipParallel(inputs: inputs, outputDir: output, level: level ?? 6)
        case "extract":
            return .extractArchive(inputs: inputs, outputDir: output)
        default:
            return nil
        }
    }

    // MARK: - Operation dispatch

    private func startOperation(_ operation: KnitOperation) {
        guard let knit = Self.locateKnitCLI() else {
            // PR #58 hotfix: this used to call `alert.runModal()`
            // synchronously here, then `NSApp.terminate(nil)`. But
            // `startOperation` is called from inside
            // `applicationDidFinishLaunching`, BEFORE the run loop
            // is fully in a state to host a modal session — and
            // before `NSApp.activate(...)` runs (we early-return out
            // of it via this guard). In a backgrounded direct-binary
            // launch (e.g. a terminal smoke test) the modal session
            // failed to enter and `runModal()` returned immediately,
            // so the user saw no alert, no stderr, no output — just
            // a silent <1s exit. This was the observation that made
            // smoke tests appear broken even though the code path
            // was being hit correctly.
            //
            // Two fixes:
            //   1. Write to stderr unconditionally so terminal users
            //      see what happened.
            //   2. Defer the alert to the next runloop tick via
            //      `DispatchQueue.main.async`, after didFinishLaunching
            //      has fully completed. The modal session can then
            //      enter properly.
            FileHandle.standardError.write(Data(
                "Knit: knit CLI not found. Run install.sh (or the installer pkg) to install /usr/local/bin/knit.\n".utf8))
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Knit CLI not found"
                alert.informativeText = "Couldn't find /usr/local/bin/knit. Run the installer (or install.sh) to install the CLI."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                _ = alert.runModal()
                NSApp.terminate(nil)
            }
            return
        }

        // Force the app to activate. Without this the published
        // NSProgress widget can appear, but Finder won't bring it
        // forward and the user won't see anything happening — Knit.app
        // gets stuck in the background of whatever app the user was
        // last clicking in. Activating also unhides the Dock icon
        // immediately, giving the user a visible cue that something
        // is in progress even if the NSProgress UI is delayed.
        NSApp.activate(ignoringOtherApps: true)

        // The coordinator captures `self` weakly so the deallocator
        // for the last coordinator can fire even from one of the
        // subprocess threads. We hold a strong ref in `coordinators`
        // for the operation's lifetime.
        var coordinator: OperationCoordinator!
        coordinator = OperationCoordinator(
            operation: operation,
            knitURL: knit
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.coordinatorFinished(coordinator)
            }
        }
        coordinators.append(coordinator)
        coordinator.start()
    }

    private func coordinatorFinished(_ coordinator: OperationCoordinator) {
        coordinators.removeAll { $0 === coordinator }
        if coordinators.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // MARK: - CLI lookup

    private static func locateKnitCLI() -> URL? {
        let candidates = [
            "/usr/local/bin/knit",
            "/opt/homebrew/bin/knit",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        // Fallback: knit binary bundled inside the .app
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "knit"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    // MARK: - Help

    private func showHelpAlert() {
        let a = NSAlert()
        a.messageText = "Knit"
        a.informativeText = "Knit is a command-line tool. Right-click any file or folder in Finder and choose a Knit Quick Action, or drag a .knit / .zip onto this app icon to extract it."
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        _ = a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// PR #58: Knit.app must be a regular foreground app (not accessory)
// for macOS to render its published `NSProgress` in the system
// progress widget and as the Finder file-icon overlay. The accessory
// activation policy that earlier revisions used silenced both of
// those surfaces — same root cause as the LSUIElement key in
// Info.plist (now removed).
//
// Consequence: the Dock icon appears while Knit.app is running an
// operation, then disappears when the app exits at the end of the
// operation. This matches how Archive Utility / Safari's
// "downloading…" / Mail's "saving…" surfaces work: they're regular
// apps that the system happens to terminate after their one
// operation. For users invoking a Quick Action this means a brief
// Dock-icon flash on fast operations and a steady Dock icon for the
// duration of slow ones.
app.setActivationPolicy(.regular)
app.run()
