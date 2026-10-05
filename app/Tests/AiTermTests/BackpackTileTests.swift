import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct BackpackTileTests {
    private let ready = BackpackSetup(sleepRule: true, location: true, network: "iPhone")
    private let unready = BackpackSetup(sleepRule: true, location: false, network: "iPhone")
    private let fine = BackpackStatus(network: "iPhone", joined: true, power: PowerReading(level: 64, onBattery: true), cutoff: 20)
    private let lost = BackpackStatus(network: "iPhone", joined: false, power: .mains, cutoff: 20)
    private let low = BackpackStatus(network: "iPhone", joined: true, power: PowerReading(level: 23, onBattery: true), cutoff: 20)
    private let lowAndLost = BackpackStatus(network: "iPhone", joined: false, power: PowerReading(level: 23, onBattery: true), cutoff: 20)

    @Test func beforeSetupIsOnlyWhenOffAndIncomplete() {
        #expect(BackpackTileState(state: .off, setup: unready, transition: nil) == .setup)
        #expect(BackpackTileState(state: .off, setup: ready, transition: nil) == .off)
    }

    @Test func aTransitionWinsOverEverything() {
        #expect(BackpackTileState(state: .off, setup: unready, transition: .turningOn) == .turningOn)
        #expect(BackpackTileState(state: .on(lost), setup: ready, transition: .turningOff) == .turningOff)
    }

    @Test func onSplitsIntoFineAndTheTwoWaysItNeedsYou() {
        #expect(BackpackTileState(state: .on(fine), setup: ready, transition: nil) == .on)
        #expect(BackpackTileState(state: .on(lost), setup: ready, transition: nil) == .lostHotspot)
        #expect(BackpackTileState(state: .on(low), setup: ready, transition: nil) == .nearCutoff)
    }

    @Test func theCutoffWinsOverALostHotspot() {
        #expect(BackpackTileState(state: .on(lowAndLost), setup: ready, transition: nil) == .nearCutoff)
    }

    /// The corner carries a task row's `StatusMark`: none while off, the spinner while it switches,
    /// the done dot while on, the needs-input dot when it needs you.
    @Test func eachStateHasItsCornerMark() {
        #expect(BackpackTileState.setup.corner == nil)
        #expect(BackpackTileState.off.corner == nil)
        #expect(BackpackTileState.turningOn.corner == .working)
        #expect(BackpackTileState.turningOff.corner == .working)
        #expect(BackpackTileState.on.corner == .done)
        #expect(BackpackTileState.nearCutoff.corner == .needsInput)
        #expect(BackpackTileState.lostHotspot.corner == .needsInput)
    }

    /// The switch shows where the mode is going: on while it turns on, off while it turns off.
    @Test func theSwitchShowsWhereTheModeIsGoing() {
        let on: [BackpackTileState] = [.turningOn, .on, .nearCutoff, .lostHotspot]
        let off: [BackpackTileState] = [.setup, .off, .turningOff]
        #expect(on.allSatisfy { $0.switchIsOn })
        #expect(!off.contains { $0.switchIsOn })
    }

    @Test func theTooltipSaysTheStateInFull() {
        func help(_ state: BackpackState, _ setup: BackpackSetup, _ transition: BackpackTransition? = nil) -> String {
            BackpackPresentation.tileHelp(BackpackTileState(state: state, setup: setup, transition: transition), state: state, setup: setup)
        }
        #expect(help(.off, unready) == "Backpack Mode needs setup: Settings › Backpack")
        #expect(help(.off, ready) == "Backpack Mode is off · joins iPhone")
        #expect(help(.off, ready, .turningOn) == "Turning on Backpack Mode · joining iPhone")
        #expect(help(.on(fine), ready) == "Backpack Mode is on · iPhone · battery 64 %, turns off at 20 %")
        #expect(help(.on(low), ready) == "Battery at 23 %: Backpack Mode turns off at 20 %")
        #expect(help(.on(lost), ready) == "Backpack Mode is on · lost iPhone: open Personal Hotspot on the iPhone")
        #expect(help(.on(fine), ready, .turningOff) == "Turning off Backpack Mode")
    }

    @Test func voiceOverHearsWhatTheMarkShows() {
        func label(_ state: BackpackState, _ setup: BackpackSetup, _ transition: BackpackTransition? = nil) -> String {
            BackpackPresentation.tileLabel(BackpackTileState(state: state, setup: setup, transition: transition), state: state)
        }
        #expect(label(.off, unready) == "Set Up Backpack Mode")
        #expect(label(.off, ready) == "Backpack Mode")
        #expect(label(.on(fine), ready) == "Backpack Mode")
        #expect(label(.off, ready, .turningOn) == "Backpack Mode, turning on")
        #expect(label(.on(fine), ready, .turningOff) == "Backpack Mode, turning off")
        #expect(label(.on(low), ready) == "Backpack Mode, needs you: battery at 23 %, turns off at 20 %")
        #expect(label(.on(lost), ready) == "Backpack Mode, needs you: lost iPhone, open Personal Hotspot on the iPhone")
    }

    @Test func theModesGlyphIsThePersonalHotspot() {
        #expect(BackpackPresentation.symbol == "personalhotspot")
    }

    /// The header is about projects again: nothing in the app still names the old glyph's type.
    @Test func theHeaderNoLongerCarriesBackpack() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTerm/Views/SidebarRows.swift"), encoding: .utf8)
        #expect(!source.contains("Backpack"))
    }
}
