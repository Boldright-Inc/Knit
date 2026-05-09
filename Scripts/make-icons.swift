// Generate Knit's app and document icons as .iconset directories.
// Usage:  swift Scripts/make-icons.swift <output_dir>
//
// Produces:
//   <out>/AppIcon.iconset/        (run iconutil -c icns ... afterwards)
//   <out>/KnitDocument.iconset/
//
// Followed by `iconutil -c icns` in build-app.sh to package.

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------------
// Drawing primitives
// ---------------------------------------------------------------------------

/// macOS-style rounded square palette tuned to read at 16px:
///   gradient indigo background, big white "K" with subtle shadow.
func drawAppIcon(in ctx: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Squircle-ish corner radius (Big Sur+ proportions).
    let cornerRadius = size * 0.2237
    ctx.saveGState()
    let clipPath = CGPath(roundedRect: rect,
                          cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius,
                          transform: nil)
    ctx.addPath(clipPath)
    ctx.clip()

    // Diagonal indigo→teal gradient.
    let colors = [
        CGColor(red: 0.16, green: 0.22, blue: 0.46, alpha: 1.0),  // top
        CGColor(red: 0.08, green: 0.40, blue: 0.55, alpha: 1.0),  // bottom
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space,
                             colors: colors,
                             locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0),
                               options: [])
    }

    // Subtle inner glow at top.
    let highlightColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.18),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: space,
                             colors: highlightColors,
                             locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(glow,
                               start: CGPoint(x: size / 2, y: size),
                               end: CGPoint(x: size / 2, y: size * 0.55),
                               options: [])
    }

    // Big white "K".
    drawLetterK(in: ctx, size: size, color: .white)

    ctx.restoreGState()
}

/// Document icon: page-with-folded-corner shape, "KNIT" wordmark + the K motif.
func drawDocumentIcon(in ctx: CGContext, size: CGFloat) {
    let pad = size * 0.06
    let pageRect = CGRect(x: pad, y: pad,
                          width: size - pad * 2,
                          height: size - pad * 2)
    let foldSize = size * 0.30

    // Page silhouette with cut corner (top-right).
    let path = CGMutablePath()
    let pTL = CGPoint(x: pageRect.minX, y: pageRect.maxY)
    let pTRcut = CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY)
    let pCorner = CGPoint(x: pageRect.maxX, y: pageRect.maxY - foldSize)
    let pBR = CGPoint(x: pageRect.maxX, y: pageRect.minY)
    let pBL = CGPoint(x: pageRect.minX, y: pageRect.minY)
    path.move(to: pTL)
    path.addLine(to: pTRcut)
    path.addLine(to: pCorner)
    path.addLine(to: pBR)
    path.addLine(to: pBL)
    path.closeSubpath()

    // Fill page with a soft white→light-gray gradient.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let bg = [
        CGColor(red: 0.99, green: 0.99, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1.0),
    ] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    if let grad = CGGradient(colorsSpace: space, colors: bg, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // Page outline (1 px logical, scaled).
    ctx.saveGState()
    ctx.setLineWidth(max(1.0, size * 0.005))
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 1.0))
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    // Folded corner triangle (the cut piece) drawn as a small flap.
    let foldPath = CGMutablePath()
    foldPath.move(to: pTRcut)
    foldPath.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY))
    foldPath.addLine(to: pCorner)
    foldPath.closeSubpath()
    ctx.saveGState()
    ctx.addPath(foldPath)
    ctx.setFillColor(CGColor(red: 0.78, green: 0.82, blue: 0.90, alpha: 1.0))
    ctx.fillPath()
    ctx.addPath(foldPath)
    ctx.setLineWidth(max(1.0, size * 0.005))
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 1.0))
    ctx.strokePath()
    ctx.restoreGState()

    // "K" mark — same indigo gradient as the app icon.
    let kRect = pageRect.insetBy(dx: pageRect.width * 0.10,
                                 dy: pageRect.height * 0.18)
    ctx.saveGState()
    let kColors = [
        CGColor(red: 0.16, green: 0.22, blue: 0.46, alpha: 1.0),
        CGColor(red: 0.08, green: 0.40, blue: 0.55, alpha: 1.0),
    ] as CFArray
    if let _ = CGGradient(colorsSpace: space, colors: kColors, locations: [0, 1]) {
        // Use solid color for the document K — keeps it readable at small sizes.
        drawLetterK(in: ctx, size: size, rect: kRect,
                    color: NSColor(calibratedRed: 0.13, green: 0.30, blue: 0.50, alpha: 1.0))
    }
    ctx.restoreGState()

    // "KNIT" wordmark below.
    let label = "KNIT"
    let fontSize = size * 0.10
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.48, alpha: 1.0),
        .kern: fontSize * 0.10,
    ]
    let attr = NSAttributedString(string: label, attributes: attrs)
    let strSize = attr.size()
    let labelX = (size - strSize.width) / 2
    let labelY = pageRect.minY + size * 0.05
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(at: CGPoint(x: labelX, y: labelY))
    NSGraphicsContext.restoreGraphicsState()
}

