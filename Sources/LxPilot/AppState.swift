import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Persistent
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { persistSettings() } }
    }
    @Published var profiles: [Profile] = []

    // Navigation / messages
    @Published var page: Page = .dashboard
    @Published var alert: String?

    // Core
    @Published var coreState: CoreState = .stopped
    @Published var coreVersion = ""
    @Published var coreInstalled = false
    @Published var installing = false
    @Published var installStatus = ""
    @Published var startedAt: Date?

    // Live data
    @Published var groups: [ProxyGroup] = []
    @Published var proxyTypes: [String: String] = [:]
    @Published var delays: [String: Int] = [:]
    @Published var testingGroups: Set<String> = []
    @Published var connections: [ClashConnection] = []
    @Published var upSpeed: Double = 0
    @Published var downSpeed: Double = 0
    @Published var upTotal: Int64 = 0
    @Published var downTotal: Int64 = 0
    @Published var memory: Int64 = 0
    @Published var speedHistory: [SpeedSample] = AppState.emptyHistory()
    @Published var logs: [LogLine] = []
    @Published var mode = ""
    @Published var modeList: [String] = []
    @Published var ipInfo: IPInfo?
    @Published var ipLoading = false

    let core: CoreManager

    private var runningSettings: AppSettings?
    private var pollTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var pollFailures = 0
    private var lastUp: Int64 = -1
    private var lastDown: Int64 = -1
    private var lastPoll = Date()
    private var sampleCounter = 60
    private var logCounter = 0
    private var bootstrapped = false

    private static let proxyDirtyKey = "systemProxyDirty"

    private init() {
        core = CoreManager()
        settings = AppState.loadSettings()
        profiles = AppState.loadProfiles()
        coreInstalled = core.binaryExists
        core.onUnexpectedExit = { [weak self] message in self?.coreDied(message) }
    }

    // MARK: - Derived

    var accent: Color { settings.accent.color }
    var isRunning: Bool { coreState == .running }
    var isBusy: Bool { coreState == .starting || coreState == .stopping }
    var currentProfile: Profile? { profiles.first { $0.id == settings.selectedProfileID } }
    var needsRestart: Bool {
        guard isRunning, let running = runningSettings else { return false }
        return running.runtimeKey != settings.runtimeKey
    }
    private var clash: ClashAPI {
        let source = runningSettings ?? settings
        return ClashAPI(port: source.clashPort, secret: source.clashSecret)
    }

    // MARK: - Launch / quit

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        // A previous run that crashed may have left the system proxy pointing at a dead port.
        if UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey) {
            _ = await Task.detached { SystemProxy.disable() }.value
            UserDefaults.standard.set(false, forKey: AppState.proxyDirtyKey)
        }
        await refreshVersion()
        if settings.autoConnect, coreInstalled, currentProfile != nil {
            await start()
        }
    }

    func shutdownSync() {
        pollTask?.cancel()
        logTask?.cancel()
        core.stopSync()
        if UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey) {
            SystemProxy.disable()
            UserDefaults.standard.set(false, forKey: AppState.proxyDirtyKey)
        }
    }

    // MARK: - Core lifecycle

    func toggle() async {
        switch coreState {
        case .running: await stop()
        case .stopped, .failed: await start()
        default: break
        }
    }

    func start() async {
        switch coreState {
        case .stopped, .failed: break
        default: return
        }
        guard core.binaryExists else {
            alert = "Ядро sing-box-lx не установлено. Скачайте его в разделе «Инструменты»."
            page = .tools
            return
        }
        guard let profile = currentProfile else {
            alert = "Сначала добавьте и выберите профиль."
            page = .profiles
            return
        }
        coreState = .starting
        let snapshot = settings
        do {
            let config = try buildConfig(profile: profile, settings: snapshot)
            try await core.start(config: config, settings: snapshot)
            runningSettings = snapshot
            coreState = .running
            startedAt = Date()
            if snapshot.systemProxyEnabled { await applySystemProxy(true) }
            beginMonitoring()
            Task { await refreshIP() }
        } catch {
            coreState = .failed(error.localizedDescription)
            alert = error.localizedDescription
        }
    }

    func stop() async {
        if case .failed = coreState {
            coreState = .stopped
            return
        }
        guard coreState == .running else { return }
        coreState = .stopping
        endMonitoring()
        await applySystemProxy(false)
        await core.stop()
        runningSettings = nil
        coreState = .stopped
    }

    func restart() async {
        if isRunning { await stop() }
        await start()
    }

    /// Pushes the current profile + settings to a running core.
    func reload() async {
        guard isRunning, let profile = currentProfile, let running = runningSettings else { return }
        var next = settings
        // Ports/engine/privilege are fixed for the lifetime of the process.
        next.tunEnabled = running.tunEnabled
        if running.engine == .lxd, next.runtimeKey == running.runtimeKey {
            do {
                let config = try buildConfig(profile: profile, settings: next)
                try await core.apply(config: config)
                runningSettings = next
                delays = [:]
                await refreshProxies()
                await refreshMode()
            } catch {
                alert = error.localizedDescription
            }
        } else {
            await restart()
        }
    }

    private func coreDied(_ message: String) {
        guard coreState == .running else { return }
        endMonitoring()
        runningSettings = nil
        coreState = .failed(message)
        alert = message
        Task { await applySystemProxy(false) }
    }

    private func buildConfig(profile: Profile, settings: AppSettings) throws -> Data {
        guard let text = try? String(contentsOf: profile.fileURL, encoding: .utf8),
              let object = ConfigBuilder.parseJSON(text) else {
            throw AppError("Не удалось прочитать профиль «\(profile.name)» — файл отсутствует или содержит некорректный JSON.")
        }
        return try ConfigBuilder.serialize(ConfigBuilder.overlay(object, settings: settings))
    }

    // MARK: - Dashboard switches

    func setTun(_ enabled: Bool) async {
        guard settings.tunEnabled != enabled else { return }
        settings.tunEnabled = enabled
        if isRunning { await restart() }      // privilege level changes → the process must be relaunched
    }

    func setSystemProxy(_ enabled: Bool) async {
        guard settings.systemProxyEnabled != enabled else { return }
        settings.systemProxyEnabled = enabled
        if isRunning { await applySystemProxy(enabled) }
    }

    private func applySystemProxy(_ enabled: Bool) async {
        let dirty = UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey)
        if !enabled && !dirty { return }
        let port = (runningSettings ?? settings).mixedPort
        let bypass = settings.bypassDomains
        let failure = await Task.detached { () -> String? in
            enabled ? SystemProxy.enable(port: port, bypass: bypass) : SystemProxy.disable()
        }.value
        UserDefaults.standard.set(enabled, forKey: AppState.proxyDirtyKey)
        if let failure { alert = failure }
    }

    func setMode(_ newMode: String) async {
        guard isRunning else { return }
        do {
            try await clash.setMode(newMode)
            mode = newMode
        } catch {
            alert = error.localizedDescription
        }
    }

    // MARK: - Monitoring

    private func beginMonitoring() {
        endMonitoring()
        pollFailures = 0
        lastUp = -1
        lastDown = -1
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(tick: tick)
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        logTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    for try await entry in self.clash.logLines(level: self.settings.logLevel) {
                        self.appendLog(level: entry.type, text: entry.payload)
                    }
                } catch {
                    // The stream drops whenever the core reloads; reconnect below.
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func endMonitoring() {
        pollTask?.cancel()
        logTask?.cancel()
        pollTask = nil
        logTask = nil
        startedAt = nil
        groups = []
        connections = []
        upSpeed = 0
        downSpeed = 0
        memory = 0
        mode = ""
        modeList = []
        testingGroups = []
        speedHistory = AppState.emptyHistory()
    }

    private func pollOnce(tick: Int) async {
        guard isRunning else { return }
        do {
            let snapshot = try await clash.connections()
            let now = Date()
            let elapsed = max(now.timeIntervalSince(lastPoll), 0.2)
            lastPoll = now
            if lastUp >= 0 {
                upSpeed = Double(max(snapshot.uploadTotal - lastUp, 0)) / elapsed
                downSpeed = Double(max(snapshot.downloadTotal - lastDown, 0)) / elapsed
            }
            lastUp = snapshot.uploadTotal
            lastDown = snapshot.downloadTotal
            upTotal = snapshot.uploadTotal
            downTotal = snapshot.downloadTotal
            memory = snapshot.memory ?? 0
            connections = snapshot.connections ?? []
            sampleCounter += 1
            speedHistory.append(SpeedSample(id: sampleCounter, up: upSpeed, down: downSpeed))
            if speedHistory.count > 60 { speedHistory.removeFirst(speedHistory.count - 60) }
            pollFailures = 0
        } catch {
            pollFailures += 1
            // A root core cannot report its own exit to us, so repeated silence means it is gone.
            if pollFailures >= 6 {
                coreDied("Ядро перестало отвечать.")
                return
            }
        }
        if tick % 3 == 0 {
            await refreshProxies()
            await refreshMode()
        }
    }

    func refreshProxies() async {
        guard isRunning, let response = try? await clash.proxies() else { return }
        var types: [String: String] = [:]
        var newDelays = delays
        for (name, info) in response.proxies {
            types[name] = info.type
            if let last = info.history?.last?.delay { newDelays[name] = last }
        }
        let order = response.proxies["GLOBAL"]?.all ?? []
        var position: [String: Int] = [:]
        for (index, name) in order.enumerated() { position[name] = index }
        var found: [ProxyGroup] = []
        for (name, info) in response.proxies {
            guard let members = info.all, name != "GLOBAL" else { continue }
            found.append(ProxyGroup(name: name, type: info.type, now: info.now ?? "", all: members))
        }
        found.sort { a, b in
            let pa = position[a.name] ?? Int.max
            let pb = position[b.name] ?? Int.max
            return pa == pb ? a.name < b.name : pa < pb
        }
        if found != groups { groups = found }
        if types != proxyTypes { proxyTypes = types }
        if newDelays != delays { delays = newDelays }
    }

    private func refreshMode() async {
        guard isRunning, let config = try? await clash.config() else { return }
        let newMode = config.mode ?? ""
        let list = config.modeList ?? []
        if newMode != mode { mode = newMode }
        if list != modeList { modeList = list }
    }

    private func appendLog(level: String, text: String) {
        logCounter += 1
        logs.append(LogLine(id: logCounter, time: Date(), level: level.lowercased(), text: stripANSI(text)))
        if logs.count > 2000 { logs.removeFirst(logs.count - 1500) }
    }

    func clearLogs() { logs = [] }

    // MARK: - Proxies

    func select(group: ProxyGroup, proxy: String) async {
        guard group.isSelectable, group.now != proxy else { return }
        do {
            try await clash.select(group: group.name, proxy: proxy)
            if let index = groups.firstIndex(where: { $0.name == group.name }) {
                groups[index].now = proxy
            }
        } catch {
            alert = error.localizedDescription
        }
    }

    func test(group: ProxyGroup) async {
        guard isRunning, !testingGroups.contains(group.name) else { return }
        testingGroups.insert(group.name)
        defer { testingGroups.remove(group.name) }
        let url = settings.testURL
        do {
            let result = try await clash.groupDelay(group.name, url: url)
            var updated = delays
            for member in group.all { updated[member] = result[member] ?? 0 }
            delays = updated
        } catch {
            // Older cores have no /group endpoint: fall back to testing members one by one.
            let api = clash
            let members = group.all
            let results = await withTaskGroup(of: (String, Int).self, returning: [String: Int].self) { tasks in
                for member in members {
                    tasks.addTask {
                        let delay = (try? await api.proxyDelay(member, url: url)) ?? 0
                        return (member, delay)
                    }
                }
                var collected: [String: Int] = [:]
                for await (member, delay) in tasks { collected[member] = delay }
                return collected
            }
            var updated = delays
            for (member, delay) in results { updated[member] = delay }
            delays = updated
        }
        await refreshProxies()
    }

    func closeConnection(_ id: String) async {
        try? await clash.closeConnection(id)
    }

    func closeAllConnections() async {
        try? await clash.closeAllConnections()
    }

    // MARK: - Network detection

    func refreshIP() async {
        guard isRunning else { return }
        ipLoading = true
        defer { ipLoading = false }
        // Ask through our own mixed inbound so the answer is the exit IP regardless of TUN / system proxy state.
        let port = (runningSettings ?? settings).mixedPort
        let proxy: [AnyHashable: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxy
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "https://ipwho.is/"),
              let (data, _) = try? await session.data(from: url),
              let info = try? JSONDecoder().decode(IPInfo.self, from: data), info.ip != nil else {
            ipInfo = nil
            return
        }
        ipInfo = info
    }

    // MARK: - Profiles

    func addProfile(name: String, url: String?, text: String?) async throws {
        var source = text ?? ""
        var info = SubscriptionInfo()
        let cleanURL = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanURL, !cleanURL.isEmpty {
            let fetched = try await ProfileImporter.fetch(cleanURL)
            source = fetched.text
            info = fetched.info
        }
        let converted = try ProfileImporter.convert(source, testURL: settings.testURL)
        var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = info.title ?? "" }
        if title.isEmpty, let cleanURL, let host = URL(string: cleanURL)?.host { title = host }
        if title.isEmpty { title = "Профиль \(profiles.count + 1)" }

        var profile = Profile(name: title)
        profile.url = (cleanURL?.isEmpty == false) ? cleanURL : nil
        profile.nodeCount = converted.nodeCount
        profile.upload = info.upload
        profile.download = info.download
        profile.total = info.total
        profile.expire = info.expire
        try converted.config.write(to: profile.fileURL, options: .atomic)
        profiles.append(profile)
        persistProfiles()
        if settings.selectedProfileID == nil { settings.selectedProfileID = profile.id }
    }

    func updateProfile(_ profile: Profile) async {
        guard let url = profile.url, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        do {
            let fetched = try await ProfileImporter.fetch(url)
            let converted = try ProfileImporter.convert(fetched.text, testURL: settings.testURL)
            try converted.config.write(to: profile.fileURL, options: .atomic)
            var updated = profiles[index]
            updated.updatedAt = Date()
            updated.nodeCount = converted.nodeCount
            updated.upload = fetched.info.upload
            updated.download = fetched.info.download
            updated.total = fetched.info.total
            updated.expire = fetched.info.expire
            profiles[index] = updated
            persistProfiles()
            if settings.selectedProfileID == profile.id { await reload() }
        } catch {
            alert = "Не удалось обновить «\(profile.name)»: \(error.localizedDescription)"
        }
    }

    func selectProfile(_ profile: Profile) async {
        guard settings.selectedProfileID != profile.id else { return }
        settings.selectedProfileID = profile.id
        await reload()
    }

    func deleteProfile(_ profile: Profile) {
        guard !(isRunning && settings.selectedProfileID == profile.id) else {
            alert = "Этот профиль сейчас используется. Отключитесь или выберите другой профиль."
            return
        }
        try? FileManager.default.removeItem(at: profile.fileURL)
        profiles.removeAll { $0.id == profile.id }
        if settings.selectedProfileID == profile.id { settings.selectedProfileID = profiles.first?.id }
        persistProfiles()
    }

    // MARK: - Core binary

    func refreshVersion() async {
        coreInstalled = core.binaryExists
        coreVersion = await core.version()
    }

    func installCore() async {
        guard coreState == .stopped else {
            alert = "Отключитесь перед обновлением ядра."
            return
        }
        installing = true
        defer { installing = false }
        do {
            let tag = try await CoreInstaller.installLatest { [weak self] text in self?.installStatus = text }
            installStatus = "Установлено: \(tag)"
            await refreshVersion()
        } catch {
            installStatus = ""
            alert = "Не удалось установить ядро: \(error.localizedDescription)"
        }
    }

    func chooseCoreBinary() async {
        guard coreState == .stopped else {
            alert = "Отключитесь перед заменой ядра."
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Выберите исполняемый файл sing-box (сборка sing-box-lx для macOS)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CoreInstaller.install(from: url)
            installStatus = ""
            await refreshVersion()
            if coreVersion.isEmpty { alert = "Файл скопирован, но не запускается как sing-box (команда version не ответила)." }
        } catch {
            alert = "Не удалось установить выбранный файл: \(error.localizedDescription)"
        }
    }

    // MARK: - Persistence

    private static func emptyHistory() -> [SpeedSample] {
        (0..<60).map { SpeedSample(id: $0, up: 0, down: 0) }
    }

    private static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: Paths.settingsFile),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            let fresh = AppSettings()
            if let data = try? JSONEncoder().encode(fresh) { try? data.write(to: Paths.settingsFile, options: .atomic) }
            return fresh
        }
        return decoded
    }

    private static func loadProfiles() -> [Profile] {
        guard let data = try? Data(contentsOf: Paths.profilesIndex),
              let decoded = try? JSONDecoder().decode([Profile].self, from: data) else { return [] }
        return decoded
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: Paths.settingsFile, options: .atomic)
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: Paths.profilesIndex, options: .atomic)
    }
}
