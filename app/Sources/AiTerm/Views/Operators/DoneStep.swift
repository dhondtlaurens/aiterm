import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast's Done step (broadcast setup v2, design 10A): the broadcast's goal, a `PromptStep` whose `/` lists both
/// agents' skills, and its extra rounds, one number under it. A goal is checked with the Oracle, so while the Oracle is
/// off both are disabled and the goal's help says why for both.
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
                if let help = model.extraRoundsHelp { HelpText(help) }
            }
        }
    }
}
