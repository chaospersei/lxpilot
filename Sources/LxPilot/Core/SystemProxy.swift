import Foundation

/// macOS system proxy via `networksetup`, applied to every enabled network service.
enum SystemProxy {
    private static let tool = "/usr/sbin/networksetup"

    static func services() -> [String] {
        let result = Shell.runSync(tool, ["-listallnetworkservices"])
        return result.stdout
            .components(separatedBy: .newlines)
            .dropFirst()                                   // "An asterisk (*) denotes that a network service is disabled."
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// Returns an error description, or nil on success.
    static func enable(port: Int, bypass: [String]) -> String? {
        var failure: String?
        for service in services() {
            let steps: [[String]] = [
                ["-setwebproxy", service, "127.0.0.1", "\(port)"],
                ["-setsecurewebproxy", service, "127.0.0.1", "\(port)"],
                ["-setsocksfirewallproxy", service, "127.0.0.1", "\(port)"],
                ["-setproxybypassdomains", service] + (bypass.isEmpty ? ["Empty"] : bypass),
            ]
            for step in steps {
                let result = Shell.runSync(tool, step)
                if !result.ok && failure == nil {
                    failure = "Не удалось задать системный прокси для «\(service)»: \(result.combined)"
                }
            }
        }
        return failure
    }

    @discardableResult
    static func disable() -> String? {
        var failure: String?
        for service in services() {
            for flag in ["-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate"] {
                let result = Shell.runSync(tool, [flag, service, "off"])
                if !result.ok && failure == nil {
                    failure = "Не удалось снять системный прокси для «\(service)»: \(result.combined)"
                }
            }
        }
        return failure
    }
}
