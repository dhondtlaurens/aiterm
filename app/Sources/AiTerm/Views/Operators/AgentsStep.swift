import SwiftUI
import AiTermUI
import AiTermCore

/// New Broadcast's Agents step (broadcast setup v2, design 1A): the combinations the Operator may start workers, tabs and
/// reviewers on, a row each of Agent · Model · Reasoning `Select`s and a ✕, the column labels once above them, then
/// “Add an agent” in the link's ink and the step's help. A row's models and reasoning levels are its agent's own, as
/// Settings › Agents lists them; picking an agent takes its default there, and a model keeps the reasoning while it
/// offers it. With no agent installed there is nothing to add, and the link is left out.
struct AgentsStep: View {
    let model: NewBroadcastModel

    /// The Agent column, fitted to “Claude Code” beside its popup's arrows.
    private static let agentWidth: CGFloat = 136
    /// The Reasoning column, fitted to “Medium” beside its popup's arrows.
    private static let reasoningWidth: CGFloat = 112

    var body: some View {
        FrontToBackStack(spacing: Space.snug) {
            Grid(alignment: .leading, horizontalSpacing: Space.gap, verticalSpacing: Space.base) {
                GridRow {
                    label("Agent").frame(width: Self.agentWidth, alignment: .leading)
                    label("Model")
                    label("Reasoning").frame(width: Self.reasoningWidth, alignment: .leading)
                    Color.clear.frame(width: Size.slot, height: 0)
                }
                ForEach(model.agentRows) { row in agentRow(row) }
            }
            if !model.offeredAgents.isEmpty {
                Button(action: model.addAgent) {
                    HStack(spacing: Space.tight) {
                        Image(systemName: "plus").font(Typography.micro)
                        Text(NewBroadcastModel.addAgentLabel).font(Typography.body)
                    }
                    .foregroundStyle(Palette.link)
                }
                .buttonStyle(.plain)
            }
            HelpText(NewBroadcastModel.agentsHelp)
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(Typography.label).foregroundStyle(Palette.muted) }

    /// A row's model is always one its agent lists: rows are seeded, defaulted and picked from those lists.
    private func agentRow(_ row: NewBroadcastModel.AgentRow) -> some View {
        let choice = row.choice, models = model.models(for: choice.agent)
        let picked = models.first { $0.id == choice.model }
        let efforts = picked?.efforts ?? []
        let removeHelp = "Remove \(choice.agent.displayName) · \(picked?.label ?? choice.model)"
        return GridRow {
            Select(values: model.offeredAgents, selection: Binding(get: { choice.agent }, set: { model.setAgent($0, of: row.id) }),
                   label: \.displayName)
                .frame(width: Self.agentWidth)
            Select(values: models, selection: Binding(get: { picked ?? models[0] }, set: { model.setModel($0, of: row.id) }),
                   label: \.label, detail: \.detail)
            Group {
                if efforts.isEmpty {
                    Color.clear.frame(height: Size.control)
                } else {
                    Select(values: efforts, selection: Binding(get: { choice.reasoning ?? picked?.defaultEffort ?? efforts[0] },
                                                               set: { model.setReasoning($0, of: row.id) }),
                           label: { $0.capitalized })
                }
            }
            .frame(width: Self.reasoningWidth)
            Button { model.removeAgent(row.id) } label: {
                Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
                    .frame(width: Size.slot, height: Size.control).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(removeHelp).accessibilityLabel(removeHelp)
        }
    }
}
