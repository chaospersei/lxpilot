import SwiftUI

// MARK: - Shared look (Liquid Glass: the window is a translucent material, the rail and the start
// button float as glass, cards are quieter material surfaces so glass is not stacked on glass)

struct CardStyle: ViewModifier {
    @EnvironmentObject var state: AppState
    var selected = false
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(shape.fill(state.accent.opacity(selected ? 0.18 : 0.04)))
            .background(.thinMaterial, in: shape)
            .overlay(shape.stroke(selected ? state.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    func card(selected: Bool = false, padding: CGFloat = 16) -> some View {
        modifier(CardStyle(selected: selected, padding: padding))
    }
}

struct CardTitle: View {
    @EnvironmentObject var state: AppState
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(state.accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.top, 6)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// The blurred desktop behind the window. `.active` keeps the blur when the window is not key.
struct WindowMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            NavigationRail()
                .padding(.leading, 10)
                .padding(.vertical, 10)
            ZStack(alignment: .bottomTrailing) {
                // A hidden window still re-evaluates its views on every state change; an empty page costs nothing.
                if state.windowVisible {
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsStartButton {
                    StartButton()
                        .padding(22)
                }
            }
        }
        .background(WindowMaterial().ignoresSafeArea())   // the only window background: opaque colour here kills the translucency
        .tint(state.accent)
        .frame(minWidth: 900, minHeight: 600)
        .ignoresSafeArea(.container, edges: .top)
        .alert("LxPilot", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.alert ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { state.alert != nil }, set: { shown in if !shown { state.alert = nil } })
    }

    private var showsStartButton: Bool {
        state.page == .dashboard || state.page == .proxies || state.page == .profiles
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.page {
        case .dashboard: DashboardView()
        case .proxies: ProxiesView()
        case .routes: RoutesView()
        case .apps: AppsView()
        case .profiles: ProfilesView()
        case .connections: ConnectionsView()
        case .logs: LogsView()
        case .tools: ToolsView()
        }
    }
}

struct NavigationRail: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: AppIcon.glyph(linked: true, size: 30))
                .renderingMode(.template)
                .foregroundStyle(state.accent)
                .padding(.top, WindowButtons.zoneHeight + 6)   // the traffic lights sit centred in the zone above
                .padding(.bottom, 14)
            ForEach(Page.allCases) { page in
                RailButton(page: page)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.bottom, 18)
                .help(statusText)
        }
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private var statusColor: Color {
        switch state.coreState {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        switch state.coreState {
        case .running: return "Ядро работает"
        case .starting: return "Запуск…"
        case .stopping: return "Остановка…"
        case .failed: return "Сбой ядра"
        case .stopped: return "Ядро остановлено"
        }
    }
}

struct RailButton: View {
    @EnvironmentObject var state: AppState
    let page: Page

    var body: some View {
        let selected = state.page == page
        Button {
            state.page = page
        } label: {
            VStack(spacing: 4) {
                Image(systemName: page.icon)
                    .font(.system(size: 17, weight: selected ? .semibold : .regular))
                    .frame(width: 56, height: 30)
                    .background(Capsule().fill(selected ? state.accent.opacity(0.22) : Color.clear))
                Text(page.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? state.accent : Color.secondary)
            .frame(width: 84, height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The floating start/stop button with the running timer.
struct StartButton: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button {
            Task { await state.toggle() }
        } label: {
            HStack(spacing: 10) {
                if state.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                }
                if state.isRunning, let started = state.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(formatDuration(context.date.timeIntervalSince(started)))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, state.isRunning ? 18 : 20)
            .frame(height: 54)
            .frame(minWidth: 54)
            .glassEffect(.regular.tint(state.accent).interactive(), in: .capsule)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .help(state.isRunning ? "Отключиться" : "Подключиться")
        .animation(.easeInOut(duration: 0.2), value: state.isRunning)
    }
}
