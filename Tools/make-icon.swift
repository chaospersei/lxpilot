// Renders the app icon: a bright glass rocket in grey-violet, pointing straight up, on a
// transparent canvas — in the spirit of Shadowrocket with the "liquid glass" look of recent macOS.
//
//   swift Tools/make-icon.swift [Resources]
//
// Writes <dir>/AppIcon.png (1024 px preview) and <dir>/AppIcon.icns. No dependencies beyond macOS.

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

/// Top-left origin, y grows downwards — easier to reason about than Quartz's default.
func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

/// Draws into a separate layer, blurs it and returns the image (same orientation as makeContext()).
func layer(blur radius: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = makeContext()
    draw(ctx)
    let image = ctx.makeImage()!
    guard radius > 0 else { return image }
    let input = CIImage(cgImage: image)
    let filter = CIFilter.gaussianBlur()
    filter.inputImage = input.clampedToExtent()
    filter.radius = Float(radius)
    let output = filter.outputImage!.cropped(to: input.extent)
    return CIContext(options: [.workingColorSpace: space, .outputColorSpace: space]).createCGImage(output, from: output.extent)!
}

func draw(_ image: CGImage, in ctx: CGContext, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.0 } as CFArray, locations: stops.map { $0.1 })!
}

func fillLinear(_ ctx: CGContext, _ path: CGPath, _ stops: [(CGColor, CGFloat)], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(gradient(stops), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func fillRadial(_ ctx: CGContext, _ path: CGPath?, _ stops: [(CGColor, CGFloat)], center: CGPoint, radius: CGFloat) {
    ctx.saveGState()
    if let path { ctx.addPath(path); ctx.clip() }
    ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
}

func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil)
}

// MARK: - Geometry

// The rocket is modelled pointing up (negative y) around (0, 0); the flame reaches y ≈ 470.
let rocketCenter = P(512, 440)
let rocketScale: CGFloat = 1.12
func rocketSpace(_ ctx: CGContext) {
    ctx.translateBy(x: rocketCenter.x, y: rocketCenter.y)
    ctx.scaleBy(x: rocketScale, y: rocketScale)
}

let body: CGPath = {
    let p = CGMutablePath()
    p.move(to: P(0, -262))
    p.addCurve(to: P(92, -40), control1: P(58, -236), control2: P(92, -140))
    p.addLine(to: P(92, 150))
    p.addQuadCurve(to: P(72, 188), control: P(92, 184))
    p.addLine(to: P(-72, 188))
    p.addQuadCurve(to: P(-92, 150), control: P(-92, 184))
    p.addLine(to: P(-92, -40))
    p.addCurve(to: P(0, -262), control1: P(-92, -140), control2: P(-58, -236))
    p.closeSubpath()
    return p
}()

func fin(mirror: Bool) -> CGPath {
    let s: CGFloat = mirror ? -1 : 1
    let p = CGMutablePath()
    p.move(to: P(s * 88, 30))
    p.addCurve(to: P(s * 182, 212), control1: P(s * 120, 90), control2: P(s * 170, 160))
    p.addQuadCurve(to: P(s * 150, 238), control: P(s * 178, 236))
    p.addLine(to: P(s * 88, 188))
    p.closeSubpath()
    return p
}

let nozzle: CGPath = {
    let p = CGMutablePath()
    p.move(to: P(-50, 186))
    p.addLine(to: P(50, 186))
    p.addLine(to: P(58, 232))
    p.addQuadCurve(to: P(-58, 232), control: P(0, 244))
    p.closeSubpath()
    return p
}()

let flame: CGPath = {
    let p = CGMutablePath()
    p.move(to: P(-50, 226))
    p.addCurve(to: P(0, 470), control1: P(-66, 330), control2: P(-26, 410))
    p.addCurve(to: P(50, 226), control1: P(26, 410), control2: P(66, 330))
    p.closeSubpath()
    return p
}()

let window = ellipse(0, -58, 46, 46)

// MARK: - Glass

/// Translucent glass: shadow, gradient fill, soft rim light, dark inner edge on the far side, specular spot.
func glass(_ ctx: CGContext, _ path: CGPath, tint: CGColor, lightFrom: CGPoint, lightTo: CGPoint, rim: CGFloat = 5, opacity: CGFloat = 1) {
    ctx.saveGState()
    ctx.setAlpha(opacity)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgba(0x120F1C, 0.45))
    ctx.addPath(path)
    ctx.setFillColor(tint)
    ctx.fillPath()
    ctx.restoreGState()

    fillLinear(ctx, path, [
        (rgba(0xFFFFFF, 0.42), 0), (rgba(0xFFFFFF, 0.14), 0.45), (rgba(0xFFFFFF, 0.0), 1),
    ], from: lightFrom, to: lightTo)

    // Far-side darkening (refraction): the path shifted towards the light, drawn as a wide stroke, clipped inside.
    let dark = layer(blur: 10) { l in
        rocketSpace(l)
        l.addPath(path); l.clip()
        l.translateBy(x: -8, y: -10)
        l.addPath(path)
        l.setStrokeColor(rgba(0x3B2F6B, 0.55))
        l.setLineWidth(26)
        l.strokePath()
    }
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); draw(dark, in: ctx); ctx.restoreGState()

    // Rim light: sharp inner stroke plus a soft glow along the near side.
    let rimGlow = layer(blur: 7) { l in
        rocketSpace(l)
        l.addPath(path); l.clip()
        l.translateBy(x: 5, y: 6)
        l.addPath(path)
        l.setStrokeColor(rgba(0xFFFFFF, 0.45))
        l.setLineWidth(18)
        l.strokePath()
    }
    ctx.saveGState(); ctx.addPath(path); ctx.clip(); draw(rimGlow, in: ctx); ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(path)
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.9))
    ctx.setLineWidth(rim)
    ctx.strokePath()
    ctx.restoreGState()

    // Thin violet contour outside the rim: keeps the shape legible on a light Dock or menu bar.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgba(0x33237A, 0.7))
    ctx.setLineWidth(2.4)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Render

