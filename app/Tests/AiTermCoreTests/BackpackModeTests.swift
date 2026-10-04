// app/Tests/AiTermCoreTests/BackpackModeTests.swift
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

    @Test func outOfRangeOrAFailedJoinStaysOff() {
        let away = FakeBackpack()
        away.wifi.inRange = ["Home"]
        #expect(mode(away).turnOn() == .failure(.notInRange(network: "Phone")))
        let failing = FakeBackpack()
        failing.wifi.joinSucceeds = false
        #expect(mode(failing).turnOn() == .failure(.joinFailed(network: "Phone")))
        #expect(away.lid.calls.isEmpty && failing.lid.calls.isEmpty)
        #expect(!away.settings.engaged && !failing.settings.engaged)
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
        let fake = FakeBackpack()
        let mode = mode(fake)
        _ = try mode.turnOn().get()
        fake.wifi.current = "Home"
        fake.wifi.inRange = ["Home"]
        #expect(mode.tick() == .changed)
        guard case .on(let away) = mode.state else { Issue.record("expected on"); return }
        #expect(!away.joined && away.degraded)
        fake.wifi.inRange = ["Home", "Phone"]
        #expect(mode.tick() == .changed)
        guard case .on(let back) = mode.state else { Issue.record("expected on"); return }
        #expect(back.joined && !back.degraded)
        #expect(fake.wifi.joins == ["Phone", "Phone"])
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
