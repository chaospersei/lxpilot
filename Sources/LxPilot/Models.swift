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

struct AppSettings: Codable, Equatable {
    var engine: Engine = .lxd
    var tunEnabled = false
    var systemProxyEnabled = true
    var manageInbounds = true
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
    var appRules: [AppRule] = []

    init() {}

    // Tolerant decoding: a settings file written by an older build keeps working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? d.engine
        tunEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunEnabled) ?? d.tunEnabled
        systemProxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled) ?? d.systemProxyEnabled
        manageInbounds = try c.decodeIfPresent(Bool.self, forKey: .manageInbounds) ?? d.manageInbounds
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
        appRules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) ?? d.appRules
    }

    static func randomSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Everything that only takes effect when the core is (re)started.
    var runtimeKey: String {
        [engine.rawValue, "\(manageInbounds)", "\(allowLAN)", "\(mixedPort)", "\(clashPort)", clashSecret,
         "\(lxdPort)", lxdSecret, tunStack, logLevel].joined(separator: "|")
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
    case dashboard, proxies, apps, profiles, connections, logs, tools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Панель"
        case .proxies: return "Прокси"
        case .apps: return "Приложения"
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
        case .apps: return "app.badge.checkmark"
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

struct IPInfo: Decodable {
    let ip: String?
    let country: String?
    let country_code: String?
    let city: String?
}
