import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

struct MacModeTests {
    private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func on(joined: Bool = true, level: Int? = 64, battery: Bool = true) -> BackpackState {
        .on(BackpackStatus(network: "Laurens’s iPhone", joined: joined, power: PowerReading(level: level, onBattery: battery)))
    }

    @Test func eachStateIsItsMode() {
        #expect(MacMode(state: .off, transition: nil, ended: nil) == .desk(ended: nil))
        #expect(MacMode(state: .off, transition: .turningOn, ended: nil) == .turningOn)
        #expect(MacMode(state: on(), transition: nil, ended: nil) == .on)
        #expect(MacMode(state: on(joined: false), transition: nil, ended: nil) == .needsYou(.lostHotspot))
        #expect(MacMode(state: on(level: 13), transition: nil, ended: nil) == .needsYou(.lowBattery(level: 13)))
        #expect(MacMode(state: on(), transition: .turningOff, ended: nil) == .turningOff)
    }

    /// The cutoff will end the mode; a lost hotspot can come back. The cutoff wins.
    @Test func theCutoffWinsOverALostHotspot() {
        #expect(MacMode(state: on(joined: false, level: 12), transition: nil, ended: nil) == .needsYou(.lowBattery(level: 12)))
    }

    /// Review focus 4: the cutoff is a battery rule; on the charger 12 % is fine.
    @Test func onACALowLevelIsNotANeed() {
        #expect(MacMode(state: on(level: 12, battery: false), transition: nil, ended: nil) == .on)
    }

    @Test func theNameAndGlyphFollowTheMode() {
        #expect(MacMode.desk(ended: nil).name == "desk mode")
        #expect(MacMode.desk(ended: nil).symbol == "macbook")
        for mode in [MacMode.turningOn, .on, .needsYou(.lostHotspot), .turningOff] {
            #expect(mode.name == "backpack mode")
            #expect(mode.symbol == "iphone")
        }
    }

    /// Only the mark after `backpack` takes colour; desk has none.
    @Test func theMarkIsTheOnlyColour() {
        #expect(MacMode.desk(ended: nil).mark == nil)
        #expect(MacMode.turningOn.mark == .working)
        #expect(MacMode.on.mark == .done)
        #expect(MacMode.needsYou(.lostHotspot).mark == .needsInput)
        #expect(MacMode.turningOff.mark == .working)
    }

    @Test func theWordsSayTheStateInFull() {
        func help(_ mode: MacMode, wifi: String? = "Office-WiFi") -> String {
            MacModePresentation.line(mode: mode, hotspot: "Laurens’s iPhone", wifi: wifi, calendar: utc).help
        }
        #expect(help(.desk(ended: nil)) == "desk mode · Office-WiFi · ⌘B turns on backpack mode")
        #expect(help(.desk(ended: nil), wifi: nil) == "desk mode · ⌘B turns on backpack mode")
        // Off with no other network in range: it stayed on the hotspot, and says so.
        #expect(help(.desk(ended: nil), wifi: "Laurens’s iPhone") == "desk mode · still on Laurens’s iPhone · ⌘B turns on backpack mode")
        #expect(help(.turningOn) == "Turning on backpack mode · joining Laurens’s iPhone")
        #expect(help(.on) == "Backpack mode on · Laurens’s iPhone · ends when your agents stop, or at 10 %")
        #expect(help(.needsYou(.lostHotspot)) == "Backpack mode needs you · lost Laurens’s iPhone, open Personal Hotspot on the iPhone")
        #expect(help(.needsYou(.lowBattery(level: 13))) == "Backpack mode needs you · battery at 13 %, turns off at 10 %")
        #expect(help(.turningOff) == "Turning off backpack mode · rejoining Wi-Fi")
    }

    @Test func anEndingIsTheRowsNoteAndTooltip() {
        let at = Date(timeIntervalSince1970: 14 * 3600 + 32 * 60)
        let stopped = MacModePresentation.line(mode: .desk(ended: BackpackEnded(at: at, cause: .agentsStopped)),
                                               hotspot: "Laurens’s iPhone", wifi: "Home-WiFi", calendar: utc)
        #expect(stopped.note == "· backpack mode ended 14:32")
        #expect(stopped.help == "Backpack mode ended at 14:32: your agents stopped")
        let battery = MacModePresentation.line(mode: .desk(ended: BackpackEnded(at: at, cause: .batteryLow(level: 10))),
                                               hotspot: nil, wifi: nil, calendar: utc)
        #expect(battery.help == "Backpack mode ended at 14:32: battery at 10 %")
        #expect(MacModePresentation.line(mode: .on, hotspot: nil, wifi: nil, calendar: utc).note == nil)
    }

    @Test func theClockIsTwentyFourHourAndPadded() {
        #expect(MacModePresentation.clock(Date(timeIntervalSince1970: 9 * 3600 + 5 * 60), calendar: utc) == "09:05")
    }
}
