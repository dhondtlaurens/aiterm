import Foundation
import AiTermCore

/// The Mac's readings under `ctx` (proposal 1A, 6 Oct 2026): its CPU, its memory and, on battery,
/// its charge, sampled off the main actor and published here for the footer. An owner of the
/// composition root, started at launch and stopped at quit with the rest.
@MainActor
@Observable
final class MachineMonitor {
    /// What the readings row draws, in its order: cpu, ram, then bat while on battery. Empty until
    /// the first sample lands.
    private(set) var lines: [UsageLine] = []

    @ObservationIgnored private let sensor: any MachineSensor
    /// The battery, as Backpack Mode reads it: one port for both.
    @ObservationIgnored private let power: any PowerSource
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var previous: MachineSample?
    @ObservationIgnored private var sampling: Task<Void, Never>?

    init(sensor: any MachineSensor, power: any PowerSource, interval: Duration = .seconds(5)) {
        self.sensor = sensor
        self.power = power
        self.interval = interval
    }

    /// Samples until `stop()`. Once started, a second call does nothing.
    func start() {
        guard sampling == nil else { return }
        // Weak: the loop must not keep the monitor alive, and it ends when the monitor goes.
        sampling = Task { [weak self] in
            while let pause = await self?.sample(), !Task.isCancelled {
                try? await Task.sleep(for: pause)
            }
        }
    }

    func stop() {
        sampling?.cancel()
        sampling = nil
    }

    /// Takes one sample and publishes what it reads; returns how long to wait for the next. The
    /// first wait is short: the CPU's share needs a second sample, and a row without `cpu` for a
    /// whole interval after launch reads as broken.
    func sample() async -> Duration {
        let sensor = self.sensor, power = self.power
        let (current, battery) = await ThreadWork.run { (sensor.sample(), power.reading()) }
        let next = MachineReadings.lines(previous: previous, current: current, power: battery)
        let pause = previous == nil ? min(interval, .seconds(1)) : interval
        previous = current
        // An equal write still notifies observers, and would redraw the footer for nothing.
        if next != lines { lines = next }
        return pause
    }

    #if DEBUG
    /// The snapshot renderer's readings, which no sampling replaces: it never starts the monitor.
    func seedSnapshotLines(_ lines: [UsageLine]) { self.lines = lines }
    #endif
}
