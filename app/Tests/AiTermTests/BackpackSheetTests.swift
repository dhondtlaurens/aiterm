import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackSheetTests {
    private func backpack(_ fake: FakeBackpack, retryDelays: [Duration] = [.milliseconds(10)]) -> BackpackController {
        BackpackController(ports: fake.ports, settings: fake.settings, tickInterval: .seconds(3600),
                           retryDelays: retryDelays, toast: { _ in })
    }

    /// Spins the main actor until `condition` holds or `timeout` passes; whether it held.
    private func until(_ timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await Task.yield() }
        return condition()
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
        #expect(model.hotspotHelp == BackpackSheetPresentation.remembered)
    }

    /// Review focus 5: nothing remembered and nothing known — Connect waits for a hotspot, and
    /// says how to get one.
    @Test func connectWaitsForAHotspot() async {
        let fake = FakeBackpack()
        fake.settings.network = nil
        fake.wifi.known = []
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.choices == [nil])
        #expect(!model.canConnect)
        #expect(model.hotspotHelp == "Join your iPhone’s hotspot once from the Wi-Fi menu, and it shows up here.")
        #expect(model.hotspotHelp == BackpackSheetPresentation.noHotspotYet)
        model.connect()
        #expect(model.step == .hotspot)
    }

    /// Known networks but none remembered: there is a hotspot to choose, so the line is the usual one.
    @Test func aKnownNetworkKeepsTheRememberedLine() async {
        let fake = FakeBackpack()
        fake.settings.network = nil
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        #expect(model.choices == [nil, "Home", "Phone"])
        #expect(model.hotspotHelp == BackpackSheetPresentation.remembered)
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

    // -- the lid closing under the sheet ------------------------------------------------

    /// Step 1: a lid close is a Cancel, and nothing was changed to put back.
    @Test func aLidCloseOnStepOneCancels() async {
        let fake = FakeBackpack()
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        await model.lidClosed()?.value
        #expect(model.step == .hotspot)
        #expect(!model.backpack.busy && !model.backpack.isOn)
        #expect(model.backpack.phase == nil)
        #expect(fake.wifi.joins.isEmpty)
        #expect(fake.wifi.current == "Home")
        #expect(fake.lid.calls.isEmpty)
    }

    /// Step 2, waiting for a hotspot that isn't showing: with the sheet gone nobody is left to
    /// Cancel, so the wait stops at once — not after its 5 s — and the undo puts the Wi-Fi back.
    @Test func aLidCloseWhileWaitingForTheHotspotStopsTheRetries() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let model = BackpackSheetModel(backpack: backpack(fake, retryDelays: [.seconds(5)]))
        await model.load()
        model.connect()
        #expect(await until { model.backpack.phase == .notInRange })
        model.lidClosed()
        #expect(await until(1) { !model.backpack.busy }, "stopped at once, not after the retry's wait")
        let joins = fake.wifi.joins
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.wifi.joins == joins, "no further joins")
        #expect(joins == ["Phone", "Home"], "one try at the hotspot, then the undo's rejoin")
        #expect(!fake.lid.calls.contains(true), "sleep untouched")
        #expect(!model.backpack.isOn)
        #expect(model.backpack.phase == nil)
        #expect(fake.wifi.current == "Home")
    }

    /// Step 2, a join in flight that then finds no hotspot: no retry follows it.
    @Test func aLidCloseDuringAJoinThatMissesTheHotspotRetriesNoMore() async {
        let fake = FakeBackpack()
        fake.wifi.inRange = ["Home"]
        fake.wifi.failingJoins = ["Phone"]
        let release = DispatchSemaphore(value: 0), entered = Mutex(false)
        // Holds the connect's first join only.
        fake.wifi.onJoin = { @Sendable in if entered.withLock({ let first = !$0; $0 = true; return first }) { release.wait() } }
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(await until { entered.withLock { $0 } })
        model.lidClosed()
        release.signal()
        #expect(await until { !model.backpack.busy })
        let joins = fake.wifi.joins
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fake.wifi.joins == joins, "no further joins")
        #expect(joins.filter { $0 == "Phone" }.count == 1)
        #expect(!fake.lid.calls.contains(true), "sleep untouched")
        #expect(!model.backpack.isOn)
    }

    /// Step 2, a join that succeeds while the lid closes: a turn-on in progress keeps going.
    @Test func aLidCloseDuringASucceedingJoinStillEndsSafe() async {
        let fake = FakeBackpack()
        let release = DispatchSemaphore(value: 0)
        fake.lid.onSet = { @Sendable in if $0 { release.wait() } }
        let model = BackpackSheetModel(backpack: backpack(fake))
        await model.load()
        model.connect()
        #expect(await until { model.backpack.phase == .keepingAwake })
        model.lidClosed()
        release.signal()
        #expect(await until { model.backpack.phase == .safe })
        #expect(model.backpack.isOn)
        #expect(!model.backpack.busy)
        #expect(fake.lid.calls == [true])
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
