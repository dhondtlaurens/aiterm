import Foundation
import Synchronization

/// Keeps the Mac awake with the lid closed, on one known Wi-Fi network: the decisions, over ports a
/// test fakes. Every method blocks — a scan takes seconds, `sudo` a moment — so the app calls them
/// on one serial queue of its own, never two at once.
public final class BackpackMode: Sendable {
    private let ports: BackpackPorts
    public let settings: BackpackSettings
    private let current = Mutex(BackpackState.off)

    public init(ports: BackpackPorts, settings: BackpackSettings) {
        self.ports = ports
        self.settings = settings
    }

    public var state: BackpackState { current.withLock { $0 } }

    public func setup() -> BackpackSetup {
        BackpackSetup(sleepRule: ports.lidSleep.isAllowed(), location: ports.location.isAuthorized(), network: settings.network)
    }

    /// The spec's order: setup, battery, range, join, marker, then `disablesleep 1`. The first
    /// failure leaves the mode off and nothing changed but, at most, the Wi-Fi network.
    public func turnOn() -> Result<BackpackStatus, BackpackRefusal> {
        if case .on(let status) = state { return .success(status) }
        let setup = setup()
        guard setup.isComplete, let network = setup.network else { return .failure(.needsSetup) }
        let power = ports.power.reading(), cutoff = settings.cutoff
        if power.onBattery, let level = power.level, level <= cutoff { return .failure(.batteryLow(level: level)) }
        if ports.wifi.currentNetwork() != network {
            guard ports.wifi.isInRange(network) else { return .failure(.notInRange(network: network)) }
            guard ports.wifi.join(network, password: settings.password) else { return .failure(.joinFailed(network: network)) }
        }
        settings.engaged = true
        guard ports.lidSleep.setDisabled(true) else {
            settings.engaged = false
            return .failure(.needsSetup)
        }
        let status = BackpackStatus(network: network, joined: true, power: power, cutoff: cutoff)
        current.withLock { $0 = .on(status) }
        return .success(status)
    }

    /// Puts sleep back. The marker is cleared only once `disablesleep 0` succeeded, so a failure is
    /// retried by the next launch. The Wi-Fi network stays as it is.
    public func turnOff() {
        guard state.isOn || settings.engaged else { return }
        if ports.lidSleep.setDisabled(false) { settings.engaged = false }
        current.withLock { $0 = .off }
    }

    /// A launch after a crash or a force quit: the marker says AiTerm left sleep disabled.
    public func recoverAtLaunch() {
        guard settings.engaged else { return }
        if ports.lidSleep.setDisabled(false) { settings.engaged = false }
    }

    /// The 60 s check while on: the battery cutoff, then the network, rejoining it when it is back.
    public func tick() -> BackpackTick {
        guard case .on(let old) = state else { return .unchanged }
        let power = ports.power.reading()
        if power.onBattery, let level = power.level, level <= old.cutoff {
            turnOff()
            return .turnedOff(level: level)
        }
        var joined = ports.wifi.currentNetwork() == old.network
        if !joined, ports.wifi.isInRange(old.network) { joined = ports.wifi.join(old.network, password: settings.password) }
        let next = BackpackStatus(network: old.network, joined: joined, power: power, cutoff: old.cutoff)
        guard next != old else { return .unchanged }
        current.withLock { if $0.isOn { $0 = .on(next) } }
        return .changed
    }
}
