import SwiftUI
import AiTermCore
import AiTermUI

/// The roles and standing instructions, staged until Settings' Save.
struct OperatorSettingsPane: View {
    let model: OperatorSettingsModel
    static let operatorHelp = "One Claude Code session, always on, that runs your signals. Its window is a chat: click its row in the sidebar."
    static let operatorDoes = [
        "Starts a task for each ticket or merge request a signal picks up, in its own worktree and window.",
        "Reads every turn a worker ends and tells it what’s next: the next step, a check, done.",
        "Answers workers’ questions with the Oracle. What they can’t settle it asks you, in its chat.",
    ]
    static let operatorNever = "It never writes code, force-pushes, pushes to a default branch or answers a permission prompt. When its conversation grows long it starts a fresh one; nothing is lost."
    static let oracleHelp = "A second model, from another family, that the Operator checks with."
    static let oracleAsks = [
        "When a worker asks a question: they agree on the answer, in up to three rounds.",
        "When it isn’t sure about a step or a verdict.",
        "Before a risky shell command, a merge or a reply on a review thread.",
    ]
    static let oracleNever = "It never talks to a worker or to you. Turned off, every worker question comes to you in the Operator’s chat."
    static let instructionsHelp = "Standing instructions, in plain sentences. They hold in every signal; a signal’s own prompt comes on top."
    static let instructionsPlaceholder = "Rules the Operator follows in every signal, one per line."
    static func oracleFieldsDimmed(_ oracle: OracleSetting) -> Bool { !oracle.isOn }
    var body: some View {
        if model.isLoaded {
            VStack(alignment: .leading, spacing: Space.block) {
                SettingsGroup(title: "Operator", help: Self.operatorHelp) {
                    SettingsRoleLines(lines: Self.operatorDoes)
                    HelpText(Self.operatorNever)
                    ModelFields(agent: .claude, models: model.models[.claude] ?? [], model: model.model, reasoning: model.reasoning,
                        selectModel: { model.select(model: $0) }, selectReasoning: { model.select(reasoning: $0) })
                }
                OracleGroup(model: model)
                OperatorInstructionsGroup(model: model)
            }
        }
    }
}

private struct SettingsRoleLines: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
                    Text("•").font(Typography.help).foregroundStyle(Palette.muted).accessibilityHidden(true)
                    HelpText(line)
                }
            }
        }
    }
}

struct OracleGroup: View {
    let model: OperatorSettingsModel
    var body: some View {
        let oracle = model.oracle
        let dimmed = OperatorSettingsPane.oracleFieldsDimmed(oracle)
        SettingsGroup(title: "Oracle", help: OperatorSettingsPane.oracleHelp) {
            SettingsSwitch(title: "Oracle", isOn: Binding(get: { model.oracle.isOn }, set: { model.oracle.isOn = $0 }))
        } rows: {
            HelpText("The Operator asks it")
            SettingsRoleLines(lines: OperatorSettingsPane.oracleAsks)
            HelpText(OperatorSettingsPane.oracleNever)
            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Agent") {
                    Select(values: model.oracleAgentChoices, selection: Binding(get: { oracle.agent }, set: { model.select(oracleAgent: $0) }),
                        label: { $0.displayName })
                }.frame(maxWidth: .infinity)
                let options = OperatorSettingsModel.options(model.models[oracle.agent] ?? [], keeping: oracle.model, reasoning: oracle.reasoning)
                if let selected = options.first(where: { $0.id == oracle.model }) ?? options.first {
                    let fields = ModelReasoningFields(models: options, model: selected.id,
                        reasoning: Binding(get: { oracle.reasoning }, set: { if let value = $0 { model.select(oracleReasoning: value) } }),
                        reasoningOptions: OperatorSettingsModel.efforts(of: selected, keeping: oracle.reasoning),
                        selectModel: { model.select(oracleModel: $0) })
                    fields.modelField
                    fields.reasoningField
                } else { FormField("Model") { HelpText(oracle.agent.harness.noModelsExplanation) }.frame(maxWidth: .infinity) }
            }
            .disabled(dimmed).opacity(dimmed ? Opacity.disabled : 1)
        }
    }
}

private struct OperatorInstructionsGroup: View {
    let model: OperatorSettingsModel
    @State private var focused = false
    /// A few standing sentences, shorter than a creation sheet's prompt step.
    private static let editorHeight: CGFloat = 96
    var body: some View {
        SettingsGroup(title: "Steer the Operator", help: OperatorSettingsPane.instructionsHelp) {
            FormField("Instructions") {
                PromptEditor(text: Binding(get: { model.instructions }, set: { model.instructions = $0 }), agent: .claude,
                    completions: model.completions, onFocusChange: { focused = $0 })
                    .frame(height: Self.editorHeight)
                    .overlay(alignment: .topLeading) {
                        if model.instructions.isEmpty {
                            Text(OperatorSettingsPane.instructionsPlaceholder).font(Typography.promptMono).foregroundStyle(Palette.placeholder)
                                .padding(.leading, PromptEditor.textInset.width + PromptEditor.lineFragmentPadding)
                                .padding(.top, PromptEditor.textInset.height).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .fieldBox(focused: focused)
                    .overlay(alignment: .topLeading) {
                        CompletionPopup(completions: model.completions, width: Sheet.width - 2 * Space.margin - 2 * Space.block)
                    }
                    .accessibilityLabel("Instructions")
            }
            HelpText("Type / for skills. You can also tell the Operator in its chat.")
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
