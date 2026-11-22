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

    /// Everything a rule or a group may point at: `outbounds` plus `endpoints` (WireGuard / AmneziaWG /
    /// Tailscale live there since sing-box 1.11 but are addressed by tag like any outbound).
    static func outboundsAndEndpoints(_ config: JSON) -> [JSON] {
        (config["outbounds"] as? [JSON] ?? []) + (config["endpoints"] as? [JSON] ?? [])
    }

    static func nodeCount(_ config: JSON) -> Int {
        outboundsAndEndpoints(config).filter { !utilityTypes.contains(($0["type"] as? String) ?? "") }.count
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
        let root = settings.runsAsRoot

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

        // Routing scenarios first, then app rules: each insertion lands ahead of the previous one,
        // so the forced per-app routes end up first and win over everything.
        if settings.autoSelector { config = withNodeSelector(config) }
        if settings.routing.replaceProfileRules { config = withoutConvertibleRules(config) }
        config = withRouting(config, routing: settings.routing)
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

// MARK: - Node selector

extension ConfigBuilder {
    static let nodeSelectorTag = "proxy"
    static let nodeSelectorFallbackTag = "lxpilot-proxy"

    /// A profile that is just a list of nodes gets a `selector` over all of them, placed first, so
    /// the "Прокси" page has something to show and switch. `route.final` that pointed at a node is
    /// redirected to the selector with that node as `default`, so nothing changes until the user
    /// picks another one; rules that name a node directly keep it.
    static func withNodeSelector(_ config: JSON) -> JSON {
        var outbounds = config["outbounds"] as? [JSON] ?? []
        let groupTypes: Set<String> = ["selector", "urltest"]
        guard !outbounds.contains(where: { groupTypes.contains(($0["type"] as? String) ?? "") }) else { return config }
        let everything = outboundsAndEndpoints(config)
        let nodes = everything.compactMap { outbound -> String? in
            guard !utilityTypes.contains((outbound["type"] as? String) ?? "") else { return nil }
            return outbound["tag"] as? String
        }
        guard !nodes.isEmpty else { return config }

        let tags = Set(everything.compactMap { $0["tag"] as? String })
        let tag = tags.contains(nodeSelectorTag) ? nodeSelectorFallbackTag : nodeSelectorTag
        guard !tags.contains(tag) else { return config }

        var config = config
        var route = config["route"] as? JSON ?? [:]
        let final = route["final"] as? String
        var selector: JSON = ["type": "selector", "tag": tag, "outbounds": nodes, "interrupt_exist_connections": false]
        if let final, nodes.contains(final) {
            selector["default"] = final
            route["final"] = tag
        } else if final == nil {
            route["final"] = tag   // sing-box would otherwise take the first outbound, which is now the selector anyway
        }
        outbounds.insert(selector, at: 0)
        config["outbounds"] = outbounds
        config["route"] = route
        return config
    }
}

// MARK: - Node description

extension ConfigBuilder {
    /// What the UI says about an outbound or endpoint: protocol, transport, TLS, server.
    static func nodeInfo(_ config: JSON, tag: String, fallbackType: String? = nil) -> CurrentNode {
        let outbound = outboundsAndEndpoints(config).first { ($0["tag"] as? String) == tag }
        let tls = outbound?["tls"] as? JSON
        // Endpoints (WireGuard) keep the address in their first peer.
        let peer = (outbound?["peers"] as? [JSON])?.first
        return CurrentNode(
            tag: tag,
            type: outbound?["type"] as? String ?? fallbackType ?? "?",
            transport: (outbound?["transport"] as? JSON)?["type"] as? String,
            tls: tls?["enabled"] as? Bool ?? false,
            reality: ((tls?["reality"] as? JSON)?["enabled"] as? Bool) ?? false,
            server: (outbound?["server"] as? String) ?? (peer?["address"] as? String),
            port: ((outbound?["server_port"] as? NSNumber) ?? (peer?["port"] as? NSNumber))?.intValue)
    }

    /// Follows the proxy tag down through groups using `next` (the core's `now`, or the config's
    /// `default`/first member when the core is not running) until it reaches a node.
    static func resolveExit(_ config: JSON, next: (String) -> String?) -> String? {
        guard var tag = proxyOutboundTag(config) else { return nil }
        var hops = 0
        while hops < 8, let following = next(tag), !following.isEmpty, following != tag {
            tag = following
            hops += 1
        }
        return tag
    }

    /// The node a fresh start would use, without the core: groups resolve by `default`, else first member.
    static func plannedExit(_ config: JSON) -> String? {
        let all = outboundsAndEndpoints(config)
        return resolveExit(config) { tag in
            guard let group = all.first(where: { ($0["tag"] as? String) == tag }),
                  ["selector", "urltest"].contains((group["type"] as? String) ?? "") else { return nil }
            return (group["default"] as? String) ?? (group["outbounds"] as? [String])?.first
        }
    }
}

// MARK: - Per-app routing

extension ConfigBuilder {
    /// Tag of the outbound that stands for "the proxy": the profile's `route.final` when it is a real
    /// node or a group, otherwise the first selector, otherwise the first node.
    static func proxyOutboundTag(_ config: JSON) -> String? {
        let outbounds = outboundsAndEndpoints(config)
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

    /// Tag of the first `direct` outbound, adding one when the profile has none.
    static func ensureDirectTag(_ config: inout JSON) -> String {
        var outbounds = config["outbounds"] as? [JSON] ?? []
        if let tag = outbounds.first(where: { ($0["type"] as? String) == "direct" })?["tag"] as? String { return tag }
        let direct: JSON = ["type": "direct", "tag": "direct"]
        outbounds.append(direct)
        config["outbounds"] = outbounds
        return "direct"
    }

    /// Inserts rules ahead of the first routing rule, after the leading `sniff` / `hijack-dns`
    /// actions, so DNS interception keeps working and the inserted rules win over the profile's own
    /// rules and over the Global/Direct clash modes. A profile may hijack DNS only after some routing
    /// rules; then a copy of that action goes in front, otherwise DNS of the matched traffic would
    /// follow the inserted route instead of the resolver.
    static func insertRules(_ inserted: [JSON], into config: JSON) -> JSON {
        guard !inserted.isEmpty else { return config }
        var config = config
        var route = config["route"] as? JSON ?? [:]
        var routeRules = route["rules"] as? [JSON] ?? []
        var block = inserted

        let position = insertionIndex(routeRules)
        let hijacksLater = routeRules[position...].contains { ($0["action"] as? String) == "hijack-dns" }
        let hijacksEarlier = routeRules[..<position].contains { ($0["action"] as? String) == "hijack-dns" }
        if hijacksLater, !hijacksEarlier {
            let hijack: JSON = ["protocol": "dns", "action": "hijack-dns"]
            block.insert(hijack, at: 0)
        }
        // Same for sniffing: domain rules need the sniffed host for TUN traffic, so a profile that
        // sniffs only later gets its sniff rule repeated in front of the inserted block.
        let sniffEarlier = routeRules[..<position].contains { ($0["action"] as? String) == "sniff" }
        if !sniffEarlier, let sniff = routeRules[position...].first(where: { ($0["action"] as? String) == "sniff" }) {
            block.insert(sniff, at: 0)
        }
        routeRules.insert(contentsOf: block, at: position)
        route["rules"] = routeRules
        config["route"] = route
        return config
    }

    /// `process_path_regex` rules for the "Приложения" page, one per mode.
    static func withAppRules(_ config: JSON, rules: [AppRule]) -> JSON {
        guard !rules.isEmpty else { return config }
        var config = config
        let proxyTag = proxyOutboundTag(config)
        let directTag = rules.contains(where: { $0.mode == .direct }) ? ensureDirectTag(&config) : nil

        var inserted: [JSON] = []
        for mode in AppRouteMode.allCases {
            let patterns = rules.filter { $0.mode == mode }.map(processPattern(for:))
            guard !patterns.isEmpty, let target = (mode == .proxy ? proxyTag : directTag) else { continue }
            let rule: JSON = ["process_path_regex": patterns, "outbound": target]
            inserted.append(rule)
        }
        return insertRules(inserted, into: config)
    }
}

// MARK: - Routing scenarios

extension ConfigBuilder {
    /// Rule-set tags the profile defines itself.
    static func profileRuleSetTags(_ config: JSON) -> [String] {
        ((config["route"] as? JSON)?["rule_set"] as? [JSON] ?? []).compactMap { $0["tag"] as? String }
    }

    /// Tags a rule may send traffic to: groups first, then nodes.
    static func routableOutboundTags(_ config: JSON) -> [String] {
        let outbounds = outboundsAndEndpoints(config)
        let skip: Set<String> = ["direct", "block", "dns"]
        let groups = outbounds.filter { ["selector", "urltest"].contains(($0["type"] as? String) ?? "") }
        let nodes = outbounds.filter { !skip.contains(($0["type"] as? String) ?? "") && !["selector", "urltest"].contains(($0["type"] as? String) ?? "") }
        return (groups + nodes).compactMap { $0["tag"] as? String }
    }

    /// The rule as sing-box JSON, or nil when it has nothing usable (then it is skipped, not broken).
    static func ruleJSON(_ rule: RouteRule, mode: String?, proxyTag: String?, directTag: String, knownRuleSets: Set<String>) -> JSON? {
        guard rule.enabled else { return nil }
        var values = rule.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if rule.match == .ruleSet { values = values.filter { knownRuleSets.contains($0) } }
        guard !values.isEmpty else { return nil }

        var json: JSON = [:]
        if rule.match == .port {
            let ports = values.compactMap { Int($0) }.filter { (1...65535).contains($0) }
            guard !ports.isEmpty else { return nil }
            json[rule.match.key] = ports
        } else {
            json[rule.match.key] = values
        }
        if let mode { json["clash_mode"] = mode }
        switch rule.target {
        case .block: json["action"] = "reject"
        case .direct: json["outbound"] = directTag
        case .proxy:
            guard let proxyTag else { return nil }
            json["outbound"] = proxyTag
        case .outbound(let tag):
            json["outbound"] = tag
        }
        return json
    }

    /// Common rules (no mode) and one `clash_mode` block per enabled scenario, each closed by the
    /// scenario's fallback so the mode fully decides where the rest goes.
    static func withRouting(_ config: JSON, routing: RoutingConfig) -> JSON {
        let active = routing.scenarios.filter { $0.enabled && ($0.isCommon ? !$0.rules.isEmpty : true) }
        guard !active.isEmpty else { return config }
        var config = config
        let proxyTag = proxyOutboundTag(config)
        let directTag = ensureDirectTag(&config)

        // Remote rule-sets from the editor, unless the profile already defines the tag.
        var route = config["route"] as? JSON ?? [:]
        var ruleSets = route["rule_set"] as? [JSON] ?? []
        var known = Set(profileRuleSetTags(config))
        for source in routing.ruleSets where source.enabled && !source.tag.isEmpty && !known.contains(source.tag) {
            guard URL(string: source.url)?.scheme != nil else { continue }
            let entry: JSON = [
                "tag": source.tag, "type": "remote", "format": source.format, "url": source.url,
                "download_detour": directTag, "update_interval": "24h",
            ]
            ruleSets.append(entry)
            known.insert(source.tag)
        }
        route["rule_set"] = ruleSets
        config["route"] = route

        var inserted: [JSON] = []
        for scenario in active {
            let mode: String? = scenario.isCommon ? nil : scenario.name.trimmingCharacters(in: .whitespaces)
            if let mode, mode.isEmpty { continue }
            for rule in scenario.rules {
                if let json = ruleJSON(rule, mode: mode, proxyTag: proxyTag, directTag: directTag, knownRuleSets: known) {
                    inserted.append(json)
                }
            }
            if let mode {
                var fallback: JSON = ["clash_mode": mode]
                switch scenario.fallback {
                case .block: fallback["action"] = "reject"
                case .direct: fallback["outbound"] = directTag
                case .proxy: fallback["outbound"] = proxyTag ?? directTag
                case .outbound(let tag): fallback["outbound"] = tag
                }
                inserted.append(fallback)
            }
        }
        return insertRules(inserted, into: config)
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

// MARK: - Profile rules

/// A route rule of the profile as the "Маршруты" page shows it: readable conditions, the action,
/// and the editor's equivalent when the rule can be expressed there.
struct ProfileRule: Identifiable, Equatable {
    enum Role: Equatable { case service, route }
    enum Converted: Equatable {
        case rule(RouteRule, mode: String?)
        case fallback(RouteTarget, mode: String)
    }

    let id: Int
    let conditions: String
    let action: String
    let mode: String?
    let role: Role
    let converted: Converted?
}

extension ConfigBuilder {
    static let terminatingActions: Set<String> = ["route", "reject"]
    private static let serviceActions: Set<String> = ["sniff", "hijack-dns", "resolve", "route-options"]

    static func isTerminating(_ rule: JSON) -> Bool {
        rule["outbound"] != nil || terminatingActions.contains((rule["action"] as? String) ?? "")
    }

    /// Where `insertRules` puts the editor's block: ahead of the first routing rule.
    static func insertionIndex(_ rules: [JSON]) -> Int {
        rules.firstIndex(where: isTerminating) ?? rules.count
    }

    static func directTags(_ config: JSON) -> Set<String> {
        Set((config["outbounds"] as? [JSON] ?? []).filter { ($0["type"] as? String) == "direct" }.compactMap { $0["tag"] as? String })
    }

    static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let list as [Any]: return list.map { "\($0)" }
        case let single?: return ["\(single)"]
        case nil: return []
        }
    }

    /// The editor's equivalent of a profile rule: one supported condition, an optional `clash_mode`,
    /// and an outbound or `reject`. A rule with only `clash_mode` is a scenario's fallback. Anything
    /// else (logical rules, several conditions, lx actions like `bypass`) stays with the profile.
    static func convert(_ rule: JSON, proxyTag: String?, directTags: Set<String>) -> ProfileRule.Converted? {
        if (rule["type"] as? String) == "logical" { return nil }
        let action = rule["action"] as? String
        var consumed: Set<String> = []
        let target: RouteTarget
        switch action {
        case "reject":
            target = .block
            consumed = ["action"]
        case nil, "route":
            guard let outbound = rule["outbound"] as? String else { return nil }
            target = outbound == proxyTag ? .proxy : directTags.contains(outbound) ? .direct : .outbound(outbound)
            consumed = ["outbound", "action"]
        default:
            return nil
        }
        let mode = rule["clash_mode"] as? String
        if mode != nil { consumed.insert("clash_mode") }

        let conditionKeys = rule.keys.filter { !consumed.contains($0) }
        if conditionKeys.isEmpty {
            guard let mode else { return nil }
            return .fallback(target, mode: mode)
        }
        guard conditionKeys.count == 1, let key = conditionKeys.first,
              let match = RouteMatch.allCases.first(where: { $0.key == key }) else { return nil }
        let values = stringList(rule[key])
        guard !values.isEmpty else { return nil }
        return .rule(RouteRule(match: match, values: values, target: target), mode: mode)
    }

    static func profileRules(_ config: JSON) -> [ProfileRule] {
        let rules = (config["route"] as? JSON)?["rules"] as? [JSON] ?? []
        let proxyTag = proxyOutboundTag(config)
        let directs = directTags(config)
        let meta: Set<String> = ["action", "outbound", "clash_mode", "type", "mode", "rules", "timeout", "method", "no_drop", "strategy", "server", "sniffer"]

        return rules.enumerated().map { index, rule in
            let action = rule["action"] as? String
            var conditions: [String] = []
            if (rule["type"] as? String) == "logical" {
                let count = (rule["rules"] as? [Any])?.count ?? 0
                let op = (rule["mode"] as? String) == "or" ? "ИЛИ" : "И"
                conditions.append("логическое (\(op)) из \(count) " + plural(count, "условия", "условий", "условий"))
            }
            for key in rule.keys.sorted() where !meta.contains(key) {
                let values = stringList(rule[key])
                if values == ["1"] || values == ["true"] { conditions.append(key) }
                else if values == ["0"] || values == ["false"] { conditions.append("не " + key) }
                else { conditions.append("\(key): " + values.joined(separator: ", ")) }
            }

            var actionText: String
            switch action {
            case nil, "route": actionText = "→ " + ((rule["outbound"] as? String) ?? "?")
            case "reject": actionText = "reject" + ((rule["method"] as? String).map { " (\($0))" } ?? "")
            case "sniff": actionText = "sniff" + ((rule["timeout"] as? String).map { " \($0)" } ?? "")
            case let other?:
                actionText = other
                if let outbound = rule["outbound"] as? String { actionText += " → " + outbound }
            }

            return ProfileRule(
                id: index,
                conditions: conditions.isEmpty ? "любой трафик" : conditions.joined(separator: " и "),
                action: actionText,
                mode: rule["clash_mode"] as? String,
                role: serviceActions.contains(action ?? "") ? .service : .route,
                converted: convert(rule, proxyTag: proxyTag, directTags: directs)
            )
        }
    }

    /// Drops the profile rules the editor can express, so after an import only the editor's copies
    /// remain and edits there are not shadowed by the originals.
    static func withoutConvertibleRules(_ config: JSON) -> JSON {
        var config = config
        var route = config["route"] as? JSON ?? [:]
        let proxyTag = proxyOutboundTag(config)
        let directs = directTags(config)
        route["rules"] = (route["rules"] as? [JSON] ?? []).filter { convert($0, proxyTag: proxyTag, directTags: directs) == nil }
        config["route"] = route
        return config
    }
}
