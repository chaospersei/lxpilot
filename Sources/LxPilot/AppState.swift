import SwiftUI
import Security
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
    @Published var page: Page = .dashboard {
        didSet { if page == .logs { logStore.flush() } }
    }
    @Published var alert: String?

    // Core
    @Published var coreState: CoreState = .stopped
    @Published var coreVersion = ""
    @Published var coreInstalled = false
    @Published var installing = false
    @Published var serviceStatus: ServiceStatus = .unknown(-1)
    @Published var serviceStatusText = ""
    @Published var serviceBusy = false
    @Published var installStatus = ""
    @Published var startedAt: Date?

    // Live data
    @Published var groups: [ProxyGroup] = []
    @Published var proxyTypes: [String: String] = [:]
    @Published var delays: [String: Int] = [:]
    @Published var testingGroups: Set<String> = []
    let live = LiveStats()
    let logStore = LogStore()
    /// False while the main window is closed, minimised or fully covered: the page content is not
    /// built at all then, and the poll skips what only the window would show.
    @Published private(set) var windowVisible = true
    /// The status item popover is open: it needs the connection list and a one-second poll.
    private(set) var popoverVisible = false
    private var lastConnectionBytes: [String: Int64] = [:]
    @Published var mode = ""
    @Published var modeList: [String] = []
    @Published var ipInfo: IPInfo?
    @Published var ipLoading = false
    @Published var proxyProbe: ProxyChecker.Result?

    // Wi-Fi rules
    @Published var currentSSID: String?
    /// The last thing a Wi-Fi rule did, with the time: shown on the "Сети" page.
    @Published var wifiNote: String?
    @Published var knownNetworks: [String] = []
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
    private var logFlushScheduled = false
    private var nextProxyRefresh = Date.distantPast
    private var nextResourceSample = Date.distantPast
    private var nextProbe = Date.distantFuture
    private var bootstrapped = false
    private let wifi = WiFiMonitor()
    private var wifiTask: Task<Void, Never>?
    /// The network whose rule was last evaluated: a rule acts on joining, not continuously, so a
    /// manual start or stop holds until the network changes.
    private var appliedSSID: String?

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

    /// The menu bar blinks red while this holds: the last start failed (or the core died), or the
    /// core runs but the latency probe through it cannot reach the test URL.
    var connectionFault: String? {
        if case .failed(let message) = coreState { return message }
        guard isRunning, let probe = proxyProbe, let error = probe.error else { return nil }
        return "Проверка соединения не прошла: \(error)"
    }
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
        if source.useSystemService {
            guard source.servicePaired, let identity = serviceIdentity(password: source.servicePassword) else { return nil }
            return LxdClient(address: source.serviceAddress, fingerprint: source.serviceFingerprint, identity: identity)
        }
        guard source.engine == .lxd else { return nil }
        return LxdClient(port: source.lxdPort, secret: source.lxdSecret)
    }
    private var cachedIdentity: (password: String, identity: SecIdentity)?
    private func serviceIdentity(password: String) -> SecIdentity? {
        if let cachedIdentity, cachedIdentity.password == password { return cachedIdentity.identity }
        guard let loaded = try? ClientIdentity.load(password: password) else { return nil }
        cachedIdentity = (password, loaded.identity)
        return loaded.identity
    }

    var currentNode: CurrentNode? {
        guard isRunning, let config = activeConfig else { return nil }
        guard let tag = ConfigBuilder.resolveExit(config, next: { tag in groups.first { $0.name == tag }?.now }) else { return nil }
        return ConfigBuilder.nodeInfo(config, tag: tag, fallbackType: proxyTypes[tag])
    }

    /// Stopped: the node the next start would use, from the profile and the current settings
    /// (groups by their `default`; the core's remembered selection is unknown until it runs).
    var plannedNode: CurrentNode? {
        guard !isRunning, let profile = currentProfile else { return nil }
        let key = "\(profile.id)|\(profile.updatedAt.timeIntervalSince1970)|\(settings.autoSelector)|\(settings.manageInbounds)"
        if let cached = plannedCache, cached.key == key { return cached.node }
        var node: CurrentNode?
        if let stored = storedProfileConfig {
            let config = ConfigBuilder.overlay(stored, settings: settings)
            node = ConfigBuilder.plannedExit(config).map { ConfigBuilder.nodeInfo(config, tag: $0) }
        }
        plannedCache = (key, node)
        return node
    }
    private var plannedCache: (key: String, node: CurrentNode?)?

    /// Tags whose traffic does not go through a proxy: direct, block and DNS outbounds of the running config.
    var nonProxyOutboundTags: Set<String> {
        guard let config = activeConfig else { return [] }
        let types: Set<String> = ["direct", "block", "dns"]
        return Set(ConfigBuilder.outboundsAndEndpoints(config)
            .filter { types.contains(($0["type"] as? String) ?? "") }
            .compactMap { $0["tag"] as? String })
    }

    // MARK: - Launch / quit

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        await refreshVersion()
        await refreshServiceStatus()
        #if DEBUG
        // The window self-test must leave the core and the system proxy alone.
        if ProcessInfo.processInfo.environment["LXPILOT_SELFTEST_WINDOW"] == "1" { return }
        #endif
        wifi.start { [weak self] in self?.networkMayHaveChanged() }
        // With rules present the network decides before auto-connect does: a "disconnect" network
        // must not see the VPN come up first. Without rules the lookup runs on the side.
        var rule: WiFiRule?
        if wifiRulesActive {
            let ssid = await WiFiMonitor.currentSSID()
            currentSSID = ssid
            appliedSSID = ssid
            rule = wifiRule(for: ssid)
        } else {
            networkMayHaveChanged()
        }
        if await adoptRunningCore() {
            if let rule, rule.action == .disconnect { await applyWiFiRule(rule) }
            return
        }
        // A previous run that crashed may have left the system proxy pointing at a dead port.
        if UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey) {
            _ = await Task.detached { SystemProxy.disable() }.value
            UserDefaults.standard.set(false, forKey: AppState.proxyDirtyKey)
        }
        guard coreInstalled, currentProfile != nil else { return }
        if let rule {
            await applyWiFiRule(rule)
        } else if settings.autoConnect {
            await start()
        }
    }

    /// Service mode: a core left running by the previous run ("keep VPN on quit", or a crash) is
    /// taken over as is — its config is the one we applied last, `runtime/config.json`.
    private func adoptRunningCore() async -> Bool {
        guard coreState == .stopped, settings.useSystemService, await core.adoptService(settings: settings) else { return false }
        runningSettings = settings
        coreState = .running
        if let text = try? String(contentsOf: Paths.runConfig, encoding: .utf8) { activeConfig = ConfigBuilder.parseJSON(text) }
        let uptime = (try? await lxd?.stats())?.coreUptimeSeconds ?? 0
        startedAt = Date().addingTimeInterval(-uptime)
        if settings.systemProxyEnabled {
            // Re-set even if the flag says it is on: the port may have changed, and it is idempotent.
            await applySystemProxy(true)
        } else if UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey) {
            await applySystemProxy(false)
        }
        beginMonitoring()
        return true
    }

    func shutdownSync() {
        pollTask?.cancel()
        logTask?.cancel()
        let keep = isRunning && settings.keepVPNOnQuit && core.viaService
        core.stopSync(keepServiceCore: keep)
        // With the core kept, the proxy stays too; the dirty flag then tells the next launch to adopt rather than clean up.
        if !keep, UserDefaults.standard.bool(forKey: AppState.proxyDirtyKey) {
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
        // Privilege is fixed for the lifetime of our own process; the service switches TUN by config.
        if !running.useSystemService { next.tunEnabled = running.tunEnabled }
        if running.hotApply, next.runtimeKey == running.runtimeKey {
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

    // MARK: - Wi-Fi rules

    /// The rule in force for a network: its own, or the default action as a rule. A switched-off
    /// rule counts as absent, so the default covers that network too. No Wi-Fi, no rule.
    func wifiRule(for ssid: String?) -> WiFiRule? {
        guard let ssid else { return nil }
        if let own = settings.wifiRules.first(where: { $0.enabled && $0.ssid == ssid }) { return own }
        return settings.wifiDefault.map { WiFiRule(ssid: ssid, action: $0) }
    }

    func hasOwnWiFiRule(_ ssid: String?) -> Bool {
        settings.wifiRules.contains { $0.enabled && $0.ssid == ssid }
    }

    private var wifiRulesActive: Bool {
        settings.wifiDefault != nil || settings.wifiRules.contains { $0.enabled }
    }

    /// Called on every hint from `WiFiMonitor`. Hints come in bursts while the Mac associates, and
    /// the name is not known until it settles, so the lookup waits a moment and the last hint wins.
    func networkMayHaveChanged() {
        wifiTask?.cancel()
        wifiTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshWiFi()
        }
    }

    /// Looks the network up and, if it is a different one than last time, applies its rule.
    func refreshWiFi() async {
        let ssid = await WiFiMonitor.currentSSID()
        if ssid != currentSSID { currentSSID = ssid }
        guard ssid != appliedSSID else { return }
        appliedSSID = ssid
        if let rule = wifiRule(for: ssid) { await applyWiFiRule(rule) }
    }

    private func applyWiFiRule(_ rule: WiFiRule) async {
        // A start or stop in flight finishes first; the rule then acts on the settled state.
        for _ in 0..<120 where isBusy { try? await Task.sleep(nanoseconds: 500_000_000) }
        let time = Date().formatted(date: .omitted, time: .shortened)
        switch rule.action {
        case .disconnect:
            guard isRunning else { return }
            await stop()
            wifiNote = "\(time) — сеть «\(rule.ssid)»: VPN отключён по правилу."
        case .connect:
            switch coreState {
            case .stopped, .failed: break
            default: return
            }
            guard coreInstalled, currentProfile != nil else { return }
            await start()
            wifiNote = isRunning ? "\(time) — сеть «\(rule.ssid)»: VPN включён по правилу."
                                 : "\(time) — сеть «\(rule.ssid)»: включить VPN по правилу не удалось."
        }
    }

    /// Stores the rules. A rule that now applies to the network the Mac is on acts at once:
    /// adding "отключать" for the current network and seeing nothing happen would read as broken.
    func setWiFiRules(_ rules: [WiFiRule]) async {
        guard settings.wifiRules != rules else { return }
        await changeWiFiSettings { $0.wifiRules = rules }
    }

    func setWiFiDefault(_ action: WiFiAction?) async {
        guard settings.wifiDefault != action else { return }
        await changeWiFiSettings { $0.wifiDefault = action }
    }

    private func changeWiFiSettings(_ change: (inout AppSettings) -> Void) async {
        let before = wifiRule(for: currentSSID)
        change(&settings)
        let after = wifiRule(for: currentSSID)
        if let after, after.action != before?.action { await applyWiFiRule(after) }
    }

    func addWiFiRule(ssid: String, action: WiFiAction = .disconnect) async {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !settings.wifiRules.contains(where: { $0.ssid == name }) else {
            alert = "Сеть «\(name)» уже есть в списке."
            return
        }
        await setWiFiRules(settings.wifiRules + [WiFiRule(ssid: name, action: action)])
    }

    func updateWiFiRule(_ rule: WiFiRule) async {
        await setWiFiRules(settings.wifiRules.map { $0.id == rule.id ? rule : $0 })
    }

    func removeWiFiRule(_ rule: WiFiRule) async {
        await setWiFiRules(settings.wifiRules.filter { $0.id != rule.id })
    }

    func loadKnownNetworks() async {
        let networks = await WiFiMonitor.knownNetworks()
        if networks != knownNetworks { knownNetworks = networks }
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
        // With TUN the whole Mac already goes through the core; a system proxy on top is redundant and
        // would outlive a crash of the root core, so it is switched off together with the toggle.
        if enabled, settings.systemProxyEnabled {
            settings.systemProxyEnabled = false
            if isRunning { await applySystemProxy(false) }
        }
        if isRunning {
            // The system service is root already: TUN is just a different config. Our own process
            // must be relaunched at the other privilege level.
            if settings.useSystemService { await reload() } else { await restart() }
        }
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
        nextProxyRefresh = .distantPast
        nextProbe = Date().addingTimeInterval(60)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: self.pollInterval)
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
        mode = ""
        modeList = []
        testingGroups = []
        live.reset()
    }

    /// Once a second normally; every five when nothing shows the numbers (window hidden, icon-only menu bar).
    private var pollInterval: UInt64 {
        !windowVisible && !popoverVisible && settings.menuBarStyle == .icon ? 5_000_000_000 : 1_000_000_000
    }

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        if visible, isRunning { Task { await pollOnce(force: true) } }
    }

    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        guard visible, isRunning else { return }
        if page == .logs { logStore.flush() }
        Task { await pollOnce(force: true) }
    }

    private func pollOnce(force: Bool = false) async {
        guard isRunning else { return }
        let showsWindow = windowVisible || popoverVisible
        let needHistory = showsWindow || settings.menuBarStyle == .speedGraph || popoverVisible
        do {
            let up: Int64
            let down: Int64
            let count: Int
            var memory: Int64?
            var list: [ClashConnection]?
            if let lxd, !showsWindow {
                // Nobody looks at the list: two totals from the daemon instead of every connection.
                let stats = try await lxd.stats()
                up = stats.uplinkTotal
                down = stats.downlinkTotal
                count = stats.connections
            } else {
                let snapshot = try await clash.connections()
                up = snapshot.uploadTotal
                down = snapshot.downloadTotal
                let items = snapshot.connections ?? []
                count = items.count
                list = items
                memory = snapshot.memory
            }
            let now = Date()
            let elapsed = max(now.timeIntervalSince(lastPoll), 0.2)
            lastPoll = now
            var upSpeed = 0.0
            var downSpeed = 0.0
            if lastUp >= 0 {
                upSpeed = Double(max(up - lastUp, 0)) / elapsed
                downSpeed = Double(max(down - lastDown, 0)) / elapsed
            }
            lastUp = up
            lastDown = down
            // Publish at display granularity: a change nobody can read must not redraw anything.
            if displayed(upSpeed) != displayed(live.upSpeed) { live.upSpeed = upSpeed }
            if displayed(downSpeed) != displayed(live.downSpeed) { live.downSpeed = downSpeed }
            if live.upTotal != up { live.upTotal = up }
            if live.downTotal != down { live.downTotal = down }
            if let memory, live.memory != memory { live.memory = memory }
            if live.connectionCount != count { live.connectionCount = count }
            if let list {
                if live.connections != list { live.connections = list }
                var seen: [String: Int64] = [:]
                var rates: [String: Double] = [:]
                for connection in list {
                    seen[connection.id] = connection.totalBytes
                    if let previous = lastConnectionBytes[connection.id] {
                        rates[connection.id] = Double(max(connection.totalBytes - previous, 0)) / elapsed
                    }
                }
                lastConnectionBytes = seen
                if live.connectionRates != rates { live.connectionRates = rates }
            }
            if needHistory { live.appendSample(up: upSpeed, down: downSpeed) }
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
        let now = Date()
        if force || now >= nextProxyRefresh {
            nextProxyRefresh = now.addingTimeInterval(3)
            await refreshProxies()
            await refreshMode()
        }
        if now >= nextProbe {
            await probeProxy()
            // A failed probe is rechecked sooner: the red menu bar should clear as soon as traffic flows again.
            nextProbe = Date().addingTimeInterval(proxyProbe?.ok == false ? 15 : 60)
        }
        if popoverVisible, force || now >= nextResourceSample {
            nextResourceSample = now.addingTimeInterval(3)
            await sampleResources()
        }
    }

    /// CPU and resident memory of this app and the core process, summed. `ps` reads any process,
    /// a root core included, which task_info from here could not.
    private func sampleResources() async {
        var pids = [ProcessInfo.processInfo.processIdentifier]
        if let corePid = await core.corePid() { pids.append(corePid) }
        let result = await Shell.run("/bin/ps", ["-o", "%cpu=,rss=", "-p", pids.map(String.init).joined(separator: ",")])
        // ps exits 1 when one pid is gone but still prints the others; use whatever came back.
        guard !result.stdout.isEmpty else { return }
        var cpu = 0.0
        var rssKB: Int64 = 0
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let c = Double(parts[0]), let r = Int64(parts[1]) else { continue }
            cpu += c
            rssKB += r
        }
        if live.cpuPercent != cpu { live.cpuPercent = cpu }
        if live.residentBytes != rssKB * 1024 { live.residentBytes = rssKB * 1024 }
    }

    private func displayed(_ speed: Double) -> String {
        formatSpeed(speed) + MenuBarRenderer.compactSpeed(speed)
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

    /// Lines are buffered and shown at most twice a second, and only while the Logs page is on screen.
    private func appendLog(level: String, text: String) {
        logStore.append(level: level, text: text)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self else { return }
            self.logFlushScheduled = false
            if self.page == .logs, self.windowVisible { self.logStore.flush() }
        }
    }

    func clearLogs() { logStore.clear() }

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

    // MARK: - System service (root daemon, mTLS)

    func refreshServiceStatus() async {
        guard coreInstalled else {
            serviceStatus = .notInstalled
            serviceStatusText = ""
            return
        }
        let (status, text) = await SystemService.status()
        serviceStatus = status
        serviceStatusText = text
    }

    /// Installs the LaunchDaemon from our core binary (one password prompt) and pairs with it.
    func installService() async {
        guard !isRunning else { alert = "Отключитесь перед установкой службы."; return }
        guard coreInstalled else { alert = "Сначала скачайте ядро в разделе «Инструменты»."; return }
        serviceBusy = true
        defer { serviceBusy = false }
        do {
            let invite = try await SystemService.install()
            try await completePairing(invite)
            alert = "Системная служба установлена и сопряжена. TUN теперь включается без запроса пароля."
        } catch {
            alert = error.localizedDescription
        }
        await refreshServiceStatus()
    }

    /// A new invite from an already installed service (ours or singbox-launcher's) and a fresh certificate.
    func pairService() async {
        guard !isRunning else { alert = "Отключитесь перед сопряжением."; return }
        serviceBusy = true
        defer { serviceBusy = false }
        do {
            let invite = try await SystemService.pair()
            try await completePairing(invite)
            alert = "Сопряжение с системной службой выполнено."
        } catch {
            alert = error.localizedDescription
        }
        await refreshServiceStatus()
    }

    func uninstallService() async {
        guard !isRunning else { alert = "Отключитесь перед удалением службы."; return }
        serviceBusy = true
        defer { serviceBusy = false }
        do {
            try await SystemService.uninstall()
            settings.useSystemService = false
            alert = "Системная служба удалена. Сопряжение сохранено на случай повторной установки."
        } catch {
            alert = error.localizedDescription
        }
        await refreshServiceStatus()
    }

    func setUseSystemService(_ enabled: Bool) async {
        guard settings.useSystemService != enabled else { return }
        if enabled, !settings.servicePaired { alert = "Сначала выполните сопряжение со службой."; return }
        settings.useSystemService = enabled
        if isRunning { await restart() }
    }

    private func completePairing(_ invite: ServiceInvite) async throws {
        // A named invite replaces the client of that name, so a fresh pair every time is fine.
        let client = try await ClientIdentity.generate(password: settings.servicePassword)
        cachedIdentity = nil
        var attempt = 0
        while true {
            do {
                _ = try await ServiceEnroll.enroll(invite: invite, name: SystemService.clientName, certificatePEM: client.certificatePEM)
                break
            } catch let error as URLError where attempt < 5 {
                // The daemon may still be coming up right after install.
                attempt += 1
                _ = error
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        settings.serviceAddress = invite.address
        settings.serviceFingerprint = invite.fingerprint
        settings.useSystemService = true
        guard let lxd, await lxd.isAlive() else {
            throw AppError("Сопряжение принято, но служба не отвечает по mTLS. Проверьте журнал \(SystemService.logPath).")
        }
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
