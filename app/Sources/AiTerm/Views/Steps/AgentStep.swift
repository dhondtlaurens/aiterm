import SwiftUI
import AiTermUI
import AiTermCore

/// Step 2 of both sheets. Spec 8: an agent whose CLI is not on the login shell's `PATH` cannot be
/// picked, and the sheet says which one and where to install it instead of letting the task open a
/// window that prints "command not found". With none installed, Continue stays disabled.
struct AgentStep: View {
    let availableAgents: Set<AgentKind>
    let models: [AgentModel]
    let catalogueLoaded: Bool
    @Binding var agent: AgentKind
    @Binding var model: String
    @Binding var reasoning: String?
    let selectAgent: (AgentKind) -> Void
    let setModel: (String) -> Void

    /// The step as both sheets use it: every value read from, and written to, the creation model.
    init<Draft, Item>(model: CreationModel<Draft, Item>) {
        availableAgents = model.availableAgents
        models = model.models
        catalogueLoaded = model.catalogueLoaded
        _agent = Binding(get: { model.draft.agent }, set: { model.draft.agent = $0 })
        _model = Binding(get: { model.draft.model }, set: { model.draft.model = $0 })
        _reasoning = Binding(get: { model.draft.reasoning }, set: { model.draft.reasoning = $0 })
        selectAgent = { model.selectAgent($0) }
        setModel = { model.draft.setModel($0, catalog: model.models) }
    }

    init(availableAgents: Set<AgentKind>, models: [AgentModel], catalogueLoaded: Bool,
         agent: Binding<AgentKind>, model: Binding<String>, reasoning: Binding<String?>,
         selectAgent: @escaping (AgentKind) -> Void, setModel: @escaping (String) -> Void) {
        self.availableAgents = availableAgents; self.models = models; self.catalogueLoaded = catalogueLoaded
        _agent = agent; _model = model; _reasoning = reasoning
        self.selectAgent = selectAgent; self.setModel = setModel
    }

    /// Names the missing CLIs and where Settings installs them.
    static func missingAgentNote(available: Set<AgentKind>) -> String? {
        let missing = AgentKind.allCases.filter { !available.contains($0) }.map(\.displayName)
        guard let last = missing.last else { return nil }
        let names = missing.count == 1 ? last : missing.dropLast().joined(separator: ", ") + " and " + last
        return names + (missing.count == 1 ? " isn’t installed. Install it" : " aren’t installed. Install them")
            + " in Settings › Agents."
    }

    static func modelPlaceholder(agent: AgentKind, catalogueLoaded: Bool) -> String {
        catalogueLoaded ? agent.noModelsExplanation : "Loading models…"
    }

    var selectedModel: AgentModel? { models.first { $0.id == model } }
    private var unselectedModel: AgentModel {
        AgentModel(id: "", label: "Choose a current model…", detail: nil, efforts: [], defaultEffort: nil)
    }
    var modelChoices: [AgentModel] { selectedModel == nil ? [unselectedModel] + models : models }
    var efforts: [String] { selectedModel?.efforts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("Agent") {
                AgentSegmented(agents: AgentKind.allCases, available: availableAgents,
                               selection: Binding(get: { agent }, set: { selectAgent($0) }))
                if let note = Self.missingAgentNote(available: availableAgents) {
                    HelpText(note, tone: .warning)
                }
            }

            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Model") {
                    if models.isEmpty {
                        HelpText(Self.modelPlaceholder(agent: agent, catalogueLoaded: catalogueLoaded)).fieldChrome()
                    } else {
                        Select(values: modelChoices, selection: Binding(get: { selectedModel ?? unselectedModel }, set: { setModel($0.id) }),
                               label: { $0.label }, detail: { $0.detail })
                    }
                }.frame(maxWidth: .infinity)
                // A model can publish no reasoning levels at all — Haiku's catalogue entry says
                // `thinking: none` — and then there is no flag to pass and nothing to pick.
                if !efforts.isEmpty {
                    FormField("Reasoning") {
                        Select(values: efforts, selection: Binding(get: { reasoning ?? efforts.first ?? "" }, set: { reasoning = $0 }),
                               label: { $0.capitalized })
                    }.frame(maxWidth: .infinity)
                }
            }

            if let detail = selectedModel?.detail, !detail.isEmpty { HelpText(detail) }
        }
    }
}
