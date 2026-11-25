import CoreWLAN
import Foundation
import Network

/// Tells which Wi-Fi network the Mac is on and when that may have changed.
///
/// Since macOS 14 `CWInterface.ssid()` answers only to apps with Location Services access, and
/// `networksetup` / `ipconfig` redact the name. `system_profiler` still reports it without any
/// permission, so it is the fallback: slow (about 2.5 s), but it runs only when the network changes.
/// What a lookup found. `.unknown` is an associated interface whose name nothing would give — seen
/// while the Mac moves between access points of one network. It must not be read as "no Wi-Fi".
enum WiFiLookup: Equatable {
    case network(String)
    case none
    case unknown

    var name: String? {
        if case .network(let name) = self { return name }
        return nil
    }
}

final class WiFiMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let path = NWPathMonitor()
    private var onChange: (() -> Void)?
    private let watchQueue = DispatchQueue(label: "lxpilot.wifi-watch", qos: .utility)
    private var watchTimer: DispatchSourceTimer?
    private var lastLink: String?

    /// `onChange` is a hint, not a fact: it also fires when a tunnel comes up or the link flaps.
    /// It is called on the main queue.
    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        client.delegate = self
        try? client.startMonitoringEvent(with: .ssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        // CoreWLAN events are not guaranteed without Location access; a path change covers the gap.
        path.pathUpdateHandler = { [weak self] _ in self?.onChange?() }
        path.start(queue: .main)
        // Neither source is complete: an association that ends or begins without an event (a roam
        // caught half-way, a wake from sleep) would leave the last lookup's answer standing for
        // good. The link state itself costs nothing to read, so it is compared every few seconds.
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let link = WiFiMonitor.linkKey
            if let last = self.lastLink, last != link {
                DispatchQueue.main.async { [weak self] in self?.onChange?() }
            }
            self.lastLink = link
        }
        timer.resume()
        watchTimer = timer
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    static var interfaceName: String { CWWiFiClient.shared().interface()?.interfaceName ?? "en0" }

    /// Link state without Location access: the name is withheld, the radio's own numbers are not.
    static var isPoweredOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }

    static var isAssociated: Bool {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return false }
        return interface.interfaceMode() != .none || interface.rssiValue() != 0
    }

    /// Changes when the Mac leaves or joins a network; a roam inside one network keeps it.
    static var linkKey: String { "\(isAssociated)|\(ipv4(of: interfaceName) ?? "-")" }

    private static func ipv4(of interfaceName: String) -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = item.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name) == interfaceName else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// The network the Wi-Fi interface is on. A lookup that lands in the middle of a
    /// re-association finds no link or no name, so both are asked again before they are believed.
    static func lookup() async -> WiFiLookup {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty { return .network(ssid) }
        let attempts = 3
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            guard isPoweredOn else { return .none }
            guard isAssociated else { continue }
            let result = await Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json", "-detailLevel", "basic"])
            if result.ok, let data = result.stdout.data(using: .utf8), let name = parseProfiler(data, interface: interfaceName) {
                return .network(name)
            }
        }
        return isAssociated ? .unknown : .none
    }

    static func parseProfiler(_ data: Data, interface: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPAirPortDataType"] as? [[String: Any]] else { return nil }
        let interfaces = sections.flatMap { $0["spairport_airport_interfaces"] as? [[String: Any]] ?? [] }
        func name(_ entry: [String: Any]) -> String? {
            guard let current = entry["spairport_current_network_information"] as? [String: Any],
                  let name = current["_name"] as? String, !name.isEmpty, name != "<redacted>" else { return nil }
            return name
        }
        if let own = interfaces.first(where: { $0["_name"] as? String == interface }) { return name(own) }
        return interfaces.lazy.compactMap(name).first
    }

    /// Networks this Mac has joined before, most preferred first: candidates for a rule.
    static func knownNetworks() async -> [String] {
        let result = await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", interfaceName])
        guard result.ok else { return [] }
        return result.stdout.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
