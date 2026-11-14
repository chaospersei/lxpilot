import SwiftUI

/// Routing editor: the common group plus switchable scenarios. Every scenario becomes a `clash_mode`
/// of the core and shows up in the mode card; edits are applied to the running core after a pause.
struct RoutesView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedID: UUID?

    private var routing: Binding<RoutingConfig> {
        Binding(get: { state.settings.routing }, set: { state.setRouting($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Маршруты") {
                Button {
                    var updated = state.settings.routing
                    let scenario = RouteScenario(name: uniqueName("Сценарий"))
                    updated.scenarios.append(scenario)
                    state.setRouting(updated)
                    selectedID = scenario.id
                } label: {
                    Label("Сценарий", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 6)

            Text("Сценарий — переключаемая группа правил: он появляется в «Режиме маршрутизации» на панели, его правила действуют, пока он выбран. Общие правила действуют всегда. Правила идут сверху вниз, первое совпавшее решает; что не совпало, идёт по правилам профиля или по запасному маршруту сценария.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 14) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.settings.routing.scenarios) { scenario in
                            ScenarioTile(scenario: scenario, selected: scenario.id == currentID)
                                .onTapGesture { selectedID = scenario.id }
                        }
                        RuleSetsCard(ruleSets: routing.ruleSets)
                    }
                    .padding(.bottom, 20)
                }
                .frame(width: 290)

                if let index = state.settings.routing.scenarios.firstIndex(where: { $0.id == currentID }) {
                    ScenarioEditor(scenario: routing.scenarios[index]) {
                        var updated = state.settings.routing
                        updated.scenarios.remove(at: index)
                        state.setRouting(updated)
                        selectedID = nil
                    }
                } else {
                    EmptyHint(icon: "arrow.triangle.swap", text: "Выберите группу слева или добавьте сценарий.")
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var currentID: UUID? {
        selectedID ?? state.settings.routing.scenarios.first?.id
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(state.settings.routing.scenarios.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

struct ScenarioTile: View {
    @EnvironmentObject var state: AppState
    let scenario: RouteScenario
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: scenario.isCommon ? "pin" : "arrow.triangle.branch")
                .foregroundStyle(scenario.enabled ? state.accent : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.name.isEmpty ? "Без названия" : scenario.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isActiveMode {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                    .help("Выбран в ядре сейчас")
            }
        }
        .contentShape(Rectangle())
        .card(selected: selected, padding: 12)
        .opacity(scenario.enabled ? 1 : 0.6)
    }

    private var subtitle: String {
        let count = scenario.rules.filter(\.enabled).count
        let rules = "\(count) " + plural(count, "правило", "правила", "правил")
        if scenario.isCommon { return "Всегда · " + rules }
        return (scenario.enabled ? "Режим · " : "Выключен · ") + rules
    }

    private var isActiveMode: Bool {
        !scenario.isCommon && state.isRunning && state.mode.lowercased() == scenario.name.lowercased()
    }
}

struct ScenarioEditor: View {
    @EnvironmentObject var state: AppState
    @Binding var scenario: RouteScenario
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if scenario.isCommon {
                    Text(scenario.name)
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    NameField(text: $scenario.name)
                    Toggle("Включён", isOn: $scenario.enabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                Spacer()
                if !scenario.isCommon, state.isRunning, state.modeList.contains(where: { $0.lowercased() == scenario.name.lowercased() }) {
                    Button("Выбрать режим") { Task { await state.setMode(scenario.name) } }
                        .disabled(state.mode.lowercased() == scenario.name.lowercased())
                }
                Button {
                    var updated = scenario
                    updated.rules.append(RouteRule())
                    scenario = updated
                } label: {
                    Label("Правило", systemImage: "plus")
                }
                if !scenario.isCommon {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .help("Удалить сценарий")
                }
            }

            if !scenario.isCommon {
                HStack(spacing: 8) {
                    Text("Всё остальное в этом сценарии:")
                        .foregroundStyle(.secondary)
                    TargetPicker(target: $scenario.fallback, allowBlock: true)
                        .frame(width: 180)
                }
                .font(.system(size: 12))
            }

            if scenario.rules.isEmpty {
                EmptyHint(icon: "list.bullet.rectangle", text: "Правил пока нет. Добавьте правило: что совпадает и куда направить.")
                    .frame(minHeight: 160)
            } else {
                List {
                    ForEach($scenario.rules) { $rule in
                        RuleRow(rule: $rule) {
                            scenario.rules.removeAll { $0.id == rule.id }
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { from, to in scenario.rules.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                Text("Перетаскивайте правила, чтобы менять порядок. Значения перечисляйте через запятую; изменения применяются к ядру через секунду после правки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
        .padding(.bottom, 20)
    }
}

/// Scenario name = clash_mode: committed on Return or when focus leaves, so typing does not re-apply per keystroke.
struct NameField: View {
    @Binding var text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Название сценария", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 240)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { active in if !active { commit() } }
            .onAppear { draft = text }
            .onChange(of: text) { value in if !focused { draft = value } }
    }

    private func commit() {
        let clean = draft.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { draft = text; return }
        if clean != text { text = clean }
    }
}

struct RuleRow: View {
    @EnvironmentObject var state: AppState
    @Binding var rule: RouteRule
    let onDelete: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $rule.enabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Picker("", selection: $rule.match) {
                ForEach(RouteMatch.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .labelsHidden()
            .frame(width: 170)
            if rule.match == .ruleSet {
                RuleSetField(values: $rule.values)
            } else {
                TextField(rule.match.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { active in if !active { commit() } }
                    .onAppear { draft = rule.values.joined(separator: ", ") }
                    .onChange(of: rule.values) { values in if !focused { draft = values.joined(separator: ", ") } }
            }
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TargetPicker(target: $rule.target, allowBlock: true)
                .frame(width: 170)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private func commit() {
        let values = draft
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if values != rule.values { rule.values = values }
    }
}

/// Rule-set tags come from a fixed list (profile + editor sources), so this is a multi-select menu.
struct RuleSetField: View {
    @EnvironmentObject var state: AppState
    @Binding var values: [String]

    var body: some View {
        let known = knownTags
        Menu {
            if known.isEmpty {
                Text("Нет наборов: добавьте их в карточке «Наборы правил»")
            }
            ForEach(known, id: \.self) { tag in
                Button {
                    if values.contains(tag) { values.removeAll { $0 == tag } } else { values.append(tag) }
                } label: {
                    if values.contains(tag) { Label(tag, systemImage: "checkmark") } else { Text(tag) }
                }
            }
        } label: {
            Text(values.isEmpty ? "Выберите наборы…" : values.joined(separator: ", "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(values.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderedButton)
    }

    private var knownTags: [String] {
        var tags = state.profileConfig.map(ConfigBuilder.profileRuleSetTags) ?? []
        for source in state.settings.routing.ruleSets where source.enabled && !tags.contains(source.tag) && !source.tag.isEmpty {
            tags.append(source.tag)
        }
        return tags
    }
}

struct TargetPicker: View {
    @EnvironmentObject var state: AppState
    @Binding var target: RouteTarget
    let allowBlock: Bool

    var body: some View {
        Picker("", selection: $target) {
            Text(RouteTarget.proxy.title).tag(RouteTarget.proxy)
            Text(RouteTarget.direct.title).tag(RouteTarget.direct)
            if allowBlock { Text(RouteTarget.block.title).tag(RouteTarget.block) }
            let tags = state.profileConfig.map(ConfigBuilder.routableOutboundTags) ?? []
            if !tags.isEmpty {
                Divider()
                ForEach(tags, id: \.self) { tag in Text(tag).tag(RouteTarget.outbound(tag)) }
            }
            if case .outbound(let tag) = target, !tags.contains(tag) {
                Text("\(tag) (нет в профиле)").tag(target)
            }
        }
        .labelsHidden()
    }
}

/// Remote rule-sets the editor can reference beyond the profile's own.
struct RuleSetsCard: View {
    @EnvironmentObject var state: AppState
    @Binding var ruleSets: [RuleSetSource]
    @State private var tag = ""
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "shippingbox", title: "Наборы правил")
            let profileTags = state.profileConfig.map(ConfigBuilder.profileRuleSetTags) ?? []
            if !profileTags.isEmpty {
                Text("Из профиля: " + profileTags.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($ruleSets) { $source in
                HStack(spacing: 6) {
                    Toggle("", isOn: $source.enabled).toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.tag).font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(source.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button { ruleSets.removeAll { $0.id == source.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("тег, например geosite-ru", text: $tag)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            TextField("URL .srs или .json", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Spacer()
                Button("Добавить набор") {
                    let cleanTag = tag.trimmingCharacters(in: .whitespaces)
                    let cleanURL = url.trimmingCharacters(in: .whitespaces)
                    guard !cleanTag.isEmpty, URL(string: cleanURL)?.scheme != nil else { return }
                    let format = cleanURL.lowercased().hasSuffix(".json") ? "source" : "binary"
                    ruleSets.append(RuleSetSource(tag: cleanTag, url: cleanURL, format: format))
                    tag = ""
                    url = ""
                }
                .disabled(tag.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: url)?.scheme == nil)
            }
            Text("Скачиваются ядром напрямую и обновляются раз в сутки.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}
