import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackControllerTests {
    private func controller(_ fake: FakeBackpack, toasts: Recorder = Recorder()) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600), toast: { toasts.lines.append($0) })
    }

    final class Recorder { var lines: [String] = [] }

    @Test func turningOnToastsAndPublishesTheState() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.turnOn()
        #expect(backpack.isOn)
        #expect(toasts.lines == ["Backpack Mode on · joined Phone"])
        await backpack.turnOff()
        #expect(!backpack.isOn)
        #expect(fake.lid.calls == [true, false])
        #expect(toasts.lines.count == 1, "a manual turn-off has no toast")
    }

    @Test func aRefusalIsAToastAndTheModeStaysOff() async {
        let fake = FakeBackpack(), toasts = Recorder()
        fake.wifi.inRange = ["Home"]
        fake.wifi.joinSucceeds = false
        let backpack = controller(fake, toasts: toasts)
        await backpack.turnOn()
        #expect(!backpack.isOn)
        #expect(toasts.lines == ["Phone isn’t in range: Backpack Mode stays off"])
    }

    @Test func aSecondToggleWhileBusyDoesNothing() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { if $0 { release.wait() } }
        let backpack = controller(fake)
        let first = Task { await backpack.turnOn() }
        while !backpack.busy { await Task.yield() }
        backpack.toggle()
        await backpack.turnOn()
        release.signal()
        await first.value
        #expect(fake.lid.calls == [true])
        #expect(fake.wifi.joins == ["Phone"])
    }

    /// The header's spinner reads this: set for as long as a turn-on runs, gone once it ends.
    @Test func aTurnOnShowsAsTurningOnWhileItRuns() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { if $0 { release.wait() } }
        let backpack = controller(fake)
        #expect(backpack.transition == nil)
        let first = Task { await backpack.turnOn() }
        while !backpack.busy { await Task.yield() }
        #expect(backpack.transition == .turningOn)
        release.signal()
        await first.value
        #expect(backpack.transition == nil)
        #expect(backpack.isOn)
    }

    /// Quit during a turn-on: shutdown waits for it, then puts sleep back, so the Mac never stays
    /// sleepless after AiTerm is gone.
    @Test func shutdownWaitsForAnInFlightTurnOnAndEndsOff() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { if $0 { release.wait() } }
        let toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        let first = Task { await backpack.turnOn() }
        while !backpack.busy { await Task.yield() }
        let releaser = Thread { Thread.sleep(forTimeInterval: 0.2); release.signal() }
        releaser.start()
        backpack.shutdown()
        #expect(fake.lid.calls == [true, false])
        #expect(!fake.settings.engaged)
        await first.value
        #expect(!backpack.isOn)
        #expect(toasts.lines.isEmpty, "no 'on' toast for a mode the quit already turned off")
    }

    @Test func theTickAtTheCutoffTurnsItOffWithAToast() async {
        let fake = FakeBackpack(), toasts = Recorder()
        fake.power.value = PowerReading(level: 40, onBattery: true)
        let backpack = controller(fake, toasts: toasts)
        await backpack.turnOn()
        fake.power.value = PowerReading(level: 9, onBattery: true)
        await backpack.tick()
        #expect(!backpack.isOn)
        #expect(toasts.lines.last == "Battery at 9 %: Backpack Mode turned off")
    }

    @Test func setUpRunsTheMissingStepsAndRefreshes() async {
        let fake = FakeBackpack()
        fake.lid.allowed = false
        fake.location.authorized = false
        let backpack = controller(fake)
        await backpack.refreshSetup()
        #expect(backpack.setup.missingSteps == [.sleepRule, .location])
        await backpack.setUp()
        #expect(fake.installer.installs == 1 && fake.location.requests == 1)
        #expect(backpack.setup.missingSteps.isEmpty)
    }

    @Test func removeSetupTurnsTheModeOffFirst() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        await backpack.turnOn()
        await backpack.removeSetup()
        #expect(!backpack.isOn)
        #expect(fake.lid.calls == [true, false])
        #expect(fake.installer.removes == 1)
        #expect(backpack.setup.missingSteps == [.sleepRule])
    }

    @Test func launchRecoveryClearsALeftoverMarker() {
        let fake = FakeBackpack()
        fake.settings.engaged = true
        controller(fake).recoverAtLaunch()
        #expect(fake.lid.calls == [false])
    }

    @Test func theInertControllerTouchesNothing() async {
        let backpack = BackpackController.inert()
        await backpack.turnOn()
        #expect(!backpack.isOn)
        #expect(await backpack.knownNetworks().isEmpty)
    }
}
