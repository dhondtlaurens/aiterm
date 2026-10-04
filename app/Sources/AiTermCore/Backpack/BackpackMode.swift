import Foundation
import Synchronization

/// Keeps the Mac awake with the lid closed, on one known Wi-Fi network: the decisions, over ports a
/// test fakes. Every method blocks — a scan takes seconds, `sudo` a moment — so the app calls them
/// on one serial queue of its own, never two at once.
public final class BackpackMode: Sendable {
    private let ports: BackpackPorts
    public let settings: BackpackSettings
    private let now: @Sendable () -> Date
    private let current = Mutex(BackpackState.off)
    /// Set by `close()`, for good: no turn-on gets past it.
    private let closed = Mutex(false)
    /// Off the network: when the next rejoin may be tried, and how many have been since the drop.
    private let rejoin = Mutex<(next: Date?, tries: Int)>((nil, 0))

    /// The waits between rejoin attempts: a 5 s check that scanned every time would keep the Wi-Fi
    /// busy for as long as the hotspot is gone.
    static let rejoinDelays: [TimeInterval] = [5, 10, 20, 30]

    public init(ports: BackpackPorts, settings: BackpackSettings, now: @escaping @Sendable () -> Date = Date.init) {
        self.ports = ports
        self.settings = settings
        self.now = now
    }

    public var state: BackpackState { current.withLock { $0 } }

    public func setup() -> BackpackSetup {
        BackpackSetup(sleepRule: ports.lidSleep.isAllowed(), location: ports.location.isAuthorized(), network: settings.network)
    }

    /// The spec's order: setup, battery, join, marker, then `disablesleep 1`. The first failure
    /// leaves the mode off and nothing changed but, at most, the Wi-Fi network. The join comes
    /// without a scan first: a locked iPhone's hotspot is missing from scans but joins with its
    /// password; the scan only decides which failure to report.
    public func turnOn() -> Result<BackpackStatus, BackpackRefusal> {
        if closed.withLock({ $0 }) { return .failure(.quitting) }
        if case .on(let status) = state { return .success(status) }
        let setup = setup()
        guard setup.isComplete, let network = setup.network else { return .failure(.needsSetup) }
        let power = ports.power.reading(), cutoff = settings.cutoff
        if power.onBattery, let level = power.level, level <= cutoff { return .failure(.batteryLow(level: level)) }
        if ports.wifi.currentNetwork() != network, !ports.wifi.join(network, password: settings.password) {
            return .failure(ports.wifi.isInRange(network) ? .joinFailed(network: network) : .notInRange(network: network))
        }
        // Checked again: quit may have come while the join ran.
        if closed.withLock({ $0 }) { return .failure(.quitting) }
        settings.engaged = true
        guard ports.lidSleep.setDisabled(true) else {
            settings.engaged = false
            return .failure(.needsSetup)
        }
        let status = BackpackStatus(network: network, joined: true, power: power, cutoff: cutoff)
        current.withLock { $0 = .on(status) }
        rejoin.withLock { $0 = (nil, 0) }
        return .success(status)
    }

    /// Puts sleep back. The marker is cleared only once `disablesleep 0` succeeded, so a failure is
    /// retried by the next launch. The Wi-Fi network stays as it is.
    public func turnOff() {
        guard state.isOn || settings.engaged else { return }
        if ports.lidSleep.setDisabled(false) { settings.engaged = false }
        current.withLock { $0 = .off }
    }

    /// Whether a rejoin may be tried now; if so, the next one is booked.
    private func rejoinIsDue() -> Bool {
        let time = now()
        return rejoin.withLock { state in
            if let next = state.next, time < next { return false }
            let delay = Self.rejoinDelays[min(state.tries, Self.rejoinDelays.count - 1)]
            state = (time.addingTimeInterval(delay), state.tries + 1)
            return true
        }
    }

    /// Quit: from now on every turn-on refuses. Safe from any thread, and immediate — unlike the
    /// queue the app runs this mode on — so a turn-on still on its way finds it.
    public func close() {
        closed.withLock { $0 = true }
    }

    /// A launch after a crash or a force quit: the marker says AiTerm left sleep disabled.
    public func recoverAtLaunch() {
        guard settings.engaged else { return }
        if ports.lidSleep.setDisabled(false) { settings.engaged = false }
    }

    /// The 5 s check while on: the battery cutoff, then the network. Off it, a rejoin is tried at
    /// once, then after each of `rejoinDelays`, the last repeating; joined again, that starts over.
    public func tick() -> BackpackTick {
        guard case .on(let old) = state else { return .unchanged }
        let power = ports.power.reading()
        if power.onBattery, let level = power.level, level <= old.cutoff {
            turnOff()
            return .turnedOff(level: level)
        }
        var joined = ports.wifi.currentNetwork() == old.network
        if !joined, rejoinIsDue() {
            joined = ports.wifi.join(old.network, password: settings.password)
        }
        if joined { rejoin.withLock { $0 = (nil, 0) } }
        let next = BackpackStatus(network: old.network, joined: joined, power: power, cutoff: old.cutoff)
        guard next != old else { return .unchanged }
        current.withLock { if $0.isOn { $0 = .on(next) } }
        return .changed
    }
}
