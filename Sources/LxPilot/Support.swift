import Foundation

typealias JSON = [String: Any]

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Paths

enum Paths {
    static let appSupport: URL = make(
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LxPilot", isDirectory: true))

    static let binDir = make(appSupport.appendingPathComponent("bin", isDirectory: true))
    static let profilesDir = make(appSupport.appendingPathComponent("profiles", isDirectory: true))
    static let runtimeDir = make(appSupport.appendingPathComponent("runtime", isDirectory: true))

    /// lxd keeps its own log next to the state directory (`<parent of state-dir>/lxd.log`).
    static let lxdUserHome = make(appSupport.appendingPathComponent("lxd-user", isDirectory: true))
    static let lxdRootHome = make(appSupport.appendingPathComponent("lxd-root", isDirectory: true))
    static let lxdUserState = make(lxdUserHome.appendingPathComponent("state", isDirectory: true))
    static let lxdRootState = make(lxdRootHome.appendingPathComponent("state", isDirectory: true))

    static let coreBinary = binDir.appendingPathComponent("sing-box")
    static let runConfig = runtimeDir.appendingPathComponent("config.json")
    static let candidateConfig = runtimeDir.appendingPathComponent("candidate.json")
    static let rootScript = runtimeDir.appendingPathComponent("root-launch.sh")
    static let rootLog = runtimeDir.appendingPathComponent("root-core.log")
    static let stopFlag = runtimeDir.appendingPathComponent("stop.flag")
    static let rootPid = runtimeDir.appendingPathComponent("root-core.pid")
    static let settingsFile = appSupport.appendingPathComponent("settings.json")
    static let profilesIndex = appSupport.appendingPathComponent("profiles.json")

    /// Root and user runs must not share a cache file: a root-owned one is not writable by the user run.
    static func cacheDB(root: Bool) -> URL {
        runtimeDir.appendingPathComponent(root ? "cache-root.db" : "cache-user.db")
    }

    static func lxdLog(root: Bool) -> URL {
        (root ? lxdRootHome : lxdUserHome).appendingPathComponent("lxd.log")
    }

    private static func make(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Shell

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
    var combined: String {
        let text = [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return stripANSI(text)
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

enum Shell {
    @discardableResult
    static func runSync(_ exe: String, _ args: [String], cwd: URL? = nil) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        // Drain stderr on another queue so a chatty process cannot block on a full pipe.
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: box.data, encoding: .utf8) ?? "")
    }

    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async -> ShellResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(exe, args, cwd: cwd))
            }
        }
    }

    /// Single-quote a value for /bin/sh.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell script file as root, detached, after the system password prompt.
    static func runScriptAsAdmin(path: String, prompt: String) async -> ShellResult {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = "do shell script \"/bin/sh \" & quoted form of \"\(esc(path))\" & \" > /dev/null 2>&1 &\" "
            + "with prompt \"\(esc(prompt))\" with administrator privileges"
        return await run("/usr/bin/osascript", ["-e", source])
    }
}

func stripANSI(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
}

// MARK: - Formatting

func formatBytes(_ value: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var x = Double(max(value, 0))
    var i = 0
    while x >= 1024 && i < units.count - 1 {
        x /= 1024
        i += 1
    }
    if i == 0 { return "\(Int(x)) B" }
    return String(format: "%.1f", x) + " " + units[i]
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    formatBytes(Int64(max(bytesPerSecond, 0))) + "/s"
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = Int(max(interval, 0))
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

/// First IPv4 address of an `en*` interface (Wi-Fi / Ethernet).
func localIPv4() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let interface = item.pointee
        guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: interface.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        if rc == 0 { return String(cString: host) }
    }
    return nil
}

/// Russian plural form: plural(3, "правило", "правила", "правил").
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

enum Ports {
    /// True when something accepts TCP connections on 127.0.0.1:port. A loopback connect answers at
    /// once, so this is cheap enough to poll.
    static func inUse(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // A reset means a listener exists but is swamped or closing: still not ours to take.
        return result == 0 || errno == ECONNRESET
    }

    /// Whether a process with this pid exists, even one we may not signal (a root core): ESRCH is the
    /// only answer that means "gone".
    static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
