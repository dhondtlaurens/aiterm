import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackHeaderTests {
    private let fine = BackpackStatus(network: "P", joined: true, power: .mains, cutoff: 10)
    private let away = BackpackStatus(network: "P", joined: false, power: .mains, cutoff: 10)

    /// Always drawn: off, a spinner while it turns on or off, on, or needing the person.
    @Test func theLookFollowsTheStateAndAnyTransition() {
        #expect(BackpackHeaderButton.look(state: .off, transition: nil) == .off)
        #expect(BackpackHeaderButton.look(state: .off, transition: .turningOn) == .busy)
        #expect(BackpackHeaderButton.look(state: .on(fine), transition: .turningOff) == .busy)
        #expect(BackpackHeaderButton.look(state: .on(fine), transition: nil) == .on)
        #expect(BackpackHeaderButton.look(state: .on(away), transition: nil) == .degraded)
    }

    /// Off is the "+"'s own grey; on is the accent; needing the person is amber.
    @Test func eachLookHasItsInk() {
        #expect(BackpackHeaderButton.ink(for: .off) == Palette.muted)
        #expect(BackpackHeaderButton.ink(for: .on) == Palette.accent)
        #expect(BackpackHeaderButton.ink(for: .degraded) == Palette.amber)
    }

    @Test func theMenuSaysTheStateAndOffersTheToggle() {
        let ready = BackpackSetup(sleepRule: true, location: true, network: "Phone")
        #expect(BackpackPresentation.menuLine(state: .off, setup: ready) == "Backpack Mode is off · joins Phone")
        #expect(BackpackPresentation.menuLine(state: .off, setup: BackpackSetup(sleepRule: false, location: true, network: nil))
                == "Backpack Mode needs setup")
        #expect(BackpackPresentation.menuLine(state: .on(fine), setup: ready) == "Backpack Mode is on · P")
        #expect(BackpackHeaderButton.toggleTitle(isOn: false) == "Turn On Backpack Mode")
        #expect(BackpackHeaderButton.toggleTitle(isOn: true) == "Turn Off Backpack Mode")
        #expect(BackpackHeaderButton.settingsFirst(state: .off, setup: BackpackSetup(sleepRule: true, location: false, network: "Phone")))
        #expect(!BackpackHeaderButton.settingsFirst(state: .off, setup: ready))
    }
}
