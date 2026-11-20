import SwiftUI

struct ProxiesView: View {
    @EnvironmentObject var state: AppState
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Прокси") {
                Button {
                    Task {
                        for group in state.groups { await state.test(group: group) }
                    }
                } label: {
                    Label("Проверить все", systemImage: "bolt")
                }
                .disabled(!state.isRunning || state.groups.isEmpty || !state.testingGroups.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 10)

            if !state.isRunning {
                EmptyHint(icon: "point.3.connected.trianglepath.dotted",
                          text: "Группы и узлы появятся после подключения.")
            } else if state.groups.isEmpty {
                EmptyHint(icon: "tray", text: "В профиле нет узлов, а группы selector / urltest отсутствуют.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(state.groups) { group in
                            GroupSection(group: group, collapsed: $collapsed)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 90)
                }
            }
        }
    }
}

struct GroupSection: View {
    @EnvironmentObject var state: AppState
    let group: ProxyGroup
    @Binding var collapsed: Set<String>

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    var body: some View {
        let isCollapsed = collapsed.contains(group.name)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    if isCollapsed { collapsed.remove(group.name) } else { collapsed.insert(group.name) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if state.testingGroups.contains(group.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await state.test(group: group) }
                    } label: {
                        Image(systemName: "bolt")
                    }
                    .buttonStyle(.borderless)
                    .help("Проверить задержку")
                }
            }
            if !isCollapsed {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(group.all, id: \.self) { name in
                        ProxyCard(name: name, selected: group.now == name, enabled: group.isSelectable) {
                            Task { await state.select(group: group, proxy: name) }
                        }
                    }
                }
            }
        }
        .card()
    }

    private var subtitle: String {
        let kind = group.type
        let current = group.now.isEmpty ? "" : " · \(group.now)"
        return "\(kind) · \(group.all.count)\(current)"
    }
}

struct ProxyCard: View {
    @EnvironmentObject var state: AppState
    let name: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Text(state.proxyTypes[name] ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    DelayLabel(delay: state.delays[name])
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? state.accent.opacity(0.24) : Color(nsColor: .windowBackgroundColor)))
            .overlay(shape.stroke(selected ? state.accent : Color.primary.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(name)
    }
}

struct DelayLabel: View {
    let delay: Int?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
    }

    private var text: String {
        guard let delay else { return "" }
        return delay > 0 ? "\(delay) ms" : "таймаут"
    }

    private var color: Color {
        guard let delay, delay > 0 else { return .secondary }
        if delay < 300 { return .green }
        if delay < 800 { return .orange }
        return .red
    }
}
