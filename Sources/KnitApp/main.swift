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
        openFileEverFired = true
        // openFiles is the LaunchServices entrypoint — double-click on
        // .knit / .zip, drag onto app icon, `open file.knit` from CLI.
        // Treat each as an extract operation.
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        startOperation(.extractArchive(inputs: urls, outputDir: nil))
        NSApp.reply(toOpenOrPrint: .success)
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
                    inputs.append(URL(fileURLWithPath: raw[i]))
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
            let alert = NSAlert()
            alert.messageText = "Knit CLI not found"
            alert.informativeText = "Couldn't find /usr/local/bin/knit. Run the installer (or install.sh) to install the CLI."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            NSApp.terminate(nil)
            return
        }

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
// Don't show in the Dock — this is a helper app, not a foreground GUI.
app.setActivationPolicy(.accessory)
app.run()
