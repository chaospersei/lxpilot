import Foundation

enum ConfigBuilder {
    static let utilityTypes: Set<String> = ["direct", "block", "dns", "selector", "urltest", "chain"]

    static func parseJSON(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        // json5Allowed: sing-box configs are often written with comments and trailing commas.
        return (try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])) as? JSON
    }

    static func serialize(_ config: JSON) throws -> Data {
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func nodeCount(_ config: JSON) -> Int {
        let outbounds = (config["outbounds"] as? [JSON] ?? []).filter {
            !utilityTypes.contains(($0["type"] as? String) ?? "")
        }
        let endpoints = config["endpoints"] as? [JSON] ?? []
        return outbounds.count + endpoints.count
    }

    /// A complete config around a list of nodes: selector + urltest, sniffing, DNS, clash modes.
    static func template(nodes: [JSON], testURL: String) -> JSON {
        let tags = nodes.compactMap { $0["tag"] as? String }

        let selector: JSON = ["type": "selector", "tag": "proxy", "outbounds": ["auto"] + tags, "default": "auto"]
        let urltest: JSON = ["type": "urltest", "tag": "auto", "outbounds": tags, "url": testURL, "interval": "5m"]
        let direct: JSON = ["type": "direct", "tag": "direct"]

        let dnsRemote: JSON = ["type": "https", "tag": "dns-remote", "server": "1.1.1.1", "detour": "proxy"]
        let dnsLocal: JSON = ["type": "local", "tag": "dns-local"]
        let dns: JSON = ["servers": [dnsRemote, dnsLocal], "final": "dns-remote", "strategy": "prefer_ipv4"]

        let sniff: JSON = ["action": "sniff"]
        let hijack: JSON = ["protocol": "dns", "action": "hijack-dns"]
        let modeDirect: JSON = ["clash_mode": "Direct", "outbound": "direct"]
        let modeGlobal: JSON = ["clash_mode": "Global", "outbound": "proxy"]
        let privateIP: JSON = ["ip_is_private": true, "outbound": "direct"]
        let route: JSON = [
            "rules": [sniff, hijack, modeDirect, modeGlobal, privateIP],
            "final": "proxy",
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-local",
        ]

        let clash: JSON = ["default_mode": "Rule"]
        let experimental: JSON = ["clash_api": clash]

        let config: JSON = [
            "dns": dns,
            "outbounds": [selector, urltest, direct] + nodes,
            "route": route,
            "experimental": experimental,
        ]
        return config
    }

    /// Runtime overlay applied on top of the selected profile right before it goes to the core.
    static func overlay(_ profile: JSON, settings: AppSettings) -> JSON {
        var config = profile
        let root = settings.tunEnabled

        var log = config["log"] as? JSON ?? [:]
        log["level"] = settings.logLevel
        config["log"] = log

        var experimental = config["experimental"] as? JSON ?? [:]
        var clash = experimental["clash_api"] as? JSON ?? [:]
        clash["external_controller"] = "127.0.0.1:\(settings.clashPort)"
        clash["secret"] = settings.clashSecret
        clash.removeValue(forKey: "external_ui")
        experimental["clash_api"] = clash
        var cache = experimental["cache_file"] as? JSON ?? [:]
        cache["enabled"] = true
        cache["path"] = Paths.cacheDB(root: root).path
        experimental["cache_file"] = cache
        config["experimental"] = experimental

        config = withAppRules(config, rules: settings.appRules.filter { $0.enabled })

        guard settings.manageInbounds else { return config }

        let existing = config["inbounds"] as? [JSON] ?? []
        let managed: Set<String> = ["tun", "mixed", "http", "socks"]
        var inbounds = existing.filter { !managed.contains(($0["type"] as? String) ?? "") }

        // Reuse the profile's own tags so route rules that match on `inbound` keep working.
        let ownMixed = existing.first(where: { ($0["type"] as? String) == "mixed" })
        let mixedTag = (ownMixed?["tag"] as? String) ?? "mixed-in"
        let mixed: JSON = [
            "type": "mixed",
            "tag": mixedTag,
            "listen": settings.allowLAN ? "::" : "127.0.0.1",
            "listen_port": settings.mixedPort,
        ]
        inbounds.append(mixed)

        if settings.tunEnabled {
            if let own = existing.first(where: { ($0["type"] as? String) == "tun" }) {
                inbounds.append(own)   // the profile author's TUN settings win
            } else {
                let tun: JSON = [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                    "auto_route": true,
                    "strict_route": true,
                    "stack": settings.tunStack,
                ]
                inbounds.append(tun)
            }
            var route = config["route"] as? JSON ?? [:]
            route["auto_detect_interface"] = true
            config["route"] = route
        }
        config["inbounds"] = inbounds
        return config
    }
}

// MARK: - Per-app routing

