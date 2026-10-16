import SwiftUI
import AiTermUI
import AiTermCore

/// New Operator… and Edit Operator…: who an operator is and how it works, read top to bottom (spec
/// §10.5, proposal step 2). Name, then Persona in the prompt editor — the lessons you kept appended
/// under their heading — Model and Reasoning, Second opinion with the model and reasoning that give it,
/// dimmed at No self-doubt, and Autonomy. Each stepped setting is a `SegmentedControl` over one
/// `HelpText` saying what its chosen stop does. No delegation setting: the operator splits the work.
struct OperatorSheet: View {
    @Bindable var model: OperatorSheetModel
    @Environment(\.dismiss) private var dismiss
    /// The persona has no `/` or `@` to complete: an empty list never opens the popup.
    private let completions = PromptCompletions()
    /// The persona editor's height: a paragraph of character, fitted to the proposal's 4-line box at
    /// `Typography.promptMono` — one-off, as `PromptStep`'s editor height is.
    private static let personaHeight: CGFloat = 96
    // `@State` storage, hand-expanded as everywhere in this target.
    private var _personaFocused = State(initialValue: false)
    private var personaFocused: Bool {
        get { _personaFocused.wrappedValue }
        nonmutating set { _personaFocused.wrappedValue = newValue }
    }

    init(model: OperatorSheetModel) { _model = Bindable(wrappedValue: model) }

    var body: some View {
        SheetLayout(title: model.title, height: Sheet.height) {
            SheetSubtitle(OperatorSheetModel.subtitle)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                FormField("Name") { Input(placeholder: "Senior engineer", text: $model.name) }
                FormField("Persona") {
                    PromptEditor(text: $model.personaText, agent: .claude, completions: completions,
                                 onFocusChange: { if personaFocused != $0 { personaFocused = $0 } })
                        .frame(height: Self.personaHeight)
                        .fieldBox(focused: personaFocused)
                    HelpText(OperatorSheetModel.personaHelp)
                }
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Model") {
                        Select(values: model.claudeModels, selection: Binding(get: { model.selectedModel }, set: { model.selectModel($0.id) }),
                               label: { $0.label }, detail: { $0.detail })
                    }.frame(maxWidth: .infinity)
                    if !model.efforts.isEmpty {
                        FormField("Reasoning") {
                            Select(values: model.efforts, selection: Binding(get: { model.effort ?? model.efforts[0] }, set: { model.effort = $0 }),
                                   label: { $0.capitalized })
                        }.frame(maxWidth: .infinity)
                    }
                }
                FormField("Second opinion") {
                    SegmentedControl(values: SecondOpinionLevel.allCases, selection: $model.level) { level, _ in
                        Text(OperatorSheetModel.title(of: level))
                    }
                    HelpText(OperatorSheetModel.help(for: model.level))
                }
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Second opinion by") {
                        Select(values: model.secondOpinionChoices,
                               selection: Binding(get: { model.secondOpinion }, set: { model.selectSecondOpinion($0) }),
                               label: { $0.label })
                    }.frame(maxWidth: .infinity)
                    if !model.secondOpinionEfforts.isEmpty {
                        FormField("Reasoning") {
                            Select(values: model.secondOpinionEfforts,
                                   selection: Binding(get: { model.secondOpinionEffort ?? model.secondOpinionEfforts[0] },
                                                      set: { model.secondOpinionEffort = $0 }),
                                   label: { $0.capitalized })
                        }.frame(maxWidth: .infinity)
                    }
                }
                // Dimmed, not absent: the choice is kept for when the operator doubts itself again.
                .disabled(model.secondOpinionDimmed)
                FormField("Autonomy") {
                    SegmentedControl(values: Autonomy.allCases, selection: $model.autonomy) { autonomy, _ in
                        Text(OperatorSheetModel.title(of: autonomy))
                    }
                    HelpText(OperatorSheetModel.help(for: model.autonomy))
                }
            }
        } footer: {
            SheetFooter(primary: model.primaryLabel, canSubmit: model.canSave, cancel: { dismiss.afterThisEvent() }, submit: submit) {
                if let error = model.error { HelpText(error, tone: .warning).lineLimit(2) }
            }
        }
    }

    private func submit() { if model.commit() { dismiss.afterThisEvent() } }
}
