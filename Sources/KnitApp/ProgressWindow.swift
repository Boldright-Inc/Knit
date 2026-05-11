// Guaranteed-visible progress UI for a single Knit operation.
//
// We also publish an `NSProgress` (in `OperationCoordinator`) which —
// with the LSUIElement fix from PR #58 — lets macOS render its own
// floating progress widget and decorate the output file's Finder
// icon. Both are best-effort, system-level surfaces that depend on
// Finder being in a state to display them. A custom NSPanel is the
// belt-and-braces fallback: opaque, drawn by us, always visible
// while an operation runs.
//
// Layout mirrors the screenshot the user pointed at — small floating
// panel in the bottom-right (out of the way of file selections in
// Finder), three rows of content:
//
//   [icon]  "Compressing 'data' to 'data.zip'"         [×]
//           [================░░░░░░░░░░░░░░░░░░]
//           660.2 MB of 6.34 GB · about 1 minute
//
// PR #58.

import AppKit
import Foundation
import UniformTypeIdentifiers

final class ProgressWindow: NSPanel {

    // MARK: - Subviews

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton()

    /// Fires when the user clicks the × button. The owner
    /// (OperationCoordinator) should cancel its NSProgress, which
    /// triggers the cancellationHandler chain.
    var onCancel: (() -> Void)?