extension ConfigBuilder {
    /// Tag of the outbound that stands for "the proxy": the profile's `route.final` when it is a real
    /// node or a group, otherwise the first selector, otherwise the first node.
    static func proxyOutboundTag(_ config: JSON) -> String? {
        let outbounds = config["outbounds"] as? [JSON] ?? []
        let nonProxy: Set<String> = ["direct", "block", "dns"]
        func type(of tag: String) -> String? {
            outbounds.first(where: { ($0["tag"] as? String) == tag })?["type"] as? String
        }
        if let final = (config["route"] as? JSON)?["final"] as? String, let t = type(of: final), !nonProxy.contains(t) {
            return final
        }
        if let selector = outbounds.first(where: { ($0["type"] as? String) == "selector" }) {
            return selector["tag"] as? String
        }
        return outbounds.first(where: { !nonProxy.contains(($0["type"] as? String) ?? "") })?["tag"] as? String
    }

    static func processPattern(for rule: AppRule) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: rule.path)
        return rule.isBundle ? "^\(escaped)/" : "^\(escaped)$"
    }

    /// Inserts `process_path_regex` rules ahead of the first routing rule, after the leading
    /// `sniff` / `hijack-dns` actions, so DNS interception keeps working and the forced route wins
    /// over the profile's rules and over the Global/Direct clash modes.
    static func withAppRules(_ config: JSON, rules: [AppRule]) -> JSON {
        guard !rules.isEmpty else { return config }
        var config = config
        var outbounds = config["outbounds"] as? [JSON] ?? []
        var route = config["route"] as? JSON ?? [:]
        var routeRules = route["rules"] as? [JSON] ?? []

        var directTag = outbounds.first(where: { ($0["type"] as? String) == "direct" })?["tag"] as? String
        if directTag == nil, rules.contains(where: { $0.mode == .direct }) {
            let direct: JSON = ["type": "direct", "tag": "direct"]
            outbounds.append(direct)
            directTag = "direct"
        }
        let proxyTag = proxyOutboundTag(config)

        var inserted: [JSON] = []
        for mode in AppRouteMode.allCases {
            let patterns = rules.filter { $0.mode == mode }.map(processPattern(for:))
            guard !patterns.isEmpty, let target = (mode == .proxy ? proxyTag : directTag) else { continue }
            let rule: JSON = ["process_path_regex": patterns, "outbound": target]
            inserted.append(rule)
        }
        guard !inserted.isEmpty else { return config }

        let terminating: Set<String> = ["route", "reject"]
        let position = routeRules.firstIndex(where: {
            $0["outbound"] != nil || terminating.contains(($0["action"] as? String) ?? "")
        }) ?? routeRules.count
        // A profile may hijack DNS only after some routing rules; keep that interception for the
        // forced apps too, otherwise their DNS would follow the forced route instead of the resolver.
        let hijacksLater = routeRules[position...].contains { ($0["action"] as? String) == "hijack-dns" }
        let hijacksEarlier = routeRules[..<position].contains { ($0["action"] as? String) == "hijack-dns" }
        if hijacksLater, !hijacksEarlier {
            let hijack: JSON = ["protocol": "dns", "action": "hijack-dns"]
            inserted.insert(hijack, at: 0)
        }
        routeRules.insert(contentsOf: inserted, at: position)

        route["rules"] = routeRules
        config["route"] = route
        config["outbounds"] = outbounds
        return config
    }
}

// MARK: - Import

struct SubscriptionInfo {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Date?
    var title: String?
}

enum ProfileImporter {
    struct Converted {
        let config: Data
        let nodeCount: Int
    }

    /// Accepts a sing-box JSON config, or a (possibly base64) list of share links.
    static func convert(_ text: String, testURL: String) throws -> Converted {
        if let object = ConfigBuilder.parseJSON(text),
           object["outbounds"] != nil || object["endpoints"] != nil || object["inbounds"] != nil {
            return Converted(config: try ConfigBuilder.serialize(object), nodeCount: ConfigBuilder.nodeCount(object))
        }
        let nodes = ShareLinks.parseAll(text)
        guard !nodes.isEmpty else {
            throw AppError("Не удалось распознать профиль: ожидается конфиг sing-box (JSON) или список ссылок vless:// / trojan:// / ss:// / hysteria2://.")
        }
        let config = ConfigBuilder.template(nodes: nodes, testURL: testURL)
        return Converted(config: try ConfigBuilder.serialize(config), nodeCount: nodes.count)
    }

    static func fetch(_ urlString: String) async throws -> (text: String, info: SubscriptionInfo) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            throw AppError("Некорректный URL подписки.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("sing-box LxPilot", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AppError("Сервер подписки ответил ошибкой (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppError("Ответ подписки не является текстом в UTF-8.")
        }

        var info = SubscriptionInfo()
        if let header = http.value(forHTTPHeaderField: "subscription-userinfo") {
            for part in header.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, let number = Int64(pair[1]) else { continue }
                switch pair[0].lowercased() {
                case "upload": info.upload = number
                case "download": info.download = number
                case "total": info.total = number
                case "expire": if number > 0 { info.expire = Date(timeIntervalSince1970: TimeInterval(number)) }
                default: break
                }
            }
        }
        if let title = http.value(forHTTPHeaderField: "profile-title"), !title.isEmpty {
            if title.lowercased().hasPrefix("base64:") {
                info.title = ShareLinks.decodeBase64(String(title.dropFirst(7)))
            } else {
                info.title = title.removingPercentEncoding ?? title
            }
        }
        return (text, info)
    }
}
