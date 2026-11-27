import SwiftUI
import AiTermUI
import AiTermCore

/// The last step of New Task and New Review. An agent whose CLI is not on the login shell's `PATH` cannot be
/// picked, and the sheet says which one and where to install it instead of letting the task open a
/// window that prints "command not found". With none installed, Continue stays disabled.
struct AgentStep: View {
    let availableAgents: Set<AgentKind>
    let models: [AgentModel]
    let catalogueLoaded: Bool
    /// Why there are no models, when the catalogue could not be read.
    let catalogueFailure: String?
    let agent: AgentKind
    let model: String
    @Binding var reasoning: String?
    let selectAgent: (AgentKind) -> Void
    let setModel: (String) -> Void

    /// The step as both sheets use it. The agent and the model are read here and changed only through
    /// `selectAgent` and `setModel`, which keep the draft's dependent fields in step; the reasoning
    /// level is the one value the step writes itself.
    init<Kind>(model: CreationModel<Kind>) {
        availableAgents = model.availableAgents
        models = model.models
        catalogueLoaded = model.catalogueLoaded
        catalogueFailure = model.catalogueFailure
        agent = model.draft.agent
        self.model = model.models.contains { $0.id == model.draft.model } ? model.draft.model : model.unavailableModel ?? ""
        _reasoning = Binding(get: { model.draft.reasoning }, set: { model.draft.reasoning = $0 })
        selectAgent = { model.selectAgent($0) }
        setModel = { model.draft.setModel($0, catalog: model.models) }
    }

    init(availableAgents: Set<AgentKind>, models: [AgentModel], catalogueLoaded: Bool, catalogueFailure: String? = nil,
         agent: AgentKind, model: String, reasoning: Binding<String?>,
         selectAgent: @escaping (AgentKind) -> Void, setModel: @escaping (String) -> Void) {
        self.availableAgents = availableAgents; self.models = models; self.catalogueLoaded = catalogueLoaded
        self.catalogueFailure = catalogueFailure
        self.agent = agent; self.model = model; _reasoning = reasoning
        self.selectAgent = selectAgent; self.setModel = setModel
    }

    /// Names every CLI and where Settings installs them when none can run.
    static let noAgentNote = AgentKind.allCases.map(\.displayName).sentenceList
        + " aren’t installed. Install them in Settings › Agents."

    /// A catalogue that could not be read says why — "PI couldn’t be launched." — rather than
    /// suggesting a sign-in that would not help.
    static func modelPlaceholder(agent: AgentKind, catalogueLoaded: Bool, failure: String? = nil) -> String {
        catalogueLoaded ? failure ?? agent.harness.noModelsExplanation : "Loading models…"
    }

    var selectedModel: AgentModel? { models.first { $0.id == model } }
    var fields: ModelReasoningFields {
        ModelReasoningFields(models: models, model: model, reasoning: $reasoning,
                             unverified: !catalogueLoaded || catalogueFailure != nil, selectModel: { setModel($0.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            HStack(alignment: .top, spacing: Space.gap) {
                if !availableAgents.isEmpty {
                    FormField("Agent") {
                        Select(values: AgentKind.allCases.filter { availableAgents.contains($0) },
                               selection: Binding(get: { agent }, set: { selectAgent($0) }), label: { $0.displayName })
                    }.frame(maxWidth: .infinity)
                }
                if models.isEmpty && model.isEmpty {
                    FormField("Model") { HelpText(Self.modelPlaceholder(agent: agent, catalogueLoaded: catalogueLoaded, failure: catalogueFailure)).fieldChrome() }
                        .frame(maxWidth: .infinity)
                } else { fields.modelField; fields.reasoningField }
            }
            if availableAgents.isEmpty { HelpText(Self.noAgentNote, tone: .warning) }
            if let catalogueFailure, !models.isEmpty || !model.isEmpty { HelpText(catalogueFailure, tone: .warning) }
            else if catalogueLoaded, selectedModel == nil, !model.isEmpty { HelpText(ModelReasoningFields.unavailableHelp, tone: .warning) }
            if let detail = selectedModel?.detail, !detail.isEmpty { HelpText(detail) }
        }
    }
}
