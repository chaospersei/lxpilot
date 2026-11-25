import SwiftUI

/// Wi-Fi rules: joining a listed network switches the VPN on or off.
struct NetworksView: View {
    @EnvironmentObject var state: AppState
    @State private var manualEntry = false
    @State private var manualName = ""

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Сети") {
                AddNetworkMenu(manualEntry: $manualEntry)
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 6)

            Text("При подключении Mac к сети Wi-Fi из списка VPN включается или отключается сам. Правило срабатывает в момент входа в сеть: ручное переключение после этого действует, пока сеть не сменится. Правила работают, пока LxPilot запущен.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CurrentNetworkCard()
                    if manualEntry { manualRow }
                    if state.settings.wifiRules.isEmpty {
                        EmptyHint(icon: "wifi",
                                  text: "Добавьте сеть: текущую, одну из сохранённых на этом Mac или по имени. Затем выберите, что делать при входе в неё — включать VPN или отключать.")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(state.settings.wifiRules) { rule in
                                WiFiRuleCard(rule: rule)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .task {
            await state.refreshWiFi()
            await state.loadKnownNetworks()
        }
    }

    private var manualRow: some View {
        HStack(spacing: 10) {
            TextField("Имя сети (SSID), с учётом регистра", text: $manualName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addManual)
            Button("Добавить", action: addManual)
                .disabled(manualName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Отмена") {
                manualEntry = false
                manualName = ""
            }
        }
        .card(padding: 14)
    }

    private func addManual() {
        let name = manualName
        manualName = ""
        manualEntry = false
        Task { await state.addWiFiRule(ssid: name) }
    }
}

struct AddNetworkMenu: View {
    @EnvironmentObject var state: AppState
    @Binding var manualEntry: Bool

    var body: some View {
        let listed = Set(state.settings.wifiRules.map(\.ssid))
        let saved = state.knownNetworks.filter { !listed.contains($0) && $0 != state.currentSSID }
        Menu {
            if let current = state.currentSSID, !listed.contains(current) {
                Button {
                    Task { await state.addWiFiRule(ssid: current) }
                } label: {
                    Label("Текущая: \(current)", systemImage: "wifi")
                }
            }
            Button {
                manualEntry = true
            } label: {
                Label("Ввести имя…", systemImage: "character.cursor.ibeam")
            }
            if !saved.isEmpty {
                Divider()
                Text("Сохранённые на этом Mac")
                ForEach(saved, id: \.self) { name in
                    Button(name) {
                        Task { await state.addWiFiRule(ssid: name) }
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

/// Which network the Mac is on now, what its rule says, and what a rule did last.
struct CurrentNetworkCard: View {
    @EnvironmentObject var state: AppState
    @State private var refreshing = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.currentSSID == nil ? "wifi.slash" : "wifi")
                .font(.system(size: 20))
                .foregroundStyle(state.currentSSID == nil ? Color.secondary : state.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.currentSSID ?? "Wi-Fi не подключён")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(ruleText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let note = state.wifiNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { @MainActor in
                    refreshing = true
                    await state.refreshWiFi()
                    refreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(refreshing)
            .help("Определить сеть заново")
        }
        .card(padding: 14)
    }

    private var ruleText: String {
        guard state.currentSSID != nil else { return "Правила не применяются." }
        guard let rule = state.wifiRule(for: state.currentSSID) else { return "Для этой сети правила нет: VPN не трогаем." }
        switch rule.action {
        case .connect: return "Правило: включать VPN при входе в сеть."
        case .disconnect: return "Правило: отключать VPN при входе в сеть."
        }
    }
}

struct WiFiRuleCard: View {
    @EnvironmentObject var state: AppState
    let rule: WiFiRule

    var body: some View {
        let current = rule.ssid == state.currentSSID
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "wifi")
                    .font(.system(size: 18))
                    .foregroundStyle(rule.enabled ? state.accent : Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.ssid)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .help(rule.ssid)
                    Text(current ? "Вы сейчас в этой сети" : " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { rule.enabled },
                    set: { value in
                        var updated = rule
                        updated.enabled = value
                        Task { await state.updateWiFiRule(updated) }
                    }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }

            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { rule.action },
                    set: { value in
                        var updated = rule
                        updated.action = value
                        Task { await state.updateWiFiRule(updated) }
                    })) {
                    ForEach(WiFiAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!rule.enabled)

                Button {
                    Task { await state.removeWiFiRule(rule) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Удалить правило")
            }
        }
        .card(selected: rule.enabled && current, padding: 14)
        .opacity(rule.enabled ? 1 : 0.7)
    }
}
