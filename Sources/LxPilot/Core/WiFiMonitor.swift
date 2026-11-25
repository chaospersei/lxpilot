import CoreWLAN
import Foundation
import Network

/// Tells which Wi-Fi network the Mac is on and when that may have changed.
///
/// Since macOS 14 `CWInterface.ssid()` answers only to apps with Location Services access, and
/// `networksetup` / `ipconfig` redact the name. `system_profiler` still reports it without any
/// permission, so it is the fallback: slow (about 2.5 s), but it runs only when the network changes.
final class WiFiMonitor: NSObject, CWEventDelegate {
    private let client = CWWiFiClient.shared()
    private let path = NWPathMonitor()
    private var onChange: (() -> Void)?

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
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    static var interfaceName: String { CWWiFiClient.shared().interface()?.interfaceName ?? "en0" }

    /// The name of the network the Wi-Fi interface is associated with; nil when Wi-Fi is off or idle.
    static func currentSSID() async -> String? {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty { return ssid }
        let result = await Shell.run("/usr/sbin/system_profiler", ["SPAirPortDataType", "-json", "-detailLevel", "basic"])
        guard result.ok, let data = result.stdout.data(using: .utf8) else { return nil }
        return parseProfiler(data, interface: interfaceName)
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
