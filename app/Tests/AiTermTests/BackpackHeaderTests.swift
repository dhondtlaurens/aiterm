import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

@MainActor
@Suite(.serialized) struct BackpackHeaderTests {
    @Test func theGlyphIsAmberOnlyWhenDegraded() {
        let fine = BackpackStatus(network: "P", joined: true, power: .mains, cutoff: 10)
        let away = BackpackStatus(network: "P", joined: false, power: .mains, cutoff: 10)
        #expect(BackpackHeaderButton.ink(for: fine) == Palette.text)
        #expect(BackpackHeaderButton.ink(for: away) == Palette.amber)
    }

    /// Off draws nothing: absent, not disabled.
    @Test func theHeaderCarriesTheGlyphOnlyWhileOn() async {
        let fake = FakeBackpack()
        let controller = AppController(preferences: .scratch(), backpackPorts: fake.ports)
        // The controller keeps its settings in the scratch preferences' defaults, not the fake's.
        controller.backpack.network = "Phone"
        #expect(!SidebarHeader.showsBackpack(controller))
        await controller.backpack.turnOn()
        #expect(SidebarHeader.showsBackpack(controller))
        await controller.backpack.turnOff()
        #expect(!SidebarHeader.showsBackpack(controller))
    }
}
