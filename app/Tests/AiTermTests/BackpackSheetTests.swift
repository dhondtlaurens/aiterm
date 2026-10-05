import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackSheetTests {
    private func backpack(_ fake: FakeBackpack) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           retryDelays: [.milliseconds(10)], toast: { _ in })
    }

    @Test func itOpensOnHotspotWithTheRememberedOne() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.step == .hotspot)
        #expect(model.network == "Phone")
        #expect(model.passwordSaved)
        #expect(model.password.isEmpty, "the saved one stays in Keychain; the field shows dots")
        #expect(model.choices == [nil, "Home", "Phone"])
    }

    /// Review focus 5: nothing remembered and nothing known — Connect waits for a hotspot.
    @Test func connectWaitsForAHotspot() async {
        let fake = FakeBackpack()
        fake.settings.network = nil
        fake.wifi.known = []
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.choices == [nil])
        #expect(!model.canConnect)
        model.connect()
        #expect(model.step == .hotspot)
    }

    @Test func connectWaitsForBothPermissions() async {
        let fake = FakeBackpack()
        fake.lid.allowed = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.canConnect)
        fake.lid.allowed = true
        await model.backpack.refreshSetup()
        #expect(model.canConnect)
    }

    @Test func connectMovesToStepTwoAndEndsSafe() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(model.step == .connect)
        while model.backpack.phase != .safe { await Task.yield() }
        #expect(model.backpack.isOn)
    }

    @Test func backReturnsToHotspotAndStopsTheConnect() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.joinSucceeds = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        while fake.wifi.joins.isEmpty { await Task.yield() }
        model.back()
        #expect(model.step == .hotspot)
        while model.backpack.busy { await Task.yield() }
        #expect(!model.backpack.isOn)
    }

    @Test func theChecksFollowThePhase() {
        let phone = "Laurens’s iPhone"
        func checks(_ phase: ConnectPhase?) -> [ConnectCheck] { BackpackSheetPresentation.checks(phase: phase, hotspot: phone) }
        #expect(checks(.joining) == [ConnectCheck(text: "Joining Laurens’s iPhone…", mark: .working, warns: false),
                                     ConnectCheck(text: "Keeping the Mac awake", mark: .idle, warns: false)])
        #expect(checks(.notInRange)[0] == ConnectCheck(text: "Laurens’s iPhone isn’t showing its hotspot yet", mark: .working, warns: true))
        #expect(checks(.keepingAwake) == [ConnectCheck(text: "Joined Laurens’s iPhone", mark: .done, warns: false),
                                          ConnectCheck(text: "Keeping the Mac awake…", mark: .working, warns: false)])
        #expect(checks(.safe).allSatisfy { $0.mark == .done && !$0.warns })
        #expect(checks(.failed(.joinFailed(network: phone)))[0]
                == ConnectCheck(text: "Couldn’t join Laurens’s iPhone: check its password", mark: .idle, warns: true))
        #expect(checks(.failed(.batteryLow(level: 8)))[0]
                == ConnectCheck(text: "Battery at 8 %: Backpack Mode stays off", mark: .idle, warns: true))
        #expect(checks(.keychainRefused)[0]
                == ConnectCheck(text: "Couldn’t save the hotspot password in Keychain", mark: .idle, warns: true))
    }

    @Test func theSafeStateSaysWhatHappensNext() {
        #expect(BackpackSheetPresentation.safeHelp(hotspot: "Laurens’s iPhone")
                == "On Laurens’s iPhone. Backpack Mode ends when your agents stop, or at 10 % battery.")
        #expect(BackpackSheetPresentation.steps == ["Hotspot", "Connect"])
    }

    @Test func theChoicesKeepARememberedNetworkTheMacForgot() {
        #expect(BackpackSheetPresentation.choices(known: ["Home"], current: "Phone") == [nil, "Phone", "Home"])
        #expect(BackpackSheetPresentation.choices(known: ["Home", "Phone"], current: "Phone") == [nil, "Home", "Phone"])
    }

    /// Already tethered to the hotspot when the sheet opens: Cancel leaves the Mac on it.
    @Test func cancelLeavesAMacAlreadyOnTheHotspotThere() async {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        await model.cancel().value
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Phone")
        #expect(fake.lid.calls.isEmpty)
    }

    /// A refusal before any join — the battery — then Cancel: still on the hotspot it started on.
    @Test func cancelAfterABatteryRefusalLeavesAMacAlreadyOnTheHotspotThere() async {
        let fake = FakeBackpack()
        fake.wifi.current = "Phone"
        fake.power.value = PowerReading(level: 8, onBattery: true)
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        while model.backpack.phase != .failed(.batteryLow(level: 8)) { await Task.yield() }
        await model.cancel().value
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Phone")
        #expect(model.backpack.phase == nil)
    }

    /// The dots stand for the remembered hotspot's password only: another hotspot needs its own.
    @Test func theSavedPasswordShowsOnlyForTheRememberedHotspot() async {
        let fake = FakeBackpack()
        fake.settings.password = "saved"
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.showsSavedPassword)
        model.network = "Home"
        #expect(!model.showsSavedPassword)
        model.network = nil
        #expect(!model.showsSavedPassword)
    }

    @Test func noSavedPasswordShowsNoDots() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.showsSavedPassword)
    }

    /// Step 2 is over — the sheet closes — once the mode is off with nothing running: turned off
    /// under the sheet, or ended by itself. Not in the turn between Connect and the connect starting.
    @Test func stepTwoIsOverOnceTheModeIsOffAndIdle() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(!model.isOver, "step 1 is never over")
        model.connect()
        #expect(!model.isOver, "the connect has not started yet")
        while model.backpack.phase != .safe { await Task.yield() }
        #expect(!model.isOver)
        await model.backpack.turnOff()
        while model.backpack.busy { await Task.yield() }
        #expect(model.isOver)
    }

    @Test func aFailedConnectIsNotOver() async {
        let fake = FakeBackpack()
        fake.wifi.joinSucceeds = false
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        while model.backpack.phase != .failed(.joinFailed(network: "Phone")) { await Task.yield() }
        while model.backpack.busy { await Task.yield() }
        #expect(!model.isOver, "Back and Cancel stay for a failure")
    }
}
