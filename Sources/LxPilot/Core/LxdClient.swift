import Foundation
import Security

// Admin REST of `sing-box lxd` (docs-lx/lxd-daemon.md §10). The app runs the daemon in plain
// loopback mode (`tls: false` + Bearer secret in daemon.json), so stdlib HTTP is enough.

struct LxdStatus {
    let state: String        // idle | started | fatal ("" when the field was not recognised)
    let lastError: String
}

struct LxdStats {
    let uplinkTotal: Int64
    let downlinkTotal: Int64
    let connections: Int
    let coreUptimeSeconds: Double
}

struct LxdClient {
    let baseURL: URL
    let secret: String
    let session: URLSession

    /// Our own daemon on loopback: plain HTTP, Bearer secret from daemon.json that we wrote.
    init(port: Int, secret: String) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        session = ClashAPI.session
    }

    /// The system service: TLS pinned to the server certificate, our enrolled client certificate.
    @MainActor
    init(address: String, fingerprint: String, identity: SecIdentity) {
        baseURL = URL(string: "https://\(address)") ?? URL(string: "https://127.0.0.1:19091")!
        secret = ""
        session = PinnedSessions.session(fingerprint: fingerprint, identity: identity)
    }

    private func makeRequest(_ method: String, _ path: String, body: Data?, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AppError("Некорректный адрес lxd: \(path)") }
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

    private func send(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 10) async throws -> (Int, Data) {
        let (data, response) = try await session.data(for: try makeRequest(method, path, body: body, timeout: timeout))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// POST /admin/stop: the core goes down, the daemon stays.
    func stop() async throws {
        let (code, _) = try await send("POST", "/admin/stop", timeout: 30)
        guard code == 200 else { throw AppError("lxd /admin/stop: HTTP \(code)") }
    }

    /// For applicationWillTerminate, where nothing async can be awaited.
    func stopSync() {
        guard let request = try? makeRequest("POST", "/admin/stop", body: nil, timeout: 8) else { return }
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 9)
    }

    func isAlive() async -> Bool {
        guard let (code, _) = try? await send("GET", "/admin/status", timeout: 2) else { return false }
        return code == 200
    }

    /// Something answers HTTP on the port, ours or not (a foreign daemon replies 401 to our secret).
    func reachable() async -> Bool {
        guard let (code, _) = try? await send("GET", "/admin/status", timeout: 2) else { return false }
        return code != 0
    }

    func status() async throws -> LxdStatus {
        let (code, data) = try await send("GET", "/admin/status", timeout: 3)
        guard code == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw AppError("lxd /admin/status: HTTP \(code)")
        }
        // Verified on 1.14.4-lx.33: the field is `status` (idle | started | fatal).
        let state = (object["status"] as? String)?.lowercased() ?? ""
        return LxdStatus(state: state, lastError: object["last_error"] as? String ?? "")
    }

    /// POST /admin/apply — 200 `{"applied":true,"active_sha256":…}` / 422 invalid / 500 failed (the daemon
    /// rolls back to last-good itself). Error bodies are JSON `{"applied":false,"error":"…","rolled_back":bool}`.
    func apply(_ config: Data) async throws {
        let (code, data) = try await send("POST", "/admin/apply", body: config, timeout: 90)
        guard code == 200 else {
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = ((try? JSONSerialization.jsonObject(with: data)) as? JSON)?["error"] as? String ?? raw
            switch code {
            case 422: throw AppError("Конфиг отклонён ядром:\n\(stripANSI(text))")
            case 500: throw AppError("Ядро не запустилось с новым конфигом, выполнен откат на предыдущий:\n\(stripANSI(text))")
            default: throw AppError("lxd /admin/apply: HTTP \(code)\n\(stripANSI(text))")
            }
        }
    }

    /// GET /admin/stats: traffic totals and the connection count without the connection list.
    func stats() async throws -> LxdStats {
        let (code, data) = try await send("GET", "/admin/stats", timeout: 3)
        guard code == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw AppError("lxd /admin/stats: HTTP \(code)")
        }
        func int64(_ key: String) -> Int64 { (object[key] as? NSNumber)?.int64Value ?? 0 }
        let connections: Int
        switch object["connections"] {
        case let number as NSNumber: connections = number.intValue
        case let list as [Any]: connections = list.count
        default: connections = 0
        }
        return LxdStats(uplinkTotal: int64("uplink_total"), downlinkTotal: int64("downlink_total"), connections: connections,
                        coreUptimeSeconds: (object["core_uptime_seconds"] as? NSNumber)?.doubleValue ?? 0)
    }

    func start() async throws {
        _ = try await send("POST", "/admin/start", timeout: 60)
    }

    func logTail(_ lines: Int = 60) async -> String {
        guard let (code, data) = try? await send("GET", "/admin/logs?tail=\(lines)", timeout: 3), code == 200 else { return "" }
        return stripANSI(String(data: data, encoding: .utf8) ?? "")
    }
}
