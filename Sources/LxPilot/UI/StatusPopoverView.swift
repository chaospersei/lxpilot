import Charts
import SwiftUI

/// What the status item shows on hover: the last five minutes of traffic and the node in use.
struct StatusPopoverView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var live: LiveStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Последние 5 минут")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Label(formatSpeed(live.upSpeed), systemImage: "arrow.up").foregroundStyle(.orange)
                Label(formatSpeed(live.downSpeed), systemImage: "arrow.down").foregroundStyle(state.accent)
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            chart
                .frame(height: 120)

            Divider()

            controls

            Divider()

            if state.isRunning, let node = state.currentNode {
                nodeCard(node)
                if state.settings.popoverConnections {
                    Divider()
                    connectionsSection
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.gray).frame(width: 8, height: 8)
                        Text("Ядро остановлено")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    if let planned = state.plannedNode {
                        row("Подключится к", planned.tag)
                        row("Протокол", planned.protocolText)
                        row("Сервер", planned.serverText)
                    } else {
                        Text(state.currentProfile == nil ? "Профиль не выбран" : "В профиле нет узлов")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var chart: some View {
        let count = LiveStats.longCount
        return Chart {
            ForEach(Array(live.longHistory.enumerated()), id: \.element.id) { index, sample in
                AreaMark(x: .value("t", index), y: .value("Загрузка", sample.down))
                    .foregroundStyle(LinearGradient(colors: [state.accent.opacity(0.35), state.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("Загрузка", sample.down), series: .value("s", "down"))
                    .foregroundStyle(state.accent)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("t", index), y: .value("Отдача", sample.up), series: .value("s", "up"))
                    .foregroundStyle(Color.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...(count - 1))
        .chartXAxis {
            AxisMarks(values: [0, 60, 120, 180, 240, count - 1]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let index = value.as(Int.self) {
                        let minutesAgo = Int((Double(count - 1 - index) / 60).rounded())
                        Text(minutesAgo == 0 ? "сейчас" : "−\(minutesAgo) мин")
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(formatSpeed(number)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    /// Connect / disconnect and the routing mode, so the common actions need no window.
    private var controls: some View {
        HStack(spacing: 12) {
            // The same glass start/stop as the window's big button, shrunk to a 30 pt disc.
            Button {
                Task { await state.toggle() }
            } label: {
                Group {
                    if state.isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .foregroundStyle(Color.white)
                .frame(width: 30, height: 30)
                .glassEffect(.regular.tint(state.isRunning ? Color.secondary : state.accent).interactive(), in: .circle)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            .help(state.isRunning ? "Отключиться" : "Подключиться")

            if state.isRunning, !state.modeList.isEmpty {
                Text("Режим")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // The getter can run after the list emptied on disconnect: never subscript it.
                Picker("", selection: Binding(
                    get: { state.modeList.first { $0.lowercased() == state.mode.lowercased() } ?? state.modeList.first ?? "" },
                    set: { mode in Task { await state.setMode(mode) } })) {
                    ForEach(state.modeList, id: \.self) { Text(modeTitle($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 200)
            }
            Spacer(minLength: 0)
        }
    }

    private func nodeCard(_ node: CurrentNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(lampColor).frame(width: 8, height: 8)
                Text(node.tag)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let started = state.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(formatDuration(context.date.timeIntervalSince(started)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            row("Протокол", node.protocolText)
            row("Сервер", node.serverText)
            row("Внешний IP", ipText)
            row("Задержка", latencyText)
            row("Режим", modeTitle(state.mode.isEmpty ? "rule" : state.mode))
            row("Передано", "↑ \(formatBytes(live.upTotal)) · ↓ \(formatBytes(live.downTotal))")
            row("CPU · RAM", live.residentBytes > 0
                ? String(format: "%.1f %% · %@", live.cpuPercent, formatBytes(live.residentBytes))
                : "…")
            if live.connectionCount > 0 {
                row("Соединений", "\(live.connectionCount)")
            }
        }
    }

    /// Only what goes through a proxy: `chains[0]` is the outbound that carries the connection.
    private var proxiedConnections: [ClashConnection] {
        let skip = state.nonProxyOutboundTags
        return live.connections.filter { connection in
            guard let exit = connection.chains?.first else { return true }
            return !skip.contains(exit)
        }
    }

    private var topConnections: [ClashConnection] {
        let rates = live.connectionRates
        let sorted: [ClashConnection]
        switch state.settings.popoverSort {
        case .speed:
            sorted = proxiedConnections.sorted { (rates[$0.id] ?? 0, $0.totalBytes) > (rates[$1.id] ?? 0, $1.totalBytes) }
        case .duration:
            sorted = proxiedConnections.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        case .volume:
            sorted = proxiedConnections.sorted { $0.totalBytes > $1.totalBytes }
        }
        return Array(sorted.prefix(5))
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Через прокси · \(proxiedConnections.count) из \(live.connectionCount)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: $state.settings.popoverSort) {
                    ForEach(PopoverSort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 170)
            }
            if topConnections.isEmpty {
                Text("Нет соединений через прокси")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("Адрес").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Скорость").frame(width: 74, alignment: .trailing)
                    Text("Время").frame(width: 56, alignment: .trailing)
                    Text("Объём").frame(width: 64, alignment: .trailing)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                ForEach(topConnections) { connection in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 8) {
                            Text(connection.hostText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(formatSpeed(live.connectionRates[connection.id] ?? 0))
                                .frame(width: 74, alignment: .trailing)
                            Text(connection.startDate.map { formatDuration(context.date.timeIntervalSince($0)) } ?? "—")
                                .frame(width: 56, alignment: .trailing)
                            Text(formatBytes(connection.totalBytes))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var lampColor: Color {
        guard let probe = state.proxyProbe else { return .orange }
        guard let ms = probe.latencyMs else { return .red }
        return ms <= 800 ? .green : .red
    }

    private var ipText: String {
        guard let info = state.ipInfo, let ip = info.ip else { return state.ipLoading ? "…" : "—" }
        return [ip, info.country_code].compactMap { $0 }.joined(separator: " · ")
    }

    private var latencyText: String {
        guard let probe = state.proxyProbe else { return state.probing ? "…" : "—" }
        if let ms = probe.latencyMs { return "\(ms) мс · HTTPS" }
        return probe.error ?? "нет ответа"
    }
}
