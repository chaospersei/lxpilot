import CryptoKit
import Foundation
import Security

// The system service of sing-box-lx (`sing-box lxd --service=install`): a root LaunchDaemon that
// hosts the core, so TUN needs no password per connection. The app is one of its mTLS clients:
// it pins the server certificate by the fingerprint from the pairing invite and presents its own
// self-signed certificate, enrolled once through POST /admin/enroll (docs-lx/lxd-daemon.md §9).

/// One-time pairing invite printed by `--service=install --invite-name` or `client add`.
struct ServiceInvite: Equatable {
    let address: String       // host:port
    let fingerprint: String   // SHA-256 of the server certificate DER, lowercase hex
    let code: String

    static func parse(_ text: String) -> ServiceInvite? {
        let pattern = #"([^\s#]+:[0-9]+)#([0-9a-fA-F]{64})#([A-Za-z0-9-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let a = Range(match.range(at: 1), in: text), let f = Range(match.range(at: 2), in: text),
              let c = Range(match.range(at: 3), in: text) else { return nil }
        return ServiceInvite(address: String(text[a]), fingerprint: text[f].lowercased(), code: String(text[c]))
    }
}

/// `lxd --service=status` exit codes.
enum ServiceStatus: Equatable {
    case running, reinstallNeeded, notInstalled, copyOnly, notRunning, unknown(Int32)

    init(exitCode: Int32) {
        switch exitCode {
        case 0: self = .running
        case 2: self = .reinstallNeeded
        case 3: self = .notInstalled
        case 4: self = .copyOnly
        case 5: self = .notRunning
        default: self = .unknown(exitCode)
        }
    }

    var title: String {
        switch self {
        case .running: return "установлена и работает"
        case .notRunning: return "установлена, но не запущена"
        case .reinstallNeeded: return "установлена старой версией, нужна переустановка"
        case .copyOnly: return "есть только root-копия, службы нет"
        case .notInstalled: return "не установлена"
        case .unknown(let code): return "неизвестно (код \(code))"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .running, .notRunning, .reinstallNeeded: return true
        default: return false
        }
    }
}

enum SystemService {
    static let label = "com.leadaxe.sing-box-lxd"
    static let stateDir = "/Library/Application Support/sing-box-lxd/state"
    static let logPath = "/Library/Application Support/sing-box-lxd/lxd.log"
    static let clientName = "LxPilot"

    static func status() async -> (ServiceStatus, String) {
        let result = await Shell.run(Paths.coreBinary.path, ["lxd", "--service=status"])
        return (ServiceStatus(exitCode: result.status), stripANSI(result.combined))
    }

    /// Installs (or reinstalls) the LaunchDaemon from the app's core binary and mints an invite.
    static func install() async throws -> ServiceInvite {
        let output = try await admin(["lxd", "--service=install", "--invite-name", clientName],
                                     prompt: "LxPilot устанавливает системную службу sing-box-lx: ядро с правами root, чтобы TUN включался без запроса пароля.")
        if let invite = ServiceInvite.parse(output) { return invite }
        // Older builds print no invite from install; a separate `client add` always does.
        return try await pair()
    }

    /// A fresh invite for this app; a named invite replaces the client of that name.
    static func pair() async throws -> ServiceInvite {
        let output = try await admin(["lxd", "client", "add", "--name", clientName, "--state-dir", stateDir],
                                     prompt: "LxPilot запрашивает у системной службы sing-box-lx приглашение для сопряжения.")
        guard let invite = ServiceInvite.parse(output) else {
            throw AppError("Служба не выдала приглашение для сопряжения:\n\(output.suffix(600))")
        }
        return invite
    }

    static func uninstall() async throws {
        _ = try await admin(["lxd", "--service=uninstall"], prompt: "LxPilot удаляет системную службу sing-box-lx.")
    }

    private static func admin(_ arguments: [String], prompt: String) async throws -> String {
        let command = ([Paths.coreBinary.path] + arguments).map(Shell.quote).joined(separator: " ")
        let result = await Shell.runAsAdmin(command: command, prompt: prompt)
        guard result.ok else {
            if result.stderr.contains("-128") { throw AppError("Отменено: без прав администратора это сделать нельзя.") }
            throw AppError("Команда службы завершилась с ошибкой:\n\(stripANSI(result.combined).suffix(800))")
        }
        return stripANSI(result.combined)
    }
}

/// The app's client certificate: a self-signed RSA pair made with the system openssl and kept as
/// PKCS#12 in the app folder. macOS 15+ imports it into memory only; older systems get a private
/// file keychain next to it (`service.keychain`, key importable by any app via `security import -A`)
/// — the login keychain would re-prompt for every ad-hoc build. RSA: the memory-only import
/// rejects EC keys.
struct ClientIdentity {
    let identity: SecIdentity
    let certificatePEM: String

    private static var p12: URL { Paths.serviceDir.appendingPathComponent("client.p12") }
    private static var certFile: URL { Paths.serviceDir.appendingPathComponent("client-cert.pem") }
    private static var keyFile: URL { Paths.serviceDir.appendingPathComponent("client-key.pem") }
    private static var keychainFile: URL { Paths.serviceDir.appendingPathComponent("service.keychain-db") }

    static var exists: Bool { FileManager.default.fileExists(atPath: p12.path) }

