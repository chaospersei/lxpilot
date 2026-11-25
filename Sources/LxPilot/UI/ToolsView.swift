import SwiftUI
import AppKit
import ServiceManagement

struct ToolsView: View {
    @EnvironmentObject var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    @State private var bypassText = ""

    private let portFormat = IntegerFormatStyle<Int>().grouping(.never)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader("Инструменты") {
                if state.needsRestart {
                    Button {
                        Task { await state.restart() }
                    } label: {
                        Label("Перезапустить ядро, чтобы применить", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 42)
            .padding(.bottom, 4)

            Form {
                coreSection
                serviceSection
                networkSection
                appSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .task { await state.refreshServiceStatus() }
        }
    }

    // MARK: - Sections

    private var coreSection: some View {
        Section("Ядро sing-box-lx") {
            LabeledContent("Версия") {
                Text(state.coreVersion.isEmpty ? "не установлено" : state.coreVersion)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            LabeledContent("Файл") {
                HStack(spacing: 8) {
                    if state.installing { ProgressView().controlSize(.small) }
                    if !state.installStatus.isEmpty {
                        Text(state.installStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Скачать последний релиз") {
                        Task { await state.installCore() }
                    }
                    .disabled(state.installing)
                    Button("Выбрать файл…") {
                        Task { await state.chooseCoreBinary() }
                    }
                    .disabled(state.installing)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.binDir])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Показать папку ядра")
                }
            }
            Picker("Движок", selection: $state.settings.engine) {
                ForEach(Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            Picker("Уровень логов", selection: $state.settings.logLevel) {
                ForEach(["debug", "info", "warn", "error"], id: \.self) { level in
                    Text(level).tag(level)
                }
            }
            Text("Релизы берутся с github.com/Leadaxe/sing-box-lx и сверяются с SHA256SUMS. Для XHTTP, AmneziaWG и lxd нужна именно сборка lx.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serviceSection: some View {
        Section("Системная служба (TUN без пароля)") {
            LabeledContent("Служба \(SystemService.label)") {
                Text(state.serviceStatus.title)
                    .foregroundStyle(state.serviceStatus == .running ? Color.green : Color.secondary)
            }
            LabeledContent("Сопряжение") {
                Text(state.settings.servicePaired ? "есть · \(state.settings.serviceAddress)" : "нет")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Toggle("Подключаться через системную службу", isOn: Binding(
                get: { state.settings.useSystemService },
                set: { value in Task { await state.setUseSystemService(value) } }))
                .disabled(!state.settings.servicePaired || state.serviceBusy)
            Toggle("Оставлять VPN при выходе из приложения", isOn: $state.settings.keepVPNOnQuit)
                .disabled(!state.settings.useSystemService)
            HStack(spacing: 10) {
                Button(state.serviceStatus.isInstalled ? "Переустановить службу…" : "Установить службу…") {
                    Task { await state.installService() }
                }
                Button("Сопряжение заново…") { Task { await state.pairService() } }
                    .disabled(!state.serviceStatus.isInstalled)
                Button("Удалить службу…") { Task { await state.uninstallService() } }
                    .disabled(!state.serviceStatus.isInstalled)
                if state.serviceBusy { ProgressView().controlSize(.small) }
            }
            .disabled(state.serviceBusy || state.isRunning || !state.coreInstalled)
            Text("С включённым «Оставлять VPN» ядро и системный прокси переживают выход из LxPilot, а при следующем запуске приложение подхватывает работающее ядро без перезапуска. Ядро ставится как LaunchDaemon с правами root (\(SystemService.stateDir)); пароль нужен один раз при установке, сопряжении и обновлении ядра. Приложение ходит к службе по mTLS своим сертификатом (папка service/). Служба общая с singbox-launcher: если она уже установлена, достаточно сопряжения.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        Section("Сеть") {
            Toggle("Управлять входящими (mixed / TUN) автоматически", isOn: $state.settings.manageInbounds)
            Toggle("Добавлять селектор узлов, если в профиле нет групп", isOn: Binding(
                get: { state.settings.autoSelector },
                set: { value in Task { await state.setAutoSelector(value) } }))
            LabeledContent("Порт mixed-прокси") {
                TextField("", value: $state.settings.mixedPort, format: portFormat)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            Toggle("Разрешить подключения из локальной сети", isOn: $state.settings.allowLAN)
            Picker("Стек TUN", selection: $state.settings.tunStack) {
                ForEach(["mixed", "system", "gvisor"], id: \.self) { stack in
                    Text(stack).tag(stack)
                }
            }
            LabeledContent("Порт Clash API") {
                TextField("", value: $state.settings.clashPort, format: portFormat)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Порт демона lxd") {
                TextField("", value: $state.settings.lxdPort, format: portFormat)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("URL проверки задержки") {
                TextField("", text: $state.settings.testURL)
                    .frame(width: 320)
            }
            LabeledContent("Исключения системного прокси") {
                TextField("", text: $bypassText)
                    .frame(width: 320)
                    .onAppear { bypassText = state.settings.bypassDomains.joined(separator: ", ") }
                    .onChange(of: bypassText) { _, value in
                        state.settings.bypassDomains = value
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
            }
            Text("Clash API и lxd слушают только 127.0.0.1 и закрыты случайными секретами. Если автоуправление входящими выключено, inbounds берутся из профиля как есть.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appSection: some View {
        Section("Приложение") {
            Toggle("Подключаться при запуске", isOn: $state.settings.autoConnect)
            Toggle("Запускать при входе в систему", isOn: Binding(
                get: { launchAtLogin },
                set: { value in setLaunchAtLogin(value) }))
            Toggle("Поповер с графиком при наведении на значок", isOn: $state.settings.hoverPopover)
            Toggle("Показывать в поповере топ-5 соединений", isOn: $state.settings.popoverConnections)
                .disabled(!state.settings.hoverPopover)
            Picker("Сортировка соединений в поповере", selection: $state.settings.popoverSort) {
                ForEach(PopoverSort.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!state.settings.hoverPopover || !state.settings.popoverConnections)
            Picker("Значок в строке меню", selection: $state.settings.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Picker("Тема", selection: $state.settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            LabeledContent("Акцентный цвет") {
                HStack(spacing: 8) {
                    ForEach(AccentChoice.allCases) { choice in
                        Circle()
                            .fill(choice.color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary, lineWidth: state.settings.accent == choice ? 2 : 0).padding(-3))
                            .onTapGesture { state.settings.accent = choice }
                    }
                }
            }
            LabeledContent("Данные приложения") {
                Button("Открыть папку") {
                    NSWorkspace.shared.open(Paths.appSupport)
                }
            }
            LabeledContent(AppInfo.version.map { "LxPilot \($0)" } ?? "LxPilot, сборка для разработки") {
                Button("О программе") { AboutWindow.show() }
            }
        }
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            state.alert = "Не удалось изменить автозапуск (работает только из собранного .app): \(error.localizedDescription)"
        }
    }
}
