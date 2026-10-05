import Foundation
import AiTermCore

/// A turn-on or turn-off under way, which the header draws as a spinner.
enum BackpackTransition: Equatable { case turningOn, turningOff }

/// Where a connect stands: the Backpack sheet's step 2 reads it.
enum ConnectPhase: Equatable {
    case joining
    /// The last join could not see the hotspot; another follows after a delay.
    case notInRange
    /// Joined; the marker and `disablesleep 1` are running.
    case keepingAwake
    case safe
    /// Final until Back or Cancel: `.joinFailed`, `.batteryLow` or `.needsSetup`.
    case failed(BackpackRefusal)
    /// The typed password could not be stored.
    case keychainRefused
}

/// The mode turned itself off: when, and why.
struct BackpackEnded: Equatable { let at: Date; let cause: BackpackEnding }

/// Backpack Mode as the app drives it: `BackpackMode`'s blocking calls run on one serial thread, so a
/// connect, a turn-off and a tick never overlap, and their outcome is published here on the main
/// actor for the Backpack sheet, the Mac row and Settings › Integrations.
@MainActor
@Observable
final class BackpackController {
    /// The glyph on every Backpack toast: the mode's own, the iPhone it runs through.
    static let symbol = "iphone"

    private(set) var state: BackpackState = .off
    private(set) var setup = BackpackSetup(sleepRule: false, location: false, network: nil)
    /// The battery as last read: with setup, and on every check while on.
    private(set) var power = PowerReading.mains
    /// A turn-on, turn-off or setup is running. ⌘B is ignored until it ends.
    private(set) var busy = false
    /// Set for as long as a turn-on or turn-off runs: joining a hotspot takes seconds.
    private(set) var transition: BackpackTransition?
    /// Where the last connect stands; nil until one runs, and again after a turn-off or Cancel.
    private(set) var phase: ConnectPhase?
    /// Set when the mode ends itself; cleared by the next connect.
    private(set) var ended: BackpackEnded?
    /// The Wi-Fi network the Mac is on, as last read: for the desk tooltip.
    private(set) var currentNetwork: String?

    @ObservationIgnored private let mode: BackpackMode
    @ObservationIgnored private let ports: BackpackPorts
    @ObservationIgnored private let toast: @MainActor (String) -> Void
    /// Opens Location in System Settings: where Allow… sends the person once macOS will not ask.
    @ObservationIgnored private let openLocationSettings: @MainActor () -> Void
    @ObservationIgnored private let tickInterval: Duration
    /// A thread of its own, not a Dispatch queue: a join blocks for up to a minute (see `SerialThread`).
    @ObservationIgnored private let worker = SerialThread(name: "com.laurensdhondt.aiterm.backpack")
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private let retryDelays: [Duration]
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Whether any session in the workspace is `.working`: the 5 s check's reason to stay on.
    @ObservationIgnored private let agentsWorking: @MainActor () -> Bool
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var retryWait: Task<Void, Never>?

    init(ports: BackpackPorts, settings: BackpackSettings, tickInterval: Duration = .seconds(5),
         retryDelays: [Duration] = [.seconds(5), .seconds(10), .seconds(20), .seconds(30)],
         now: @escaping @Sendable () -> Date = Date.init, agentsWorking: @escaping @MainActor () -> Bool = { false },
         openLocationSettings: @escaping @MainActor () -> Void = {},
         toast: @escaping @MainActor (String) -> Void) {
        self.openLocationSettings = openLocationSettings
        self.ports = ports
        mode = BackpackMode(ports: ports, settings: settings, now: now)
        self.tickInterval = tickInterval
        self.retryDelays = retryDelays
        self.now = now
        self.agentsWorking = agentsWorking
        self.toast = toast
        setup.network = settings.network
    }

