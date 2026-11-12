import Foundation

/// Share-link → sing-box outbound mapping (a consumer-side job: the core only takes config JSON).
/// Supported: vless, trojan, ss, hysteria2/hy2; transports tcp, ws, grpc, httpupgrade, http, xhttp.
enum ShareLinks {
    static let reservedTags: Set<String> = ["proxy", "auto", "direct"]

    static func parseAll(_ text: String) -> [JSON] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.contains("://"), let decoded = decodeBase64(body) { body = decoded }

        var result: [JSON] = []
        var used = reservedTags
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, var node = parse(line) else { continue }
            var tag = (node["tag"] as? String) ?? ""
            if tag.isEmpty { tag = "node" }
            var candidate = tag
            var n = 2
            while used.contains(candidate) {
                candidate = "\(tag) \(n)"
                n += 1
            }
            used.insert(candidate)
            node["tag"] = candidate
            result.append(node)
        }
        return result
    }

    static func decodeBase64(_ value: String) -> String? {
        var text = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ line: String) -> JSON? {
        guard let schemeRange = line.range(of: "://") else { return nil }
        let scheme = line[..<schemeRange.lowerBound].lowercased()
        var rest = String(line[schemeRange.upperBound...])
        var name = ""
        if let hash = rest.firstIndex(of: "#") {
            let fragment = String(rest[rest.index(after: hash)...])
            name = fragment.removingPercentEncoding ?? fragment
            rest = String(rest[..<hash])
        }
        switch scheme {
        case "vless", "trojan", "hysteria2", "hy2":
            return parseStandard(scheme: scheme, rest: rest, name: name)
        case "ss":
            return parseShadowsocks(rest: rest, name: name)
        default:
            return nil
        }
    }

    // MARK: - Pieces

    private static func splitQuery(_ rest: String) -> (main: String, query: [String: String]) {
        guard let mark = rest.firstIndex(of: "?") else { return (rest, [:]) }
        var query: [String: String] = [:]
        for pair in rest[rest.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            query[String(first)] = value.removingPercentEncoding ?? value
        }
        return (String(rest[..<mark]), query)
    }

    private static func splitHostPort(_ value: String) -> (host: String, port: Int)? {
        var text = value
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let tail = text[text.index(after: close)...]
            guard tail.hasPrefix(":"), let port = Int(tail.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        return (String(text[..<colon]), port)
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let value else { return false }
        return value == "1" || value.lowercased() == "true"
    }

    private static func parseStandard(scheme: String, rest: String, name: String) -> JSON? {
        let (main, query) = splitQuery(rest)
        guard let at = main.lastIndex(of: "@") else { return nil }
        let userRaw = String(main[..<at])
        let user = userRaw.removingPercentEncoding ?? userRaw
        guard let endpoint = splitHostPort(String(main[main.index(after: at)...])) else { return nil }

        var out: JSON = [
            "tag": name.isEmpty ? endpoint.host : name,
            "server": endpoint.host,
            "server_port": endpoint.port,
        ]

        if scheme == "hysteria2" || scheme == "hy2" {
            out["type"] = "hysteria2"
            out["password"] = user
            var tls: JSON = ["enabled": true]
            if let sni = query["sni"], !sni.isEmpty { tls["server_name"] = sni }
            if truthy(query["insecure"]) || truthy(query["allowInsecure"]) { tls["insecure"] = true }
            out["tls"] = tls
            if let obfs = query["obfs"], !obfs.isEmpty, obfs != "none" {
                let obfsConfig: JSON = ["type": obfs, "password": query["obfs-password"] ?? ""]
                out["obfs"] = obfsConfig
            }
            return out
        }

        if scheme == "vless" {
            out["type"] = "vless"
            out["uuid"] = user
            if let flow = query["flow"], !flow.isEmpty { out["flow"] = flow }
            // lx extension: post-quantum VLESS encryption (client half).
            if let encryption = query["encryption"], !encryption.isEmpty, encryption != "none" {
                out["encryption"] = encryption
            }
        } else {
            out["type"] = "trojan"
            out["password"] = user
        }

        let security = (query["security"] ?? (scheme == "trojan" ? "tls" : "none")).lowercased()
        if security == "tls" || security == "reality" {
            var tls: JSON = ["enabled": true]
            if let sni = query["sni"] ?? query["peer"], !sni.isEmpty { tls["server_name"] = sni }
            if let alpn = query["alpn"], !alpn.isEmpty {
                tls["alpn"] = alpn.split(separator: ",").map { String($0) }
            }
            if truthy(query["allowInsecure"]) || truthy(query["insecure"]) { tls["insecure"] = true }
            var fingerprint = query["fp"] ?? ""
            if security == "reality" {
                var reality: JSON = ["enabled": true, "public_key": query["pbk"] ?? ""]
                if let sid = query["sid"], !sid.isEmpty { reality["short_id"] = sid }
                tls["reality"] = reality
                if fingerprint.isEmpty { fingerprint = "chrome" }   // REALITY requires uTLS
            }
            if !fingerprint.isEmpty {
                let utls: JSON = ["enabled": true, "fingerprint": fingerprint]
                tls["utls"] = utls
            }
            out["tls"] = tls
        }

        let host = query["host"] ?? ""
        let path = query["path"] ?? ""
        switch (query["type"] ?? "tcp").lowercased() {
        case "ws":
            var transport: JSON = ["type": "ws", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty {
                let headers: JSON = ["Host": host]
                transport["headers"] = headers
            }
            out["transport"] = transport
        case "grpc":
            let transport: JSON = ["type": "grpc", "service_name": query["serviceName"] ?? ""]
            out["transport"] = transport
        case "httpupgrade":
            var transport: JSON = ["type": "httpupgrade", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { transport["host"] = host }
            out["transport"] = transport
        case "http", "h2":
            var transport: JSON = ["type": "http", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { transport["host"] = host.split(separator: ",").map { String($0) } }
            out["transport"] = transport
        case "xhttp", "splithttp":
            // lx extension: Xray-compatible XHTTP (`with_xhttp`).
            var transport: JSON = ["type": "xhttp", "path": path.isEmpty ? "/" : path]
            if !host.isEmpty { transport["host"] = host }
            let mode = query["mode"] ?? ""
            transport["mode"] = mode.isEmpty ? "auto" : mode
            out["transport"] = transport
        default:
            break
        }
        return out
    }

    private static func parseShadowsocks(rest: String, name: String) -> JSON? {
        let (main, _) = splitQuery(rest)
        let credentials: String
        let endpointText: String
        if let at = main.lastIndex(of: "@") {
            let userRaw = String(main[..<at])
            credentials = decodeBase64(userRaw) ?? (userRaw.removingPercentEncoding ?? userRaw)
            endpointText = String(main[main.index(after: at)...])
        } else {
            guard let decoded = decodeBase64(main), let at = decoded.lastIndex(of: "@") else { return nil }
            credentials = String(decoded[..<at])
            endpointText = String(decoded[decoded.index(after: at)...])
        }
        guard let colon = credentials.firstIndex(of: ":"), let endpoint = splitHostPort(endpointText) else { return nil }
        let out: JSON = [
            "type": "shadowsocks",
            "tag": name.isEmpty ? endpoint.host : name,
            "server": endpoint.host,
            "server_port": endpoint.port,
            "method": String(credentials[..<colon]),
            "password": String(credentials[credentials.index(after: colon)...]),
        ]
        return out
    }
}
