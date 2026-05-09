import Foundation

/// Renders a `CompressibilityHeatmap` to an ANSI-styled string suitable for
/// terminal output, and (optionally) to a portable PPM image file.
///
/// The visual encoding is deliberately information-dense:
///   - **Cell character** picks one of `▁▂▃▄▅▆▇█` based on per-block ratio
///     (taller bar = block went on disk closer to its original size).
///   - **Cell foreground colour** is a viridis-inspired ramp keyed by
///     entropy: deep blue → teal → green → yellow → red as bits/byte rises
///     toward 8.
///   - **Cell background** is a desaturated version of the same hue —
///     this gives the grid a continuous "thermal" feel even when individual
///     bars are short.
///
/// The result reads at a glance: cool blue regions are highly compressible
/// text/code, warm red regions are already-compressed media, and shorter
/// bars sit where the codec actually managed to shrink the block on disk.
public struct HeatmapRenderer {

    public struct Options {
        public var width: Int = 64
        public var includeLegend: Bool = true
        public var includeSummary: Bool = true
        /// Optional metadata strings rendered in the header (one per line).
        public var headerLines: [String] = []
        /// Optional GPU device label rendered in the footer telemetry block.
        public var gpuDeviceLabel: String? = nil
        /// Predicted ratio (e.g. from the entropy probe) for delta vs. final.
        public var predictedRatio: Float? = nil
        /// Wall-clock elapsed during the run (seconds).
        public var elapsedSeconds: Double? = nil

        public init() {}
    }

    public let heatmap: CompressibilityHeatmap
    public let options: Options

    public init(heatmap: CompressibilityHeatmap, options: Options = Options()) {
        self.heatmap = heatmap
        self.options = options
    }

    // MARK: - Public API

    public func renderANSI() -> String {
        if heatmap.samples.isEmpty {
            return "  (no compressible blocks recorded)\n"
        }
        var s = ""
        s += renderHeader()
        s += renderGrid()
        if options.includeLegend { s += renderLegend() }
        if options.includeSummary { s += renderSummary() }
        return s
    }

    /// Write a P6 PPM image where each block becomes a `cellPx × cellPx`
    /// square coloured by the entropy ramp. Easy to view in Preview.app or
    /// share as a screenshot — independent of terminal capabilities.
    public func writePPM(to url: URL, cellPx: Int = 16, columns: Int = 64) throws {
        let n = heatmap.samples.count
        if n == 0 { return }
        let cols = max(1, min(columns, n))
        let rows = (n + cols - 1) / cols
        let pxW = cols * cellPx
        let pxH = rows * cellPx

        var data = Data()
        let header = "P6\n\(pxW) \(pxH)\n255\n"
        data.append(header.data(using: .ascii)!)
        data.reserveCapacity(data.count + pxW * pxH * 3)

        // Pre-compute one RGB per cell.
        var colours = [(UInt8, UInt8, UInt8)](repeating: (0,0,0), count: cols * rows)
        for (i, sample) in heatmap.samples.enumerated() {
            let (r, g, b) = colourRamp(entropy: sample.entropy,
                                       brightness: 1.0 - 0.55 * (1.0 - Double(sample.ratio)))
            colours[i] = (r, g, b)
        }

        for py in 0..<pxH {
            let cy = py / cellPx
            for px in 0..<pxW {
                let cx = px / cellPx
                let idx = cy * cols + cx
                let (r, g, b) = idx < colours.count ? colours[idx] : (0, 0, 0)
                data.append(r); data.append(g); data.append(b)
            }
        }
        try data.write(to: url)
    }

    // MARK: - Sections

    private func renderHeader() -> String {
        let inner = options.width - 2
        var s = ""
        s += "╭" + String(repeating: "─", count: inner) + "╮\n"
        s += boxLine("  Knit Compressibility Map", width: inner) + "\n"
        for line in options.headerLines {
            s += boxLine("  " + line, width: inner) + "\n"
        }
        s += "├" + String(repeating: "─", count: inner) + "┤\n"
        return s
    }

