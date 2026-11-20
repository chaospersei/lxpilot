import AppKit
import Combine
import SwiftUI

/// The menu bar item, done in AppKit: a left click shows or hides the window, a right click (or
/// control-click) opens the menu. MenuBarExtra cannot tell clicks apart, and the app has no Dock
/// icon, so this click is the one way back to the window.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let state: AppState
    private let menu = NSMenu()
    private var subscriptions: Set<AnyCancellable> = []
    private var symbolShown = ""

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.toolTip = "LxPilot — клик: окно, правый клик: меню"
        }
        // objectWillChange fires before the change; hopping through the main queue reads the new values.
        state.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        state.live.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
        render()
    }

    private func render() {
        guard let button = item.button else { return }
        switch state.settings.menuBarStyle {
        case .icon:
            let symbol = state.isRunning ? "shield.lefthalf.filled" : "shield"
            guard symbol != symbolShown else { return }
            symbolShown = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LxPilot")
            image?.isTemplate = true
            button.image = image
        case .speed, .speedGraph:
            symbolShown = ""
            let image = MenuBarRenderer.image(
                up: state.live.upSpeed, down: state.live.downSpeed,
                history: state.live.speedHistory, showGraph: state.settings.menuBarStyle == .speedGraph)
            // The renderer hands back the same object while nothing changed; a new one costs a status bar snapshot.
            if button.image !== image { button.image = image }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            MainWindow.toggle()
        }
    }

    private func showMenu() {
        item.menu = menu
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

    static func toggle() {
        guard let window else { return }
        if window.isVisible, !window.isMiniaturized, NSApp.isActive {
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
