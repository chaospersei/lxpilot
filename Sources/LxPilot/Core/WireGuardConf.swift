import Foundation
import Compression

/// A WireGuard / AmneziaWG client config (`awg.conf`, wg-quick format) → sing-box `endpoints` entry.
/// The lx core takes the AmneziaWG keys on the endpoint root under the same names in lower case
/// (`Jc` → `jc`, `H1` → `h1`); the AWG 3.x ones are snake_case.
enum WireGuardConf {
    static func looksLikeConf(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("[interface]") && lower.contains("[peer]")
    }

    private struct Section {
        let name: String
        var values: [String: String] = [:]
    }

    private static func sections(_ text: String) -> [Section] {
        var result: [Section] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }   // as wg-quick does
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                result.append(Section(name: line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()))
                continue
            }
            // Only the first "=" separates: base64 keys end with their own.
            guard let equals = line.firstIndex(of: "="), !result.isEmpty else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if key == "address" || key == "allowedips", let previous = result[result.count - 1].values[key] {
                result[result.count - 1].values[key] = previous + "," + value   // the key may repeat
            } else {
                result[result.count - 1].values[key] = value
            }
        }
        return result
    }

    private static let intKeys = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"]
    private static let verbatimKeys = ["i1", "i2", "i3", "i4", "i5", "id", "ip", "ib"]
    /// A number, or an AWG 2/3 range kept as the string `"N-M"`.
    private static let rangeKeys: [String: String] = [
        "h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
        "contentpaddingaddition": "content_padding_addition",
        "rekeyaftertime": "rekey_after_time",
        "rekeytimeout": "rekey_timeout",
        "rejectaftertime": "reject_after_time",
        "keepalivetimeout": "keepalive_timeout",
        "maxhandshakeattempts": "max_handshake_attempts",
    ]
    private static let flagKeys = ["randomtrailers": "random_trailers", "disablecookies": "disable_cookies"]

    private static func numberOrRange(_ value: String) -> Any? {
        if let number = Int(value) { return number }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let low = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let high = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return "\(low)-\(high)"
    }

    private static func isKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }

    private static func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func splitEndpoint(_ value: String) -> (host: String, port: Int)? {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let tail = value[value.index(after: close)...]
            guard tail.hasPrefix(":"), let port = Int(tail.dropFirst()), !host.isEmpty else { return nil }
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { return nil }
        let host = String(value[..<colon])
        return host.isEmpty ? nil : (host, port)
    }

    /// `fallbackEndpoint` covers Amnezia exports whose `Endpoint` line is not filled in.
    static func endpoint(from text: String, name: String?, fallbackEndpoint: (host: String, port: Int)? = nil) throws -> JSON {
        let all = sections(text)
        guard let interface = all.first(where: { $0.name == "interface" })?.values else {
            throw AppError("В конфиге WireGuard нет секции [Interface].")
        }
        let peerSections = all.filter { $0.name == "peer" }.map { $0.values }
        guard !peerSections.isEmpty else { throw AppError("В конфиге WireGuard нет секции [Peer].") }
        guard let privateKey = interface["privatekey"], isKey(privateKey) else {
            throw AppError("В секции [Interface] нет корректного PrivateKey.")
        }
        let addresses = list(interface["address"]).map { address -> String in
            address.contains("/") ? address : address + (address.contains(":") ? "/128" : "/32")
        }
        guard !addresses.isEmpty else { throw AppError("В секции [Interface] нет адреса (Address).") }

        var peers: [JSON] = []
        for peer in peerSections {
            guard let publicKey = peer["publickey"], isKey(publicKey) else {
                throw AppError("В секции [Peer] нет корректного PublicKey.")
            }
            guard let server = peer["endpoint"].flatMap(splitEndpoint) ?? fallbackEndpoint else {
                throw AppError("В секции [Peer] нет адреса сервера (Endpoint = адрес:порт).")
            }
            let allowed = list(peer["allowedips"])
            var entry: JSON = [
                "address": server.host,
                "port": server.port,
                "public_key": publicKey,
                "allowed_ips": allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed,
            ]
            if let shared = peer["presharedkey"], isKey(shared) { entry["pre_shared_key"] = shared }
            if let keepalive = peer["persistentkeepalive"].flatMap(numberOrRange), (keepalive as? Int) != 0 {
                entry["persistent_keepalive_interval"] = keepalive
            }
            peers.append(entry)
        }

        var out: JSON = ["type": "wireguard", "private_key": privateKey, "address": addresses, "peers": peers]
        for key in intKeys {
            if let number = interface[key].flatMap({ Int($0) }) { out[key] = number }
        }
        for key in verbatimKeys {
            if let value = interface[key] { out[key] = value }
        }
        for (confKey, jsonKey) in rangeKeys {
            if let value = interface[confKey].flatMap(numberOrRange) { out[jsonKey] = value }
        }
        if let key = interface["headerprotectionkey"], isKey(key) { out["header_protection_key"] = key }
        for (confKey, jsonKey) in flagKeys {
            if let value = interface[confKey]?.lowercased(), ["on", "true", "1", "yes"].contains(value) { out[jsonKey] = true }
        }

        // S4 is prepended to every data packet, so an AmneziaWG tunnel carries less than WireGuard's
        // usual 1420: over budget the handshake passes and data fails with "message too long".
        // Left out, the core picks the MTU itself (1280 with S4, 1408 without).
        if let mtu = interface["mtu"].flatMap({ Int($0) }), mtu > 0 {
            let budget = 1432 - ((out["s4"] as? Int) ?? 0)
            out["mtu"] = min(mtu, budget)
        }

        let amnezia = out.keys.contains { $0 != "type" && $0 != "private_key" && $0 != "address" && $0 != "peers" && $0 != "mtu" }
        let host = (peers.first?["address"] as? String) ?? ""
        var tag = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isEmpty { tag = (amnezia ? "awg " : "wg ") + host }
        if ShareLinks.reservedTags.contains(tag) { tag += " 2" }
        out["tag"] = tag
        return out
    }
}

