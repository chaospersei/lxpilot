import SwiftUI
import AppKit

/// Per-application forced routing: every process of the chosen app goes through the proxy or directly,
/// ahead of the profile's rules and of the Global/Direct mode.
struct AppsView: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Приложения") {
                AddAppMenu()
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 6)

            Text("Соединения выбранных приложений (включая их вспомогательные процессы) идут по заданному маршруту независимо от правил профиля и режима Global/Direct. Изменения применяются сразу, без перезапуска ядра на движке lxd.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            if state.settings.appRules.isEmpty {
                EmptyHint(icon: "app.badge.checkmark",
                          text: "Добавьте приложение из запущенных или выберите его в Finder, затем задайте для него маршрут: через прокси или напрямую.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(state.settings.appRules) { rule in
                            AppRuleCard(rule: rule)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
        }
    }
}

struct AddAppMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // The candidate list is rebuilt each time the menu opens: it is a computed property of the state.
        Menu {
            Button {
                Task { await state.chooseApp() }
            } label: {
                Label("Выбрать в Finder…", systemImage: "folder")
            }
            let running = state.runningAppCandidates
            if !running.isEmpty {
                Divider()
                Text("Запущенные")
                ForEach(running, id: \.url) { app in
                    Button {
                        Task { await state.addAppRule(url: app.url) }
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            Image(nsImage: AppRuleCard.icon(for: app.url.path, side: 16))
                        }
                    }
                }
            }
        } label: {
            Label("Добавить", systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }
}

struct AppRuleCard: View {
    @EnvironmentObject var state: AppState
    let rule: AppRule

    static func icon(for path: String, side: CGFloat) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: side, height: side)
        return image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: AppRuleCard.icon(for: rule.path, side: 36))
                    .opacity(rule.enabled ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(rule.path)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.path)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { value in
                        var updated = rule
                        updated.enabled = value
                        Task { await state.updateAppRule(updated) }
                    }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { rule.mode },
                    set: { value in
                        var updated = rule
                        updated.mode = value
                        Task { await state.updateAppRule(updated) }
                    })) {
                    ForEach(AppRouteMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!rule.enabled)

                Button {
                    Task { await state.removeAppRule(rule) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Удалить правило")
            }
        }
        .card(selected: rule.enabled && rule.mode == .proxy, padding: 14)
        .opacity(rule.enabled ? 1 : 0.7)
    }
}
