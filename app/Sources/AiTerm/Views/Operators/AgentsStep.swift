import SwiftUI
import AiTermUI
import AiTermCore

/// New Signal's Agents step lists the agent, model and reasoning combinations available to its workers.
/// Each row uses its agent's models and defaults from Settings › Agents. With no agent installed, Add is absent.
struct AgentsStep: View {
    let rows: [AgentChoiceRow]
    let offeredAgents: [AgentKind]
    let models: (AgentKind) -> [AgentModel]
    let addAgent: () -> Void
    let removeAgent: (UUID) -> Void
    let setAgent: (AgentKind, UUID) -> Void
    let setModel: (AgentModel, UUID) -> Void
    let setReasoning: (String?, UUID) -> Void
    let help: String


    init(model: SignalModel) {
        rows = model.agentRows; offeredAgents = model.offeredAgents; models = model.models(for:)
        addAgent = model.addAgent; removeAgent = model.removeAgent; setAgent = model.setAgent(_:of:)
        setModel = model.setModel(_:of:); setReasoning = model.setReasoning(_:of:)
        help = "The Operator picks one of these for each task. It moves to the next when one passes 80 % of its weekly limit."
    }

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
                ForEach(rows) { row in agentRow(row) }
            }
            if !offeredAgents.isEmpty {
                Button(action: addAgent) {
                    HStack(spacing: Space.snug) {
                        Image(systemName: "plus").font(Typography.micro)
                        Text("Add an agent").font(Typography.body)
                    }
                    .frame(height: Size.control)
                    .foregroundStyle(Palette.link)
                }
                .buttonStyle(.plain)
            }
            HelpText(help)
        }
    }

    private func label(_ text: String) -> some View { Text(text).font(Typography.label).foregroundStyle(Palette.muted) }

    private func agentRow(_ row: AgentChoiceRow) -> some View {
        let choice = row.choice, models = self.models(choice.agent)
        let removeHelp = "Remove \(choice.agent.displayName) · \(models.first { $0.id == choice.model }?.label ?? choice.model)"
        return HStack(spacing: Space.gap) {
            Select(values: offeredAgents, selection: Binding(get: { choice.agent }, set: { setAgent($0, row.id) }),
                   label: \.displayName)
                .frame(width: Self.agentWidth)
            ModelReasoningFields(models: models, model: choice.model,
                                 reasoning: Binding(get: { choice.reasoning }, set: { setReasoning($0, row.id) }),
                                 labelled: false, selectModel: { setModel($0, row.id) })
            Button { removeAgent(row.id) } label: {
                Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
                    .frame(width: Size.slot, height: Size.control).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(removeHelp).accessibilityLabel(removeHelp)
        }
    }
}
