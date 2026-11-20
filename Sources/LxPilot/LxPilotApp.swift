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
