import SwiftUI
import AppKit

@main
struct LxPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("LxPilot", id: "main") {
            RootView()
                .background(MainWindowAccessor())
                .environmentObject(state)
                .environmentObject(state.live)
                .environmentObject(state.logStore)
                .preferredColorScheme(state.settings.appearance.colorScheme)
                .task { await state.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the notification settles: willClose fires while the window is still visible.
                Task { @MainActor in AppDelegate.updateWindowVisibility() }
            }
        }
        // `kill <pid>` would skip applicationWillTerminate and leave the core and the system proxy behind.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        termSource = source

        // Menu bar app: no Dock icon, no app switcher entry (LSUIElement does the same for the bundle).
        NSApp.setActivationPolicy(.accessory)
        if let icon = AppIcon.full { NSApp.applicationIconImage = icon }   // used by alerts and the password prompt
        statusItem = StatusItemController(state: AppState.shared)
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
        if ProcessInfo.processInfo.environment["LXPILOT_SELFTEST_WINDOW"] == "1" { selfTestWindow() }
        #endif
    }

    #if DEBUG
    /// `LXPILOT_SELFTEST_WINDOW=1`: close the window the way the red button does, then bring it back.
    private func selfTestWindow() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let window = MainWindow.window
            NSLog("selftest: window=%@ delegate=%@", window.map { "\($0)" } ?? "nil", window?.delegate.map { "\(type(of: $0))" } ?? "nil")
            window?.performClose(nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSLog("selftest: after close — still in NSApp.windows=%d visible=%d windowVisible=%d",
                  window.map { NSApp.windows.contains($0) } ?? false, window?.isVisible ?? false, AppState.shared.windowVisible)
            MainWindow.toggle()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSLog("selftest: after toggle — visible=%d key=%d windowVisible=%d policy=%d",
                  window?.isVisible ?? false, window?.isKeyWindow ?? false, AppState.shared.windowVisible, NSApp.activationPolicy().rawValue)
            // A click on the status item while the window is up: must hide and stay hidden.
            NSApp.deactivate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            MainWindow.toggle()
            MainWindow.toggle()   // the spurious second call a click used to produce
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSLog("selftest: after inactive-app toggle pair — visible=%d (expected 1: hide, then the second call brings it back; the debounce lives in the click handler)", window?.isVisible ?? false)
            statusItem?.simulateClick()
            statusItem?.simulateClick()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSLog("selftest: after two status-item clicks within 0.3 s — visible=%d (expected 0)", window?.isVisible ?? false)
            MainWindow.show()
            try? await Task.sleep(nanoseconds: 500_000_000)
            func frames() -> String {
                guard let window, let close = window.standardWindowButton(.closeButton), let zoom = window.standardWindowButton(.zoomButton),
                      let titlebar = close.superview, let container = titlebar.superview else { return "no buttons" }
                return String(format: "close=(%.0f,%.0f) zoom=(%.0f,%.0f) titlebar h=%.0f container y=%.0f h=%.0f frame h=%.0f",
                              close.frame.origin.x, close.frame.origin.y, zoom.frame.origin.x, zoom.frame.origin.y,
                              titlebar.frame.height, container.frame.origin.y, container.frame.height, container.superview?.bounds.height ?? 0)
            }
            NSLog("selftest: buttons %@", frames())
            window?.setContentSize(NSSize(width: 1000, height: 650))
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSLog("selftest: buttons after resize %@", frames())
            statusItem?.simulateHover(true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSLog("selftest: popover after hover-in %d (expected 1)", statusItem?.popoverShown ?? false)
            statusItem?.simulateHover(false)
            try? await Task.sleep(nanoseconds: 700_000_000)
            NSLog("selftest: popover after hover-out %d (expected 0; %@)", statusItem?.popoverShown ?? false, statusItem?.hoverState ?? "")
            // A failed start must make the status item blink red until the state changes.
            let state = AppState.shared
            if state.coreState == .stopped {
                state.coreState = .failed("selftest")
                try? await Task.sleep(nanoseconds: 100_000_000)
                let first = statusItem?.alarmShown ?? false
                try? await Task.sleep(nanoseconds: 600_000_000)
                let second = statusItem?.alarmShown ?? false
                NSLog("selftest: fault blink — blinking=%d phases %d/%d (expected 1, phases differ)", statusItem?.blinking ?? false, first, second)
                state.coreState = .stopped
                try? await Task.sleep(nanoseconds: 200_000_000)
                NSLog("selftest: after clearing fault — blinking=%d alarm=%d (expected 0/0)", statusItem?.blinking ?? false, statusItem?.alarmShown ?? false)
            } else {
                NSLog("selftest: fault blink skipped, core state %@", "\(state.coreState)")
            }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // keeps running in the menu bar, like FlClash in the tray
    }

    /// The status item owns a window as well; only windows that can become main count as "the window".
    static func updateWindowVisibility() {
        let visible = NSApp.windows.contains { window in
            window.canBecomeMain && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        }
        AppState.shared.setWindowVisible(visible)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdownSync()
    }
}

func modeTitle(_ mode: String) -> String {
    switch mode.lowercased() {
    case "rule": return "По правилам"
    case "global": return "Глобально"
    case "direct": return "Напрямую"
    default: return mode
    }
}
