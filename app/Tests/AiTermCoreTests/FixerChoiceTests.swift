import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

struct FixerChoiceTests {
    @Test func onlyAgentsWithAnUnattendedModeAreFixers() {
        #expect(AgentKind.claude.fixer == .claude)
        #expect(AgentKind.codex.fixer == .codex)
        #expect(AgentKind.grok.fixer == nil, "no network-off on macOS yet (spikes)")
        #expect(AgentKind.pi.fixer == nil)
    }

    @Test func theButtonUsesTheShortName() {
        #expect(FixerAgent.claude.shortName == "Claude")
        #expect(FixerAgent.codex.shortName == "Codex")
    }

    /// Spec §3 decision 7: a missing agent is named, never swapped for another vendor.
    @Test func aMissingChoiceIsNamedNotReplaced() {
        #expect(FixerChoice.agent(.claude).resolve(installed: [.codex]) == .missing(.claude))
        #expect(FixerChoice.agent(.codex).resolve(installed: [.codex, .claude]) == .ready(.codex))
        #expect(FixerChoice.off.resolve(installed: [.claude]) == .off)
    }

    /// First launch: the first installed of Claude Code, Codex; none → Off. Saved, so a
    /// later install does not change it.
    @Test func theFirstLaunchPicksTheFirstInstalledAndKeepsIt() {
        let defaults = ScratchDefaults.make()
        #expect(FixerSettings.load(defaults: defaults, installed: [.grok, .codex]) == .agent(.codex))
        #expect(FixerSettings.load(defaults: defaults, installed: [.claude]) == .agent(.codex), "kept once chosen")
        #expect(FixerSettings.load(defaults: ScratchDefaults.make(), installed: [.pi]) == .off)
    }

    @Test func aSavedChoiceRoundTrips() {
        let defaults = ScratchDefaults.make()
        FixerSettings.save(.off, defaults: defaults)
        #expect(FixerSettings.load(defaults: defaults, installed: [.claude]) == .off)
        FixerSettings.save(.agent(.codex), defaults: defaults)
        #expect(FixerSettings.load(defaults: defaults, installed: []) == .agent(.codex))
    }

    @Test func anUnknownSavedValueReadsAsOff() {
        let defaults = ScratchDefaults.make()
        defaults.set("gemini", forKey: "fixer")
        #expect(FixerSettings.load(defaults: defaults, installed: [.claude]) == .off)
    }
}
