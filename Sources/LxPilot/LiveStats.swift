import SwiftUI

/// Per-second numbers from the core. Only the dashboard, the connections page and the menu bar
/// observe this object, so the tick leaves the rest of the window alone.
@MainActor
final class LiveStats: ObservableObject {
    @Published var upSpeed: Double = 0
    @Published var downSpeed: Double = 0
    @Published var upTotal: Int64 = 0
    @Published var downTotal: Int64 = 0
    @Published var memory: Int64 = 0
    @Published var connectionCount = 0
    @Published var connections: [ClashConnection] = []
    /// Bytes per second per connection id, from the last two polls.
    @Published var connectionRates: [String: Double] = [:]
    /// App + core together, sampled with `ps` while the popover is open.
    @Published var cpuPercent: Double = 0
    @Published var residentBytes: Int64 = 0
    /// Always exactly 60 samples (zero-filled): the chart and the menu bar graph rely on it.
    @Published var speedHistory: [SpeedSample] = LiveStats.emptyHistory()
    /// Five minutes for the status item popover, same samples, longer window.
    @Published var longHistory: [SpeedSample] = LiveStats.emptyHistory(LiveStats.longCount)
    static let longCount = 300
    private var sampleCounter = 60

    static func emptyHistory(_ count: Int = 60) -> [SpeedSample] {
        (0..<count).map { SpeedSample(id: $0, up: 0, down: 0) }
    }

    func appendSample(up: Double, down: Double) {
        sampleCounter += 1
        let sample = SpeedSample(id: sampleCounter, up: up, down: down)
        speedHistory.append(sample)
        if speedHistory.count > 60 { speedHistory.removeFirst(speedHistory.count - 60) }
        longHistory.append(sample)
        if longHistory.count > LiveStats.longCount { longHistory.removeFirst(longHistory.count - LiveStats.longCount) }
    }

    func reset() {
        upSpeed = 0
        downSpeed = 0
        upTotal = 0
        downTotal = 0
        memory = 0
        connectionCount = 0
        connections = []
        connectionRates = [:]
        cpuPercent = 0
        residentBytes = 0
        speedHistory = LiveStats.emptyHistory()
        longHistory = LiveStats.emptyHistory(LiveStats.longCount)
    }
}

/// Core log lines. New lines wait in `pending` until `flush()`, so a busy core does not republish
/// the list once per line; both buffers keep at most ~2000 lines.
@MainActor
final class LogStore: ObservableObject {
    @Published private(set) var lines: [LogLine] = []
    private var pending: [LogLine] = []
    private var counter = 0

    var hasPending: Bool { !pending.isEmpty }

    func append(level: String, text: String) {
        counter += 1
        pending.append(LogLine(id: counter, time: Date(), level: level.lowercased(), text: stripANSI(text)))
        if pending.count > 2000 { pending.removeFirst(pending.count - 1500) }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending = []
        if lines.count > 2000 { lines.removeFirst(lines.count - 1500) }
    }

    func clear() {
        lines = []
        pending = []
    }
}
