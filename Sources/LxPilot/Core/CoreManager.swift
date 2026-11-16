import Foundation

/// Owns the sing-box-lx process.
///
/// Two engines:
///  - `lxd`     — `sing-box lxd`: the daemon hosts the core in-process, config changes go through
///                `POST /admin/apply` (validated, with automatic rollback) and the process stays up;
///  - `classic` — `sing-box run`: every config change is a process restart.
///
/// Two privilege levels: a plain child process, or (for TUN, which needs root on macOS) a root
/// process started through the system password prompt and tied to this app by a small watchdog.
@MainActor
final class CoreManager {
    var onUnexpectedExit: ((String) -> Void)?

    private var process: Process?
    private var outputTail = ""
    private var expectingExit = false
    private(set) var runningAsRoot = false
    private(set) var runningEngine: Engine = .lxd
    private var activeClash: ClashAPI?
    private var activeLxd: LxdClient?

    var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.coreBinary.path)
    }

    func version() async -> String {
        guard binaryExists else { return "" }
        let result = await Shell.run(Paths.coreBinary.path, ["version"])
        guard result.ok, let line = result.stdout.components(separatedBy: .newlines).first else { return "" }
        return line.replacingOccurrences(of: "sing-box version ", with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Start

    func start(config: Data, settings: AppSettings) async throws {
        guard binaryExists else { throw AppError("Ядро sing-box-lx не установлено.") }
        try await validateAndStore(config)

        let root = settings.tunEnabled
        let clash = ClashAPI(port: settings.clashPort, secret: settings.clashSecret)
        let lxd = LxdClient(port: settings.lxdPort, secret: settings.lxdSecret)
        if await clash.reachable() {
            throw AppError("Порт Clash API \(settings.clashPort) уже занят другим экземпляром ядра. Остановите его или смените порт в «Инструментах».")
        }
        if settings.engine == .lxd, await lxd.reachable() {
            throw AppError("Порт демона lxd \(settings.lxdPort) уже занят другим демоном. Остановите его или смените порт в «Инструментах».")
        }

        let arguments: [String]
        switch settings.engine {
        case .lxd:
            let stateDir = root ? Paths.lxdRootState : Paths.lxdUserState
            try writeDaemonJSON(to: stateDir, settings: settings)
            // --config-force: always boot from our file; --run: bring the core up regardless of the remembered run state.
            arguments = ["lxd", "--state-dir", stateDir.path, "--config-force", Paths.runConfig.path, "--run"]
        case .classic:
            arguments = ["run", "-c", Paths.runConfig.path, "-D", Paths.runtimeDir.path]
        }

        expectingExit = false
        outputTail = ""
        runningAsRoot = root
        runningEngine = settings.engine
        activeClash = clash
        activeLxd = settings.engine == .lxd ? lxd : nil

        if root {
            try await launchAsRoot(arguments)
        } else {
            try launchAsUser(arguments)
        }

        // The core is up when its Clash API answers.
        let deadline = Date().addingTimeInterval(root ? 45 : 30)
        var failure = ""
        while Date() < deadline {
            if await clash.isAlive() { return }
            if !root, let process, !process.isRunning {
                failure = "Процесс ядра завершился сразу после запуска."
                break
            }
            if settings.engine == .lxd, let status = try? await lxd.status(), status.state == "fatal" {
                failure = status.lastError.isEmpty ? "Демон lxd сообщил о сбое запуска ядра." : status.lastError
                break
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if failure.isEmpty { failure = "Ядро не ответило за отведённое время." }
        let details = await failureDetails()
        await stop()
        throw AppError(details.isEmpty ? failure : "\(failure)\n\n\(details)")
    }

    /// Hot config swap. `lxd` engine only — the caller restarts the process for `classic`.
    func apply(config: Data) async throws {
        guard let lxd = activeLxd, let clash = activeClash else {
            throw AppError("Горячая замена конфига доступна только с демоном lxd.")
        }
        try await validateAndStore(config)
        try await lxd.apply(config)
        try? await lxd.start()
        for _ in 0..<25 {
            if await clash.isAlive() { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    // MARK: - Stop

    func stop() async {
        expectingExit = true
        if runningAsRoot {
            FileManager.default.createFile(atPath: Paths.stopFlag.path, contents: nil)
            if let clash = activeClash {
                for _ in 0..<40 {
                    if !(await clash.isAlive()) { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        } else if let process {
            if process.isRunning { process.terminate() }
            for _ in 0..<25 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process = nil
        runningAsRoot = false
        activeClash = nil
        activeLxd = nil
    }

    /// Used from applicationWillTerminate. The root watchdog also notices that the app's pid is gone.
    func stopSync() {
        expectingExit = true
        if runningAsRoot {
            FileManager.default.createFile(atPath: Paths.stopFlag.path, contents: nil)
        }
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
    }

    // MARK: - Pieces

    private func validateAndStore(_ config: Data) async throws {
        try config.write(to: Paths.candidateConfig, options: .atomic)
        let result = await Shell.run(Paths.coreBinary.path,
                                     ["check", "-c", Paths.candidateConfig.path, "-D", Paths.runtimeDir.path])
        guard result.ok else {
            throw AppError("Конфиг не прошёл проверку ядром (sing-box check):\n\(result.combined)")
        }
        try config.write(to: Paths.runConfig, options: .atomic)
    }

    private func writeDaemonJSON(to stateDir: URL, settings: AppSettings) throws {
        let daemon: JSON = [
            "listen": "127.0.0.1:\(settings.lxdPort)",
            "tls": false,
            "secret": settings.lxdSecret,
        ]
        let data = try JSONSerialization.data(withJSONObject: daemon, options: [.prettyPrinted])
        let file = stateDir.appendingPathComponent("daemon.json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func launchAsUser(_ arguments: [String]) throws {
        let child = Process()
        child.executableURL = Paths.coreBinary
        child.arguments = arguments
        child.currentDirectoryURL = Paths.runtimeDir
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.appendOutput(text) }
        }
        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            let pid = finished.processIdentifier
            Task { @MainActor [weak self] in self?.handleExit(pid: pid, status: status) }
        }
        try child.run()
        process = child
    }

    private func appendOutput(_ text: String) {
        outputTail += stripANSI(text)
        if outputTail.count > 6000 { outputTail = String(outputTail.suffix(4000)) }
    }

    private func handleExit(pid: Int32, status: Int32) {
        guard let current = process, current.processIdentifier == pid else { return }
        process = nil
        if !expectingExit {
            let tail = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
            onUnexpectedExit?("Ядро завершилось с кодом \(status)." + (tail.isEmpty ? "" : "\n\n\(String(tail.suffix(1500)))"))
        }
    }

    private func launchAsRoot(_ arguments: [String]) async throws {
        try? FileManager.default.removeItem(at: Paths.stopFlag)
        let q = Shell.quote
        // A root process must not execute a user-writable binary, so the core is first copied to a
        // root-owned location with its own `--service=copy` (available in recent lx releases).
        // If that is not supported, the app's own copy is used as a fallback.
        let script = """
        #!/bin/sh
        BIN=\(q(Paths.coreBinary.path))
        RUNTIME=\(q(Paths.runtimeDir.path))
        FLAG=\(q(Paths.stopFlag.path))
        LOG=\(q(Paths.rootLog.path))
        APP_PID=\(ProcessInfo.processInfo.processIdentifier)
        EXEC_DIR=/Library/PrivilegedHelperTools/LxPilot
        RB="$BIN"
        if "$BIN" lxd --service=copy --exec-dir "$EXEC_DIR" >/dev/null 2>&1 && [ -x "$EXEC_DIR/sing-box-lxd" ]; then
          RB="$EXEC_DIR/sing-box-lxd"
        fi
        rm -f "$FLAG"
        : > "$LOG"
        cd "$RUNTIME" || exit 1
        "$RB" \(arguments.map(q).joined(separator: " ")) >> "$LOG" 2>&1 &
        P=$!
        while kill -0 "$APP_PID" 2>/dev/null && [ ! -e "$FLAG" ] && kill -0 "$P" 2>/dev/null; do
          sleep 1
        done
        kill "$P" 2>/dev/null
        i=0
        while kill -0 "$P" 2>/dev/null && [ "$i" -lt 6 ]; do
          sleep 1
          i=$((i+1))
        done
        kill -9 "$P" 2>/dev/null
        rm -f "$FLAG"
        """
        try script.write(to: Paths.rootScript, atomically: true, encoding: .utf8)
        let result = await Shell.runScriptAsAdmin(
            path: Paths.rootScript.path,
            prompt: "LxPilot запускает ядро sing-box с правами администратора — это нужно для режима TUN.")
        guard result.ok else {
            if result.stderr.contains("-128") {
                throw AppError("Запуск отменён: для режима TUN нужны права администратора.")
            }
            throw AppError("Не удалось запустить ядро с правами администратора: \(result.combined)")
        }
    }

    private func failureDetails() async -> String {
        var parts: [String] = []
        let tail = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(String(tail.suffix(1500))) }
        if runningAsRoot, let text = try? String(contentsOf: Paths.rootLog, encoding: .utf8) {
            let clean = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { parts.append(String(clean.suffix(1500))) }
        }
        if let lxd = activeLxd {
            var daemonLog = await lxd.logTail(40)
            if daemonLog.isEmpty, let text = try? String(contentsOf: Paths.lxdLog(root: runningAsRoot), encoding: .utf8) {
                daemonLog = stripANSI(text)
            }
            let clean = daemonLog.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { parts.append(String(clean.suffix(1500))) }
        }
        return parts.joined(separator: "\n\n")
    }
}
