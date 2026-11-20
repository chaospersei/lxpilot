import Foundation

// The desktop builds of sing-box-lx keep `with_clash_api`; this is the data plane the UI reads:
// groups, delays, connections, traffic totals, logs and the Rule/Global/Direct mode.

struct ClashDelay: Decodable {
    let delay: Int
}

struct ClashProxyInfo: Decodable {
    let type: String
    let now: String?
    let all: [String]?
    let history: [ClashDelay]?
}

struct ClashProxiesResponse: Decodable {
    let proxies: [String: ClashProxyInfo]
}

struct ClashConfigResponse: Decodable {
    let mode: String?
    let modeList: [String]?

    enum CodingKeys: String, CodingKey {
        case mode
        case modeList = "mode-list"
    }
}

struct ClashConnectionMeta: Decodable, Equatable {
    let network: String?
    let type: String?
    let sourceIP: String?
    let sourcePort: String?
    let destinationIP: String?
    let destinationPort: String?
    let host: String?
    let processPath: String?
}

struct ClashConnection: Decodable, Identifiable, Equatable {
    let id: String
    let metadata: ClashConnectionMeta
    let upload: Int64?
    let download: Int64?
    let chains: [String]?
    let rule: String?
    let rulePayload: String?

    var hostText: String {
        let host = (metadata.host?.isEmpty == false ? metadata.host : metadata.destinationIP) ?? "—"
        if let port = metadata.destinationPort, !port.isEmpty { return "\(host):\(port)" }
        return host
    }
    var chainText: String { (chains ?? []).reversed().joined(separator: " → ") }
    var ruleText: String {
        let r = rule ?? ""
        if let payload = rulePayload, !payload.isEmpty { return "\(r) (\(payload))" }
        return r
    }
    var processText: String {
        guard let path = metadata.processPath, !path.isEmpty else { return "" }
        return (path as NSString).lastPathComponent
    }
}

struct ClashConnectionsResponse: Decodable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [ClashConnection]?
    let memory: Int64?
}

struct ClashLog: Decodable {
    let type: String
    let payload: String
}

private struct ClashMessage: Decodable {
    let message: String?
}

struct ClashAPI {
    let port: Int
    let secret: String

    /// Loopback only: never route these requests through the system proxy we may have just set.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 10) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw AppError("Некорректный адрес Clash API: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    private func send(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 10) async throws -> Data {
        let request = try makeRequest(path, method: method, body: body, timeout: timeout)
        let (data, response) = try await ClashAPI.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode(ClashMessage.self, from: data))?.message
            throw AppError(message ?? "Clash API: HTTP \(code)")
        }
        return data
    }

    func isAlive() async -> Bool {
        (try? await send("/version", timeout: 2)) != nil
    }

    /// Something answers HTTP on the port, ours or not: a foreign core rejects our secret with 401,
    /// which `isAlive` would report as "nobody there".
    func reachable() async -> Bool {
        guard let request = try? makeRequest("/version", timeout: 2),
              let (_, response) = try? await ClashAPI.session.data(for: request) else { return false }
        return response is HTTPURLResponse
    }

    func proxies() async throws -> ClashProxiesResponse {
        try JSONDecoder().decode(ClashProxiesResponse.self, from: try await send("/proxies"))
    }

    func config() async throws -> ClashConfigResponse {
        try JSONDecoder().decode(ClashConfigResponse.self, from: try await send("/configs"))
    }

    func setMode(_ mode: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["mode": mode])
        try await send("/configs", method: "PATCH", body: body)
    }

    func select(group: String, proxy: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": proxy])
        try await send("/proxies/\(ClashAPI.encode(group))", method: "PUT", body: body)
    }

    /// Tests every member of a group; returns tag → delay in ms for the ones that answered.
    func groupDelay(_ group: String, url: String, timeoutMs: Int = 5000) async throws -> [String: Int] {
        let path = "/group/\(ClashAPI.encode(group))/delay?url=\(ClashAPI.encode(url))&timeout=\(timeoutMs)"
        let data = try await send(path, timeout: 40)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }

    func proxyDelay(_ proxy: String, url: String, timeoutMs: Int = 5000) async throws -> Int {
        let path = "/proxies/\(ClashAPI.encode(proxy))/delay?url=\(ClashAPI.encode(url))&timeout=\(timeoutMs)"
        let data = try await send(path, timeout: 20)
        return try JSONDecoder().decode(ClashDelay.self, from: data).delay
    }

    func connections() async throws -> ClashConnectionsResponse {
        try JSONDecoder().decode(ClashConnectionsResponse.self, from: try await send("/connections"))
    }

    func closeConnection(_ id: String) async throws {
        try await send("/connections/\(ClashAPI.encode(id))", method: "DELETE")
    }

    func closeAllConnections() async throws {
        try await send("/connections", method: "DELETE")
    }

    /// Long-lived stream of the core's log (one JSON object per line).
    func logLines(level: String) -> AsyncThrowingStream<ClashLog, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try self.makeRequest("/logs?level=\(ClashAPI.encode(level))", timeout: 86_400)
                    let (bytes, _) = try await ClashAPI.session.bytes(for: request)
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let entry = try? JSONDecoder().decode(ClashLog.self, from: data) else { continue }
                        continuation.yield(entry)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
