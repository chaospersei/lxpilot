import Foundation

/// Measures what an application actually gets: a fresh HTTPS request through our mixed inbound,
/// so the number includes the proxy handshake, the tunnel and the remote TLS handshake.
enum ProxyChecker {
    struct Result: Equatable {
        var latencyMs: Int?
        var error: String?
        var checkedAt = Date()
        var ok: Bool { latencyMs != nil }
    }

    /// A session that goes through `127.0.0.1:<port>` regardless of the system proxy state.
    static func session(port: Int, timeout: TimeInterval) -> URLSession {
        let proxy: [AnyHashable: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxy
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    static func measure(port: Int, url urlString: String, timeout: TimeInterval = 10) async -> Result {
        guard let url = URL(string: urlString), url.scheme != nil else {
            return Result(error: "Некорректный URL проверки.")
        }
        let session = session(port: port, timeout: timeout)
        defer { session.invalidateAndCancel() }
        let started = Date()
        do {
            let (_, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<400).contains(code) else { return Result(error: "HTTP \(code)") }
            return Result(latencyMs: Int(Date().timeIntervalSince(started) * 1000))
        } catch let error as URLError {
            switch error.code {
            case .timedOut: return Result(error: "Таймаут \(Int(timeout)) с")
            case .cannotFindHost, .dnsLookupFailed: return Result(error: "DNS не разрешил имя")
            case .secureConnectionFailed, .serverCertificateUntrusted: return Result(error: "Ошибка TLS")
            case .networkConnectionLost, .notConnectedToInternet: return Result(error: "Нет сети")
            default: break
            }
            // kCFErrorHTTPSProxyConnectionFailure: nothing listens on the mixed port.
            if (error as NSError).code == 310 || error.code == .cannotConnectToHost {
                return Result(error: "Прокси 127.0.0.1:\(port) не отвечает")
            }
            return Result(error: error.localizedDescription)
        } catch {
            return Result(error: error.localizedDescription)
        }
    }
}
