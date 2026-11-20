// Concept icon: X-rays from a source on the left pass through a stone wall; inside the beam the
// wall turns into a glowing radiograph of itself.
//
//   swift Tools/make-xray-icon.swift <outDir>
//
// Writes <outDir>/XRay.png (1024) and <outDir>/XRay-sheet.png (256 / 128 / 64 / 32 side by side).

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
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

func makeContext(_ side: CGFloat = size) -> CGContext {
    let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: side)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func layer(blur radius: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext()
    draw(ctx)
    let image = ctx.makeImage()!
    guard radius > 0 else { return image }
    let filter = CIFilter.gaussianBlur()
    filter.inputImage = CIImage(cgImage: image).clampedToExtent()
    filter.radius = Float(radius)
    let out = filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return CIContext().createCGImage(out, from: out.extent)!
}

func draw(_ image: CGImage, in ctx: CGContext, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAlpha(alpha)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}
func fillLinear(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGColor, CGFloat)], from: CGPoint, to: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(gradient(stops), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func fillRadial(_ ctx: CGContext, _ path: CGPath?, _ stops: [(CGColor, CGFloat)], center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    if let path { ctx.addPath(path); ctx.clip() }
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

// MARK: - Geometry

let inset: CGFloat = 100
let tileRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = CGPath(roundedRect: tileRect, cornerWidth: 186, cornerHeight: 186, transform: nil)

/// Bricks in running bond covering the tile; mortar is the gap between them.
let brickH: CGFloat = 104, brickW: CGFloat = 176, mortar: CGFloat = 14
var bricks: [CGRect] = []
var row = 0
var y = tileRect.minY - 40
while y < tileRect.maxY + 40 {
    let offset = row % 2 == 0 ? 0 : brickW / 2
    var x = tileRect.minX - brickW + offset
    while x < tileRect.maxX + brickW {
        bricks.append(CGRect(x: x + mortar / 2, y: y + mortar / 2, width: brickW - mortar, height: brickH - mortar))
        x += brickW
    }
    y += brickH
    row += 1
}
func brickPath(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil) }

/// The beam: apex at the source, fanning out to the right edge of the tile.
let source = P(196, 512)
let cone: CGPath = {
    let p = CGMutablePath()
    p.move(to: source)
    p.addLine(to: P(size, 250))
    p.addLine(to: P(size, 774))
    p.closeSubpath()
    return p
}()

// MARK: - Render

let ctx = makeContext()

// Tile: deep grey-violet with a faint vignette.
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgba(0x000000, 0.45))
ctx.addPath(tile); ctx.setFillColor(rgba(0x2A2736)); ctx.fillPath(); ctx.restoreGState()
fillLinear(ctx, tile, [(rgba(0x34303F), 0), (rgba(0x1C1A24), 1)], from: P(0, tileRect.minY), to: P(0, tileRect.maxY))

// Solid stone outside the beam.
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
for r in bricks {
    let p = brickPath(r)
    fillLinear(ctx, p, [(rgba(0x56515F), 0), (rgba(0x3F3B49), 1)], from: P(r.minX, r.minY), to: P(r.maxX, r.maxY))
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.10)); ctx.setLineWidth(6)
    ctx.move(to: P(r.minX, r.maxY)); ctx.addLine(to: P(r.minX, r.minY)); ctx.addLine(to: P(r.maxX, r.minY)); ctx.strokePath()
    ctx.setStrokeColor(rgba(0x000000, 0.25))
    ctx.move(to: P(r.minX, r.maxY)); ctx.addLine(to: P(r.maxX, r.maxY)); ctx.addLine(to: P(r.maxX, r.minY)); ctx.strokePath()
    ctx.restoreGState()
}
ctx.restoreGState()

// Inside the beam the wall becomes a radiograph: dark translucent body, bricks as glowing outlines.
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); ctx.addPath(cone); ctx.clip()
fillLinear(ctx, cone, [(rgba(0x0A0F2A, 0.96), 0), (rgba(0x0E1838, 0.90), 1)], from: source, to: P(size, 512))
for r in bricks {
    let p = brickPath(r)
    fillLinear(ctx, p, [(rgba(0x7FA6FF, 0.10), 0), (rgba(0x7FA6FF, 0.03), 1)], from: P(r.minX, r.minY), to: P(r.maxX, r.maxY))
}
ctx.restoreGState()

