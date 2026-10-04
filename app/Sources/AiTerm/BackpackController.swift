import Foundation
import AiTermCore

/// A turn-on or turn-off under way, which the header draws as a spinner.
enum BackpackTransition: Equatable { case turningOn, turningOff }

/// Backpack Mode as the app drives it: `BackpackMode`'s blocking calls run on one serial queue, so a
/// turn-on, a turn-off and a tick never overlap, and their outcome is published here on the main
/// actor for the menu item, Settings › Backpack and the header glyph.
@MainActor
@Observable
final class BackpackController {
    private(set) var state: BackpackState = .off
    private(set) var setup = BackpackSetup(sleepRule: false, location: false, network: nil)
    /// The battery as last read: with setup, and on every check while on.
    private(set) var power = PowerReading.mains
    /// A turn-on, turn-off or setup is running. ⌘B is ignored until it ends.
    private(set) var busy = false
    /// Set for as long as a turn-on or turn-off runs: joining a hotspot takes seconds.
    private(set) var transition: BackpackTransition?

    @ObservationIgnored private let mode: BackpackMode
    @ObservationIgnored private let ports: BackpackPorts
    @ObservationIgnored private let toast: @MainActor (String) -> Void
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let queue = DispatchQueue(label: "com.laurensdhondt.aiterm.backpack")
    @ObservationIgnored private var ticking: Task<Void, Never>?

    init(ports: BackpackPorts, settings: BackpackSettings, tickInterval: Duration = .seconds(5),
         toast: @escaping @MainActor (String) -> Void) {
        self.ports = ports
        mode = BackpackMode(ports: ports, settings: settings)
        self.tickInterval = tickInterval
        self.toast = toast
        setup.network = settings.network
    }

    /// Over the inert ports, in memory: for a sheet or a test that never turns it on.
    static func inert() -> BackpackController {
        BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
    }

    var isOn: Bool { state.isOn }

    /// Settings › Backpack's two fields, written on Save. A change takes effect at the next turn-on.
    var network: String? {
        get { mode.settings.network }
        set { mode.settings.network = newValue; setup.network = newValue }
    }
    var cutoff: Int {
        get { mode.settings.cutoff }
        set { mode.settings.cutoff = newValue }
    }
    /// Read off the main actor's hot path only by Settings, once as it opens.
    var password: String? {
        get { mode.settings.password }
        set { mode.settings.password = newValue }
    }

    /// ⌘B, and the header glyph's Turn Off.
    func toggle() {
        guard !busy else { return }
        Task { isOn ? await turnOff() : await turnOn() }
    }

    func turnOn() async {
        guard !busy, !isOn else { return }
        busy = true
        transition = .turningOn
        defer { busy = false; transition = nil }
        let mode = self.mode
        let result = (try? await BackgroundWork.run(on: queue) { mode.turnOn() }) ?? .failure(.needsSetup)
        state = mode.state
        switch result {
        case .success(let status):
            // A quit that ran while this was in flight has already turned it off again.
            guard state.isOn else { return }
            toast(BackpackCopy.turnedOn(network: status.network))
            startTicking()
        case .failure(let refusal):
            toast(refusal.message)
            if refusal == .needsSetup { await refreshSetupWhileBusy() }
        }
    }

    func turnOff() async {
        guard !busy, isOn else { return }
        busy = true
        transition = .turningOff
        defer { busy = false; transition = nil }
        ticking?.cancel()
        let mode = self.mode
        _ = try? await BackgroundWork.run(on: queue) { mode.turnOff() }
        state = mode.state
    }

    func refreshSetup() async {
        guard !busy else { return }
        await refreshSetupWhileBusy()
    }

    /// Set Up…: the sudoers rule's admin prompt, then the Location prompt, each only if missing.
    func setUp() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await refreshSetupWhileBusy()
        if setup.missingSteps.contains(.sleepRule) {
            let installer = ports.installer
            _ = try? await BackgroundWork.run(on: queue) { installer.install() }
        }
        if setup.missingSteps.contains(.location) { _ = await ports.location.request() }
        await refreshSetupWhileBusy()
    }

    /// Remove Setup: off first, then the rule. Location stays granted; System Settings revokes it.
    func removeSetup() async {
        if isOn { await turnOff() }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let installer = ports.installer
        _ = try? await BackgroundWork.run(on: queue) { installer.remove() }
        await refreshSetupWhileBusy()
    }

    func knownNetworks() async -> [String] {
        let wifi = ports.wifi
        return (try? await BackgroundWork.run { wifi.knownNetworks() }) ?? []
    }

    /// The 5 s check: the cutoff, and the network.
    func tick() async {
        let mode = self.mode
        let outcome = try? await BackgroundWork.run(on: queue) { mode.tick() }
        state = mode.state
        if case .on(let status) = state { power = status.power }
        if case .turnedOff(let level)? = outcome {
            ticking?.cancel()
            toast(BackpackCopy.cutOff(level: level))
        }
    }

    /// At launch, before anything else: a marker left by a crash puts sleep back.
    func recoverAtLaunch() {
        let mode = self.mode
        queue.sync { mode.recoverAtLaunch() }
    }

    /// At quit. Synchronous: it waits behind a turn-on still running on the queue, then turns the
    /// mode off, so AiTerm never exits leaving lid sleep disabled.
    func shutdown() {
        ticking?.cancel()
        let mode = self.mode
        // Closed before waiting: a turn-on whose work has not reached the queue yet would otherwise
        // run after this turn-off and leave sleep disabled behind the quit.
        mode.close()
        queue.sync { mode.turnOff() }
        state = mode.state
    }

    #if DEBUG
    /// Snapshots draw a state without turning anything on.
    func preview(state: BackpackState, setup: BackpackSetup, transition: BackpackTransition? = nil) {
        self.state = state
        self.setup = setup
        self.transition = transition
        if case .on(let status) = state { power = status.power }
    }
    #endif

    private func refreshSetupWhileBusy() async {
        let mode = self.mode, powerSource = ports.power
        if let fresh = try? await BackgroundWork.run(on: queue, { (mode.setup(), powerSource.reading()) }) {
            setup = fresh.0
            power = fresh.1
        }
    }

    private func startTicking() {
        ticking?.cancel()
        let interval = tickInterval
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.isOn else { return }
                await self.tick()
            }
        }
    }
}