    /// Over the inert ports, in memory: for a sheet or a test that never turns it on.
    static func inert() -> BackpackController {
        BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })
    }

    var isOn: Bool { state.isOn }

    /// The hotspot and its password, written on Save. A change takes effect at the next turn-on.
    var network: String? {
        get { mode.settings.network }
        set { mode.settings.network = newValue; setup.network = newValue }
    }
    /// A Keychain read: off the main actor where it can be (`hasPassword()`).
    var password: String? {
        get { mode.settings.password }
        set { mode.settings.setPassword(newValue) }
    }

    /// Writes the password to the Keychain; false when it refused.
    func setPassword(_ value: String) -> Bool { mode.settings.setPassword(value) }

    /// Whether a password is saved, read off the main actor for the field's placeholder.
    func hasPassword() async -> Bool {
        let settings = mode.settings
        return await ThreadWork.run { settings.password != nil }
    }

    /// What a failed `disablesleep 0` says; the checks keep trying until it works.
    static let restoreFailed = "Couldn’t turn lid sleep back on: AiTerm keeps trying"

    /// The sheet's Connect: saves the hotspot (and a typed password), then turns on, retrying a
    /// hotspot that isn't showing on `retryDelays` until it shows, a final refusal, Cancel or quit.
    func connect(network: String, password: String?) async {
        guard !busy, !isOn else { return }
        self.network = network
        if let password, !password.isEmpty, !setPassword(password) { phase = .keychainRefused; return }
        busy = true
        transition = .turningOn
        defer { busy = false; transition = nil }
        cancelled = false
        ended = nil
        phase = .joining
        var attempt = 0
        let mode = self.mode
        while !cancelled {
            let joined: @Sendable () -> Void = { Task { @MainActor [weak self] in
                if self?.phase == .joining { self?.phase = .keepingAwake }
            } }
            let result = await worker.run { mode.turnOn(onJoined: joined) }
            state = mode.state
            switch result {
            case .success(let status):
                if cancelled { break }
                setup = BackpackSetup(sleepRule: true, location: true, network: status.network)
                currentNetwork = status.network
                phase = .safe
                startTicking()
                return
            case .failure(.notInRange):
                // Cancelled while that join ran: undo now, not after the wait.
                if cancelled { break }
                phase = .notInRange
                let delay = retryDelays[min(attempt, retryDelays.count - 1)]
                attempt += 1
                retryWait = Task { try? await Task.sleep(for: delay) }
                await retryWait?.value
                if !cancelled { phase = .joining }
            case .failure(.quitting):
                phase = nil
                return
            case .failure(let refusal):
                // Cancel wins over a refusal it came before: undo, and show no failure.
                if cancelled { break }
                phase = .failed(refusal)
                if refusal == .needsSetup { await refreshSetupWhileBusy() }
                return
            }
        }
        await undoWhileBusy(leaving: network)
    }

    /// The sheet's Cancel and Back. During a connect: stop after the attempt under way, then undo.
    /// After a final refusal: put the Wi-Fi back if the attempt left the Mac on the hotspot.
    func cancelConnect() async {
        if busy {
            cancelled = true
            retryWait?.cancel()
            return
        }
        guard !isOn, let network else { phase = nil; return }
        busy = true
        defer { busy = false; transition = nil }
        await undoWhileBusy(leaving: network)
    }

    /// Off by hand: sleep back, then the best known network in range.
    func turnOff() async {
        guard !busy, isOn else { return }
        busy = true
        transition = .turningOff
        defer { busy = false; transition = nil }
        ticking?.cancel()
        let mode = self.mode, hotspot = network ?? ""
        let (restored, joined) = await worker.run { (mode.turnOff(), mode.rejoinPreferred(leaving: hotspot)) }
        state = mode.state
        phase = nil
        currentNetwork = joined ?? hotspot
        if !restored {
            toast(Self.restoreFailed)
            startTicking()
        }
    }

    /// Cancel's undo, under `busy`: off if it got that far, then off the hotspot.
    private func undoWhileBusy(leaving hotspot: String) async {
        transition = .turningOff
        let mode = self.mode
        let joined = await worker.run { () -> String? in
            mode.turnOff()
            return mode.rejoinPreferred(leaving: hotspot)
        }
        state = mode.state
        phase = nil
        currentNetwork = joined
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
        // Not on the mode's thread: the admin prompt waits on the person.
        if setup.missingSteps.contains(.sleepRule) {
            let installer = ports.installer
            _ = await ThreadWork.run { installer.install() }
        }
        if setup.missingSteps.contains(.location), !(await ports.location.request()) { openLocationSettings() }
        await refreshSetupWhileBusy()
    }

    /// Remove Setup: off first, then the rule. Location stays granted; System Settings revokes it.
    func removeSetup() async {
        if isOn { await turnOff() }
        guard !busy else { return }
        // Without the rule nothing could put sleep back.
        if mode.settings.engaged {
            toast(Self.restoreFailed)
            return
        }
        busy = true
        defer { busy = false }
        let installer = ports.installer
        _ = await ThreadWork.run { installer.remove() }
        await refreshSetupWhileBusy()
    }

    func knownNetworks() async -> [String] {
        let wifi = ports.wifi
        return await ThreadWork.run { wifi.knownNetworks() }
    }

    /// The 5 s check: the cutoff, the work, and the network.
    func tick() async {
        let mode = self.mode, working = agentsWorking()
        let outcome: BackpackTick? = await worker.run { mode.tick(agentsWorking: working) }
        state = mode.state
        if case .on(let status) = state { power = status.power }
        guard case .ended(let cause)? = outcome else { return }
        if mode.settings.engaged { toast(Self.restoreFailed) }
        ended = BackpackEnded(at: now(), cause: cause)
        transition = .turningOff
        let hotspot = network ?? ""
        currentNetwork = await worker.run { mode.rejoinPreferred(leaving: hotspot) }
        transition = nil
    }

    /// Yields each time the lid goes from open to closed. A lid already closed when this starts —
    /// a Mac in clamshell with a display — yields only after it opens and closes again; a Mac
    /// without a lid never yields.
    func lidCloses(every interval: Duration = .milliseconds(500)) -> AsyncStream<Void> {
        let sensor = ports.lidSensor
        return AsyncStream { continuation in
            let task = Task {
                var last = sensor.isClosed()
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    let now = sensor.isClosed()
                    if last == false, now == true { continuation.yield() }
                    last = now
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// At launch, before anything else: a marker left by a crash puts sleep back.
    func recoverAtLaunch() {
        let mode = self.mode
        worker.sync { mode.recoverAtLaunch() }
    }

    /// Launch: put sleep back if a crash left it off, then read setup, so the header's menu knows.
    func launch() async {
        recoverAtLaunch()
        await refreshSetup()
    }

    /// At quit. Closes the mode — waiting only for a turn-on in the middle of committing — then
    /// turns it off at once: not behind a join on the worker, which can take a minute. A turn-on
    /// still on its way finds the mode closed, so AiTerm never exits leaving lid sleep disabled.
    func shutdown() {
        ticking?.cancel()
        cancelled = true
        retryWait?.cancel()
        let mode = self.mode
        mode.close()
        mode.turnOff()
        state = mode.state
    }

    #if DEBUG
    /// Snapshots draw a state without turning anything on.
    func preview(state: BackpackState, setup: BackpackSetup, transition: BackpackTransition? = nil,
                 phase: ConnectPhase? = nil, ended: BackpackEnded? = nil) {
        self.state = state
        self.setup = setup
        self.transition = transition
        self.phase = phase
        self.ended = ended
        if case .on(let status) = state { power = status.power }
    }
    #endif

    private func refreshSetupWhileBusy() async {
        let mode = self.mode, powerSource = ports.power, wifi = ports.wifi
        let fresh = await worker.run { (mode.setup(), powerSource.reading(), wifi.currentNetwork()) }
        setup = fresh.0
        power = fresh.1
        currentNetwork = fresh.2
    }

    private func startTicking() {
        ticking?.cancel()
        let interval = tickInterval
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // On, or off with a failed restore still to retry.
                guard !Task.isCancelled, let self, self.isOn || self.mode.settings.engaged else { return }
                await self.tick()
            }
        }
    }
}
