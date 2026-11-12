import Foundation

// Admin REST of `sing-box lxd` (docs-lx/lxd-daemon.md §10). The app runs the daemon in plain
// loopback mode (`tls: false` + Bearer secret in daemon.json), so stdlib HTTP is enough.

struct LxdStatus {
    let state: String        // idle | started | fatal ("" when the field was not recognised)
    let lastError: String
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

    func status() async throws -> LxdStatus {
        let (code, data) = try await send("GET", "/admin/status", timeout: 3)
        guard code == 200, let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw AppError("lxd /admin/status: HTTP \(code)")
        }
        // The exact key of the state field is not part of the documented contract, so look it up tolerantly.
        let known = ["idle", "started", "fatal"]
        var state = ""
        for key in ["state", "status", "core_state", "core"] {
            if let value = (object[key] as? String)?.lowercased(), known.contains(value) {
                state = value
                break
            }
        }
        if state.isEmpty {
            for value in object.values {
                if let text = (value as? String)?.lowercased(), known.contains(text) {
                    state = text
                    break
                }
            }
        }
        return LxdStatus(state: state, lastError: object["last_error"] as? String ?? "")
    }

    /// POST /admin/apply — 200 applied / 422 invalid / 500 failed (the daemon rolls back to last-good itself).
    func apply(_ config: Data) async throws {
        let (code, data) = try await send("POST", "/admin/apply", body: config, timeout: 90)
        guard code == 200 else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch code {
            case 422: throw AppError("Конфиг отклонён ядром:\n\(stripANSI(text))")
            case 500: throw AppError("Ядро не запустилось с новым конфигом, выполнен откат на предыдущий:\n\(stripANSI(text))")
            default: throw AppError("lxd /admin/apply: HTTP \(code)\n\(stripANSI(text))")
            }
        }
    }

    func start() async throws {
        _ = try await send("POST", "/admin/start", timeout: 60)
    }

    func logTail(_ lines: Int = 60) async -> String {
        guard let (code, data) = try? await send("GET", "/admin/logs?tail=\(lines)", timeout: 3), code == 200 else { return "" }
        return stripANSI(String(data: data, encoding: .utf8) ?? "")
    }
}