    static func load(password: String) throws -> ClientIdentity? {
        guard FileManager.default.fileExists(atPath: p12.path) else { return nil }
        let pem = (try? String(contentsOf: certFile, encoding: .utf8)) ?? ""
        if #available(macOS 15, *) {
            return ClientIdentity(identity: try importToMemory(password: password), certificatePEM: pem)
        }
        return ClientIdentity(identity: try loadFromKeychain(password: password), certificatePEM: pem)
    }

    @available(macOS 15, *)
    private static func importToMemory(password: String) throws -> SecIdentity {
        let data = try Data(contentsOf: p12)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String] else {
            throw AppError("Клиентский сертификат службы не читается (ошибка \(status)). Выполните сопряжение заново.")
        }
        return raw as! SecIdentity
    }

    static func loadFromKeychain(password: String) throws -> SecIdentity {
        var keychain: SecKeychain?
        guard SecKeychainOpen(keychainFile.path, &keychain) == errSecSuccess, let keychain else {
            throw AppError("Хранилище сертификата службы не открывается. Выполните сопряжение заново.")
        }
        SecKeychainUnlock(keychain, UInt32(password.utf8.count), password, true)
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchSearchList as String: [keychain],
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            throw AppError("Клиентский сертификат службы не найден в хранилище (ошибка \(status)). Выполните сопряжение заново.")
        }
        return result as! SecIdentity
    }

    static func generate(password: String) async throws -> ClientIdentity {
        let passFile = Paths.serviceDir.appendingPathComponent(".p12pass")
        try password.write(to: passFile, atomically: true, encoding: .utf8)   // `file:` takes the first line as is
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passFile.path)
        defer { try? FileManager.default.removeItem(at: passFile) }

        let request = await Shell.run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=LxPilot",
            "-keyout", keyFile.path, "-out", certFile.path,
        ])
        guard request.ok else { throw AppError("Не удалось создать клиентский сертификат (openssl):\n\(request.combined.suffix(500))") }
        let export = await Shell.run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", keyFile.path, "-in", certFile.path, "-passout", "file:\(passFile.path)", "-out", p12.path,
        ])
        guard export.ok else { throw AppError("Не удалось упаковать клиентский сертификат (openssl pkcs12):\n\(export.combined.suffix(500))") }
        for file in [keyFile, certFile, p12] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if #unavailable(macOS 15) {
            try await importIntoKeychain(password: password)
        }
        guard let loaded = try load(password: password) else { throw AppError("Сертификат создан, но файл не найден.") }
        return loaded
    }

    /// macOS 13–14: a fresh file keychain holding only this identity; the key is marked accessible
    /// to any application, so a rebuilt (re-signed) binary does not trigger the keychain prompt.
    static func importIntoKeychain(password: String) async throws {
        try? FileManager.default.removeItem(at: keychainFile)
        let create = await Shell.run("/usr/bin/security", ["create-keychain", "-p", password, keychainFile.path])
        guard create.ok else { throw AppError("Не удалось создать хранилище сертификата:\n\(create.combined.suffix(300))") }
        _ = await Shell.run("/usr/bin/security", ["set-keychain-settings", keychainFile.path])   // never auto-lock
        let imported = await Shell.run("/usr/bin/security", ["import", p12.path, "-k", keychainFile.path, "-P", password, "-A", "-T", "/usr/bin/security"])
        guard imported.ok else { throw AppError("Не удалось импортировать сертификат в хранилище:\n\(imported.combined.suffix(300))") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keychainFile.path)
    }
}

/// URLSession that trusts exactly one server certificate (by SHA-256 of its DER) and, when given
/// an identity, answers the client-certificate challenge with it.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate {
    let fingerprint: String
    let identity: SecIdentity?

    init(fingerprint: String, identity: SecIdentity?) {
        self.fingerprint = fingerprint
        self.identity = identity
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust, Self.fingerprint(of: trust) == fingerprint else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            if let identity {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// One session per (fingerprint, identity): sessions hold threads and must not be made per request.
@MainActor
enum PinnedSessions {
    private static var cache: [String: URLSession] = [:]

    static func session(fingerprint: String, identity: SecIdentity?) -> URLSession {
        let key = fingerprint + (identity.map { "+\(Unmanaged.passUnretained($0).toOpaque())" } ?? "")
        if let session = cache[key] { return session }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: PinnedSessionDelegate(fingerprint: fingerprint, identity: identity), delegateQueue: nil)
        cache[key] = session
        return session
    }
}

enum ServiceEnroll {
    /// POST /admin/enroll with the one-time code: no Authorization, no client certificate yet.
    /// Returns the fingerprint the daemon recorded for our certificate.
    @MainActor
    static func enroll(invite: ServiceInvite, name: String, certificatePEM: String) async throws -> String {
        guard let url = URL(string: "https://\(invite.address)/admin/enroll") else { throw AppError("Некорректный адрес службы: \(invite.address)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": invite.code, "name": name, "cert_pem": certificatePEM])
        let session = PinnedSessions.session(fingerprint: invite.fingerprint, identity: nil)
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        guard code == 200, object?["enrolled"] as? Bool == true else {
            let text = (object?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw AppError("Служба отклонила сопряжение (HTTP \(code)): \(text.prefix(300))")
        }
        return object?["fingerprint"] as? String ?? ""
    }
}
