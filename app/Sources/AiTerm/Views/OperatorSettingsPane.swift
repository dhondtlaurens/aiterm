import SwiftUI
import AiTermCore
import AiTermUI

/// Settings › Operator (spec §8): four `SettingsGroup`s. Agent names Claude Code, the one agent that
/// can lead, with no control to pick it, then its Model and Reasoning. Autonomy lists the base, then
/// each slice with its switch, then the fixed Never lines. Oracle is one switch in its heading over
/// Agent, Model and Reasoning, dimmed and kept while it is off. Instructions is a `PromptEditor`
/// whose `/` lists both agents' skills. Everything is staged in `OperatorSettingsModel` until Save.
struct OperatorSettingsPane: View {
    let model: OperatorSettingsModel

    /// One slice of trust (spec §5): its name, what it allows, and its switch in `Slices`.
    struct Slice: Identifiable, Sendable {
        let title: String
        let help: String
        let keyPath: WritableKeyPath<Slices, Bool> & Sendable
        var id: String { title }
    }

    static let agentHelp = "It plans the work and steers the agents in your tasks. It reads code but never writes it."
    static let autonomyHelp = "What it does without asking you. Each switch is one slice of trust on top of the base. Changes apply to the next broadcast."
    static let baseHelp = "Plans, starts tasks, steers its agents and answers them from the brief and the code. Adds backlog tasks, the Oracle checking them. Commits, pushes the task’s branch, opens a draft MR, runs agent reviews."
    static let alwaysOn = "Always on"
    static let slices = [
        Slice(title: "Jira",
              help: "Creates and updates tickets in the broadcast’s Jira projects: tickets for planned work and off-brief finds, status moves, links.",
              keyPath: \.jira),
        Slice(title: "Review",
              help: "Involves people on the MR: marks it ready, assigns reviewers, has the agent fix their feedback and replies in the threads.",
              keyPath: \.review),
        Slice(title: "Merge",
              help: "Merges when what you wrote in Review and Done holds: through the MR, or locally without pushing. Only a commit it checked, with the pipeline green and every thread resolved.",
              keyPath: \.merge),
    ]
    /// What it never does, whatever the slices (spec §2): facts, not failures, so muted rather than amber.
    static let never = [
        "Never writes code itself. Its agents do.",
        "Never deploys, force-pushes, or pushes to a default or protected branch.",
        "Never answers an agent’s permission prompt. That’s always yours.",
    ]
    static let oracleHelp = "A second agent that checks the Operator’s plan, its backlog additions and its verdicts. Each check adds tens of seconds. PI checks with read-only tools, not a sandbox. Changes apply to the next broadcast."
    static let instructionsHelp = "House rules for every broadcast. Type / for the agents’ skills."

    /// The Oracle's fields are dimmed, and disabled, while it is off; their values are kept.
    static func oracleFieldsDimmed(_ oracle: OracleSetting) -> Bool { !oracle.isOn }

    var body: some View {
        // Drawn once the profile is read, which Settings starts as it opens: before that there is
        // nothing true to show.
        if model.isLoaded {
            VStack(alignment: .leading, spacing: Space.block) {
                OperatorAgentGroup(model: model)
                OperatorAutonomyGroup(model: model)
                OracleGroup(model: model)
                OperatorInstructionsGroup(model: model)
            }
        }
    }
}

/// Claude Code by its mark and name, then the Operator's model and reasoning.
private struct OperatorAgentGroup: View {
    let model: OperatorSettingsModel

    var body: some View {
        SettingsGroup(title: "Agent", help: OperatorSettingsPane.agentHelp) {
            HStack(spacing: Space.base) {
                VendorMark(agent: AgentKind.claude.session, size: Size.vendorMark)
                Text(AgentKind.claude.displayName).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
            }
            .accessibilityElement(children: .combine)
            ModelFields(agent: .claude, models: model.models[.claude] ?? [], model: model.model, reasoning: model.reasoning,
                        selectModel: { model.select(model: $0) }, selectReasoning: { model.select(reasoning: $0) })
        }
    }
}

/// The base, always on, then each slice with its switch, rows split by a `Hairline`, then the Never lines.
private struct OperatorAutonomyGroup: View {
    let model: OperatorSettingsModel