    private func renderGrid() -> String {
        let inner = options.width - 2
        let usable = max(8, inner - 4)
        let n = heatmap.samples.count
        let cols = min(usable, max(8, n))
        let rows = (n + cols - 1) / cols

        var s = ""
        s += boxLine("", width: inner) + "\n"
        for r in 0..<rows {
            var line = "  "
            for c in 0..<cols {
                let i = r * cols + c
                if i >= n {
                    line += " "
                } else {
                    line += renderCell(heatmap.samples[i])
                }
            }
            // Pad with spaces to fill the box (ANSI escapes don't count
            // against terminal width but our printable budget does, so we
            // pad in printable cells, not raw chars).
            s += "│" + line + ANSI.reset
            let printable = 2 + cols
            if printable < inner { s += String(repeating: " ", count: inner - printable) }
            s += "│\n"
        }
        s += boxLine("", width: inner) + "\n"
        return s
    }

    private func renderCell(_ sample: HeatmapSample) -> String {
        // 8 bar heights, indexed by ratio: ratio≈0 → tall █ inverted means
        // "compressed away to nothing"; ratio≈1 → short bar means "barely
        // shrank". We invert: shorter bar = better compression.
        // Visually: a wall of short bars in cool colours = "great corpus";
        // a wall of full red blocks = "this is mostly noise".
        let bars: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let ratioClamped = max(0.0, min(1.0, Double(sample.ratio)))
        let barIndex = Int((ratioClamped * Double(bars.count - 1)).rounded())
        let ch = bars[barIndex]

        let brightness = 1.0 - 0.45 * (1.0 - Double(sample.ratio))
        let (fr, fg, fb) = colourRamp(entropy: sample.entropy, brightness: brightness)
        let (br, bg, bb) = colourRamp(entropy: sample.entropy, brightness: brightness * 0.25)

        return ANSI.fg(fr, fg, fb) + ANSI.bg(br, bg, bb) + String(ch) + ANSI.reset
    }

    private func renderLegend() -> String {
        let inner = options.width - 2
        var s = ""
        s += "├" + String(repeating: "─", count: inner) + "┤\n"
        s += boxLine("  Entropy ramp:", width: inner) + "\n"

        // Sample 32 points across the ramp.
        let columns = max(16, min(inner - 6, 48))
        var rampLine = "    "
        for i in 0..<columns {
            let t = Float(i) / Float(columns - 1)
            let entropy = t * 8.0
            let (r, g, b) = colourRamp(entropy: entropy, brightness: 1.0)
            rampLine += ANSI.fg(r, g, b) + "█" + ANSI.reset
        }
        // Append literal scale.
        s += "│" + rampLine
        let printable = 4 + columns
        if printable < inner { s += String(repeating: " ", count: inner - printable) }
        s += "│\n"
        s += boxLine("    0 bit/byte ◀────── compressible ──────▶ 8 bit/byte (random)",
                     width: inner) + "\n"
        s += boxLine("    Bar height: stored/original ratio (▁ smaller, █ unchanged)",
                     width: inner) + "\n"
        return s
    }

    private func renderSummary() -> String {
        let inner = options.width - 2
        var s = ""
        s += "├" + String(repeating: "─", count: inner) + "┤\n"

        let total = heatmap.samples.count
        let stored = heatmap.storedBlockCount
        let compressed = heatmap.compressedBlockCount
        let storedFrac = total > 0 ? Float(stored) / Float(total) : 0
        let compFrac = total > 0 ? Float(compressed) / Float(total) : 0

        s += boxLine(String(format: "  Blocks:      %8d  total", total), width: inner) + "\n"
        s += boxLine(format(label: "  Compressed:", count: compressed,
                            fraction: compFrac, accent: .compressible),
                     width: inner) + "\n"
        s += boxLine(format(label: "  Stored:    ", count: stored,
                            fraction: storedFrac, accent: .incompressible),
                     width: inner) + "\n"

        s += boxLine(String(format: "  Mean entropy: %.2f bits/byte", heatmap.meanEntropy),
                     width: inner) + "\n"

        let inMB = Double(heatmap.totalOriginalBytes) / 1_000_000
        let outMB = Double(heatmap.totalStoredBytes) / 1_000_000
        let ratioPct = heatmap.overallRatio * 100
        s += boxLine(String(format: "  Bytes in/out: %.2f MB → %.2f MB  (%.2f%%)",
                            inMB, outMB, ratioPct),
                     width: inner) + "\n"

        if let predicted = options.predictedRatio {
            let delta = (heatmap.overallRatio - predicted) * 100
            s += boxLine(String(format: "  Predicted:    %.2f%%  (Δ %+.2f%%)",
                                predicted * 100, delta),
                         width: inner) + "\n"
        }
        if let elapsed = options.elapsedSeconds, elapsed > 0 {
            let mbs = inMB / elapsed
            s += boxLine(String(format: "  Throughput:   %.2f s wall, %.0f MB/s",
                                elapsed, mbs),
                         width: inner) + "\n"
        }
        if let gpu = options.gpuDeviceLabel {
            s += boxLine("  GPU:          " + gpu, width: inner) + "\n"
        }
        s += "╰" + String(repeating: "─", count: inner) + "╯\n"
        return s
    }

