import Testing
import Foundation
@testable import AiTermCore

@Suite struct BackpackModeTests {
    private func mode(_ fake: FakeBackpack) -> BackpackMode { BackpackMode(ports: fake.ports, settings: fake.settings) }

    @Test func turningOnJoinsTheNetworkWritesTheMarkerThenDisablesSleep() throws {
        let fake = FakeBackpack()
        var markerWhenSleepDisabled: Bool?
        fake.lid.onSet = { if $0 { markerWhenSleepDisabled = fake.settings.engaged } }
        let mode = mode(fake)
        let status = try mode.turnOn().get()
        #expect(status == BackpackStatus(network: "Phone", joined: true, power: .mains, cutoff: 10))
        #expect(fake.wifi.joins == ["Phone"])
        #expect(fake.lid.calls == [true])
        #expect(markerWhenSleepDisabled == true, "the marker is written before disablesleep 1")
        #expect(fake.settings.engaged)
        #expect(mode.state == .on(status))
    }

    @Test func theSavedPasswordIsWhatTheJoinGets() throws {
        let fake = FakeBackpack()
        fake.settings.password = "hunter2"
        _ = try mode(fake).turnOn().get()
        #expect(fake.wifi.passwords == ["hunter2"])
    }

    @Test func alreadyOnTheNetworkSkipsTheScanAndTheJoin() throws {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        fake.wifi.inRange = []
        _ = try mode(fake).turnOn().get()
        #expect(fake.wifi.joins.isEmpty)
    }

    @Test func eachMissingSetupStepRefusesWithNeedsSetup() {
        for breakIt in [{ (f: FakeBackpack) in f.lid.allowed = false },
                        { (f: FakeBackpack) in f.location.authorized = false },
                        { (f: FakeBackpack) in f.settings.network = nil }] {
            let fake = FakeBackpack()
            breakIt(fake)
            let mode = mode(fake)
            #expect(mode.turnOn() == .failure(.needsSetup))
            #expect(fake.lid.calls.isEmpty && fake.wifi.joins.isEmpty)
            #expect(mode.state == .off)
        }
    }

    @Test func atOrBelowTheCutoffOnBatteryItStaysOff() {
        let fake = FakeBackpack()
        fake.power.value = PowerReading(level: 10, onBattery: true)
        #expect(mode(fake).turnOn() == .failure(.batteryLow(level: 10)))
        #expect(fake.lid.calls.isEmpty)
    }

    @Test func onACALowBatteryDoesNotStopIt() throws {
        let fake = FakeBackpack()
        fake.power.value = PowerReading(level: 3, onBattery: false)
        _ = try mode(fake).turnOn().get()
    }

    /// A locked iPhone's hotspot is missing from scans but joins with its password: ⌘B tries.
    @Test func turningOnJoinsEvenWhenTheScanCannotSeeIt() throws {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        _ = try mode(fake).turnOn().get()
        #expect(fake.wifi.joins == ["Phone"])
    }

    @Test func aFailedJoinOutOfSightIsNotInRange() {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.joinSucceeds = false
        #expect(mode(fake).turnOn() == .failure(.notInRange(network: "Phone")))
        #expect(fake.lid.calls.isEmpty && !fake.settings.engaged)
    }

    @Test func aFailedJoinInSightIsAPasswordProblem() {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false
        #expect(mode(fake).turnOn() == .failure(.joinFailed(network: "Phone")))
        #expect(fake.lid.calls.isEmpty && !fake.settings.engaged)
    }

    /// The rule went missing between the check and the call: the marker comes back off.
    @Test func aFailedDisableSleepRollsTheMarkerBack() {
        let fake = FakeBackpack()
        fake.lid.succeeds = false
        let mode = mode(fake)
        #expect(mode.turnOn() == .failure(.needsSetup))
        #expect(!fake.settings.engaged)
        #expect(mode.state == .off)
    }

    @Test func turningOffRestoresSleepAndClearsTheMarkerButLeavesWiFi() throws {
        let fake = FakeBackpack()
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        mode.turnOff()
        #expect(fake.lid.calls == [true, false])
        #expect(!fake.settings.engaged)
        #expect(fake.wifi.current == "Phone")
        #expect(mode.state == .off)
    }

    /// A failed `disablesleep 0` keeps the marker, so the next launch tries again.
    @Test func aFailedRestoreKeepsTheMarker() throws {
        let fake = FakeBackpack()
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        fake.lid.succeeds = false
        mode.turnOff()
        #expect(fake.settings.engaged)
        #expect(mode.state == .off)
    }

    /// Quit closes the mode first: a turn-on still on its way must not disable sleep after it.
    @Test func aClosedModeNeverTurnsOn() {
        let fake = FakeBackpack()
        let mode = mode(fake)
        mode.close()
        #expect(mode.turnOn() == .failure(.quitting))
        #expect(fake.lid.calls.isEmpty && fake.wifi.joins.isEmpty)
        #expect(mode.state == .off)
    }

    /// A failed `disablesleep 0` is reported, keeps the marker, and the next check tries again.
    @Test func aFailedRestoreIsReportedAndRetriedOnTheTick() throws {
        let fake = FakeBackpack()
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        fake.lid.succeeds = false
        #expect(!mode.turnOff())
        #expect(fake.settings.engaged && mode.state == .off)
        fake.lid.succeeds = true
        _ = mode.tick()
        #expect(!fake.settings.engaged)
        #expect(fake.lid.calls == [true, false, false])
    }

