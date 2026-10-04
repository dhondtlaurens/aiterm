import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackControllerTests {
    private func controller(_ fake: FakeBackpack, toasts: Recorder = Recorder(),
                            openLocationSettings: @escaping @MainActor () -> Void = {}) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           openLocationSettings: openLocationSettings, toast: { toasts.lines.append($0) })
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
        let entered = Mutex(false)
        fake.lid.onSet = { if $0 { entered.withLock { $0 = true }; release.wait() } }
        let toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        let first = Task { await backpack.turnOn() }
        // Until the turn-on's work is on the queue: `busy` is set a moment before it gets there.
        while !entered.withLock({ $0 }) { await Task.yield() }
        let releaser = Thread { Thread.sleep(forTimeInterval: 0.2); release.signal() }
        releaser.start()
        backpack.shutdown()
        #expect(fake.lid.calls == [true, false])
        #expect(!fake.settings.engaged)
        await first.value
        #expect(!backpack.isOn)
        #expect(toasts.lines.isEmpty, "no 'on' toast for a mode the quit already turned off")
    }

    /// The gap the test above cannot hold open: quit lands after ⌘B set `busy` but before its work
    /// reached the queue. That turn-on must find the mode closed.
    @Test func aTurnOnThatReachesTheQueueAfterShutdownDoesNothing() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        backpack.shutdown()
        await backpack.turnOn()
        #expect(!fake.lid.calls.contains(true))
        #expect(!backpack.isOn)
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

    /// The Battery card reads the level even while the mode is off.
    @Test func refreshingReadsTheBatteryToo() async {
        let fake = FakeBackpack()
        fake.power.value = PowerReading(level: 64, onBattery: true)
        let backpack = controller(fake)
        await backpack.refreshSetup()
        #expect(backpack.power == PowerReading(level: 64, onBattery: true))
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

    /// Location already refused: macOS will not ask again, so Allow… opens its pane in System
    /// Settings instead, and the controller is free again at once.
    @Test func allowOpensLocationSettingsWhenTheRequestCannotAsk() async {
        let fake = FakeBackpack()
        fake.location.authorized = false
        fake.location.grantsOnRequest = false
        let opened = Recorder()
        let backpack = controller(fake, openLocationSettings: { opened.lines.append("opened") })
        await backpack.setUp()
        #expect(opened.lines == ["opened"])
        #expect(!backpack.busy)
    }

    @Test func aFailedTurnOffSaysSoAndKeepsTrying() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.turnOn()
        fake.lid.succeeds = false
        await backpack.turnOff()
        #expect(!backpack.isOn)
        #expect(toasts.lines.last == "Couldn’t turn lid sleep back on: AiTerm keeps trying")
        #expect(fake.settings.engaged)
        fake.lid.succeeds = true
        await backpack.tick()
        #expect(!fake.settings.engaged)
    }

    /// Removing the rule while sleep is still disabled would leave nothing able to put it back.
    @Test func removeSetupRefusesWhileSleepIsStillDisabled() async {
        let fake = FakeBackpack(), toasts = Recorder()
        let backpack = controller(fake, toasts: toasts)
        await backpack.turnOn()
        fake.lid.succeeds = false
        await backpack.removeSetup()
        #expect(fake.installer.removes == 0)
        #expect(toasts.lines.last == "Couldn’t turn lid sleep back on: AiTerm keeps trying")
    }

    /// Quit does not sit behind a join that takes a minute: it closes the mode and turns off now.
    @Test func quitDoesNotWaitBehindASlowJoin() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0), entered = Mutex(false)
        fake.wifi.onJoin = { entered.withLock { $0 = true }; release.wait() }
        let backpack = controller(fake)
        let first = Task { await backpack.turnOn() }
        while !entered.withLock({ $0 }) { await Task.yield() }
        let started = Date()
        backpack.shutdown()
        #expect(Date().timeIntervalSince(started) < 1)
        release.signal()
        await first.value
        #expect(!fake.lid.calls.contains(true))
        #expect(!backpack.isOn)
    }

    @Test func aSuccessfulTurnOnMarksSetupComplete() async {
        let fake = FakeBackpack()
        let backpack = controller(fake)
        #expect(!backpack.setup.isComplete)
        await backpack.turnOn()
        #expect(backpack.setup.isComplete)
    }

    /// At launch the header's menu must know setup is done, not wait for Settings to open.
    @Test func launchPutsSleepBackAndReadsSetup() async {
        let fake = FakeBackpack()
        fake.settings.engaged = true
        let backpack = controller(fake)
        await backpack.launch()
        #expect(fake.lid.calls == [false])
        #expect(backpack.setup.isComplete)
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
