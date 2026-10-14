import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' “Fix problems with”, as `AgentIntegrations` keeps it.
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
        FixerSettings.save(.off, defaults: defaults)
        let integrations = integrations(defaults: defaults, installed: [.claude, .codex])
        #expect(integrations.fixerChoice == .off, "read at launch, before the probe answers")
        await integrations.probe()
        #expect(integrations.fixerChoice == .off)
        #expect(integrations.fixer == .off)
    }

    @Test func offIsSavedToo() {
        let defaults = ScratchDefaults.make()
        let integrations = integrations(defaults: defaults, installed: nil)
        integrations.fixerChoice = .off
        #expect(FixerSettings.saved(defaults: defaults) == .off)
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

    /// Spec §3: Grok Build and PI are shown but cannot be picked, each saying why; a fixer that is
    /// not installed says so by name.
    @Test func aGreyedSegmentSaysWhy() {
        let installed: Set<AgentKind> = [.claude, .grok, .pi]
        #expect(FixerSettingsGroup.help(for: .claude, installed: installed) == nil)
        #expect(FixerSettingsGroup.help(for: .codex, installed: installed) == "Codex isn’t installed.")
        #expect(FixerSettingsGroup.help(for: .grok, installed: installed)
                == "Grok Build can’t run with its network off on macOS yet.")
        #expect(FixerSettingsGroup.help(for: .pi, installed: installed) == "PI can’t run unattended.")
        #expect(FixerSettingsGroup.help(for: .pi, installed: []) == "PI can’t run unattended.", "never fixing outranks not installed")
    }

    @Test func onlyAnInstalledFixerCanBePicked() {
        #expect(FixerSettingsGroup.isSelectable(.codex, installed: [.codex]))
        #expect(!FixerSettingsGroup.isSelectable(.claude, installed: [.codex]))
        #expect(!FixerSettingsGroup.isSelectable(.grok, installed: Set(AgentKind.allCases)))
        #expect(!FixerSettingsGroup.isSelectable(.pi, installed: Set(AgentKind.allCases)))
    }

    /// Design 4A: with neither Claude Code nor Codex installed the group says what to do, and its
    /// lone Off is regular weight, not the selected emphasis.
    @Test func noInstalledFixerSwapsTheHelpAndQuietensOff() {
        let generic = "The agent a Fix button asks when AiTerm hits a git problem. It proposes a fix, using the model on its card below, and changes nothing until you press Apply."
        #expect(FixerSettingsGroup.groupHelp(installed: [.claude]) == generic)
        #expect(FixerSettingsGroup.groupHelp(installed: [.codex, .grok]) == generic)
        #expect(FixerSettingsGroup.groupHelp(installed: [.grok, .pi])
                == "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it.")
        #expect(FixerSettingsGroup.groupHelp(installed: [])
                == "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it.")
        #expect(FixerSettingsGroup.noFixerInstalled([.grok, .pi]))
        #expect(!FixerSettingsGroup.noFixerInstalled([.pi, .codex]))
    }

    /// The segment a choice shows as selected: a missing fixer stays selected rather than moving.
    @Test func theSelectedSegmentFollowsTheChoice() {
        #expect(FixerSettingsGroup.Option(.agent(.claude)) == .agent(.claude))
        #expect(FixerSettingsGroup.Option(.agent(.codex)) == .agent(.codex))
        #expect(FixerSettingsGroup.Option(.off) == .off)
    }

    /// Picking a segment: a fixer or Off changes the choice; an agent that cannot fix leaves it alone.
    @Test func pickingASegmentMapsToAChoice() {
        #expect(FixerSettingsGroup.choice(picking: .agent(.codex), from: .off) == .agent(.codex))
        #expect(FixerSettingsGroup.choice(picking: .agent(.claude), from: .agent(.codex)) == .agent(.claude))
        #expect(FixerSettingsGroup.choice(picking: .off, from: .agent(.claude)) == .off)
        #expect(FixerSettingsGroup.choice(picking: .agent(.grok), from: .agent(.claude)) == .agent(.claude))
        #expect(FixerSettingsGroup.choice(picking: .agent(.pi), from: .off) == .off)
    }

    /// A choice whose agent is not installed stays selected, and its segment is the one dimmed.
    @Test func aMissingChoiceStaysSelectedAndDimmed() {
        let installed: Set<AgentKind> = [.codex]
        let selected = FixerSettingsGroup.Option(.agent(.claude))
        #expect(selected == .agent(.claude))
        #expect(!FixerSettingsGroup.isSelectable(.claude, installed: installed))
        #expect(FixerSettingsGroup.help(for: .claude, installed: installed) == "Claude Code isn’t installed.")
        #expect(FixerSettingsGroup.isSelectable(.codex, installed: installed))
    }

    /// Settings' stand-in integrations leave no preferences file of their own behind.
    @Test func theInertIntegrationsKeepTheirChoiceInTheTemporaryFolder() {
        let inert = AgentIntegrations.inert()
        inert.fixerChoice = .off
        #expect(inert.fixer == .off)
    }
}
