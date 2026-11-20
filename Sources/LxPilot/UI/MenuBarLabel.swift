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

    /// The tile on the 1024 canvas without the margin of the macOS icon grid (unit coordinates).
    /// Keep in sync with `inset` in Tools/make-icon.swift.
    private static let rocketBounds = CGRect(x: 80.0 / 1024, y: 80.0 / 1024, width: 864.0 / 1024, height: 864.0 / 1024)
    static let traySize = NSSize(width: 18, height: 18)

    /// Menu bar version: the tile, 18 pt. Not a template, so it keeps its colours next to the
    /// tinted speed text.
    static let tray: NSImage = {
        guard let full else {
            return NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) ?? NSImage(size: traySize)
        }
        let crop = NSRect(x: rocketBounds.minX * full.size.width, y: rocketBounds.minY * full.size.height,
                          width: rocketBounds.width * full.size.width, height: rocketBounds.height * full.size.height)
        return NSImage(size: traySize, flipped: false) { rect in
            full.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
    }()
}

/// Draws the menu bar item: the coloured app icon, two lines of speed (upload on top, download
/// below) and, optionally, two rows of mini bar graphs with the recent history.
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
    static func image(up: Double, down: Double, history: [SpeedSample], showGraph: Bool) -> NSImage {
        let graphWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
        let textX = AppIcon.traySize.width + iconGap
        let width = textX + textWidth + (showGraph ? 5 + graphWidth : 0)
        let recent = Array(history.suffix(barCount))
        let ups = showGraph ? barHeights(recent.map { $0.up }) : []
        let downs = showGraph ? barHeights(recent.map { $0.down }) : []
        let upText = compactSpeed(up)
        let downText = compactSpeed(down)
        let key = "\(upText)|\(downText)|\(showGraph)|\(ups)|\(downs)"
        if key == cacheKey, let cached = cacheImage { return cached }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let icon = AppIcon.traySize
            AppIcon.tray.draw(in: NSRect(x: 0, y: (height - icon.height) / 2, width: icon.width, height: icon.height),
                              from: .zero, operation: .sourceOver, fraction: 1)

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
