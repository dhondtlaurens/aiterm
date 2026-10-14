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
            HelpText("Settings tests each agent when it opens. Install adds a missing CLI with its vendor’s own installer, then AiTerm’s driver. The install and the Fix problems with choice both take effect immediately; Cancel does not undo them.")
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

/// “Fix problems with”: which agent every Fix button asks, or Off. An agent without an unattended
/// mode (Grok Build, PI), or not installed, cannot be picked and says why.
struct FixerSettingsGroup: View {
    @Binding var choice: FixerChoice
    let installed: Set<AgentKind>

    enum Option: Hashable {
        case agent(AgentKind), off

        /// The segment a choice shows as selected: a fixer that is not installed stays selected.
        init(_ choice: FixerChoice) {
            switch choice {
            case .agent(let fixer): self = .agent(fixer.agent)
            case .off: self = .off
            }
        }
    }

    /// What picking a segment makes of the choice: a fixer or Off changes it, an agent that cannot
    /// fix leaves it as it was.
    static func choice(picking option: Option, from current: FixerChoice) -> FixerChoice {
        switch option {
        case .off: .off
        case .agent(let agent): agent.fixer.map(FixerChoice.agent) ?? current
        }
    }

    /// Whether neither Claude Code nor Codex is installed, so that Off is the only segment left.
    static func noFixerInstalled(_ installed: Set<AgentKind>) -> Bool {
        !installed.contains { $0.fixer != nil }
    }

    /// The group's one line of help; with nothing that can fix installed it says what to do instead.
    static func groupHelp(installed: Set<AgentKind>) -> String {
        noFixerInstalled(installed)
            ? "No agent that can run unattended is installed. Install Claude Code or Codex below to fix problems with it."
            : "The agent a Fix button asks when AiTerm hits a git problem. It proposes a fix, using the model on its card below, and changes nothing until you press Apply."
    }
    /// Whether a segment can be picked: Off always, an agent only when it can fix and is installed.
    static func isSelectable(_ agent: AgentKind, installed: Set<AgentKind>) -> Bool {
        agent.fixer != nil && installed.contains(agent)
    }

    /// Why a segment is greyed, nil while it can be picked. What the agent can never do comes
    /// before what is merely not installed.
    static func help(for agent: AgentKind, installed: Set<AgentKind>) -> String? {
        if isSelectable(agent, installed: installed) { return nil }
        switch agent {
        case .grok: return "Grok Build can’t run with its network off on macOS yet."
        case .pi: return "PI can’t run unattended."
        case .claude, .codex: return "\(agent.displayName) isn’t installed."
        }
    }

    var body: some View {
        SettingsGroup(title: "Fix problems with",
                      help: Self.groupHelp(installed: installed)) {
            SegmentedControl(values: AgentKind.allCases.map(Option.agent) + [.off], selection: selection,
                             isSelectable: { option in
                                 guard case .agent(let agent) = option else { return true }
                                 return Self.isSelectable(agent, installed: installed)
                             },
                             help: { option in
                                 guard case .agent(let agent) = option else { return nil }
                                 return Self.help(for: agent, installed: installed)
                             }) { option, on in
                switch option {
                case .agent(let agent): AgentSegmentLabel(agent: agent, on: on, name: agent.fixer?.shortName)
                // The lone Off, with nothing else to pick, is not an emphasised choice.
                case .off: Text("Off").font(on && !Self.noFixerInstalled(installed) ? Typography.bodyEmphasis : Typography.body)
                }
            }
            .accessibilityIdentifier("fixer-choice")
        }
    }

    private var selection: Binding<Option> {
        Binding(get: { Option(choice) }, set: { choice = Self.choice(picking: $0, from: choice) })
    }
}
