import SwiftUI

enum Engine: String, Codable, CaseIterable, Identifiable {
    case lxd, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lxd: return "Демон lxd — смена конфига без перезапуска"
        case .classic: return "Классический sing-box run"
        }
    }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case icon, speed, speedGraph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icon: return "Только значок"
        case .speed: return "Скорость"
        case .speedGraph: return "Скорость и графики"
        }
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case indigo, blue, teal, green, orange, pink, purple
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .indigo: return .indigo
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .purple: return .purple
        }
    }
}

/// Forced route for one application's traffic.
enum AppRouteMode: String, Codable, CaseIterable, Identifiable {
    case proxy, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .proxy: return "Через прокси"
        case .direct: return "Напрямую"
        }
    }
}

/// What joining a Wi-Fi network does to the VPN.
enum WiFiAction: String, Codable, CaseIterable, Identifiable {
    case connect, disconnect
    var id: String { rawValue }
    var title: String { title(in: .power) }
    func title(in mode: WiFiMode) -> String {
        switch (self, mode) {
        case (.connect, .power): return "Включать VPN"
        case (.disconnect, .power): return "Отключать VPN"
        case (.connect, .routing): return "Через VPN"
        case (.disconnect, .routing): return "Напрямую"
        }
    }
}

/// How the Wi-Fi rules act: by starting and stopping the core, or by rerouting a core that stays up.
enum WiFiMode: String, Codable, CaseIterable, Identifiable {
    case power, routing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .power: return "Отключать VPN"
        case .routing: return "Переключать маршрутизацию"
        }
    }
}

/// A rule for one Wi-Fi network, matched by its exact name.
struct WiFiRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var ssid: String
    var action: WiFiAction = .disconnect
    var enabled = true
}

/// An application whose connections are routed by a rule placed ahead of the profile's own rules.
struct AppRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// `/Applications/X.app` — every process inside the bundle matches — or a bare executable path.
    var path: String
    var bundleID: String?
    var mode: AppRouteMode = .proxy
    var enabled = true

    var isBundle: Bool { path.hasSuffix(".app") }
}

// MARK: - Routing editor

/// What a routing rule matches on; `key` is the sing-box rule field.
enum RouteMatch: String, Codable, CaseIterable, Identifiable {
    case domainSuffix, domainKeyword, domainFull, domainRegex, ipCIDR, ruleSet, port, sniffedProtocol
    var id: String { rawValue }

    var title: String {
        switch self {
        case .domainSuffix: return "Домен и поддомены"
        case .domainKeyword: return "Домен содержит"
        case .domainFull: return "Домен точно"
        case .domainRegex: return "Домен по regex"
        case .ipCIDR: return "IP / подсеть"
        case .ruleSet: return "Набор правил"
        case .port: return "Порт"
        case .sniffedProtocol: return "Протокол"
        }
    }

    var key: String {
        switch self {
        case .domainSuffix: return "domain_suffix"
        case .domainKeyword: return "domain_keyword"
        case .domainFull: return "domain"
        case .domainRegex: return "domain_regex"
        case .ipCIDR: return "ip_cidr"
        case .ruleSet: return "rule_set"
        case .port: return "port"
        case .sniffedProtocol: return "protocol"
        }
    }

    var placeholder: String {
        switch self {
        case .domainSuffix: return "youtube.com, googlevideo.com"
        case .domainKeyword: return "google, telegram"
        case .domainFull: return "api.openai.com"
        case .domainRegex: return "^(.+\\.)?example\\.com$"
        case .ipCIDR: return "10.0.0.0/8, 1.1.1.1"
        case .ruleSet: return "geoip-ru, geosite-ru"
        case .port: return "443, 8443"
        case .sniffedProtocol: return "tls, quic, bittorrent"
        }
    }
}

/// Where matched traffic goes. `outbound` is a tag from the profile (node or group).
enum RouteTarget: Codable, Equatable, Hashable {
    case proxy, direct, block
    case outbound(String)

    var title: String {
        switch self {
        case .proxy: return "Через прокси"
        case .direct: return "Напрямую"
        case .block: return "Блокировать"
        case .outbound(let tag): return tag
        }
    }
}

struct RouteRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var match: RouteMatch = .domainSuffix
    var values: [String] = []
    var target: RouteTarget = .proxy
    var enabled = true
}

/// A switchable group of rules: becomes a `clash_mode` of the core and a choice in the mode card.
/// The common group (`isCommon`) has no mode: its rules apply always.
struct RouteScenario: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var enabled = true
    var rules: [RouteRule] = []
    /// Where everything else goes while this scenario is selected; ignored for the common group.
    var fallback: RouteTarget = .proxy
    var isCommon = false
}

/// A remote rule-set the editor may reference in addition to the ones the profile defines.
struct RuleSetSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var tag: String
    var url: String
    var format = "binary"   // binary (.srs) | source (.json)
    var enabled = true
}