    private enum Accent { case compressible, incompressible }

    private func format(label: String, count: Int, fraction: Float, accent: Accent) -> String {
        let pct = fraction * 100
        let barWidth = 24
        let filled = Int((Double(fraction) * Double(barWidth)).rounded())
        let empty = barWidth - filled
        let (r, g, b): (UInt8, UInt8, UInt8) = (accent == .compressible)
            ? (90, 200, 140) : (235, 130, 95)
        let bar = ANSI.fg(r, g, b) + String(repeating: "█", count: filled) + ANSI.reset
                + String(repeating: "·", count: empty)
        return String(format: "%@ %7d  (%5.1f%%)  %@", label, count, pct, bar)
    }

    // MARK: - Colour ramp

    /// Smooth perceptual ramp through cool→warm hues, optionally dimmed by
    /// `brightness` ∈ [0, 1]. The control points are picked to feel close
    /// to viridis without pulling in a full LUT.
    private func colourRamp(entropy: Float, brightness: Double) -> (UInt8, UInt8, UInt8) {
        // Control points (entropy threshold, RGB)
        let stops: [(Float, (Double, Double, Double))] = [
            (0.0, ( 24.0,  35.0, 110.0)),   // deep indigo  — text, code
            (3.0, ( 35.0, 130.0, 165.0)),   // teal         — structured data
            (5.5, ( 70.0, 180.0, 110.0)),   // green        — typical mixed
            (6.8, (235.0, 200.0,  90.0)),   // amber        — borderline
            (7.5, (235.0, 130.0,  85.0)),   // orange       — barely
            (8.0, (210.0,  60.0,  70.0)),   // red          — incompressible
        ]
        let e = max(0, min(8, entropy))
        var rgb: (Double, Double, Double) = stops[0].1
        for i in 1..<stops.count {
            let (eHi, hi) = stops[i]
            let (eLo, lo) = stops[i - 1]
            if e <= eHi {
                let t = Double((e - eLo) / max(0.001, (eHi - eLo)))
                rgb = (
                    lo.0 + (hi.0 - lo.0) * t,
                    lo.1 + (hi.1 - lo.1) * t,
                    lo.2 + (hi.2 - lo.2) * t
                )
                break
            }
            rgb = hi
        }
        let b = max(0.0, min(1.0, brightness))
        let r = UInt8(max(0, min(255, rgb.0 * b)))
        let g = UInt8(max(0, min(255, rgb.1 * b)))
        let bl = UInt8(max(0, min(255, rgb.2 * b)))
        return (r, g, bl)
    }

    // MARK: - Box helpers

    /// Pads `text` (which may contain ANSI sequences — those don't count
    /// against the visible width) to `width` printable cells inside a box.
    private func boxLine(_ text: String, width: Int) -> String {
        let visible = ansiVisibleLength(text)
        let pad = max(0, width - visible)
        return "│" + text + String(repeating: " ", count: pad) + "│"
    }

    private func ansiVisibleLength(_ s: String) -> Int {
        var count = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\u{1B}" {
                // Skip ANSI escape: ESC [ ... letter
                var j = s.index(after: i)
                if j < s.endIndex, s[j] == "[" {
                    j = s.index(after: j)
                    while j < s.endIndex {
                        let cj = s[j]
                        j = s.index(after: j)
                        if cj.isLetter { break }
                    }
                }
                i = j
            } else {
                count += 1
                i = s.index(after: i)
            }
        }
        return count
    }
}

// MARK: - ANSI helpers

enum ANSI {
    static let reset = "\u{1B}[0m"
    static func fg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
        "\u{1B}[38;2;\(r);\(g);\(b)m"
    }
    static func bg(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> String {
        "\u{1B}[48;2;\(r);\(g);\(b)m"
    }
}
