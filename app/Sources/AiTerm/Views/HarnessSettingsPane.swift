import SwiftUI
import AiTermCore
import AiTermUI

enum HarnessCardPresentation {
    static let agents = AgentKind.allCases

    /// The CLI and the driver. Models stay out: the picker below carries an empty catalogue, and the
    /// opening test's daemon and delivery checks reach the user through the status sentence.
    static func chips(for snapshot: HarnessSnapshot) -> [HarnessCheck] {
        snapshot.checks.filter { $0.id == .cli || $0.id == .integration }
    }

    static func status(for snapshot: HarnessSnapshot) -> SettingsStatus {
        // A passing test confirms the probe, so the label holds at "Ready" through the spinner and
        // after it; only a failure changes what the card says.
        switch snapshot.health {
        case .ready: return SettingsStatus(.ready, "Ready")
        case .warning: return SettingsStatus(.attention, snapshot.summary)
        // A missing CLI is a neutral fact until installing it fails; then it needs attention.
        case .unavailable:
            return SettingsStatus(snapshot.checks.contains { $0.id == .operation } ? .attention : .idle,
                                  snapshot.summary)
        }
    }

    /// The card's one action, named for what it will do here; every label runs the same install.
    /// Install while the CLI or the driver is missing, Repair while a check is amber, Reinstall
    /// over a card that is Ready. No action while the only amber check is one Install cannot fix:
    /// the button would run, write nothing and leave the card as it was.
    static func action(for snapshot: HarnessSnapshot) -> String? {
        if snapshot.installChangesNothing { return nil }
        if snapshot.health == .unavailable || snapshot.integrationState == .missing { return "Install" }
        return snapshot.health == .ready ? "Reinstall" : "Repair"
    }

    static func modelOptions(_ models: [AgentModel], preference: ModelPreference?) -> [AgentModel] {
        guard let preference, !models.contains(where: { $0.id == preference.model }) else { return models }
        let missing = AgentModel(id: "", label: "Unavailable: \(preference.model)", detail: nil,
                                 efforts: [], defaultEffort: nil)
        return [missing] + models
    }
}

struct HarnessSettingsPane: View {
    let model: HarnessSettingsModel
    /// Where the fixer is chosen, and which agents are installed to choose from.
    let agents: AgentIntegrations

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FixerSettingsGroup(choice: Binding(get: { agents.fixerChoice }, set: { agents.fixerChoice = $0 }),
                               installed: agents.availableAgents)
            ForEach(HarnessCardPresentation.agents, id: \.self) { agent in
                if let snapshot = model.snapshots[agent] {
                    card(snapshot)
                        .accessibilityIdentifier("harness-card-\(agent.rawValue)")
                }
            }
            HelpText("Settings tests each agent when it opens. Install adds a missing CLI with its vendor’s own installer, then AiTerm’s driver. The install and Fix with AI both take effect immediately; Cancel does not undo them.")
        }
    }

    private func card(_ snapshot: HarnessSnapshot) -> some View {
        SettingsCard(title: snapshot.agent.displayName, status: HarnessCardPresentation.status(for: snapshot)) {
            VendorMark(agent: snapshot.agent.session, size: Size.control)
        } chips: {
            ForEach(HarnessCardPresentation.chips(for: snapshot), id: \.id) { check in
                Badge(check.label,
                      icon: .symbol(check.passed ? "checkmark" : "exclamationmark"),
                      help: check.explanation,
                      iconTint: check.passed ? Palette.green : Palette.amber)
            }
        } actions: {
            actions(snapshot)
        } content: {
            defaults(snapshot)
        }
    }

    @ViewBuilder
    private func actions(_ snapshot: HarnessSnapshot) -> some View {
        if model.running.contains(snapshot.agent) {
            ProgressView().controlSize(.small)
        }
        // On every card but one whose only warning Install cannot fix, so a working driver can be
        // overwritten on purpose and a missing CLI installed. Disabled only where the file is not
        // AiTerm's to replace.
        if let action = HarnessCardPresentation.action(for: snapshot) {
            Button(action) { Task { await model.install(snapshot.agent) } }
                .disabled(model.running.contains(snapshot.agent) || !snapshot.canInstall)
                .help(snapshot.health == .unavailable
                      ? "Runs \(snapshot.agent.harness.installCommand), then installs AiTerm’s driver." : "")
        }
    }

    @ViewBuilder
    private func defaults(_ snapshot: HarnessSnapshot) -> some View {
        if snapshot.models.isEmpty {
            HelpText(snapshot.agent.harness.noModelsExplanation)
        } else {
            let preference = model.preferences[snapshot.agent]
            let options = HarnessCardPresentation.modelOptions(snapshot.models, preference: preference)
            let selected = options.first { $0.id == preference?.model } ?? options[0]
            VStack(alignment: .leading, spacing: Space.base) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Default model") {
                        Select(values: options,
                               selection: Binding(get: { selected }, set: { model.select($0, for: snapshot.agent) }),
                               label: { $0.label },
                               detail: \.detail)
                            .disabled(snapshot.modelsAreStale)
                    }
                    .frame(maxWidth: .infinity)
                    if let exact = snapshot.models.first(where: { $0.id == preference?.model }),
                       !exact.efforts.isEmpty {
                        FormField("Default reasoning") {
                            Select(values: exact.efforts,
                                   selection: Binding(
                                    get: { preference?.reasoning.flatMap { exact.efforts.contains($0) ? $0 : nil }
                                        ?? exact.defaultEffort ?? exact.efforts[0] },
                                    set: { model.selectReasoning($0, for: snapshot.agent) }),
                                   label: { $0.capitalized })
                                .disabled(snapshot.modelsAreStale)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if snapshot.modelsAreStale {
                    HelpText("Showing the last verified model catalogue.")
                } else if preference != nil && !snapshot.models.contains(where: { $0.id == preference?.model }) {
                    HelpText("Choose a current model to replace the unavailable default.")
                }
            }
        }
    }
}

