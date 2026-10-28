import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast's Agents step (broadcast setup v2, design 1A): the combinations the Operator may start workers, tabs and
/// reviewers on, a row each of an Agent `Select`, an unlabelled `ModelReasoningFields` and a ✕, the column labels once
/// above them, then “Add an agent” in the link's ink and the step's help. A row's models and reasoning levels are its
/// agent's own, as Settings › Agents lists them; picking an agent takes its default there, and a model keeps the
/// reasoning while it offers it. With no agent installed there is nothing to add, and the link is left out.
struct AgentsStep: View {
    let model: NewBroadcastModel

    /// The Agent column, fitted to “Claude Code” beside its popup's arrows.
    private static let agentWidth: CGFloat = 136

    var body: some View {
        FrontToBackStack(spacing: Space.snug) {
            VStack(alignment: .leading, spacing: Space.base) {
                // Model and Reasoning split what is left as `ModelReasoningFields` splits it.
                HStack(spacing: Space.gap) {
                    label("Agent").frame(width: Self.agentWidth, alignment: .leading)
                    label("Model").frame(maxWidth: .infinity, alignment: .leading)
                    label("Reasoning").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Size.slot, height: 0)
                }
                ForEach(model.agentRows) { row in agentRow(row) }
            }
            if !model.offeredAgents.isEmpty {
                Button(action: model.addAgent) {
                    HStack(spacing: Space.snug) {
                        Image(systemName: "plus").font(Typography.micro)
                        Text(NewBroadcastModel.addAgentLabel).font(Typography.body)
                    }
                    .frame(height: Size.control)
                    .foregroundStyle(Palette.link)
                }
                .buttonStyle(.plain)
            }
            HelpText(NewBroadcastModel.agentsHelp)
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(Typography.label).foregroundStyle(Palette.muted) }

    private func agentRow(_ row: NewBroadcastModel.AgentRow) -> some View {
        let choice = row.choice, models = model.models(for: choice.agent)
        let removeHelp = "Remove \(choice.agent.displayName) · \(models.first { $0.id == choice.model }?.label ?? choice.model)"
        return HStack(spacing: Space.gap) {
            Select(values: model.offeredAgents, selection: Binding(get: { choice.agent }, set: { model.setAgent($0, of: row.id) }),
                   label: \.displayName)
                .frame(width: Self.agentWidth)
            ModelReasoningFields(models: models, model: choice.model,
                                 reasoning: Binding(get: { choice.reasoning }, set: { model.setReasoning($0, of: row.id) }),
                                 labelled: false, selectModel: { model.setModel($0, of: row.id) })
            Button { model.removeAgent(row.id) } label: {
                Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
                    .frame(width: Size.slot, height: Size.control).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(removeHelp).accessibilityLabel(removeHelp)
        }
    }
}
