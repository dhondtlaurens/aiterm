import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast's Task step (broadcast setup v2, design 13A): what every task follows, under a lead line saying so. The
/// review is a `PromptStep` whose `/` lists both agents' skills; the end a neutral `SegmentedControl` of the four ends,
/// Merge and Local merge dimmed and unpickable while the Merge slice is off, Draft MR and Merge while a chosen project
/// has no connected code host (`NewBroadcastModel.canPick`), an end picked that is dimmed since moving to Commit; then
/// the two closing checkboxes on one edge, the second disabled while the first is off. Taller than `Sheet.height`
/// allows, so its content scrolls a little.
struct TaskStep: View {
    @Bindable var model: NewBroadcastModel

    var body: some View {
        FrontToBackStack(spacing: Space.block) {
            HelpText(Text("\(Text(NewBroadcastModel.taskLeadTitle).fontWeight(.semibold).foregroundStyle(Palette.text)) \(NewBroadcastModel.taskLead)"))
            // Claude's form for what `/` writes, as on the Prompt step.
            PromptStep(text: $model.review, agent: .claude, completions: model.completions, label: NewBroadcastModel.reviewLabel,
                       placeholder: NewBroadcastModel.reviewPlaceholder, help: NewBroadcastModel.reviewHelp)
            FormField(NewBroadcastModel.endLabel) {
                SegmentedControl(values: TaskEnd.allCases, selection: Binding(get: { model.end }, set: { model.pick(end: $0) }),
                                 isSelectable: model.canPick) { end, _ in
                    Text(end.title).font(Typography.body)
                }
                HelpText(model.endHelp)
            }
            FormField(NewBroadcastModel.closingLabel) {
                Toggle(NewBroadcastModel.closeLabel, isOn: $model.closeWhenDone)
                    .toggleStyle(.checkbox).font(Typography.body)
                Toggle(NewBroadcastModel.deleteBranchLabel, isOn: $model.deleteMergedBranch)
                    .toggleStyle(.checkbox).font(Typography.body)
                    .disabled(!model.canDeleteMergedBranch)
            }
        }
    }
}