/// “Fix with AI”: a switch for whether Fix buttons are offered, and a select of the agents that can
/// fix — Claude and Codex — in the cards' Default model column. Off dims the select and keeps its
/// agent; a chosen agent that is not installed stays chosen, and a line under the select says so.
struct FixerSettingsGroup: View {
    @Binding var choice: FixerChoice
    let installed: Set<AgentKind>

    /// Whether neither Claude Code nor Codex is installed, so that the switch can only be off.
    static func noFixerInstalled(_ installed: Set<AgentKind>) -> Bool {
        !installed.contains { $0.fixer != nil }
    }

    /// The group's one line of help; with nothing that can fix installed it says what to do instead.
    static func groupHelp(installed: Set<AgentKind>) -> String {
        noFixerInstalled(installed)
            ? "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it."
            : "When AiTerm hits a git problem, a Fix button asks this agent. It proposes a fix, using the model on its card below, and changes nothing until you press Apply."
    }

    /// What the switch shows: off, and disabled, while nothing that can fix is installed.
    static func switchIsOn(_ choice: FixerChoice, installed: Set<AgentKind>) -> Bool {
        choice.isOn && !noFixerInstalled(installed)
    }

    /// The line under the select while the switch is on and its agent is not installed, naming the
    /// installed one to choose instead.
    static func missingHelp(_ choice: FixerChoice, installed: Set<AgentKind>) -> String? {
        guard switchIsOn(choice, installed: installed), !installed.contains(choice.agent.agent) else { return nil }
        let others = FixerAgent.allCases.filter { $0 != choice.agent && installed.contains($0.agent) }
        let instead = others.first.map { ", or choose \($0.shortName)" } ?? ""
        return "\(choice.agent.agent.displayName) isn’t installed. Install it below\(instead)."
    }

    var body: some View {
        let isOn = Self.switchIsOn(choice, installed: installed)
        SettingsGroup(title: "Fix with AI", help: Self.groupHelp(installed: installed)) {
            SettingsSwitch(title: "Fix with AI", isOn: Binding(get: { isOn }, set: { choice.isOn = $0 }))
                .disabled(Self.noFixerInstalled(installed))
                .accessibilityIdentifier("fixer-switch")
        } rows: {
            // Two columns, as an agent card's Default model and Default reasoning, so this select
            // lines up with the cards' below it; the help under them, as the card's is.
            VStack(alignment: .leading, spacing: Space.base) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Agent") {
                        Select(values: FixerAgent.allCases, selection: $choice.agent, label: \.shortName)
                            .disabled(!isOn)
                            .accessibilityIdentifier("fixer-agent")
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
                if let help = Self.missingHelp(choice, installed: installed) {
                    HelpText(help)
                }
            }
        }
    }
}
