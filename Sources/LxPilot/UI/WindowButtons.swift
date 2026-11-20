import AppKit

/// Puts the close / minimise / zoom buttons in the top centre of the navigation rail, Telegram
/// style. The title bar zone is made 48 pt tall so the buttons keep their hover and hit area, and
/// the layout is re-applied whenever AppKit lays the title bar out again (resize, key changes…).
@MainActor
enum WindowButtons {
    static let zoneHeight: CGFloat = 48
    /// Rail: 10 pt leading padding + 92 pt wide → centre at 56.
    static let centerX: CGFloat = 56
    private static let spacing: CGFloat = 20
    private static var installed: Set<ObjectIdentifier> = []

    static func install(on window: NSWindow) {
        guard !installed.contains(ObjectIdentifier(window)) else { return }
        installed.insert(ObjectIdentifier(window))
        apply(to: window)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                Task { @MainActor in if let window { apply(to: window) } }
            }
        }
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            titlebar.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: titlebar, queue: .main) { [weak window] _ in
                Task { @MainActor in if let window { apply(to: window) } }
            }
        }
    }

    static func apply(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let titlebar = buttons[0].superview, let container = titlebar.superview,
              let frameView = container.superview else { return }

        let width = frameView.bounds.width
        let containerFrame = NSRect(x: 0, y: frameView.bounds.height - zoneHeight, width: width, height: zoneHeight)
        if container.frame != containerFrame { container.frame = containerFrame }
        let titlebarFrame = NSRect(x: 0, y: 0, width: width, height: zoneHeight)
        if titlebar.frame != titlebarFrame { titlebar.frame = titlebarFrame }

        let span = spacing * CGFloat(buttons.count - 1) + buttons[0].frame.width
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: (centerX - span / 2 + spacing * CGFloat(index)).rounded(),
                                 y: ((zoneHeight - button.frame.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}