let ctx = makeContext()

// Flame glow behind everything else.
let glow = layer(blur: 46) { l in
    rocketSpace(l)
    l.addPath(ellipse(0, 340, 120, 180)); l.setFillColor(rgba(0x9B78FF, 0.95)); l.fillPath()
}
draw(glow, in: ctx)

ctx.saveGState()
rocketSpace(ctx)

// Flame: hot white core fading to violet.
fillLinear(ctx, flame, [
    (rgba(0xFFFFFF, 1.0), 0), (rgba(0xD9C8FF, 1.0), 0.25), (rgba(0x8F67FF, 0.9), 0.65), (rgba(0x6E45F0, 0.0), 1),
], from: P(0, 226), to: P(0, 470))
let core = CGMutablePath()
core.move(to: P(-24, 230)); core.addCurve(to: P(0, 390), control1: P(-30, 300), control2: P(-10, 360))
core.addCurve(to: P(24, 230), control1: P(10, 360), control2: P(30, 300)); core.closeSubpath()
fillLinear(ctx, core, [(rgba(0xFFFFFF, 1), 0), (rgba(0xFFFFFF, 0), 1)], from: P(0, 230), to: P(0, 390))

// Fins, nozzle, body, nose, window. Light comes from the upper left.
let lightA = P(-120, -200), lightB = P(140, 220)
glass(ctx, fin(mirror: false), tint: rgba(0x6A4FDC, 0.98), lightFrom: lightA, lightTo: lightB, rim: 4)
glass(ctx, fin(mirror: true), tint: rgba(0x6A4FDC, 0.98), lightFrom: lightA, lightTo: lightB, rim: 4)
glass(ctx, nozzle, tint: rgba(0x4C3AA8, 0.98), lightFrom: lightA, lightTo: lightB, rim: 4)
glass(ctx, body, tint: rgba(0x8B6CF5, 0.97), lightFrom: lightA, lightTo: lightB)

// Refraction band: a soft diagonal streak of light crossing the body.
let band = layer(blur: 14) { l in
    rocketSpace(l)
    l.addPath(body); l.clip()
    let s = CGMutablePath()
    s.move(to: P(-92, 60)); s.addLine(to: P(92, -60)); s.addLine(to: P(92, 10)); s.addLine(to: P(-92, 130)); s.closeSubpath()
    l.addPath(s); l.setFillColor(rgba(0xFFFFFF, 0.22)); l.fillPath()
}
draw(band, in: ctx)

// Nose cap: a deeper violet band of glass.
let nose = CGMutablePath()
nose.addRect(CGRect(x: -120, y: -300, width: 240, height: 130))
ctx.saveGState()
ctx.addPath(body); ctx.clip()
fillLinear(ctx, nose, [(rgba(0x5B33F2, 1.0), 0), (rgba(0x8D6CFF, 0.55), 1)], from: P(0, -262), to: P(0, -170))
ctx.restoreGState()

// Window: dark glass with a bright arc.
glass(ctx, window, tint: rgba(0x241A52, 0.97), lightFrom: P(-40, -100), lightTo: P(40, -16), rim: 4)
fillRadial(ctx, window, [(rgba(0xA68EFF, 0.65), 0), (rgba(0xA68EFF, 0), 1)], center: P(12, -44), radius: 40)

// Specular highlight along the body's near edge.
let spec = layer(blur: 9) { l in
    rocketSpace(l)
    l.addPath(body); l.clip()
    l.addPath(ellipse(-62, -40, 16, 150)); l.setFillColor(rgba(0xFFFFFF, 0.85)); l.fillPath()
    l.addPath(ellipse(-20, -215, 26, 10)); l.setFillColor(rgba(0xFFFFFF, 0.7)); l.fillPath()
}
ctx.restoreGState()
draw(spec, in: ctx)

// MARK: - Output

let master = ctx.makeImage()!

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

func scaled(_ image: CGImage, to px: Int) -> CGImage {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return c.makeImage()!
}

let fm = FileManager.default
try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
write(master, to: outDir.appendingPathComponent("AppIcon.png"))

let iconset = fm.temporaryDirectory.appendingPathComponent("LxPilot-AppIcon.iconset", isDirectory: true)
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    write(scaled(master, to: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    write(scaled(master, to: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? fm.removeItem(at: iconset)
print("written: \(outDir.path)/AppIcon.png, AppIcon.icns")
