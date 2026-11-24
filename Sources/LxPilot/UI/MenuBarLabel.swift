import AppKit

/// The app icon as an image: from the bundle, or from the source tree when run as a bare
/// SwiftPM binary (`swift run`).
enum AppIcon {
    static let full: NSImage? = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
            return image
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcon.icns")
        return NSImage(contentsOf: source)
    }()

    static let traySize = NSSize(width: 18, height: 18)

    /// The app glyph, vector: two nodes on either side of a wall, a link line through its gap when
    /// `linked`. Same geometry as Tools/make-glyph-icon.swift (1024 design units), drawn into `rect`
    /// with a flipped (top-left origin) context.
    static func drawGlyph(in rect: CGRect, linked: Bool, color: CGColor, ctx: CGContext) {
        let k = rect.width / 1024
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: rect.minX + x * k, y: rect.minY + y * k, width: w * k, height: h * k),
                   cornerWidth: 40 * k, cornerHeight: 40 * k, transform: nil)
        }
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        if linked {
            ctx.setLineWidth(72 * k)
            ctx.setLineCap(.round)
            ctx.move(to: pt(188, 512)); ctx.addLine(to: pt(836, 512)); ctx.strokePath()
        }
        ctx.addPath(rr(436, 130, 152, 318)); ctx.fillPath()
        ctx.addPath(rr(436, 576, 152, 318)); ctx.fillPath()
        for x in [188.0, 836.0] as [CGFloat] {
            ctx.addPath(CGPath(ellipseIn: CGRect(x: rect.minX + (x - 140) * k, y: rect.minY + 372 * k, width: 280 * k, height: 280 * k), transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Template image of the glyph: takes the menu bar or accent colour. With `color` it is a plain
    /// image in that colour instead: the status bar ignores `contentTintColor` on a template image,
    /// so the red blink phase has to carry its colour itself.
    static func glyph(linked: Bool, size: CGFloat, color: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(in: rect, linked: linked, color: (color ?? .black).cgColor, ctx: ctx)
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}

/// Draws the menu bar item: the app glyph (link line while connected), two lines of speed (upload
/// on top, download below) and, optionally, two rows of mini bar graphs with the recent history.
///
/// MenuBarExtra shows only the first Image of a composite label, so everything is one NSImage.
/// It cannot be a template (that would flatten the icon to one colour), so text and bars use
/// `labelColor` inside the drawing handler: the handler runs with the menu bar's appearance
/// current, which makes them dark on a light menu bar and light on a dark one.
enum MenuBarRenderer {
    private static let height: CGFloat = 22
    private static let iconGap: CGFloat = 3
    /// Fits the widest value `compactSpeed` produces ("88.8 MB/s" ≈ 47 pt at 9 pt semibold).
    private static let textWidth: CGFloat = 48
    private static let rowHeight: CGFloat = 8
    /// 7 bars × (3 + 1) pt = 27 pt wide; was 12 bars / 47 pt, cut ~1.7× to leave room for the icon.
    private static let barCount = 7
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 1
    /// Scale floor: below this the bars stay low instead of idle noise filling the graph.
    private static let scaleFloor: Double = 64 * 1024

    private static var cacheKey = ""
    private static var cacheImage: NSImage?

    /// The same picture is handed back while nothing visible changed: AppKit re-snapshots the status
    /// item for every new image, which is the bulk of an idle app's CPU.
    /// `alarm` paints the glyph red: one phase of the menu bar blink while the connection is faulted.
    static func image(up: Double, down: Double, history: [SpeedSample], showGraph: Bool, linked: Bool, alarm: Bool = false) -> NSImage {
        let graphWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
        let textX = AppIcon.traySize.width + iconGap
        let width = textX + textWidth + (showGraph ? 5 + graphWidth : 0)
        let recent = Array(history.suffix(barCount))
        let ups = showGraph ? barHeights(recent.map { $0.up }) : []
        let downs = showGraph ? barHeights(recent.map { $0.down }) : []
        let upText = compactSpeed(up)
        let downText = compactSpeed(down)
        let key = "\(upText)|\(downText)|\(showGraph)|\(linked)|\(alarm)|\(ups)|\(downs)"
        if key == cacheKey, let cached = cacheImage { return cached }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let icon = AppIcon.traySize
            if let cg = NSGraphicsContext.current?.cgContext {
                // Same appearance-aware colour as the text: the handler runs with the menu bar's appearance.
                cg.saveGState()
                cg.translateBy(x: 0, y: height)   // the glyph is designed top-down; this handler is bottom-up
                cg.scaleBy(x: 1, y: -1)
                AppIcon.drawGlyph(in: CGRect(x: 0, y: (height - icon.height) / 2, width: icon.width, height: icon.height),
                                  linked: linked, color: (alarm ? NSColor.systemRed : NSColor.labelColor).cgColor, ctx: cg)
                cg.restoreGState()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            (upText as NSString).draw(in: NSRect(x: textX, y: 10.5, width: textWidth, height: 11), withAttributes: attributes)
            (downText as NSString).draw(in: NSRect(x: textX, y: 0.5, width: textWidth, height: 11), withAttributes: attributes)

            if showGraph {
                let originX = textX + textWidth + 5
                drawBars(ups, originX: originX, y: 12)
                drawBars(downs, originX: originX, y: 2)
            }
            return true
        }
        image.isTemplate = false
        cacheKey = key
        cacheImage = image
        return image
    }

    /// Bar heights in points, right-aligned: the newest sample is always the last bar, even with a
    /// short history; 0 = empty slot.
    private static func barHeights(_ values: [Double]) -> [Int] {
        let peak = max(values.max() ?? 0, scaleFloor)
        let offset = barCount - values.count
        return (0..<barCount).map { slot in
            let index = slot - offset
            guard index >= 0, values[index] > 0 else { return 0 }
            return max(1, Int((CGFloat(values[index] / peak) * rowHeight).rounded()))
        }
    }

    private static func drawBars(_ heights: [Int], originX: CGFloat, y: CGFloat) {
        for (slot, filled) in heights.enumerated() {
            let x = originX + CGFloat(slot) * (barWidth + barGap)
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: rowHeight)).fill()
            guard filled > 0 else { continue }
            NSColor.labelColor.setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: min(CGFloat(filled), rowHeight))).fill()
        }
    }

    /// Short fixed-width form for the menu bar: "0 KB/s", "7.3 KB/s", "742 KB/s", "9.8 MB/s", "125 MB/s".
    /// Tenths only below 10; idle traffic is reported in KB/s rather than bytes to keep the column calm.
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let kb = max(bytesPerSecond, 0) / 1024
        if kb == 0 { return "0 KB/s" }
        if kb < 1000 { return (kb < 10 ? String(format: "%.1f", kb) : String(format: "%.0f", kb)) + " KB/s" }
        let mb = kb / 1024
        if mb < 1000 { return (mb < 10 ? String(format: "%.1f", mb) : String(format: "%.0f", mb)) + " MB/s" }
        let gb = mb / 1024
        return (gb < 10 ? String(format: "%.1f", gb) : String(format: "%.0f", gb)) + " GB/s"
    }
}
