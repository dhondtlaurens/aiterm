import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' “Fix with AI”, as `AgentIntegrations` keeps it.
@MainActor struct FixerSettingsTests {
    private func integrations(defaults: UserDefaults, installed: Set<AgentKind>?) -> AgentIntegrations {
        AgentIntegrations(harnessHome: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          bundledResourcesURL: nil, locateAgents: { installed }, rememberedModels: { [:] },
                          defaults: defaults)
    }

    @Test func theChoiceIsSavedAndResolvedAgainstWhatIsInstalled() async {
        let defaults = ScratchDefaults.make()
        let integrations = integrations(defaults: defaults, installed: [.codex])
        await integrations.probe()
        #expect(integrations.fixerChoice == .agent(.codex), "the first installed fixer, once the probe has answered")
        #expect(FixerSettings.saved(defaults: defaults) == .agent(.codex), "saved at once, so a later install does not move it")
        integrations.fixerChoice = .agent(.claude)
        #expect(integrations.fixer == .missing(.claude))
        #expect(FixerSettings.load(defaults: defaults, installed: []) == .agent(.claude))
    }

    /// The model a fixer runs with, for New Review's footer and the banner alike: its card's default
    /// in Settings › Agents, else the model last picked for that agent, else empty — the agent's own.
    @Test func aFixerRunsWithItsCardsDefaultElseTheModelLastPickedElseItsOwn() {
        let defaults = ScratchDefaults.make()
        let none = AgentIntegrations.fixerModel(.claude, remembered: [:], defaults: defaults)
        #expect(none.model == "" && none.reasoning == nil)
        let remembered = AgentIntegrations.fixerModel(.codex, remembered: [.codex: "gpt-5", .claude: "opus"], defaults: defaults)
        #expect(remembered.model == "gpt-5" && remembered.reasoning == nil)
        ModelSettings.save(ModelPreference(model: "sonnet", reasoning: "high"), for: .claude, defaults: defaults)
        let card = AgentIntegrations.fixerModel(.claude, remembered: [.claude: "opus"], defaults: defaults)
        #expect(card.model == "sonnet" && card.reasoning == "high")
    }

    @Test func aSavedChoiceSurvivesTheProbe() async {
        let defaults = ScratchDefaults.make()
        FixerSettings.save(.off(keeping: .codex), defaults: defaults)
        let integrations = integrations(defaults: defaults, installed: [.claude, .codex])
        #expect(integrations.fixerChoice == .off(keeping: .codex), "read at launch, before the probe answers")
        await integrations.probe()
        #expect(integrations.fixerChoice == .off(keeping: .codex))
        #expect(integrations.fixer == .off)
    }

    /// The switch turns Fix buttons off and back on to the same agent, each flip saved.
    @Test func theSwitchIsSavedAndKeepsTheAgent() {
        let defaults = ScratchDefaults.make()
        let integrations = integrations(defaults: defaults, installed: nil)
        integrations.fixerChoice = .agent(.codex)
        integrations.fixerChoice.isOn = false
        #expect(FixerSettings.saved(defaults: defaults) == .off(keeping: .codex))
        #expect(integrations.fixer == .off)
        integrations.fixerChoice.isOn = true
        #expect(integrations.fixer == .ready(.codex))
    }

    /// The login shell failing means every agent stays offered, so the first launch settles on the
    /// first fixer rather than waiting for an answer that is not coming.
    @Test func aProbeThatCannotTellLeavesTheFirstFixerChosenButNotSaved() async {
        let defaults = ScratchDefaults.make()
        let integrations = integrations(defaults: defaults, installed: nil)
        await integrations.probe()
        #expect(integrations.fixer == .ready(.claude))
        #expect(FixerSettings.saved(defaults: defaults) == nil, "the next launch asks again")
    }

    /// With neither Claude Code nor Codex installed the group says what to do instead.
    @Test func noInstalledFixerSwapsTheHelp() {
        let generic = "When AiTerm hits a git problem, a Fix button asks this agent. It proposes a fix, using the model on its card below, and changes nothing until you press Apply."
        #expect(FixerSettingsGroup.groupHelp(installed: [.claude]) == generic)
        #expect(FixerSettingsGroup.groupHelp(installed: [.codex, .grok]) == generic)
        #expect(FixerSettingsGroup.groupHelp(installed: [.grok, .pi])
                == "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it.")
        #expect(FixerSettingsGroup.groupHelp(installed: [])
                == "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it.")
        #expect(FixerSettingsGroup.noFixerInstalled([.grok, .pi]))
        #expect(!FixerSettingsGroup.noFixerInstalled([.pi, .codex]))
    }

    /// The switch shows the choice, but reads off — and is disabled — while nothing can fix.
    @Test func theSwitchIsOffWhileNothingCanFix() {
        #expect(FixerSettingsGroup.switchIsOn(.agent(.claude), installed: [.claude]))
        #expect(FixerSettingsGroup.switchIsOn(.agent(.claude), installed: [.codex]), "a missing agent is still on")
        #expect(!FixerSettingsGroup.switchIsOn(.off(), installed: [.claude, .codex]))
        #expect(!FixerSettingsGroup.switchIsOn(.agent(.claude), installed: [.grok, .pi]))
    }

    /// A chosen agent that is not installed stays chosen; the line under the select names it, and
    /// the installed one to choose instead. Nothing is said while it is installed, or while off.
    @Test func aMissingChoiceSaysSoUnderTheSelect() {
        #expect(FixerSettingsGroup.missingHelp(.agent(.codex), installed: [.claude])
                == "Codex isn’t installed. Install it below, or choose Claude.")
        #expect(FixerSettingsGroup.missingHelp(.agent(.claude), installed: [.codex, .pi])
                == "Claude Code isn’t installed. Install it below, or choose Codex.")
        #expect(FixerSettingsGroup.missingHelp(.agent(.claude), installed: [.claude]) == nil)
        #expect(FixerSettingsGroup.missingHelp(.off(keeping: .codex), installed: [.claude]) == nil)
        #expect(FixerSettingsGroup.missingHelp(.agent(.claude), installed: [.grok]) == nil, "the group's help says it")
    }

    /// Settings' stand-in integrations leave no preferences file of their own behind.
    @Test func theInertIntegrationsKeepTheirChoiceInTheTemporaryFolder() {
        let inert = AgentIntegrations.inert()
        inert.fixerChoice = .off()
        #expect(inert.fixer == .off)
    }
}
