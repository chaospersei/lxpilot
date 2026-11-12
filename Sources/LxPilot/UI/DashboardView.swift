import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader("Панель") {
                    if let profile = state.currentProfile {
                        Label(profile.name, systemImage: "folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if case .failed(let message) = state.coreState {
                    FailureBanner(message: message)
                }
                SpeedCard()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ModeCard()
                    TrafficCard()
                    TunCard()
                    SystemProxyCard()
                    NetworkCard()
                    CoreCard()
                }
            }
            .padding(20)
            .padding(.top, 22)
            .padding(.bottom, 80)
        }
    }
}

struct FailureBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(8)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.red.opacity(0.10)))
    }
}

struct SpeedCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                CardTitle(icon: "speedometer", title: "Скорость сети")
                Label(formatSpeed(state.upSpeed), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
                Label(formatSpeed(state.downSpeed), systemImage: "arrow.down")
                    .foregroundStyle(state.accent)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            Chart {
                ForEach(state.speedHistory) { sample in
                    AreaMark(x: .value("t", sample.id), y: .value("Загрузка", sample.down))
                        .foregroundStyle(LinearGradient(
                            colors: [state.accent.opacity(0.35), state.accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", sample.id), y: .value("Загрузка", sample.down), series: .value("s", "down"))
                        .foregroundStyle(state.accent)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("t", sample.id), y: .value("Отдача", sample.up), series: .value("s", "up"))
                        .foregroundStyle(Color.orange)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(formatSpeed(number))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .frame(height: 130)
        }
        .card()
    }
}

struct ModeCard: View {
    @EnvironmentObject var state: AppState

    private var modes: [String] {
        state.modeList.isEmpty ? ["Rule", "Global", "Direct"] : state.modeList
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "arrow.triangle.branch", title: "Режим маршрутизации")
            ForEach(modes, id: \.self) { item in
                let selected = item.lowercased() == state.mode.lowercased()
                Button {
                    Task { await state.setMode(item) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected ? state.accent : Color.secondary)
                        Text(modeTitle(item))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!state.isRunning || state.modeList.isEmpty)
            }
            if state.isRunning && state.modeList.isEmpty {
                Text("В профиле нет правил clash_mode — переключение недоступно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card()
    }
}

struct TrafficCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "chart.bar", title: "Трафик за сеанс")
            statRow("Отдано", formatBytes(state.upTotal), "arrow.up")
            statRow("Загружено", formatBytes(state.downTotal), "arrow.down")
            statRow("Соединений", "\(state.connections.count)", "link")
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card()
    }

    private func statRow(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}

struct TunCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(icon: "network", title: "TUN")
                Toggle("", isOn: Binding(
                    get: { state.settings.tunEnabled },
                    set: { value in Task { await state.setTun(value) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(state.isBusy)
            }
            Text("Весь трафик Mac через виртуальный интерфейс. Нужны права администратора: при подключении macOS спросит пароль.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card(selected: state.settings.tunEnabled)
    }
}

struct SystemProxyCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(icon: "globe", title: "Системный прокси")
                Toggle("", isOn: Binding(
                    get: { state.settings.systemProxyEnabled },
                    set: { value in Task { await state.setSystemProxy(value) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(state.isBusy)
            }
            Text("HTTP/HTTPS/SOCKS-прокси macOS указывает на 127.0.0.1:\(String(state.settings.mixedPort)). Снимается при отключении и выходе.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card(selected: state.settings.systemProxyEnabled)
    }
}

struct NetworkCard: View {
    @EnvironmentObject var state: AppState
    @State private var localIP = localIPv4() ?? "—"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardTitle(icon: "location", title: "Определение сети")
                Button {
                    localIP = localIPv4() ?? "—"
                    Task { await state.refreshIP() }
                } label: {
                    if state.ipLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!state.isRunning || state.ipLoading)
            }
            row("Внешний IP", externalText)
            row("Страна", countryText)
            row("Локальный IP", localIP)
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card()
    }

    private var externalText: String {
        guard state.isRunning else { return "—" }
        return state.ipInfo?.ip ?? (state.ipLoading ? "…" : "не определён")
    }

    private var countryText: String {
        guard state.isRunning, let info = state.ipInfo else { return "—" }
        return [info.country, info.city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }
}

struct CoreCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(icon: "cpu", title: "Ядро")
            row("Версия", state.coreVersion.isEmpty ? "не установлено" : state.coreVersion)
            row("Движок", state.settings.engine == .lxd ? "lxd" : "run")
            row("Память", state.isRunning ? formatBytes(state.memory) : "—")
        }
        .frame(minHeight: 118, alignment: .topLeading)
        .card()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
    }
}