    // MARK: - Construction

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 96),
            // .nonactivatingPanel keeps the user's previously-active
            // app frontmost (Finder usually) — the progress panel
            // floats above without stealing focus.
            // .hudWindow gives the dark vibrancy look matching the
            // Finder Compress widget from the user's screenshot.
            styleMask: [.titled, .hudWindow, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = ""
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        configureSubviews()
        layoutSubviews()
        positionInBottomRight()
    }

    private func configureSubviews() {
        guard let content = self.contentView else { return }
        // Force the content view's flipped origin (top-left) so frame
        // math below reads naturally top-down.
        let flipped = FlippedView(frame: content.bounds)
        flipped.autoresizingMask = [.width, .height]
        flipped.wantsLayer = true
        content.addSubview(flipped)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: "doc.fill",
                                  accessibilityDescription: "file")
        flipped.addSubview(iconView)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.textColor = .labelColor
        flipped.addSubview(titleLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.startAnimation(nil)
        flipped.addSubview(progressBar)

        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.textColor = .secondaryLabelColor
        flipped.addSubview(detailLabel)

        cancelButton.bezelStyle = .circular
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                      accessibilityDescription: "cancel")
        cancelButton.imagePosition = .imageOnly
        cancelButton.isBordered = false
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        flipped.addSubview(cancelButton)
    }

    /// Lay out the subviews with hand-computed frames. The panel is
    /// fixed-size so we don't need Auto Layout's overhead — a single
    /// `layoutSubviews()` call after construction is enough.
    private func layoutSubviews() {
        // Panel content: 460 wide × 96 tall.
        // 12 px gutter on every side; icon 36×36 top-left; cancel
        // button 22×22 top-right.
        iconView.frame = NSRect(x: 12, y: 12, width: 36, height: 36)
        cancelButton.frame = NSRect(x: 460 - 12 - 22, y: 12, width: 22, height: 22)

        // Title between icon and cancel button, on the top row.
        let titleX: CGFloat = 12 + 36 + 10
        let titleW: CGFloat = 460 - titleX - 22 - 12 - 8
        titleLabel.frame = NSRect(x: titleX, y: 14, width: titleW, height: 18)

        // Progress bar fills the second row, full width minus gutters.
        progressBar.frame = NSRect(x: titleX, y: 38, width: titleW, height: 12)

        // Detail label on the third row, just below the bar.
        detailLabel.frame = NSRect(x: titleX, y: 56, width: titleW, height: 14)
    }

    /// Stick the panel in the bottom-right of the main screen — out
    /// of the way of typical Finder selections and matches where Mac
    /// system progress widgets land.
    private func positionInBottomRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let size = frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
        setFrameOrigin(origin)
    }

    @objc private func handleCancel() {
        onCancel?()
    }

    // MARK: - Public update API

    /// Set the static header (icon + "Compressing X to Y" title).
    /// Called once when the operation starts.
    func configure(sourceURL: URL, outputURL: URL?, verb: Verb) {
        iconView.image = Self.icon(for: verb,
                                    sourceURL: sourceURL,
                                    outputURL: outputURL)

        switch verb {
        case .compressing:
            if let outputURL = outputURL {
                titleLabel.stringValue = "Compressing \"\(sourceURL.lastPathComponent)\" to \"\(outputURL.lastPathComponent)\""
            } else {
                titleLabel.stringValue = "Compressing \"\(sourceURL.lastPathComponent)\""
            }
        case .extracting:
            titleLabel.stringValue = "Extracting \"\(sourceURL.lastPathComponent)\""
        }
    }

    /// Pick the most informative icon for the panel:
    ///
    /// - **Compressing** → the OUTPUT format's icon. The user is making
    ///   a `.knit` (or `.zip`); seeing that format's icon makes "what
    ///   am I producing?" obvious at a glance. The earlier behaviour
    ///   (source icon: PVM, PNG, etc.) put the focus on the wrong end
    ///   of the operation.
    /// - **Extracting** → the SOURCE archive's icon. The user already
    ///   sees the archive in Finder; matching its icon ties the panel
    ///   visually to the file they just acted on.
    ///
    /// For `.knit` the bundled `KnitDocument.icns` is preferred over
    /// `NSWorkspace.icon(for: UTType)` because Launch Services may not
    /// have registered our exported `co.boldright.knit.archive` UTI for
    /// a locally-built / not-yet-installed Knit.app — system lookup
    /// would silently return a generic document icon in that case. The
    /// bundled resource is always present in the .app, so the icon is
    /// always correct.
    private static func icon(for verb: Verb,
                              sourceURL: URL,
                              outputURL: URL?) -> NSImage? {
        switch verb {
        case .compressing:
            guard let outputURL = outputURL else {
                return NSWorkspace.shared.icon(forFile: sourceURL.path)
            }
            let ext = outputURL.pathExtension.lowercased()
            if ext == "knit",
               let iconURL = Bundle.main.url(forResource: "KnitDocument",
                                              withExtension: "icns"),
               let image = NSImage(contentsOf: iconURL) {
                return image
            }
            // `.zip` (and any other system-known type) goes through
            // UTType so we get whatever the system has registered.
            if let utType = UTType(filenameExtension: ext) {
                return NSWorkspace.shared.icon(for: utType)
            }
            return NSWorkspace.shared.icon(forFile: sourceURL.path)
        case .extracting:
            return NSWorkspace.shared.icon(forFile: sourceURL.path)
        }
    }

    /// Apply a fresh progress snapshot. `processed`/`total` in
    /// uncompressed bytes; `etaSeconds` may be `.infinity` to
    /// indicate "unknown" (we treat that as indeterminate).
    func update(processed: UInt64, total: UInt64, etaSeconds: Double) {
        if total == 0 {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            detailLabel.stringValue = Self.formatBytes(processed)
            return
        }
        progressBar.isIndeterminate = false
        progressBar.maxValue = Double(total)
        progressBar.doubleValue = Double(processed)

        let processedStr = Self.formatBytes(processed)
        let totalStr = Self.formatBytes(total)
        let etaStr = Self.formatETA(etaSeconds)
        detailLabel.stringValue = "\(processedStr) of \(totalStr)\(etaStr)"
    }

    /// Show the panel. Called after `configure(...)`.
    func show() {
        // orderFrontRegardless avoids needing keyboard focus — the
        // panel just shows up above whatever the user is doing.
        orderFrontRegardless()
    }

    /// Tear down the panel. Call after the operation finishes.
    func dismiss() {
        progressBar.stopAnimation(nil)
        orderOut(nil)
        close()
    }

    // MARK: - Verb type

    enum Verb {
        case compressing
        case extracting
    }

    // MARK: - Helpers

    /// Decimal SI byte formatting, matching macOS Finder's display.
    private static func formatBytes(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1_000_000_000 {
            return String(format: "%.2f GB", v / 1_000_000_000)
        }
        if v >= 1_000_000 {
            return String(format: "%.1f MB", v / 1_000_000)
        }
        if v >= 1_000 {
            return String(format: "%.0f KB", v / 1_000)
        }
        return "\(n) B"
    }

    /// Human ETA matching macOS-style phrasing: "about 1 minute",
    /// "30 seconds", "—" when unknown. Used as the suffix on the
    /// detail line; empty string when ETA shouldn't be rendered.
    private static func formatETA(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        if s < 5 { return "" }  // misleadingly precise on very short tails
        if s < 60 { return " · \(s) seconds remaining" }
        let m = s / 60
        if m == 1 { return " · about 1 minute remaining" }
        if m < 10 { return " · about \(m) minutes remaining" }
        let h = m / 60
        if h == 0 { return " · \(m) minutes remaining" }
        return " · about \(h)h \(m % 60)m remaining"
    }
}

/// Flipped coordinate-system container so subview frames read in
/// the natural top-down layout used by `layoutSubviews()` above —
/// matches CSS / web-style top-origin without needing to invert
/// every y-coordinate.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
