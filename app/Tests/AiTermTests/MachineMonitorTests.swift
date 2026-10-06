import Foundation
import Observation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Hands out its samples in order, repeating the last.
private final class ScriptedSensor: MachineSensor, @unchecked Sendable {
    private let samples: Mutex<[MachineSample]>
    init(_ samples: [MachineSample]) { self.samples = Mutex(samples) }
    func sample() -> MachineSample {
        samples.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
    }
}

@MainActor
struct MachineMonitorTests {
    private func sample(user: UInt32, idle: UInt32, used: UInt64 = 8) -> MachineSample {
        MachineSample(cpu: CPUTicks(user: user, system: 0, idle: idle, nice: 0), memory: MemoryUse(used: used, total: 16),
                      throttled: false, memoryPressure: false)
    }

    /// The first sample draws ram alone and waits a moment; the second adds the CPU's share and
    /// waits the full interval.
    @Test func theCPUJoinsOnTheSecondSample() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0), sample(user: 25, idle: 75)]),
                                     power: FakePower(), interval: .seconds(5))
        #expect(await monitor.sample() == .seconds(1))
        #expect(monitor.lines.map(\.window) == [.ram])
        #expect(await monitor.sample() == .seconds(5))
        #expect(monitor.lines.map(\.window) == [.cpu, .ram])
        #expect(monitor.lines.map(\.percent) == [25, 50])
    }

    /// The battery is the port Backpack Mode reads: on battery it joins the row.
    @Test func theBatteryJoinsOnBattery() async {
        let power = FakePower()
        power.value = PowerReading(level: 64, onBattery: true)
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0)]), power: power)
        _ = await monitor.sample()
        #expect(monitor.lines.last == UsageLine(window: .battery, percent: 64, warning: false))
    }

    /// A sample that reads the same as the last leaves the footer alone: an `@Observable` write of an
    /// equal value still invalidates whatever read it.
    @Test func anUnchangedSampleRedrawsNothing() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0), sample(user: 10, idle: 10),
                                                             sample(user: 20, idle: 20)]),
                                     power: FakePower())
        _ = await monitor.sample()
        _ = await monitor.sample()
        let changed = Mutex(false)
        withObservationTracking { _ = monitor.lines } onChange: { changed.withLock { $0 = true } }
        _ = await monitor.sample()
        #expect(monitor.lines.map(\.percent) == [50, 50])
        #expect(!changed.withLock { $0 })
    }

    /// Started, it samples on its own; stopped, it does not start twice or keep going.
    @Test func startSamplesUntilStopped() async {
        let monitor = MachineMonitor(sensor: ScriptedSensor([sample(user: 0, idle: 0)]), power: FakePower(),
                                     interval: .milliseconds(10))
        monitor.start()
        monitor.start()
        await eventually { !monitor.lines.isEmpty }
        monitor.stop()
        #expect(monitor.lines.map(\.window) == [.ram])
    }
}
