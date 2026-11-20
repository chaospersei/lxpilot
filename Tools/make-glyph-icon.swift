// Flat glyph in the spirit of SF Symbols: two nodes on either side of a wall, a link line through
// a gap in it. Variant A (no line) is the "disconnected" state. The app draws the same geometry
// itself (AppIcon.glyph in UI/MenuBarLabel.swift); keep the two in sync.
//
//   swift Tools/make-glyph-icon.swift <outDir>
//
// Writes Glyph-A.png / Glyph-B.png (1024, black on transparent, template-ready) and Glyph-sheet.png.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255, CGFloat(hex & 0xff) / 255, a,
    ])!
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func makeContext(_ w: CGFloat, _ h: CGFloat) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: h)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// Draws the glyph into a 1024 square with the given colour. Proportions are chosen for 18 pt:
/// nodes big enough to stay round, the wall wide enough to stay a bar, the gap wide enough to stay a gap.
func glyph(link: Bool, color: CGColor) -> CGImage {
    let ctx = makeContext(size, size)
    ctx.setFillColor(color)
    ctx.setStrokeColor(color)
    let nodeR: CGFloat = 140
    let left = P(188, 512), right = P(836, 512)
    let wallX: CGFloat = 436, wallW: CGFloat = 152
    let top: CGFloat = 130, bottom: CGFloat = 894

    if link {
        // Line first, so the wall blocks sit on top; the gap between them is where it passes.
        ctx.setLineWidth(72); ctx.setLineCap(.round)
        ctx.move(to: left); ctx.addLine(to: right); ctx.strokePath()
        let gap: CGFloat = 128
        for r in [CGRect(x: wallX, y: top, width: wallW, height: 512 - gap / 2 - top),
                  CGRect(x: wallX, y: 512 + gap / 2, width: wallW, height: bottom - 512 - gap / 2)] {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil)); ctx.fillPath()
        }
    } else {
        // Three blocks: a wall, not a pillar.
        let gap: CGFloat = 128   // the same gap as variant B, so "off" is B without the line
        let blockH = (bottom - top - gap) / 2
        for i in 0..<2 {
            let r = CGRect(x: wallX, y: top + CGFloat(i) * (blockH + gap), width: wallW, height: blockH)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 40, cornerHeight: 40, transform: nil)); ctx.fillPath()
        }
    }
    for c in [left, right] {
        ctx.addPath(CGPath(ellipseIn: CGRect(x: c.x - nodeR, y: c.y - nodeR, width: nodeR * 2, height: nodeR * 2), transform: nil))
        ctx.fillPath()
    }
    return ctx.makeImage()!
}

func write(_ cg: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let a = glyph(link: false, color: rgba(0x000000))
let b = glyph(link: true, color: rgba(0x000000))
write(a, to: outDir.appendingPathComponent("Glyph-A.png"))
write(b, to: outDir.appendingPathComponent("Glyph-B.png"))

// Sheet: both variants at 18 / 24 / 36 / 64 / 128 pt, black on light and white on dark, next to the SF shield for scale.
let sizes: [CGFloat] = [18, 24, 36, 64, 128]
let colW: CGFloat = 230, rowH: CGFloat = 170
let sheetW = colW * CGFloat(sizes.count) + 140, sheetH = rowH * 4 + 40
let sheet = makeContext(sheetW, sheetH)
let shield = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: nil)!
func stamp(_ image: CGImage, at origin: CGPoint, size s: CGFloat, in ctx: CGContext) {
    ctx.saveGState(); ctx.translateBy(x: 0, y: sheetH); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: origin.x, y: sheetH - origin.y - s, width: s, height: s))
    ctx.restoreGState()
}
for (row, (variant, dark)) in [(false, false), (false, true), (true, false), (true, true)].enumerated() {
    let y0 = 20 + CGFloat(row) * rowH
    sheet.setFillColor(dark ? rgba(0x1E1C26) : rgba(0xEEEDF3)); sheet.fill(CGRect(x: 20, y: y0, width: sheetW - 40, height: rowH - 10))
    let img = glyph(link: variant, color: dark ? rgba(0xFFFFFF) : rgba(0x000000))
    for (i, s) in sizes.enumerated() {
        let x = 40 + CGFloat(i) * colW
        stamp(img, at: P(x, y0 + (rowH - 10 - s) / 2), size: s, in: sheet)
        // SF shield at the same point size for comparison
        let config = NSImage.SymbolConfiguration(pointSize: s * 0.8, weight: .regular)
        if let sym = shield.withSymbolConfiguration(config), let cg = sym.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = CGFloat(cg.width) * s / CGFloat(cg.height), h = s
            sheet.saveGState(); sheet.translateBy(x: 0, y: sheetH); sheet.scaleBy(x: 1, y: -1)
            sheet.clip(to: CGRect(x: x + s + 24, y: sheetH - (y0 + (rowH - 10 - h) / 2) - h, width: w, height: h), mask: cg)
            sheet.setFillColor(dark ? rgba(0xFFFFFF) : rgba(0x000000)); sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
            sheet.restoreGState()
        }
    }
}
write(sheet.makeImage()!, to: outDir.appendingPathComponent("Glyph-sheet.png"))
print("written to \(outDir.path)")