struct RoutingConfig: Codable, Equatable {
    var scenarios: [RouteScenario] = [RouteScenario(name: "Общие правила", isCommon: true)]
    var ruleSets: [RuleSetSource] = []
    /// After an import: the profile rules the editor can express are dropped from the config the core
    /// gets, so the editor's copies are the only ones and edits there take effect.
    var replaceProfileRules = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scenarios = try c.decodeIfPresent([RouteScenario].self, forKey: .scenarios) ?? RoutingConfig().scenarios
        ruleSets = try c.decodeIfPresent([RuleSetSource].self, forKey: .ruleSets) ?? []
        replaceProfileRules = try c.decodeIfPresent(Bool.self, forKey: .replaceProfileRules) ?? false
        if !scenarios.contains(where: \.isCommon) {
            scenarios.insert(RouteScenario(name: "Общие правила", isCommon: true), at: 0)
        }
    }
}

struct AppSettings: Codable, Equatable {
    var engine: Engine = .lxd
    var tunEnabled = false
    var systemProxyEnabled = true
    var manageInbounds = true
    /// Profile without a selector group: add one over all its nodes so they can be switched by hand.
    var autoSelector = true
    var allowLAN = false
    var mixedPort = 7890
    var clashPort = 19090
    var clashSecret = AppSettings.randomSecret()
    var lxdPort = 19191
    var lxdSecret = AppSettings.randomSecret()
    var tunStack = "mixed"
    var logLevel = "info"
    var testURL = "https://www.gstatic.com/generate_204"
    var bypassDomains = ["localhost", "127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "*.local"]
    var selectedProfileID: UUID?
    var autoConnect = false
    var appearance: AppearanceMode = .system
    var accent: AccentChoice = .indigo
    var menuBarStyle: MenuBarStyle = .speedGraph
    /// Popover with the 5-minute chart and the node card when the pointer rests on the status item.
    var hoverPopover = true
    var popoverConnections = true
    var popoverSort: PopoverSort = .speed
    var appRules: [AppRule] = []
    /// Connect or disconnect on joining a named Wi-Fi network; not a core setting, so not in `runtimeKey`.
    var wifiRules: [WiFiRule] = []
    /// What joining a Wi-Fi network without a rule of its own does; nil leaves the VPN alone.
    var wifiDefault: WiFiAction?
    /// `.routing` puts the "everything direct" clash mode into the config; switched hot, not in `runtimeKey`.
    var wifiMode: WiFiMode = .power
    /// Routing mode: the clash mode in force before the direct one took over, to return to.
    var wifiSavedMode: String?
    var routing = RoutingConfig()
    /// Talk to the system LaunchDaemon of sing-box-lx (root, mTLS) instead of running a core process.
    var useSystemService = false
    var serviceAddress = ""        // host:port from the pairing invite
    var serviceFingerprint = ""    // pinned server certificate, sha256 hex
    var servicePassword = AppSettings.randomSecret()   // passphrase of service/client.p12
    /// Service mode: quitting the app leaves the core (and the system proxy) running; the next
    /// launch adopts it instead of restarting.
    var keepVPNOnQuit = false

    init() {}

    // Tolerant decoding: a settings file written by an older build keeps working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? d.engine
        tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? d.tunEnabled
        systemProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled) ?? d.systemProxyEnabled
        manageInbounds = try c.decodeIfPresent(Bool.self, forKey: .manageInbounds) ?? d.manageInbounds
        autoSelector = try c.decodeIfPresent(Bool.self, forKey: .autoSelector) ?? d.autoSelector
        allowLAN = try c.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? d.allowLAN
        mixedPort = try c.decodeIfPresent(Int.self, forKey: .mixedPort) ?? d.mixedPort
        clashPort = try c.decodeIfPresent(Int.self, forKey: .clashPort) ?? d.clashPort
        clashSecret = try c.decodeIfPresent(String.self, forKey: .clashSecret) ?? d.clashSecret
        lxdPort = try c.decodeIfPresent(Int.self, forKey: .lxdPort) ?? d.lxdPort
        lxdSecret = try c.decodeIfPresent(String.self, forKey: .lxdSecret) ?? d.lxdSecret
        tunStack = try c.decodeIfPresent(String.self, forKey: .tunStack) ?? d.tunStack
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
        testURL = try c.decodeIfPresent(String.self, forKey: .testURL) ?? d.testURL
        bypassDomains = try c.decodeIfPresent([String].self, forKey: .bypassDomains) ?? d.bypassDomains
        selectedProfileID = try c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? d.autoConnect
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        accent = try c.decodeIfPresent(AccentChoice.self, forKey: .accent) ?? d.accent
        menuBarStyle = try c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle) ?? d.menuBarStyle
        hoverPopover = try c.decodeIfPresent(Bool.self, forKey: .hoverPopover) ?? d.hoverPopover
        popoverConnections = try c.decodeIfPresent(Bool.self, forKey: .popoverConnections) ?? d.popoverConnections
        popoverSort = try c.decodeIfPresent(PopoverSort.self, forKey: .popoverSort) ?? d.popoverSort
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? d.appRules
        wifiRules = try c.decodeIfPresent([WiFiRule].self, forKey: .wifiRules) ?? d.wifiRules
        wifiDefault = try c.decodeIfPresent(WiFiAction.self, forKey: .wifiDefault)
        wifiMode = try c.decodeIfPresent(WiFiMode.self, forKey: .wifiMode) ?? d.wifiMode
        wifiSavedMode = try c.decodeIfPresent(String.self, forKey: .wifiSavedMode)
        routing = try c.decodeIfPresent(RoutingConfig.self, forKey: .routing) ?? d.routing
        useSystemService = try c.decodeIfPresent(Bool.self, forKey: .useSystemService) ?? d.useSystemService
        serviceAddress = try c.decodeIfPresent(String.self, forKey: .serviceAddress) ?? d.serviceAddress
        serviceFingerprint = try c.decodeIfPresent(String.self, forKey: .serviceFingerprint) ?? d.serviceFingerprint
        servicePassword = try c.decodeIfPresent(String.self, forKey: .servicePassword) ?? d.servicePassword
        keepVPNOnQuit = try c.decodeIfPresent(Bool.self, forKey: .keepVPNOnQuit) ?? d.keepVPNOnQuit
    }

    var servicePaired: Bool { !serviceAddress.isEmpty && !serviceFingerprint.isEmpty }
    /// The core runs as root: either our root launch for TUN or the system service.
    var runsAsRoot: Bool { tunEnabled || useSystemService }
    /// Config changes go through POST /admin/apply instead of a process restart.
    var hotApply: Bool { useSystemService || engine == .lxd }

    static func randomSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Everything that only takes effect when the core is (re)started.
    var runtimeKey: String {
        [engine.rawValue, "\(manageInbounds)", "\(allowLAN)", "\(mixedPort)", "\(clashPort)", clashSecret,
         "\(lxdPort)", lxdSecret, tunStack, logLevel, "\(useSystemService)", serviceAddress, serviceFingerprint].joined(separator: "|")
    }
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String?
    var updatedAt = Date()
    var nodeCount = 0
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Date?

    var fileURL: URL { Paths.profilesDir.appendingPathComponent("\(id.uuidString).json") }
}