let outlines = layer(blur: 10) { l in
    l.addPath(tile); l.clip(); l.addPath(cone); l.clip()
    l.setStrokeColor(rgba(0xBFD7FF, 0.9)); l.setLineWidth(8)
    for r in bricks { l.addPath(brickPath(r)) }
    l.strokePath()
}
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(outlines, in: ctx, alpha: 0.9); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); ctx.addPath(cone); ctx.clip()
ctx.setStrokeColor(rgba(0xEAF2FF, 0.95)); ctx.setLineWidth(3.5)
for r in bricks { ctx.addPath(brickPath(r)) }
ctx.strokePath()
ctx.restoreGState()

// Beam body: a soft wedge of light fading towards the right.
let wedge = layer(blur: 30) { l in
    l.addPath(tile); l.clip()
    fillLinear(l, cone, [(rgba(0xCFE4FF, 0.55), 0), (rgba(0x8FB4FF, 0.12), 0.55), (rgba(0x8FB4FF, 0.0), 1)], from: source, to: P(size, 512))
}
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(wedge, in: ctx); ctx.restoreGState()

// Rays: crisp lines with a glow underneath.
let rayEnds: [CGPoint] = (0..<7).map { i in P(size, 290 + CGFloat(i) * 74) }
let rayGlow = layer(blur: 14) { l in
    l.addPath(tile); l.clip()
    l.setStrokeColor(rgba(0xDCEBFF, 0.8)); l.setLineWidth(10); l.setLineCap(.round)
    for e in rayEnds { l.move(to: source); l.addLine(to: e) }
    l.strokePath()
}
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(rayGlow, in: ctx); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
for (i, e) in rayEnds.enumerated() {
    ctx.setStrokeColor(rgba(0xFFFFFF, i == 3 ? 0.95 : 0.7)); ctx.setLineWidth(i == 3 ? 4 : 2.5); ctx.setLineCap(.round)
    ctx.move(to: source); ctx.addLine(to: e); ctx.strokePath()
}
ctx.restoreGState()

// The source: a small white-hot sphere with a wide halo.
let halo = layer(blur: 50) { l in
    l.addPath(tile); l.clip()
    fillRadial(l, nil, [(rgba(0xDCEBFF, 0.95), 0), (rgba(0x8FB4FF, 0.35), 0.5), (rgba(0x8FB4FF, 0), 1)], center: source, radius: 220)
}
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(halo, in: ctx); ctx.restoreGState()
fillRadial(ctx, CGPath(ellipseIn: CGRect(x: source.x - 46, y: source.y - 46, width: 92, height: 92), transform: nil),
           [(rgba(0xFFFFFF), 0), (rgba(0xEAF2FF), 0.45), (rgba(0x9FC0FF, 0.9), 1)], center: P(source.x - 10, source.y - 10), radius: 56)

// Glass highlight across the top of the tile.
fillLinear(ctx, tile, [(rgba(0xFFFFFF, 0.16), 0), (rgba(0xFFFFFF, 0.0), 1)], from: P(0, tileRect.minY), to: P(0, tileRect.minY + 300))
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); ctx.addPath(tile)
ctx.setStrokeColor(rgba(0xFFFFFF, 0.22)); ctx.setLineWidth(6); ctx.strokePath(); ctx.restoreGState()

// MARK: - Output

let image = ctx.makeImage()!
func write(_ cg: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
write(image, to: outDir.appendingPathComponent("XRay.png"))

// Contact sheet: how it reads at menu bar and rail sizes.
let sizes: [CGFloat] = [256, 128, 64, 32]
let sheetW = sizes.reduce(0, +) + CGFloat(sizes.count + 1) * 40
let sheet = CGContext(data: nil, width: Int(sheetW), height: 336, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(rgba(0xE9E7EF)); sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: 336))
sheet.setFillColor(rgba(0x1E1C26)); sheet.fill(CGRect(x: 0, y: 0, width: sheetW / 2, height: 336))
var cursor: CGFloat = 40
sheet.interpolationQuality = .high
for s in sizes {
    sheet.draw(image, in: CGRect(x: cursor, y: (336 - s) / 2, width: s, height: s))
    cursor += s + 40
}
write(sheet.makeImage()!, to: outDir.appendingPathComponent("XRay-sheet.png"))
print("written to \(outDir.path)")
