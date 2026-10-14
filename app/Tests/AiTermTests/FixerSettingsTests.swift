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
}
