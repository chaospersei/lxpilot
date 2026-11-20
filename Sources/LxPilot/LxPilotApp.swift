import SwiftUI
import AppKit

@main
struct LxPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("LxPilot", id: "main") {
            RootView()
                .environmentObject(state)
                .environmentObject(state.live)
                .environmentObject(state.logStore)
                .preferredColorScheme(state.settings.appearance.colorScheme)
                .task { await state.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
                .environmentObject(state.live)
        }
    }
}

/// Observes LiveStats directly, so the once-a-second numbers reach the status item without the
/// whole App body. One Image: MenuBarExtra shows only the first image of a composite label.
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var live: LiveStats

    var body: some View {
        switch state.settings.menuBarStyle {
        case .icon:
            Image(systemName: state.isRunning ? "shield.lefthalf.filled" : "shield")
        case .speed, .speedGraph:
            Image(nsImage: MenuBarRenderer.image(
                up: live.upSpeed,
                down: live.downSpeed,
                history: live.speedHistory,
                showGraph: state.settings.menuBarStyle == .speedGraph))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

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

        // When started as a bare SwiftPM binary (not from the .app bundle) the process needs this to get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = AppIcon.full {
            NSApp.applicationIconImage = icon   // `swift run`: no bundle to take the Dock icon from
        }
    }

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

struct MenuBarContent: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(state.isRunning ? "Отключиться" : "Подключиться") {
            Task { await state.toggle() }
        }
        .disabled(state.isBusy)

        Divider()

        Toggle("Режим TUN", isOn: Binding(
            get: { state.settings.tunEnabled },
            set: { value in Task { await state.setTun(value) } }))
        Toggle("Системный прокси", isOn: Binding(
            get: { state.settings.systemProxyEnabled },
            set: { value in Task { await state.setSystemProxy(value) } }))

        if state.isRunning && !state.modeList.isEmpty {
            Divider()
            ForEach(state.modeList, id: \.self) { item in
                Button((item.lowercased() == state.mode.lowercased() ? "✓ " : "    ") + modeTitle(item)) {
                    Task { await state.setMode(item) }
                }
            }
        }

        Divider()

        Picker("Значок в строке меню", selection: $state.settings.menuBarStyle) {
            ForEach(MenuBarStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }

        Button("Открыть окно") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Выйти") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
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
