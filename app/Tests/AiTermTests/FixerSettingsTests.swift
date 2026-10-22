import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' “Help with problems”, as `AgentIntegrations` keeps it: one switch, the fixer
/// always the Operator's Claude at Settings › Operator's model and reasoning.
@MainActor struct FixerSettingsTests {
    private func integrations(defaults: UserDefaults, installed: Set<AgentKind>?) -> AgentIntegrations {
        AgentIntegrations(harnessHome: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          bundledResourcesURL: nil, locateAgents: { installed }, rememberedModels: { [:] },
                          defaults: defaults)
    }

    /// On from the first launch; off with Claude Code missing, whatever is saved; each flip saved.
    @Test func theSwitchIsSavedAndResolvedAgainstClaude() async {
        let defaults = ScratchDefaults.make()
        let integrations = integrations(defaults: defaults, installed: [.codex])
        #expect(integrations.helpWithProblems == HelpWithProblems(isOn: true))
        await integrations.probe()
        #expect(integrations.fixer == .off, "Codex is no stand-in for the Operator")
        integrations.availableAgents = [.claude]
        #expect(integrations.fixer == .ready(.claude))
        integrations.helpWithProblems.isOn = false
        #expect(HelpWithProblems.load(defaults: defaults) == HelpWithProblems(isOn: false))
        #expect(integrations.fixer == .off)
    }

    /// A Fix runs at the Operator's model and reasoning, Settings › Operator's, whichever agent it is handed.
    @Test func aFixRunsAtTheOperatorsModel() {
        let defaults = ScratchDefaults.make()
        OperatorProfileStore.save(OperatorProfile(model: "claude-opus-5-5", reasoning: "high"), defaults)
        let integrations = integrations(defaults: defaults, installed: [.claude])
        let model = integrations.fixModel(.claude)
        #expect(model.model == "claude-opus-5-5" && model.reasoning == "high")
        #expect(integrations.operatorProfile().model == "claude-opus-5-5")
    }

    /// What an agent's card gives it, which the Operator's tasks launch with: its card's default in
    /// Settings › Agents, else the model last picked for that agent, else empty — the agent's own.
    @Test func anAgentRunsWithItsCardsDefaultElseTheModelLastPickedElseItsOwn() {
        let defaults = ScratchDefaults.make()
        let none = AgentIntegrations.fixerModel(.claude, remembered: [:], defaults: defaults)
        #expect(none.model == "" && none.reasoning == nil)
        let remembered = AgentIntegrations.fixerModel(.codex, remembered: [.codex: "gpt-5", .claude: "opus"], defaults: defaults)
        #expect(remembered.model == "gpt-5" && remembered.reasoning == nil)
        ModelSettings.save(ModelPreference(model: "sonnet", reasoning: "high"), for: .claude, defaults: defaults)
        let card = AgentIntegrations.fixerModel(.claude, remembered: [.claude: "opus"], defaults: defaults)
        #expect(card.model == "sonnet" && card.reasoning == "high")
        let pi = AgentIntegrations.fixerModel(.pi, remembered: [.pi: "openai-codex/gpt-5.6-sol", .claude: "opus"], defaults: defaults)
        #expect(pi.model == "openai-codex/gpt-5.6-sol" && pi.reasoning == nil, "PI's own, never Claude's")
    }

    /// Without Claude Code the group says what to do instead, and its switch reads off.
    @Test func withoutClaudeTheSwitchIsOffAndTheHelpSaysWhy() {
        #expect(HelpWithProblemsGroup.title == "Help with problems")
        #expect(HelpWithProblemsGroup.groupHelp(installed: [.claude])
                == "When AiTerm hits a git problem, like a diverged branch or a conflicted rebase, a button asks the Operator for a fix, with the agent and model set in Settings › Operator. Nothing changes until you press Apply.")
        #expect(HelpWithProblemsGroup.groupHelp(installed: [.codex, .pi])
                == "Needs Claude Code, the Operator’s agent. Install it on its card below.")
        #expect(HelpWithProblemsGroup.switchIsOn(HelpWithProblems(isOn: true), installed: [.claude]))
        #expect(!HelpWithProblemsGroup.switchIsOn(HelpWithProblems(isOn: true), installed: [.codex]))
        #expect(!HelpWithProblemsGroup.switchIsOn(HelpWithProblems(isOn: false), installed: [.claude]))
    }

    /// Settings' stand-in integrations leave no preferences file of their own behind.
    @Test func theInertIntegrationsKeepTheirChoiceInTheTemporaryFolder() {
        let inert = AgentIntegrations.inert()
        inert.helpWithProblems.isOn = false
        #expect(inert.fixer == .off)
    }
}
