import SwiftUI
import AppKit

struct LogsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var logStore: LogStore
    @State private var query = ""
    @State private var level = "all"
    @State private var follow = true

    private let levels = ["all", "debug", "info", "warning", "error"]

    private var rows: [LogLine] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return logStore.lines.filter { line in
            (level == "all" || line.level.hasPrefix(level.prefix(4)))
                && (needle.isEmpty || line.text.lowercased().contains(needle))
        }
    }

    var body: some View {
        let visible = rows
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Логи") {
                Picker("", selection: $level) {
                    ForEach(levels, id: \.self) { item in
                        Text(item == "all" ? "Все уровни" : item).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Поиск", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Toggle("Следить", isOn: $follow)
                    .toggleStyle(.checkbox)
                Button {
                    NSWorkspace.shared.open(Paths.lxdLog(root: state.settings.tunEnabled))
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Открыть журнал демона lxd (lxd.log)")
                Button {
                    logStore.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Очистить")
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 10)

            if visible.isEmpty {
                EmptyHint(icon: "doc.text", text: state.isRunning ? "Записей пока нет." : "Лог ядра появится после подключения.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(visible) { line in
                                LogRow(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                    .onChange(of: logStore.lines.count) { _, _ in
                        if follow, let last = visible.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
            Text(line.level.uppercased().prefix(4))
                .foregroundStyle(color)
                .frame(width: 38, alignment: .leading)
            Text(line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var color: Color {
        switch line.level {
        case "error", "fatal", "panic": return .red
        case "warning", "warn": return .orange
        case "debug", "trace": return .secondary
        default: return .green
        }
    }
}
