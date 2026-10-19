import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' “Help with problems”: one switch. The fix runs as the Operator, so its agent is
/// always Claude, at Settings › Operator's model and reasoning.
struct FixerChoiceTests {
    @Test func onlyAgentsWithAnUnattendedModeAreFixers() {
        #expect(AgentKind.claude.fixer == .claude)
        #expect(AgentKind.codex.fixer == .codex)
        #expect(AgentKind.grok.fixer == nil, "no network-off on macOS yet (spikes)")
        #expect(AgentKind.pi.fixer == nil)
    }

    /// The Operator's agent is Claude: without it the switch is off, whatever was saved, and with it
    /// the fixer is Claude, never another vendor.
    @Test func offWithoutClaude() {
        let on = HelpWithProblems(isOn: true)
        #expect(on.resolve(installed: [.claude, .codex]) == .ready(.claude))
        #expect(on.resolve(installed: [.codex, .grok, .pi]) == .off, "Codex is no stand-in for the Operator")
        #expect(on.resolve(installed: []) == .off)
        #expect(HelpWithProblems(isOn: false).resolve(installed: [.claude]) == .off)
        #expect(on.isAvailable(installed: [.claude]) && !on.isAvailable(installed: [.codex]))
    }

    /// On until it is turned off, kept under its own key; the old Fix with AI keys are not read.
    @Test func itIsOnUntilTurnedOffAndRoundTrips() {
        let defaults = ScratchDefaults.make()
        defaults.set("off", forKey: "fixer")
        defaults.set(false, forKey: "fixerIsOn")
        #expect(HelpWithProblems.load(defaults: defaults) == HelpWithProblems(isOn: true), "no migration of the old keys")
        HelpWithProblems.save(HelpWithProblems(isOn: false), defaults: defaults)
        #expect(defaults.object(forKey: "operator.helpWithProblems") as? Bool == false)
        #expect(HelpWithProblems.load(defaults: defaults) == HelpWithProblems(isOn: false))
        HelpWithProblems.save(HelpWithProblems(isOn: true), defaults: defaults)
        #expect(HelpWithProblems.load(defaults: defaults) == HelpWithProblems(isOn: true))
    }
}
