import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast's Done step (broadcast setup v2, design 10A; copy 2, 5 Nov 2026): the broadcast's goal, a `PromptStep` whose
/// `/` lists both agents' skills; Goal rounds, one number under it; then Worker questions, a `Select` of how hard the Oracle
/// checks a worker's question before it reaches you (`RelayCheck`). All three need the Oracle, so while it is off they are
/// disabled and dimmed as 10A draws them, Worker questions reading Straight to you, and the goal's help says why for all.
struct DoneStep: View {
    @Bindable var model: NewBroadcastModel

    /// The extra rounds' field, fitted to a count of a few digits rather than the step's width.
    private static let roundsWidth: CGFloat = 112

    var body: some View {
        let available = model.goalIsAvailable
        FrontToBackStack(spacing: Space.block) {
            // Claude's form for what `/` writes, as on the Prompt step.
            PromptStep(text: $model.done, agent: .claude, completions: model.completions, label: NewBroadcastModel.goalLabel,
                       placeholder: NewBroadcastModel.goalPlaceholder, help: model.goalHelp)
                .disabled(!available)
            FormField(NewBroadcastModel.extraRoundsLabel) {
                Input(placeholder: NewBroadcastModel.extraRoundsPlaceholder, text: $model.extraRoundsText)
                    .frame(width: Self.roundsWidth)
                    .disabled(!available)
                    .opacity(available ? 1 : Opacity.disabled)
                if let help = model.extraRoundsHelp { HelpText(help) }
            }
            FormField(NewBroadcastModel.workerQuestionsLabel) {
                Select(values: RelayCheck.allCases, selection: Binding(get: { model.shownRelayCheck }, set: { model.relayCheck = $0 }),
                       label: \.title)
                    .fixedSize()
                    .disabled(!available)
                    .opacity(available ? 1 : Opacity.disabled)
                if let help = model.workerQuestionsHelp { HelpText(help) }
            }
        }
    }
}
