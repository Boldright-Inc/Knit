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

/// macOS-style document page: pure white, subtle drop shadow, small folded
/// corner in the top-right. Modeled after Apple's stock .zip / .pages icons.
func drawFoldedPage(in ctx: CGContext, size: CGFloat) -> CGRect {
    // Slim portrait-ish rectangle — wider top/bottom padding than left/right
    // so the page feels like a sheet of paper, not a square sticker.
    let padX = size * 0.13
    let padY = size * 0.06
    let pageRect = CGRect(x: padX, y: padY,
                          width: size - padX * 2,
                          height: size - padY * 2)
    let foldSize = size * 0.16    // refined fold — Apple uses ~15%

    let pathFull = CGMutablePath()
    let pTL = CGPoint(x: pageRect.minX, y: pageRect.maxY)
    let pTRcut = CGPoint(x: pageRect.maxX - foldSize, y: pageRect.maxY)
    let pCorner = CGPoint(x: pageRect.maxX, y: pageRect.maxY - foldSize)
    let pBR = CGPoint(x: pageRect.maxX, y: pageRect.minY)
    let pBL = CGPoint(x: pageRect.minX, y: pageRect.minY)
    pathFull.move(to: pTL)
    pathFull.addLine(to: pTRcut)
    pathFull.addLine(to: pCorner)
    pathFull.addLine(to: pBR)
    pathFull.addLine(to: pBL)
    pathFull.closeSubpath()

    // Drop shadow under the page so it lifts off dark backgrounds in Finder.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.025,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.addPath(pathFull)
    ctx.fillPath()
    ctx.restoreGState()

    // Re-paint the page surface with a barely-there top-light gradient so it
    // doesn't look completely flat at large sizes.
    ctx.saveGState()
    ctx.addPath(pathFull)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let surface = [
        CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),  // top
        CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1.0),  // bottom
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: surface, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: pageRect.maxY),
                               end: CGPoint(x: 0, y: pageRect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Page outline (very subtle).
    ctx.saveGState()
    ctx.setLineWidth(max(1.0, size * 0.0035))
    ctx.setStrokeColor(CGColor(red: 0.78, green: 0.81, blue: 0.86, alpha: 1.0))
    ctx.addPath(pathFull)
    ctx.strokePath()
    ctx.restoreGState()

    // Folded corner triangle with its own slight shadow + matte fill.
    let foldPath = CGMutablePath()
    foldPath.move(to: pTRcut)
    foldPath.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY))
    foldPath.addLine(to: pCorner)
    foldPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -size * 0.004, height: -size * 0.004),
                  blur: size * 0.008,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.setFillColor(CGColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0))
    ctx.addPath(foldPath)
    ctx.fillPath()
    ctx.restoreGState()
    // Re-stroke the diagonal edge for crispness
    ctx.saveGState()
    ctx.setLineWidth(max(1.0, size * 0.0035))
    ctx.setStrokeColor(CGColor(red: 0.78, green: 0.81, blue: 0.86, alpha: 1.0))
    ctx.move(to: pTRcut)
    ctx.addLine(to: pCorner)
    ctx.strokePath()
    ctx.restoreGState()

    return pageRect
}

func drawDerivedDocIcon(appImage: CGImage, in ctx: CGContext, size: CGFloat) {
    let pageRect = drawFoldedPage(in: ctx, size: size)

    // Knit logo, centered in the upper portion of the page so the wordmark
    // has room below — proportions match Apple's .zip icon where the central
    // graphic dominates the page.
    let logoSide = pageRect.width * 0.78
    let logoRect = CGRect(
        x: pageRect.midX - logoSide / 2,
        y: pageRect.minY + pageRect.height * 0.22,
        width: logoSide,
        height: logoSide
    )

    // Soft drop shadow under the logo for depth.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                  blur: size * 0.015,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.draw(appImage, in: logoRect)
    ctx.restoreGState()

    // "KNIT" wordmark — clean dark gray, modest tracking, low on the page.
    let label = "KNIT"
    let fontSize = size * 0.095
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.27, green: 0.31, blue: 0.40, alpha: 1.0),
        .kern: fontSize * 0.18,
    ]
    let attr = NSAttributedString(string: label, attributes: attrs)
    let strSize = attr.size()
    let labelX = (size - strSize.width) / 2
    let labelY = pageRect.minY + pageRect.height * 0.08
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

// Surface what we actually loaded — most of the "background looks gray
// in the Dock" reports turn out to be a transparent-background source
// PNG that visually appeared white in Preview because Preview composites
// alpha against its own light-mode chrome. Print the alpha presence so
// the user can sanity-check.
let alphaInfo = appImage.alphaInfo
let hasAlpha = (alphaInfo == .first || alphaInfo == .last
              || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast)
print(">> app-icon source: \(appPNGURL.path) (\(appImage.width)x\(appImage.height), alpha=\(hasAlpha ? "yes" : "no"))")
if hasAlpha {
    print("   note: source has alpha — AppIcon canvas will be pre-filled opaque white")
    print("         so transparent regions composite against pure white, not the Dock blur.")
}

print(">> writing AppIcon.iconset (from app-icon.png)")
try writeIconset(name: "AppIcon", into: outDir) { ctx, size in
    // Pre-fill opaque white before drawing the PNG. Without this, any
    // transparent pixels in the source (most user-supplied logo PNGs
    // have transparent backgrounds) stay alpha=0 in the rendered
    // iconset, and macOS's Dock blur shows through as a soft gray
    // gradient halo. Filling white forces those pixels to composite
    // against pure white instead — matching the "background should
    // be pure white" intent and the way Preview.app already shows
    // the source PNG.
    ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
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
