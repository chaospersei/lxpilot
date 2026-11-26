import AppKit
import SwiftUI

/// What the About window says. Fill in the author and the repository before publishing: an empty
/// value shows as "не указан", and its link is not clickable.
enum AppInfo {
    static let author = "persei"
    /// Optional: the author's page; makes the name a link.
    static let authorURL = ""
    /// The project's page, e.g. https://github.com/<owner>/LxPilot
    static let repositoryURL = "https://github.com/chaospersei/lxpilot"
    static let license = "GNU GPL v3"
    static let coreURL = "https://github.com/Leadaxe/sing-box-lx"

    /// "0.1.0 (12)" from the bundle; nil for a bare SwiftPM binary, which has no Info.plist of its own.
    static var version: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    static var versionLine: String {
        version.map { "Версия \($0)" } ?? "Сборка для разработки"
    }
}

struct AboutView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let icon = AppIcon.full {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }
            Text("LxPilot")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 8)
            Text(AppInfo.versionLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("Клиент macOS для ядра sing-box-lx")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 10)

            VStack(spacing: 0) {
                row("Автор") { link(AppInfo.author, url: AppInfo.authorURL) }
                Divider()
                row("GitHub") { link(shortURL(AppInfo.repositoryURL), url: AppInfo.repositoryURL) }
                Divider()
                row("Ядро") {
                    link(state.coreVersion.isEmpty ? "sing-box-lx, не установлено" : state.coreVersion, url: AppInfo.coreURL)
                }
                Divider()
                row("Лицензия") { Text(AppInfo.license) }
            }
            .card(padding: 0)
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .frame(width: 360)
        .background(WindowMaterial().ignoresSafeArea())
        .tint(state.accent)
        .preferredColorScheme(state.settings.appearance.colorScheme)
    }

    private func row<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// Text that is a link when there is somewhere to go, and a dimmed placeholder when empty.
    @ViewBuilder
    private func link(_ text: String, url: String) -> some View {
        if text.isEmpty {
            Text("не указан").foregroundStyle(.tertiary)
        } else if let destination = URL(string: url), destination.scheme != nil {
            Link(text, destination: destination)
                .help(url)
        } else {
            Text(text).textSelection(.enabled)
        }
    }

    private func shortURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

/// A window of its own: the app has no Dock icon and no main menu to hang the standard panel on.
@MainActor
enum AboutWindow {
    private(set) static var window: NSWindow?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView().environmentObject(AppState.shared))
            let panel = Panel(contentViewController: hosting)
            panel.styleMask = [.titled, .closable, .fullSizeContentView]
            panel.title = "О программе LxPilot"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Never "main": the app decides whether its window is on screen by looking for a main-capable
    /// one, and this panel must not keep the once-a-second polling alive.
    private final class Panel: NSWindow {
        override var canBecomeMain: Bool { false }
    }
}
