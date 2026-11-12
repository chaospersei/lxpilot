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
                .preferredColorScheme(state.settings.appearance.colorScheme)
                .task { await state.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1060, height: 720)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            switch state.settings.menuBarStyle {
            case .icon:
                Image(systemName: state.isRunning ? "shield.lefthalf.filled" : "shield")
            case .speed, .speedGraph:
                // Redrawn once a second together with the speed samples.
                HStack(spacing: 4) {
                    Image(nsImage: AppIcon.tray)
                    Image(nsImage: MenuBarRenderer.image(
                        up: state.upSpeed,
                        down: state.downSpeed,
                        history: state.speedHistory,
                        showGraph: state.settings.menuBarStyle == .speedGraph))
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
