import Foundation

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
}

struct LxdClient {
    let port: Int
    let secret: String

    private func send(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 10) async throws -> (Int, Data) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw AppError("Некорректный адрес lxd: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if !secret.isEmpty { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await ClashAPI.session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
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
        return LxdStats(uplinkTotal: int64("uplink_total"), downlinkTotal: int64("downlink_total"), connections: connections)
    }

    func start() async throws {
        _ = try await send("POST", "/admin/start", timeout: 60)
    }

    func logTail(_ lines: Int = 60) async -> String {
        guard let (code, data) = try? await send("GET", "/admin/logs?tail=\(lines)", timeout: 3), code == 200 else { return "" }
        return stripANSI(String(data: data, encoding: .utf8) ?? "")
    }
}