    var body: some View {
        SettingsGroup(title: "Autonomy", help: OperatorSettingsPane.autonomyHelp) {
            row(title: "Base", help: OperatorSettingsPane.baseHelp) {
                Text(OperatorSettingsPane.alwaysOn).font(Typography.help).foregroundStyle(Palette.muted)
            }
            ForEach(OperatorSettingsPane.slices) { slice in
                Hairline()
                row(title: slice.title, help: slice.help) {
                    SettingsSwitch(title: slice.title,
                                   isOn: Binding(get: { model.slices[keyPath: slice.keyPath] },
                                                 set: { model.slices[keyPath: slice.keyPath] = $0 }))
                }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Space.tight) {
                ForEach(OperatorSettingsPane.never, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.snug) {
                        Image(systemName: "nosign").accessibilityHidden(true)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Typography.help)
                    .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func row(title: String, help: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.gap) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                HelpText(help)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
    }
}

/// The Oracle's switch in the heading, over its Agent, Model and Reasoning. Not private: the snapshots
/// draw it alone, off.
struct OracleGroup: View {
    let model: OperatorSettingsModel
    var body: some View {
        let oracle = model.oracle
        let dimmed = OperatorSettingsPane.oracleFieldsDimmed(oracle)
        SettingsGroup(title: "Oracle", help: OperatorSettingsPane.oracleHelp) {
            SettingsSwitch(title: "Oracle", isOn: Binding(get: { model.oracle.isOn }, set: { model.oracle.isOn = $0 }))
        } rows: {
            VStack(alignment: .leading, spacing: Space.gap) {
                FormField("Agent") {
                    Select(values: model.oracleAgentChoices,
                           selection: Binding(get: { oracle.agent }, set: { model.select(oracleAgent: $0) }),
                           label: { $0.displayName })
                }
                ModelFields(agent: oracle.agent, models: model.models[oracle.agent] ?? [], model: oracle.model, reasoning: oracle.reasoning,
                            selectModel: { model.select(oracleModel: $0) }, selectReasoning: { model.select(oracleReasoning: $0) })
            }
            .disabled(dimmed)
            .opacity(dimmed ? Opacity.disabled : 1)
        }
    }
}

/// House rules for every broadcast, in the prompt editor the creation sheets use.
private struct OperatorInstructionsGroup: View {
    let model: OperatorSettingsModel

    init(model: OperatorSettingsModel) { self.model = model }
    /// The editor's height: the drawing's, a few lines of rules. Shorter than `PromptStep`'s,
    /// which is a sheet's one field; one view reads it.
    private static let editorHeight: CGFloat = 96
    private var _editorFocused = State(initialValue: false)
    private var editorFocused: Bool {
        get { _editorFocused.wrappedValue }
        nonmutating set { _editorFocused.wrappedValue = newValue }
    }

    var body: some View {
        SettingsGroup(title: "Instructions", help: OperatorSettingsPane.instructionsHelp) {
            PromptEditor(text: Binding(get: { model.instructions }, set: { model.instructions = $0 }), agent: .claude,
                         completions: model.completions,
                         onFocusChange: { if editorFocused != $0 { editorFocused = $0 } })
                .frame(height: Self.editorHeight)
                .fieldBox(focused: editorFocused)
                .overlay(alignment: .topLeading) {
                    CompletionPopup(completions: model.completions,
                                    width: Sheet.width - 2 * Space.margin - 2 * Space.block)
                }
                .accessibilityLabel("Instructions")
        }
    }
}

/// Model, and Reasoning beside it while the model takes one, from `agent`'s catalogue; the saved
/// model is offered by its id when the catalogue no longer lists it.
private struct ModelFields: View {
    let agent: AgentKind
    let models: [AgentModel]
    let model: String
    let reasoning: String?
    let selectModel: (AgentModel) -> Void
    let selectReasoning: (String) -> Void

    var body: some View {
        let options = OperatorSettingsModel.options(models, keeping: model, reasoning: reasoning)
        if options.isEmpty {
            HelpText(agent.harness.noModelsExplanation)
        } else {
            let selected = options.first { $0.id == model } ?? options[0]
            let efforts = OperatorSettingsModel.efforts(of: selected, keeping: reasoning)
            ModelReasoningFields(
                models: options, model: selected.id,
                reasoning: Binding(get: { reasoning }, set: { if let value = $0 { selectReasoning(value) } }),
                reasoningOptions: efforts, selectModel: selectModel)
        }
    }
}
