import SwiftUI
import AiTermUI
import AiTermCore

/// New Operation…: what to hand the Operator. The Brief in the prompt editor, a wall of tickets and
/// loose to-dos alike; Done when, what finished looks like, which grants nothing itself (a draft MR or
/// merge is an end in the plan); the destination line; Start Operation on ⌘↩, which opens
/// the Operator's window with the brief as its first message. The plan's Task 16 replaces it.
struct NewOperationSheet: View {
    @Bindable var model: NewOperationModel
    @Environment(\.dismiss) private var dismiss
    /// The brief completes nothing: Jira keys are the operator's to read, not the editor's.
    private let completions = PromptCompletions()
    /// The brief's height: four lines at `Typography.promptMono`, the proposal's box — one-off, as
    /// `PromptStep`'s editor height is.
    private static let briefHeight: CGFloat = 104
    private var _briefFocused = State(initialValue: false)
    private var briefFocused: Bool {
        get { _briefFocused.wrappedValue }
        nonmutating set { _briefFocused.wrappedValue = newValue }
    }

    init(model: NewOperationModel) { _model = Bindable(wrappedValue: model) }

    var body: some View {
        SheetLayout(title: NewOperationModel.title, height: Sheet.height) {
            SheetSubtitle(NewOperationModel.subtitle)
        } content: {
            FrontToBackStack(spacing: Space.block) {
                FormField("Brief") {
                    PromptEditor(text: $model.prompt, agent: .claude, completions: completions,
                                 onFocusChange: { if briefFocused != $0 { briefFocused = $0 } }, focusOnAppear: true)
                        .frame(height: Self.briefHeight)
                        .fieldBox(focused: briefFocused)
                    HelpText(NewOperationModel.promptHelp)
                }
                FormField("Done when") {
                    Input(placeholder: NewOperationModel.donePlaceholder, text: $model.done)
                    HelpText(NewOperationModel.doneHelp)
                }
                DestinationLine(model.destination)
            }
        } footer: {
            SheetFooter(primary: "Start Operation", canSubmit: model.canStart, primaryBusy: model.starting,
                        cancel: { if !model.starting { dismiss.afterThisEvent() } }, submit: submit) {
                if let error = model.error { HelpText(error, tone: .warning).lineLimit(2) }
            }
        }
    }

    /// Already past the button's event by the time it dismisses: the start is awaited first.
    private func submit() { Task { if await model.startOperation() != nil { dismiss() } } }
}
