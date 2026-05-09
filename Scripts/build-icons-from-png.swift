// Build AppIcon and KnitDocument iconsets from user-supplied PNG(s).
//
// Usage:
//   swift Scripts/build-icons-from-png.swift <out_dir>
//
// Required input:
//   Resources/Icons/app-icon.png        (square, ideally 1024x1024)
//
// Optional input:
//   Resources/Icons/doc-icon.png        (overrides auto-derived document icon)
//
// If doc-icon.png is missing, the document icon is auto-derived by compositing
// the app icon onto a folded-corner page silhouette. This matches the macOS
// convention where "the document icon is the app icon, sitting on a page".
//
// Output:
//   <out_dir>/AppIcon.iconset/         (PNG slices for iconutil)
//   <out_dir>/KnitDocument.iconset/

import AppKit
import CoreGraphics
import Foundation

// ---------------------------------------------------------------------------

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()    // Scripts/
    .deletingLastPathComponent()    // <repo>/
let iconsDir = projectRoot.appendingPathComponent("Resources/Icons")
let appPNGURL  = iconsDir.appendingPathComponent("app-icon.png")
let docPNGURL  = iconsDir.appendingPathComponent("doc-icon.png")

guard FileManager.default.fileExists(atPath: appPNGURL.path) else {
    FileHandle.standardError.write(
        "error: \(appPNGURL.path) not found\n".data(using: .utf8)!)
    FileHandle.standardError.write(
        "Drop a square PNG (ideally 1024x1024) at Resources/Icons/app-icon.png and re-run.\n"
            .data(using: .utf8)!)
    exit(1)
}

let outArg = CommandLine.arguments.dropFirst().first ?? "."
let outDir = URL(fileURLWithPath: outArg, isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// ---------------------------------------------------------------------------
// Image loading + resizing
// ---------------------------------------------------------------------------

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return img
}

func renderToPNG(at pixelSize: Int, drawer: (CGContext, CGFloat) -> Void) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: pixelSize,
                              height: pixelSize,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("CGContext alloc failed\n".data(using: .utf8)!)
        exit(1)
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    drawer(ctx, CGFloat(pixelSize))
    guard let cg = ctx.makeImage() else {
        FileHandle.standardError.write("makeImage failed\n".data(using: .utf8)!)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG encode failed\n".data(using: .utf8)!)
        exit(1)
    }
    return png
}

// ---------------------------------------------------------------------------
// Document icon synthesis (when doc-icon.png isn't provided)
// ---------------------------------------------------------------------------

func drawFoldedPage(in ctx: CGContext, size: CGFloat) -> CGRect {
    let pad = size * 0.06
    let pageRect = CGRect(x: pad, y: pad,
                          width: size - pad * 2,
                          height: size - pad * 2)
    let foldSize = size * 0.30

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

    // Page fill — soft white→light grey gradient
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = [
        CGColor(red: 0.99, green: 0.99, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1.0),
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: bg, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }
    ctx.restoreGState()

    // Outline
    ctx.saveGState()
    ctx.setLineWidth(max(1.0, size * 0.005))
    ctx.setStrokeColor(CGColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 1.0))
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()

    // Folded corner triangle
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

    return pageRect
}

func drawDerivedDocIcon(appImage: CGImage, in ctx: CGContext, size: CGFloat) {
    let pageRect = drawFoldedPage(in: ctx, size: size)
    // Inset the app icon onto the page, centered, ~62% of page width.
    let logoSide = pageRect.width * 0.62
    let logoRect = CGRect(
        x: pageRect.midX - logoSide / 2,
        y: pageRect.midY - logoSide / 2 + size * 0.04, // nudged up so KNIT label fits below
        width: logoSide,
        height: logoSide
    )
    ctx.draw(appImage, in: logoRect)

    // "KNIT" wordmark below the inset image.
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

// ---------------------------------------------------------------------------
// Iconset writers
// ---------------------------------------------------------------------------

struct IconSpec {
    let pixelSize: Int
    let filename: String
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

func writeIconset(name: String,
                  into outDir: URL,
                  drawer: (CGContext, CGFloat) -> Void) throws {
    let iconsetDir = outDir.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconsetDir)
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    for spec in specs {
        let png = renderToPNG(at: spec.pixelSize, drawer: drawer)
        let outURL = iconsetDir.appendingPathComponent(spec.filename)
        try png.write(to: outURL)
        print("  \(name)/\(spec.filename) (\(spec.pixelSize)px)")
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

guard let appImage = loadCGImage(appPNGURL) else {
    FileHandle.standardError.write("error: couldn't decode \(appPNGURL.path)\n".data(using: .utf8)!)
    exit(1)
}
print(">> app-icon source: \(appPNGURL.path) (\(appImage.width)x\(appImage.height))")

print(">> writing AppIcon.iconset (from app-icon.png)")
try writeIconset(name: "AppIcon", into: outDir) { ctx, size in
    ctx.draw(appImage, in: CGRect(x: 0, y: 0, width: size, height: size))
}

let docImage: CGImage? = loadCGImage(docPNGURL)
if let docImage = docImage {
    print(">> doc-icon source:  \(docPNGURL.path) (\(docImage.width)x\(docImage.height))")
    print(">> writing KnitDocument.iconset (from doc-icon.png)")
    try writeIconset(name: "KnitDocument", into: outDir) { ctx, size in
        ctx.draw(docImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
} else {
    print(">> doc-icon.png not found — deriving document icon from app-icon")
    print(">> writing KnitDocument.iconset (auto-derived)")
    try writeIconset(name: "KnitDocument", into: outDir) { ctx, size in
        drawDerivedDocIcon(appImage: appImage, in: ctx, size: size)
    }
}

print(">> done.")
