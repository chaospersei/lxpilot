import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var live: LiveStats
    @State private var query = ""

    private var rows: [ClashConnection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return live.connections }
        return live.connections.filter { item in
            item.hostText.lowercased().contains(needle)
                || item.chainText.lowercased().contains(needle)
                || item.ruleText.lowercased().contains(needle)
                || item.processText.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Соединения") {
                TextField("Поиск", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    Task { await state.closeAllConnections() }
                } label: {
                    Label("Закрыть все", systemImage: "xmark.circle")
                }
                .disabled(!state.isRunning || live.connections.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 10)

            if !state.isRunning {
                EmptyHint(icon: "arrow.left.arrow.right", text: "Активные соединения появятся после подключения.")
            } else {
                Table(rows) {
                    TableColumn("Адрес") { (item: ClashConnection) in
                        Text(item.hostText)
                            .lineLimit(1)
                            .help(item.hostText)
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Сеть") { (item: ClashConnection) in
                        Text((item.metadata.network ?? "").uppercased())
                            .foregroundStyle(.secondary)
                    }
                    .width(46)
                    TableColumn("Процесс") { (item: ClashConnection) in
                        Text(item.processText)
                            .lineLimit(1)
                    }
                    .width(min: 70, ideal: 110)
                    TableColumn("Цепочка") { (item: ClashConnection) in
                        Text(item.chainText)
                            .lineLimit(1)
                            .help(item.chainText)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("Правило") { (item: ClashConnection) in
                        Text(item.ruleText)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(item.ruleText)
                    }
                    .width(min: 100, ideal: 170)
                    TableColumn("↓ / ↑") { (item: ClashConnection) in
                        Text("\(formatBytes(item.download ?? 0)) / \(formatBytes(item.upload ?? 0))")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("") { (item: ClashConnection) in
                        Button {
                            Task { await state.closeConnection(item.id) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help("Закрыть соединение")
                    }
                    .width(28)
                }
            }
        }
    }
}