enum CoreState: Equatable {
    case stopped, starting, running, stopping
    case failed(String)
}

enum Page: String, CaseIterable, Identifiable {
    case dashboard, proxies, routes, apps, networks, profiles, connections, logs, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Панель"
        case .proxies: return "Прокси"
        case .routes: return "Маршруты"
        case .apps: return "Приложения"
        case .networks: return "Сети"
        case .profiles: return "Профили"
        case .connections: return "Соединения"
        case .logs: return "Логи"
        case .tools: return "Инструменты"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .proxies: return "point.3.connected.trianglepath.dotted"
        case .routes: return "arrow.triangle.swap"
        case .apps: return "app.badge.checkmark"
        case .networks: return "wifi"
        case .profiles: return "folder"
        case .connections: return "arrow.left.arrow.right"
        case .logs: return "doc.text"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

struct ProxyGroup: Identifiable, Equatable {
    let name: String
    let type: String
    var now: String
    let all: [String]
    var id: String { name }
    var isSelectable: Bool { type.lowercased() == "selector" }
}

struct SpeedSample: Identifiable {
    let id: Int
    let up: Double
    let down: Double
}

struct LogLine: Identifiable {
    let id: Int
    let time: Date
    let level: String
    let text: String
}

/// The node that carries "proxy" traffic right now: the selector chain resolved through `now`.
/// Order of the connection list in the status item popover.
enum PopoverSort: String, Codable, CaseIterable, Identifiable {
    case speed, duration, volume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "По скорости"
        case .duration: return "По продолжительности"
        case .volume: return "По объёму"
        }
    }
}

struct CurrentNode: Equatable {
    let tag: String
    let type: String
    let transport: String?
    let tls: Bool
    let reality: Bool
    var server: String?
    var port: Int?

    var serverText: String {
        guard let server, !server.isEmpty else { return "—" }
        return port.map { "\(server):\($0)" } ?? server
    }

    var protocolText: String {
        let names = ["vless": "VLESS", "vmess": "VMess", "trojan": "Trojan", "shadowsocks": "Shadowsocks",
                     "hysteria2": "Hysteria2", "hysteria": "Hysteria", "tuic": "TUIC", "wireguard": "WireGuard",
                     "ssh": "SSH", "http": "HTTP", "socks": "SOCKS", "direct": "Direct", "anytls": "AnyTLS"]
        var parts = [names[type.lowercased()] ?? type]
        if let transport, !transport.isEmpty { parts.append(transport) }
        if reality { parts.append("Reality") } else if tls { parts.append("TLS") }
        return parts.joined(separator: " · ")
    }
}

struct IPInfo: Decodable {
    let ip: String?
    let country: String?
    let country_code: String?
    let city: String?
}
