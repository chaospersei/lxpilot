// Concept icon: two nodes on opposite sides of a stone wall, joined by a cable that runs through a
// hole in it.
//
//   swift Tools/make-link-icon.swift <outDir>
//
// Writes <outDir>/Link.png (1024) and <outDir>/Link-sheet.png (256 / 128 / 64 / 32 side by side).

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

/// A vertical wall through the middle: one column of big blocks, offset every other course.
let wallX: CGFloat = 436, wallW: CGFloat = 152
let blockH: CGFloat = 136, mortar: CGFloat = 16
var blocks: [CGRect] = []
var course = 0
var y = tileRect.minY - 60
while y < tileRect.maxY + 60 {
    let split = course % 2 == 0   // a course of two half blocks reads as masonry, not a pillar
    if split {
        blocks.append(CGRect(x: wallX + mortar / 2, y: y + mortar / 2, width: wallW / 2 - mortar, height: blockH - mortar))
        blocks.append(CGRect(x: wallX + wallW / 2 + mortar / 2, y: y + mortar / 2, width: wallW / 2 - mortar, height: blockH - mortar))
    } else {
        blocks.append(CGRect(x: wallX + mortar / 2, y: y + mortar / 2, width: wallW - mortar, height: blockH - mortar))
    }
    y += blockH
    course += 1
}
func blockPath(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil) }

let left = P(262, 640), right = P(762, 384)
let hole = P(512, 512), holeR: CGFloat = 64
let cable: CGPath = {
    let p = CGMutablePath()
    p.move(to: left)
    p.addCurve(to: hole, control1: P(400, 640), control2: P(430, 512))
    p.addCurve(to: right, control1: P(594, 512), control2: P(624, 384))
    return p
}()

// MARK: - Render

let ctx = makeContext()

ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgba(0x000000, 0.45))
ctx.addPath(tile); ctx.setFillColor(rgba(0x2A2736)); ctx.fillPath(); ctx.restoreGState()
fillLinear(ctx, tile, [(rgba(0x3A3647), 0), (rgba(0x1C1A24), 1)], from: P(0, tileRect.minY), to: P(0, tileRect.maxY))

// Wall with a hole where the cable goes through.
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
let holePath = CGPath(ellipseIn: CGRect(x: hole.x - holeR, y: hole.y - holeR, width: holeR * 2, height: holeR * 2), transform: nil)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgba(0x000000, 0.5))
ctx.setFillColor(rgba(0x3F3B49)); ctx.fill(CGRect(x: wallX, y: tileRect.minY - 60, width: wallW, height: tileRect.height + 120)); ctx.restoreGState()
for r in blocks {
    let p = blockPath(r)
    fillLinear(ctx, p, [(rgba(0x6B6577), 0), (rgba(0x4A4556), 1)], from: P(r.minX, r.minY), to: P(r.maxX, r.maxY))
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.12)); ctx.setLineWidth(8)
    ctx.move(to: P(r.minX, r.maxY)); ctx.addLine(to: P(r.minX, r.minY)); ctx.addLine(to: P(r.maxX, r.minY)); ctx.strokePath()
    ctx.setStrokeColor(rgba(0x000000, 0.28))
    ctx.move(to: P(r.minX, r.maxY)); ctx.addLine(to: P(r.maxX, r.maxY)); ctx.addLine(to: P(r.maxX, r.minY)); ctx.strokePath()
    ctx.restoreGState()
}
// The hole: dark inside, chipped rim.
ctx.saveGState(); ctx.addPath(holePath); ctx.clip()
fillRadial(ctx, nil, [(rgba(0x0B0A12), 0), (rgba(0x17151F), 0.7), (rgba(0x2A2736), 1)], center: hole, radius: holeR)
ctx.restoreGState()
ctx.addPath(holePath); ctx.setStrokeColor(rgba(0x8B8498, 0.8)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()

// Cable: glow, dark sheath, bright core; the part inside the hole is drawn after the wall so it reads as passing through.
let cableGlow = layer(blur: 26) { l in
    l.addPath(tile); l.clip()
    l.addPath(cable); l.setStrokeColor(rgba(0x7C6CFF, 0.8)); l.setLineWidth(70); l.setLineCap(.round); l.strokePath()
}
ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(cableGlow, in: ctx); ctx.restoreGState()
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.addPath(cable); ctx.setStrokeColor(rgba(0x2A2440)); ctx.setLineWidth(46); ctx.strokePath()
ctx.saveGState(); ctx.addPath(cable.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10)); ctx.clip()
ctx.drawLinearGradient(gradient([(rgba(0x8F7CFF), 0), (rgba(0x6E5FE8), 0.5), (rgba(0x5CC8FF), 1)]), start: left, end: right, options: [])
ctx.restoreGState()
ctx.addPath(cable); ctx.setStrokeColor(rgba(0xFFFFFF, 0.55)); ctx.setLineWidth(8); ctx.strokePath()
ctx.restoreGState()

// Nodes: glass spheres with a halo.
for (c, tint) in [(left, 0x8F7CFF), (right, 0x5CC8FF)] as [(CGPoint, UInt32)] {
    let halo = layer(blur: 44) { l in
        l.addPath(tile); l.clip()
        fillRadial(l, nil, [(rgba(tint, 0.9), 0), (rgba(tint, 0.25), 0.5), (rgba(tint, 0), 1)], center: c, radius: 190)
    }
    ctx.saveGState(); ctx.addPath(tile); ctx.clip(); draw(halo, in: ctx); ctx.restoreGState()
    let r: CGFloat = 84
    let sphere = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgba(0x000000, 0.45))
    ctx.addPath(sphere); ctx.setFillColor(rgba(tint)); ctx.fillPath(); ctx.restoreGState()
    fillRadial(ctx, sphere, [(rgba(0xFFFFFF, 0.95), 0), (rgba(tint, 0.9), 0.55), (rgba(0x2A2440, 0.9), 1)], center: P(c.x - 28, c.y - 30), radius: r * 1.35)
    ctx.addPath(sphere); ctx.setStrokeColor(rgba(0xFFFFFF, 0.35)); ctx.setLineWidth(4); ctx.strokePath()
}

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
write(image, to: outDir.appendingPathComponent("Link.png"))

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
write(sheet.makeImage()!, to: outDir.appendingPathComponent("Link-sheet.png"))
print("written to \(outDir.path)")
