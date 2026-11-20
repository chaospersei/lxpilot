import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    @Published var proxyProbe: ProxyChecker.Result?
    @Published var probing = false
    /// The config the running core was given (profile + overlay), for node details the Clash API lacks.
    @Published private(set) var activeConfig: JSON?
    private var probedNode: String?
    private var autoTestedGroups: Set<String> = []
    private var routingApplyTask: Task<Void, Never>?

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
    private var lxd: LxdClient? {
        let source = runningSettings ?? settings
        guard source.engine == .lxd else { return nil }
        return LxdClient(port: source.lxdPort, secret: source.lxdSecret)
    }

    var currentNode: CurrentNode? {
        guard isRunning, let config = activeConfig, var tag = ConfigBuilder.proxyOutboundTag(config) else { return nil }
        var hops = 0
        while hops < 8, let group = groups.first(where: { $0.name == tag }), !group.now.isEmpty, group.now != tag {
            tag = group.now
            hops += 1
        }
        let outbounds = config["outbounds"] as? [JSON] ?? []
        let outbound = outbounds.first { ($0["tag"] as? String) == tag }
        let type = outbound?["type"] as? String ?? proxyTypes[tag] ?? "?"
        let tls = outbound?["tls"] as? JSON
        return CurrentNode(
            tag: tag,
            type: type,
            transport: (outbound?["transport"] as? JSON)?["type"] as? String,
            tls: tls?["enabled"] as? Bool ?? false,
            reality: ((tls?["reality"] as? JSON)?["enabled"] as? Bool) ?? false)
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
            beginMonitoring()   // the first proxy refresh triggers the IP lookup and the latency probe
        } catch {
            coreState = .failed(error.localizedDescription)
            alert = error.localizedDescription
        }
    }

    func stop() async {
        if case .failed = coreState {
            await core.stop()   // a daemon may still be up with a dead core inside
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

    /// The core stopped answering or its process exited. With lxd the daemon process usually
    /// outlives its core, so it is stopped explicitly; otherwise the next start would launch a
    /// second daemon on the same port and orphan this one.
    private func coreDied(_ message: String) {
        guard coreState == .running else { return }
        endMonitoring()
        runningSettings = nil
        coreState = .failed(message)
        alert = message
        Task {
            await applySystemProxy(false)
            await core.stop()
        }
    }

    private func buildConfig(profile: Profile, settings: AppSettings) throws -> Data {
        guard let text = try? String(contentsOf: profile.fileURL, encoding: .utf8),
              let object = ConfigBuilder.parseJSON(text) else {
            throw AppError("Не удалось прочитать профиль «\(profile.name)» — файл отсутствует или содержит некорректный JSON.")
        }
        let config = ConfigBuilder.overlay(object, settings: settings)
        activeConfig = config
        return try ConfigBuilder.serialize(config)
    }

    // MARK: - Per-app routing

    func setAutoSelector(_ enabled: Bool) async {
        guard settings.autoSelector != enabled else { return }
        settings.autoSelector = enabled
        if isRunning { await reload() }
    }

    /// Replaces the rule list and pushes it to the running core (hot apply with lxd, restart with classic).
    func setAppRules(_ rules: [AppRule]) async {
        guard settings.appRules != rules else { return }
        settings.appRules = rules
        if isRunning { await reload() }
    }

    func addAppRule(url: URL, mode: AppRouteMode = .proxy) async {
        let path = url.standardizedFileURL.path
        guard !settings.appRules.contains(where: { $0.path == path }) else {
            alert = "«\(url.deletingPathExtension().lastPathComponent)» уже есть в списке."
            return
        }
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let rule = AppRule(name: name, path: path, bundleID: bundle?.bundleIdentifier, mode: mode)
        await setAppRules(settings.appRules + [rule])
    }

    func updateAppRule(_ rule: AppRule) async {
        guard let index = settings.appRules.firstIndex(where: { $0.id == rule.id }) else { return }
        var rules = settings.appRules
        rules[index] = rule
        await setAppRules(rules)
    }

    func removeAppRule(_ rule: AppRule) async {
        await setAppRules(settings.appRules.filter { $0.id != rule.id })
    }

    /// Applications with a Dock presence; the ones already listed are skipped.
    var runningAppCandidates: [(name: String, url: URL)] {
        let listed = Set(settings.appRules.map(\.path))
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, url: URL)? in
                guard let url = app.bundleURL, let name = app.localizedName else { return nil }
                let path = url.standardizedFileURL.path
                guard !listed.contains(path), seen.insert(path).inserted, path != Bundle.main.bundleURL.path else { return nil }
                return (name, url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func chooseApp() async {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle, .unixExecutable]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { await addAppRule(url: url) }
    }

    // MARK: - Routing editor

    /// Stores the editor state at once and pushes it to the running core a moment later, so a burst
    /// of edits becomes one apply.
    func setRouting(_ routing: RoutingConfig) {
        guard settings.routing != routing else { return }
        settings.routing = routing
        routingApplyTask?.cancel()
        routingApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.isRunning else { return }
            await self.reload()
        }
    }

    /// The selected profile as JSON (the running config when connected), for pickers in the editor.
    var profileConfig: JSON? {
        if let activeConfig { return activeConfig }
        return storedProfileConfig
    }

    /// The profile file as written, without the overlay: what the "Правила профиля" list shows.
    var storedProfileConfig: JSON? {
        guard let profile = currentProfile, let text = try? String(contentsOf: profile.fileURL, encoding: .utf8) else { return nil }
        return ConfigBuilder.parseJSON(text)
    }

    /// Copies the profile's expressible rules into the editor: rules without a mode go to the common
    /// group, rules with `clash_mode` to a scenario of that name (created when missing), and a
    /// mode-only rule becomes that scenario's fallback. Rules already present are not duplicated.
    /// Afterwards the originals are dropped from the config the core gets (`replaceProfileRules`).
    func importProfileRules() {
        guard let config = storedProfileConfig else { return }
        var routing = settings.routing
        var imported = 0
        var skipped = 0

        func scenarioIndex(_ mode: String?) -> Int {
            guard let mode else { return routing.scenarios.firstIndex(where: \.isCommon) ?? 0 }
            if let i = routing.scenarios.firstIndex(where: { !$0.isCommon && $0.name.lowercased() == mode.lowercased() }) { return i }
            routing.scenarios.append(RouteScenario(name: mode))
            imported += 1     // a new scenario counts even when its rules add nothing
            return routing.scenarios.count - 1
        }

        for item in ConfigBuilder.profileRules(config) {
            switch item.converted {
            case .rule(let rule, let mode):
                let i = scenarioIndex(mode)
                let exists = routing.scenarios[i].rules.contains {
                    $0.match == rule.match && $0.values == rule.values && $0.target == rule.target
                }
                if !exists {
                    routing.scenarios[i].rules.append(rule)
                    imported += 1
                }
            case .fallback(let target, let mode):
                routing.scenarios[scenarioIndex(mode)].fallback = target
            case nil:
                if item.role == .route { skipped += 1 }
            }
        }
        routing.replaceProfileRules = true
        setRouting(routing)

        var text = imported == 0
            ? "Новых правил нет: всё выражаемое уже есть в редакторе."
            : "Импортировано \(imported) " + plural(imported, "правило", "правила", "правил") + "."
        if skipped > 0 {
            text += " \(skipped) " + plural(skipped, "правило", "правила", "правил") + " в редакторе не выражается (несколько условий, логические правила, действия lx) — " + (skipped == 1 ? "оно остаётся" : "они остаются") + " в профиле и действуют после правил редактора."
        }
        alert = text
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
        probedNode = nil
        proxyProbe = nil
        autoTestedGroups = []
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
            // The lxd daemon knows at once whether its core is gone, and why.
            if let lxd, let status = try? await lxd.status(), status.state != "started" {
                let reason = status.lastError.isEmpty ? "состояние демона: \(status.state)" : stripANSI(status.lastError)
                coreDied("Ядро остановилось внутри демона lxd (\(reason)).")
                return
            }
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
        if tick % 60 == 30 {
            await probeProxy()
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
        // A different node means a different exit IP and latency.
        if let node = currentNode?.tag, node != probedNode {
            probedNode = node
            Task {
                await probeProxy()
                await refreshIP()
            }
        }
        if newDelays != delays { delays = newDelays }
        // First sight of a group this session: measure its members once, so the page opens with numbers.
        for group in found where !autoTestedGroups.contains(group.name) {
            autoTestedGroups.insert(group.name)
            Task { await test(group: group) }
        }
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
            // Verified on 1.14.4-lx.33: a `urltest` group answers `{}` even though it did test its members,
            // so an empty map must not be read as "everyone failed".
            guard !result.isEmpty else { throw AppError("empty group delay") }
            var updated = delays
            for member in group.all { updated[member] = result[member] ?? 0 }
            delays = updated
        } catch {
            // Older cores have no /group endpoint and urltest groups return nothing: test members one by one.
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

    /// One HTTPS request to the test URL through the mixed inbound, timed end to end.
    func probeProxy() async {
        guard isRunning, !probing else { return }
        probing = true
        defer { probing = false }
        let port = (runningSettings ?? settings).mixedPort
        let result = await ProxyChecker.measure(port: port, url: settings.testURL)
        if isRunning { proxyProbe = result }
    }

    func refreshIP() async {
        guard isRunning else { return }
        ipLoading = true
        defer { ipLoading = false }
        // Ask through our own mixed inbound so the answer is the exit IP regardless of TUN / system proxy state.
        let port = (runningSettings ?? settings).mixedPort
        let session = ProxyChecker.session(port: port, timeout: 8)
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
