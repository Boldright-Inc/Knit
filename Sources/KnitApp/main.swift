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

    private func extract(path: String, completion: @escaping () -> Void) {
        let url = URL(fileURLWithPath: path)
        let outDir = url.deletingLastPathComponent().path
        let knit = Self.locateKnitCLI()

        guard let knit = knit else {
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
            if lower.hasSuffix(".knit") {
                proc.arguments = ["unpack", path, "-o", outDir]
            } else if lower.hasSuffix(".zip") {
                // Forward .zip too — knit doesn't ship a zip extractor yet,
                // so fall back to the system's unzip via /usr/bin/unzip.
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
                    if ok {
                        self.notify(title: "Knit", body: "Extracted \(url.lastPathComponent)")
                    } else {
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

    private func notify(title: String, body: String) {
        // Lightweight: shell out to osascript so we don't pull in
        // UserNotifications/NotificationCenter setup for a one-shot helper.
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
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