    /// The wait before the next rejoin counts from when the last one ended: a join can take a
    /// minute, and counting from its start would run the next one straight after.
    @Test func theNextRejoinIsBookedAfterASlowJoinEnds() throws {
        let fake = FakeBackpack(), clock = TestClock()
        let mode = BackpackMode(ports: fake.ports, settings: fake.settings, now: { clock.now })
        _ = try mode.turnOn().get()
        fake.wifi.current = "Home"
        fake.wifi.joinSucceeds = false
        fake.wifi.onJoin = { clock.advance(by: 60) }
        _ = mode.tick()
        #expect(fake.wifi.joins.count == 2)
        _ = mode.tick()
        #expect(fake.wifi.joins.count == 2, "the next attempt waits 5 s from the end of the slow one")
    }

    /// Saving another network and its password while on takes effect at the next turn-on: until
    /// then a rejoin uses the password the mode turned on with.
    @Test func rejoinsUseThePasswordTheModeTurnedOnWith() throws {
        let fake = FakeBackpack(), clock = TestClock()
        fake.settings.password = "phone-password"
        let mode = BackpackMode(ports: fake.ports, settings: fake.settings, now: { clock.now })
        _ = try mode.turnOn().get()
        fake.settings.network = "Other"
        fake.settings.password = "other-password"
        fake.wifi.current = "Home"
        _ = mode.tick()
        #expect(fake.wifi.joins == ["Phone", "Phone"])
        #expect(fake.wifi.passwords == ["phone-password", "phone-password"])
    }

    @Test func turningOffWhenOffDoesNothing() {
        let fake = FakeBackpack()
        mode(fake).turnOff()
        #expect(fake.lid.calls.isEmpty)
    }

    @Test func launchRecoveryRestoresSleepOnlyWhenTheMarkerIsSet() {
        let clean = FakeBackpack()
        mode(clean).recoverAtLaunch()
        #expect(clean.lid.calls.isEmpty, "a disablesleep the person set is theirs")
        let crashed = FakeBackpack()
        crashed.settings.engaged = true
        mode(crashed).recoverAtLaunch()
        #expect(crashed.lid.calls == [false])
        #expect(!crashed.settings.engaged)
    }

    @Test func theTickTurnsItOffAtTheCutoffOnBattery() throws {
        let fake = FakeBackpack()
        fake.power.value = PowerReading(level: 50, onBattery: true)
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        fake.power.value = PowerReading(level: 10, onBattery: true)
        #expect(mode.tick() == .turnedOff(level: 10))
        #expect(mode.state == .off)
        #expect(fake.lid.calls == [true, false])
    }

    @Test func aMacWithoutABatteryIsNeverCutOff() throws {
        let fake = FakeBackpack()
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        #expect(mode.tick() == .unchanged)
        guard case .on(let status) = mode.state else { Issue.record("expected on"); return }
        #expect(!status.nearCutoff && !status.degraded)
    }

    @Test func theTickMarksItDegradedOffTheNetworkAndRejoinsWhenBack() throws {
        let fake = FakeBackpack(), clock = TestClock()
        let mode = BackpackMode(ports: fake.ports, settings: fake.settings, now: { clock.now })
        _ = try mode.turnOn().get()
        fake.wifi.current = "Home"
        fake.wifi.joinSucceeds = false
        #expect(mode.tick() == .changed)
        guard case .on(let away) = mode.state else { Issue.record("expected on"); return }
        #expect(!away.joined && away.degraded)
        fake.wifi.joinSucceeds = true
        clock.advance(by: 5)
        #expect(mode.tick() == .changed)
        guard case .on(let back) = mode.state else { Issue.record("expected on"); return }
        #expect(back.joined && !back.degraded)
        #expect(fake.wifi.joins == ["Phone", "Phone", "Phone"])
    }

    /// Off the network, a join is tried at once, then after 5, 10, 20 and every 30 s — not on every
    /// 5 s check, which would keep the Wi-Fi scanning — and the schedule starts over once joined.
    @Test func rejoinAttemptsBackOffAndResetOnceJoined() throws {
        let fake = FakeBackpack(), clock = TestClock()
        let mode = BackpackMode(ports: fake.ports, settings: fake.settings, now: { clock.now })
        _ = try mode.turnOn().get()
        fake.wifi.current = "Home"
        fake.wifi.joinSucceeds = false
        func attempts() -> Int { fake.wifi.joins.count - 1 }
        _ = mode.tick()
        #expect(attempts() == 1)
        for (wait, expected) in [(4.0, 1), (1.0, 2), (5.0, 2), (5.0, 3), (19.0, 3), (1.0, 4), (29.0, 4), (1.0, 5), (30.0, 6)] {
            clock.advance(by: wait)
            _ = mode.tick()
            #expect(attempts() == expected, "after +\(wait) s")
        }
        fake.wifi.joinSucceeds = true
        clock.advance(by: 30)
        _ = mode.tick()
        #expect(attempts() == 7)
        guard case .on(let back) = mode.state, back.joined else { Issue.record("expected joined"); return }
        fake.wifi.current = "Home"
        fake.wifi.joinSucceeds = false
        _ = mode.tick()
        #expect(attempts() == 8, "a new drop tries at once")
    }

    @Test func theTickWhenOffDoesNothing() {
        let fake = FakeBackpack()
        #expect(mode(fake).tick() == .unchanged)
    }

    @Test func setupReportsEachPart() {
        let fake = FakeBackpack()
        fake.location.authorized = false
        #expect(mode(fake).setup() == BackpackSetup(sleepRule: true, location: false, network: "Phone"))
    }
}
