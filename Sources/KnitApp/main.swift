// Knit.app — minimal AppKit launcher.
//
// Two responsibilities:
//   1. Provide a registered .app bundle so macOS Launch Services can apply
//      the .knit UTI declaration + document icon (declared in Info.plist).
//   2. When the user double-clicks a .knit file (or drags one onto the app
//      icon), invoke `/usr/local/bin/knit unpack` for them.
//
// Compiled stand-alone via swiftc inside Scripts/build-app.sh — kept out of
// Package.swift so KnitCore doesn't gain an AppKit dependency.

import AppKit

// 100 MiB. Inputs at or above this size open a Terminal window so the
// user sees `knit unpack --progress`; smaller inputs extract silently
// in the background with no notification. The threshold is intentionally
// generous — on M5 Max a 100 MiB archive extracts in ~0.05 s and the
// Terminal window's own appearance animation takes longer than that.
// On slower Apple Silicon hardware (base M1 / M2, ~1.5 GB/s SSDs) it
// approaches 0.2 s, still under the "noticeable enough to want a
// progress bar" line. PR #50 set this value to match the matching
// threshold inside `Scripts/build-quick-actions.sh`.
private let kTerminalSizeThresholdBytes: UInt64 = 100 * 1024 * 1024

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pendingExtractions = 0
    private var openFileEverFired = false

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openFileEverFired = true
        pendingExtractions += filenames.count
        for path in filenames {
            extract(path: path) { [weak self] in
                guard let self = self else { return }
                self.pendingExtractions -= 1
                if self.pendingExtractions == 0 {
                    NSApp.reply(toOpenOrPrint: .success)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // openFiles is delivered after applicationWillFinishLaunching but
        // possibly slightly after didFinishLaunching. Wait briefly, then
        // either show a help message or exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, !self.openFileEverFired else { return }
            self.showHelpAlert()
            NSApp.terminate(nil)
        }
    }

    /// Route the extraction either through a Terminal window (when the
    /// archive is large enough that the user benefits from a live
    /// `--progress` bar) or through a silent background `Process`
    /// (small archives — over before the Terminal window would have
    /// finished opening). Neither path emits a completion notification,
    /// matching the rest of the Quick Action surface (PR #50 spec).
    private func extract(path: String, completion: @escaping () -> Void) {
        let size: UInt64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        }()

        if size >= kTerminalSizeThresholdBytes {
            extractViaTerminal(path: path, completion: completion)
        } else {
            extractSilent(path: path, completion: completion)
        }
    }

    /// Silent fast path: spawn the unpacker, wait for it, complete. No
    /// Terminal window, no notification, no UI other than an error
    /// alert if the binary is missing or the run fails.
    private func extractSilent(path: String, completion: @escaping () -> Void) {
        let url = URL(fileURLWithPath: path)
        let outDir = url.deletingLastPathComponent().path

        guard let knit = Self.locateKnitCLI() else {
            DispatchQueue.main.async {
                self.alert(title: "Knit CLI not found",
                           message: "Couldn't find /usr/local/bin/knit. Run install.sh from the Knit DMG to install the CLI.")
                completion()
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = knit
            let lower = path.lowercased()
            if lower.hasSuffix(".zip") {
                // knit doesn't ship a zip extractor yet — fall back to
                // /usr/bin/unzip. Same policy the Terminal path takes
                // (see Scripts/build-quick-actions.sh's extract.sh).
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-q", "-o", path, "-d", outDir]
            } else {
                proc.arguments = ["unpack", path, "-o", outDir]
            }
            do {
                try proc.run()
                proc.waitUntilExit()
                let ok = proc.terminationStatus == 0
                DispatchQueue.main.async {
                    if !ok {
                        self.alert(title: "Extraction failed",
                                   message: "knit unpack exited with status \(proc.terminationStatus) for \(url.lastPathComponent).")
                    }
                    completion()
                }
            } catch {
                DispatchQueue.main.async {
                    self.alert(title: "Couldn't launch knit",
                               message: error.localizedDescription)
                    completion()
                }
            }
        }
    }

    /// Large-archive path: open Terminal.app via AppleScript and run
    /// `knit unpack … --progress` there. Mirrors the Quick Action
    /// runner shape — print "[Done.]" + sleep 3, then have AppleScript
    /// close the window once the shell exits. Knit.app doesn't block
    /// on the Terminal session; once `osascript` returns, we call
    /// completion and let the app terminate.
    private func extractViaTerminal(path: String, completion: @escaping () -> Void) {
        let url = URL(fileURLWithPath: path)
        let outDir = url.deletingLastPathComponent().path
        let lower = path.lowercased()

        // Build the command the runner shell will execute. We
        // intentionally don't shell-quote here via `escaped` because
        // the values are already path strings and we pipe them through
        // a heredoc into a runner script file below. Each path gets
        // single-quoted with any embedded `'` doubled, which is the
        // standard POSIX-safe quoting for shell strings.
        func sqQuote(_ s: String) -> String {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let qPath = sqQuote(path)
        let qOutDir = sqQuote(outDir)
        let knitCmd: String
        if lower.hasSuffix(".zip") {
            knitCmd = "/usr/bin/unzip -o \(qPath) -d \(qOutDir)"
        } else {
            knitCmd = "/usr/local/bin/knit unpack \(qPath) --progress -o \(qOutDir)"
        }

        // Write the runner script to a temp file. AppleScript's
        // `do script` will execute it, then we close the Terminal
        // window when the tab is no longer busy.
        let runner = (try? Self.writeRunner(knitCmd: knitCmd)) ?? "/tmp/knit-runner-failed.sh"

        let appleScript = """
        tell application "Terminal"
            activate
            set theTab to do script "\(runner); exit"
            set theWindowID to id of front window
            repeat while busy of theTab
                delay 0.5
            end repeat
            delay 0.3
            repeat with w in windows
                if id of w is theWindowID then
                    close w saving no
                    exit repeat
                end if
            end repeat
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", appleScript]
            try? osa.run()
            // Don't wait — Knit.app exiting is fine. Terminal owns the
            // session and its AppleScript loop closes the window when
            // the runner finishes. The user-perceived completion is
            // when the Terminal window goes away, not when Knit.app
            // exits.
            DispatchQueue.main.async {
                completion()
            }
        }
        _ = url  // silence unused warning if path lookups change later
    }

    /// Write a small zsh runner script to a tempfile and return its
    /// path. The runner prints "[Done.]" + sleeps 3 so the user can
    /// read the final summary before the Terminal window auto-closes,
    /// then deletes itself.
    private static func writeRunner(knitCmd: String) throws -> String {
        let tmp = NSTemporaryDirectory()
        let path = (tmp as NSString).appendingPathComponent("knit_unpack_runner_\(UUID().uuidString).sh")
        let body = """
        #!/bin/zsh
        set -u
        \(knitCmd)
        printf "\\n[Done.]\\n"
        sleep 3
        rm -f -- '\(path)'
        exit 0
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        var attrs = [FileAttributeKey: Any]()
        attrs[.posixPermissions] = NSNumber(value: 0o755)
        try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
        return path
    }

    private static func locateKnitCLI() -> URL? {
        let candidates = [
            "/usr/local/bin/knit",
            "/opt/homebrew/bin/knit",
        ]
        for c in candidates {
            if FileManager.default.isExecutableFile(atPath: c) {
                return URL(fileURLWithPath: c)
            }
        }
        // Fallback: knit binary bundled inside the .app
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "knit"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    private func alert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func showHelpAlert() {
        let a = NSAlert()
        a.messageText = "Knit"
        a.informativeText = "Knit is a command-line tool. Right-click any .knit or .zip file in Finder and choose a Knit Quick Action, or drag a file onto this app icon to extract it."
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