/// The Amnezia app's own export: a `vpn://` link, or a series of QR codes carrying the same bytes.
/// Inside is JSON packed with Qt's qCompress; the AmneziaWG client config sits in
/// `containers[].awg.last_config` (itself a JSON string) → `config`, in `awg.conf` form.
enum AmneziaLink {
    struct Export {
        let conf: String
        let name: String?
        let endpoint: (host: String, port: Int)?
    }

    static func isLink(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("vpn://")
    }

    static func decode(_ text: String) throws -> Export {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("vpn://".count))
        guard let packed = base64URL(body) else {
            throw AppError("Ссылка vpn:// повреждена: это не base64.")
        }
        // Old exports are not compressed.
        let data = inflate(packed) ?? packed
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw AppError("Ссылка vpn:// повреждена: внутри не оказалось конфигурации Amnezia.")
        }
        for container in root["containers"] as? [JSON] ?? [] {
            for key in ["awg", "wireguard"] {
                guard let protocolConfig = container[key] as? JSON else { continue }
                let last: JSON?
                if let string = protocolConfig["last_config"] as? String {
                    last = ConfigBuilder.parseJSON(string)
                } else {
                    last = protocolConfig["last_config"] as? JSON
                }
                guard let last, let conf = last["config"] as? String, WireGuardConf.looksLikeConf(conf) else { continue }
                var endpoint: (host: String, port: Int)?
                let host = (last["hostName"] as? String) ?? (root["hostName"] as? String) ?? ""
                let port = (last["port"] as? NSNumber)?.intValue ?? Int((last["port"] as? String) ?? "") ?? Int((protocolConfig["port"] as? String) ?? "")
                if !host.isEmpty, let port { endpoint = (host, port) }
                let description = (root["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Export(conf: conf, name: description?.isEmpty == false ? description : nil, endpoint: endpoint)
            }
        }
        throw AppError("В ссылке vpn:// нет конфигурации AmneziaWG или WireGuard: другие протоколы Amnezia не поддерживаются.")
    }

    /// Amnezia splits its export over several QR codes: each is base64url of a QDataStream record
    /// `int16 1984, uint8 count, uint8 index, QByteArray chunk`. Returns nil when the payloads are
    /// not such a series; throws when the series is incomplete.
    static func link(fromQRParts payloads: [String]) throws -> String? {
        var total = 0
        var chunks: [Int: Data] = [:]
        for payload in payloads {
            guard let record = base64URL(payload), record.count > 8, record[0] == 0x07, record[1] == 0xC0 else { continue }
            let length = record[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, record.count >= 8 + length else { continue }
            total = Int(record[2])
            chunks[Int(record[3])] = record.subdata(in: 8..<(8 + length))
        }
        guard total > 0 else { return nil }
        guard chunks.count >= total, (0..<total).allSatisfy({ chunks[$0] != nil }) else {
            throw AppError("Это QR-код приложения Amnezia из \(total) " + plural(total, "части", "частей", "частей")
                + ", а прочитано \(chunks.count). Выберите все картинки сразу или экспортируйте конфиг в формате AmneziaWG (.conf).")
        }
        let data = (0..<total).reduce(into: Data()) { $0.append(chunks[$1] ?? Data()) }
        return "vpn://" + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URL(_ value: String) -> Data? {
        var text = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    /// qCompress output: 4 bytes of big-endian uncompressed length, then a zlib stream.
    private static func inflate(_ data: Data) -> Data? {
        guard data.count > 10, data[4] == 0x78 else { return nil }
        let expected = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard expected > 0, expected <= 8 << 20 else { return nil }
        // Compression's ZLIB is a raw deflate stream: skip the two bytes of zlib header.
        let stream = data.dropFirst(6)
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            stream.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let targetBase = target.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(targetBase, expected, sourceBase, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
    }
}
