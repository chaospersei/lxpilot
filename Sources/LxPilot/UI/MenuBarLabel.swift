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

    /// Where the rocket sits on the transparent 1024 canvas (unit coordinates, origin bottom-left):
    /// fins to flame, the faint end of the exhaust cut off. Keep in sync with Tools/make-icon.swift.
    private static let rocketBounds = CGRect(x: 0.29, y: 0.10, width: 0.42, height: 0.77)
    static let traySize = NSSize(width: 11, height: 20)

    /// Menu bar version: the rocket alone, 20 pt tall. Not a template, so it keeps its colours next
    /// to the tinted speed text.
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

    static func image(up: Double, down: Double, history: [SpeedSample], showGraph: Bool) -> NSImage {
        let graphWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
        let textX = AppIcon.traySize.width + iconGap
        let width = textX + textWidth + (showGraph ? 5 + graphWidth : 0)
        let recent = Array(history.suffix(barCount))
        let ups = recent.map { $0.up }
        let downs = recent.map { $0.down }
        let upText = compactSpeed(up)
        let downText = compactSpeed(down)

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
        return image
    }

    private static func drawBars(_ values: [Double], originX: CGFloat, y: CGFloat) {
        let peak = max(values.max() ?? 0, scaleFloor)
        // Right-align: the newest sample is always the last bar, even with a short history.
        let offset = barCount - values.count
        for slot in 0..<barCount {
            let x = originX + CGFloat(slot) * (barWidth + barGap)
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: rowHeight)).fill()

            let index = slot - offset
            guard index >= 0, values[index] > 0 else { continue }
            let filled = max(1, (CGFloat(values[index] / peak) * rowHeight).rounded())
            NSColor.labelColor.setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: min(filled, rowHeight))).fill()
        }
    }

    /// Short fixed-width form for the menu bar: "0 KB/s", "742 KB/s", "12.4 MB/s", "125 MB/s".
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let kb = max(bytesPerSecond, 0) / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 100 { return String(format: "%.1f", mb) + " MB/s" }
        if mb < 1000 { return String(format: "%.0f", mb) + " MB/s" }
        return String(format: "%.2f", mb / 1024) + " GB/s"
    }
}
