import AppKit
import Combine
import SwiftUI

/// The menu bar item, done in AppKit: a left click shows or hides the window, a right click (or
/// control-click) opens the menu. MenuBarExtra cannot tell clicks apart, and the app has no Dock
/// icon, so this click is the one way back to the window.
@MainActor
final class StatusItemController: NSResponder, NSMenuDelegate {
    private let item: NSStatusItem
    private let state: AppState
    private let statusMenu = NSMenu()
    private var subscriptions: Set<AnyCancellable> = []
    private var symbolShown = ""
    private var lastToggle = Date.distantPast
    private var popover: NSPopover?
    private var hoverTask: Task<Void, Never>?
    private var overButton = false
    private var overPopover = false

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusMenu.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "LxPilot — клик: окно, правый клик: меню"
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self, userInfo: nil))
        }
        // objectWillChange fires before the change; hopping through the main queue reads the new values.
        state.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        state.live.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        guard let button = item.button else { return }
        switch state.settings.menuBarStyle {
        case .icon:
            // The link line shows only while connected.
            let symbol = state.isRunning ? "linked" : "apart"
            guard symbol != symbolShown else { return }
            symbolShown = symbol
            button.image = AppIcon.glyph(linked: state.isRunning, size: 18)
        case .speed, .speedGraph:
            symbolShown = ""
            let image = MenuBarRenderer.image(
                up: state.live.upSpeed, down: state.live.downSpeed,
                history: state.live.speedHistory, showGraph: state.settings.menuBarStyle == .speedGraph, linked: state.isRunning)
            // The renderer hands back the same object while nothing changed; a new one costs a status bar snapshot.
            if button.image !== image { button.image = image }
        }
    }

    // MARK: Hover popover

    override func mouseEntered(with event: NSEvent) { hover(button: true) }
    override func mouseExited(with event: NSEvent) { hover(button: false) }

    /// The popover opens after the pointer rests on the item for a moment and closes once it has
    /// left both the item and the popover; the grace period lets the pointer travel between them.
    private func hover(button: Bool? = nil, popover: Bool? = nil) {
        if let button { overButton = button }
        if let popover { overPopover = popover }
        hoverTask?.cancel()
        let shouldShow = overButton || overPopover
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: shouldShow ? 450_000_000 : 300_000_000)
            guard !Task.isCancelled, let self else { return }
            if shouldShow { self.showPopover() } else { self.closePopover() }
        }
    }

    private func showPopover() {
        guard state.settings.hoverPopover, let button = item.button, popover?.isShown != true else { return }
        let content = StatusPopoverView()
            .environmentObject(state)
            .environmentObject(state.live)
            .onHover { [weak self] inside in self?.hover(popover: inside) }
        let popover = NSPopover()
        popover.behavior = .applicationDefined   // never steals focus, closes only on our say-so
        popover.animates = true
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]   // the popover takes the view's own size, no clipping
        popover.contentViewController = hosting
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        state.setPopoverVisible(true)
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        overPopover = false
        state.setPopoverVisible(false)
    }

    #if DEBUG
    func simulateHover(_ inside: Bool) { hover(button: inside) }
    var popoverShown: Bool { popover?.isShown ?? false }
    var hoverState: String { "button=\(overButton) popover=\(overPopover) mouse=\(NSEvent.mouseLocation)" }
    #endif

    @objc private func clicked() {
        // One click can reach us more than once (the status button also reports the press);
        // only a left mouse-up toggles, and never twice within a third of a second — a down+up
        // pair would otherwise hide the window and bring it straight back.
        guard let event = NSApp.currentEvent else { return }
        hoverTask?.cancel()
        closePopover()
        switch event.type {
        case .rightMouseUp:
            showMenu()
        case .leftMouseUp:
            if event.modifierFlags.contains(.control) {
                showMenu()
            } else if Date().timeIntervalSince(lastToggle) > 0.3 {
                lastToggle = Date()
                MainWindow.toggle()
            }
        default:
            break
        }
    }

    #if DEBUG
    /// Self-test hook: what a left mouse-up on the status button does.
    func simulateClick() {
        if Date().timeIntervalSince(lastToggle) > 0.3 {
            lastToggle = Date()
            MainWindow.toggle()
        }
    }
    #endif

    private func showMenu() {
        item.menu = statusMenu
        item.button?.performClick(nil)   // tracks the menu synchronously
        item.menu = nil                  // the next left click is ours again
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = state
        menu.addItem(ClosureItem(state.isRunning ? "Отключиться" : "Подключиться", enabled: !state.isBusy) {
            Task { await state.toggle() }
        })
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Режим TUN", checked: state.settings.tunEnabled) {
            Task { await state.setTun(!state.settings.tunEnabled) }
        })
        menu.addItem(ClosureItem("Системный прокси", checked: state.settings.systemProxyEnabled) {
            Task { await state.setSystemProxy(!state.settings.systemProxyEnabled) }
        })
        if state.isRunning, !state.modeList.isEmpty {
            menu.addItem(.separator())
            for mode in state.modeList {
                menu.addItem(ClosureItem(modeTitle(mode), checked: mode.lowercased() == state.mode.lowercased()) {
                    Task { await state.setMode(mode) }
                })
            }
        }
        menu.addItem(.separator())
        let styles = NSMenuItem(title: "Значок в строке меню", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for style in MenuBarStyle.allCases {
            submenu.addItem(ClosureItem(style.title, checked: state.settings.menuBarStyle == style) {
                state.settings.menuBarStyle = style
            })
        }
        styles.submenu = submenu
        menu.addItem(styles)
        menu.addItem(ClosureItem("Открыть окно") { MainWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureItem("Выйти", key: "q") { NSApp.terminate(nil) })
    }
}

/// NSMenuItem with a closure instead of target/action plumbing.
final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// The one SwiftUI window, kept alive: closing hides it (so the status item can bring it back
/// without going through SwiftUI's `openWindow`, which only views inside a scene can reach).
@MainActor
enum MainWindow {
    private(set) static var window: NSWindow?
    private static let interceptor = CloseInterceptor()

    static func adopt(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Translucent window: SwiftUI's own background stays opaque under `Window`, so the
        // desktop shows through only when the NSWindow itself is clear and a behind-window
        // material view (WindowMaterial in RootView) does the blur.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        WindowButtons.install(on: window)
        if window.delegate !== interceptor {
            interceptor.original = window.delegate
            window.delegate = interceptor
        }
    }

    static func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// On screen → hide, even when another app is in front; buried, minimised or hidden → bring up.
    static func toggle() {
        guard let window else { return }
        if window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) {
            window.orderOut(nil)
        } else {
            if window.isMiniaturized { window.deminiaturize(nil) }
            show()
        }
    }

    /// Hides instead of closing and forwards everything else to SwiftUI's own delegate.
    private final class CloseInterceptor: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (original?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original
        }
    }
}

/// Finds the NSWindow behind RootView and hands it to `MainWindow`.
struct MainWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { MainWindow.adopt(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { MainWindow.adopt(window) } }
    }
}
