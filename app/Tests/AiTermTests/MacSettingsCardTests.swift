import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct MacSettingsCardTests {
    private func setup(_ sleep: Bool, _ location: Bool) -> BackpackSetup {
        BackpackSetup(sleepRule: sleep, location: location, network: nil)
    }

    @Test func theStatusSaysWhatIsMissing() {
        #expect(MacCardPresentation.status(setup(true, true)) == SettingsStatus(.ready, "Ready for backpack mode"))
        #expect(MacCardPresentation.status(setup(false, true)) == SettingsStatus(.attention, "Backpack mode needs lid sleep"))
        #expect(MacCardPresentation.status(setup(true, false)) == SettingsStatus(.attention, "Backpack mode needs network discovery"))
        #expect(MacCardPresentation.status(setup(false, false))
                == SettingsStatus(.attention, "Backpack mode needs lid sleep and network discovery"))
    }

    /// A network is the sheet's business now: a card without one is still Ready.
    @Test func aMissingNetworkIsNotTheCardsConcern() {
        #expect(MacCardPresentation.status(BackpackSetup(sleepRule: true, location: true, network: nil)).tone == .ready)
    }

    @Test func theStepsAreTheMissingOnesInOrder() {
        #expect(MacCardPresentation.steps(setup(false, false)) == [
            "Allow AiTerm to keep the Mac awake with the lid closed. macOS asks for your password once.",
            "Allow AiTerm to see nearby Wi-Fi networks. macOS hides their names from apps without Location access.",
        ])
        #expect(MacCardPresentation.steps(setup(true, false)).count == 1)
        #expect(MacCardPresentation.steps(setup(true, true)).isEmpty)
    }

    @Test func theReadyCardSaysWhatTheModeDoes() {
        #expect(MacCardPresentation.summary == "Backpack mode keeps the Mac awake with the lid closed and finds your iPhone’s hotspot. AiTerm never reads where you are. Remove takes the lid-sleep rule out again.")
    }

    /// Backpack is no longer a tab: Agents, Integrations, Interface on ⌘1–⌘3.
    @Test func settingsHasThreeTabs() {
        #expect(SettingsTab.allCases == [.agents, .integrations, .interface])
        #expect(SettingsTab.interface.key == "3")
    }

    /// A missing Mac permission does not pull Settings onto Integrations; iTerm2 still does.
    @Test func theOpeningRuleIsUnchanged() {
        #expect(SettingsTab.opening(iterm: .connected(version: "3.7.2"), serviceTestFailed: false) == .agents)
    }
}