func drawLetterK(in ctx: CGContext,
                 size: CGFloat,
                 rect overrideRect: CGRect? = nil,
                 color: NSColor) {
    let r = overrideRect ?? CGRect(x: 0, y: 0, width: size, height: size)
    let fontSize = r.width * 0.95
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let str = NSAttributedString(string: "K", attributes: attrs)
    let strSize = str.size()
    let x = r.minX + (r.width - strSize.width) / 2
    // Optical centering: nudge K up slightly because heavy weight has more
    // ink at the top.
    let y = r.minY + (r.height - strSize.height) / 2 - r.height * 0.02

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    str.draw(at: CGPoint(x: x, y: y))
    NSGraphicsContext.restoreGraphicsState()
}

// ---------------------------------------------------------------------------
// Iconset writer
// ---------------------------------------------------------------------------

struct IconSpec {
    let pixelSize: Int
    let filename: String   // e.g., icon_16x16.png, icon_16x16@2x.png
}

let specs: [IconSpec] = [
    IconSpec(pixelSize: 16,   filename: "icon_16x16.png"),
    IconSpec(pixelSize: 32,   filename: "icon_16x16@2x.png"),
    IconSpec(pixelSize: 32,   filename: "icon_32x32.png"),
    IconSpec(pixelSize: 64,   filename: "icon_32x32@2x.png"),
    IconSpec(pixelSize: 128,  filename: "icon_128x128.png"),
    IconSpec(pixelSize: 256,  filename: "icon_128x128@2x.png"),
    IconSpec(pixelSize: 256,  filename: "icon_256x256.png"),
    IconSpec(pixelSize: 512,  filename: "icon_256x256@2x.png"),
    IconSpec(pixelSize: 512,  filename: "icon_512x512.png"),
    IconSpec(pixelSize: 1024, filename: "icon_512x512@2x.png"),
]

func writeIconset(name: String, drawer: (CGContext, CGFloat) -> Void, into outDir: URL) {
    let iconsetDir = outDir.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconsetDir)
    try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    for spec in specs {
        let px = spec.pixelSize
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: px,
                                  height: px,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            FileHandle.standardError.write("CGContext alloc failed\n".data(using: .utf8)!)
            exit(1)
        }
        // High quality interpolation
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        // Clear background (transparent for app/doc icons).
        ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

        drawer(ctx, CGFloat(px))

        guard let cg = ctx.makeImage() else {
            FileHandle.standardError.write("makeImage failed for \(spec.filename)\n".data(using: .utf8)!)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
            exit(1)
        }
        let outURL = iconsetDir.appendingPathComponent(spec.filename)
        try! pngData.write(to: outURL)
        print("  \(name)/\(spec.filename) (\(px)px)")
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

let outArg = CommandLine.arguments.dropFirst().first ?? "."
let outDir = URL(fileURLWithPath: outArg, isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

print(">> writing AppIcon.iconset")
writeIconset(name: "AppIcon", drawer: drawAppIcon, into: outDir)

print(">> writing KnitDocument.iconset")
writeIconset(name: "KnitDocument", drawer: drawDocumentIcon, into: outDir)

print(">> done. Convert with: iconutil -c icns <name>.iconset")
