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

    /// Menu bar version, 18 pt: the tile without the canvas margin of the icon grid. Not a template,
    /// so it keeps its colours next to the tinted speed image.
    static let tray: NSImage = {
        let side: CGFloat = 18
        guard let full else {
            return NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: side, height: side))
        }
        let margin = full.size.width * 80 / 1024
        let crop = NSRect(x: margin, y: margin, width: full.size.width - margin * 2, height: full.size.height - margin * 2)
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            full.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
            return true
        }
    }()
}

/// Draws the speed part of the menu bar item: two lines of speed (upload on top, download below)
/// and, optionally, two rows of mini bar graphs with the recent history.
///
/// It is one template NSImage — macOS then tints it for light/dark menu bars and for the
/// highlighted state; the coloured app icon sits next to it as a separate view.
enum MenuBarRenderer {
    private static let height: CGFloat = 22
    private static let textWidth: CGFloat = 54
    private static let rowHeight: CGFloat = 8
    /// 7 bars × (3 + 1) pt = 27 pt wide; was 12 bars / 47 pt, cut ~1.7× to leave room for the icon.
    private static let barCount = 7
    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 1
    /// Scale floor: below this the bars stay low instead of idle noise filling the graph.
    private static let scaleFloor: Double = 64 * 1024

    static func image(up: Double, down: Double, history: [SpeedSample], showGraph: Bool) -> NSImage {
        let graphWidth = CGFloat(barCount) * (barWidth + barGap) - barGap
        let width = showGraph ? textWidth + 5 + graphWidth : textWidth
        let recent = Array(history.suffix(barCount))
        let ups = recent.map { $0.up }
        let downs = recent.map { $0.down }
        let upText = compactSpeed(up)
        let downText = compactSpeed(down)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
            (upText as NSString).draw(in: NSRect(x: 0, y: 10.5, width: textWidth, height: 11), withAttributes: attributes)
            (downText as NSString).draw(in: NSRect(x: 0, y: 0.5, width: textWidth, height: 11), withAttributes: attributes)

            if showGraph {
                let originX = textWidth + 5
                drawBars(ups, originX: originX, y: 12)
                drawBars(downs, originX: originX, y: 2)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBars(_ values: [Double], originX: CGFloat, y: CGFloat) {
        let peak = max(values.max() ?? 0, scaleFloor)
        // Right-align: the newest sample is always the last bar, even with a short history.
        let offset = barCount - values.count
        for slot in 0..<barCount {
            let x = originX + CGFloat(slot) * (barWidth + barGap)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: rowHeight)).fill()

            let index = slot - offset
            guard index >= 0, values[index] > 0 else { continue }
            let filled = max(1, (CGFloat(values[index] / peak) * rowHeight).rounded())
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: x, y: y, width: barWidth, height: min(filled, rowHeight))).fill()
        }
    }

    /// Short fixed-width form for the menu bar: "0 KB/s", "742 KB/s", "12.4 MB/s".
    static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let kb = max(bytesPerSecond, 0) / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 1000 { return String(format: "%.1f", mb) + " MB/s" }
        return String(format: "%.2f", mb / 1024) + " GB/s"
    }
}
