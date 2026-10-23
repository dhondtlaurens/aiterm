import SwiftUI
import AiTermUI
import AiTermCore

/// Shared controls; callers retain their policy for missing models and reasoning levels.
struct ModelReasoningFields: View {
    let models: [AgentModel]
    let model: String
    @Binding var reasoning: String?
    var prefix = ""
    var missingModelLabel = "Choose a current model…"
    var disabled = false
    var reasoningOptions: [String]? = nil
    let selectModel: (AgentModel) -> Void

    var selectedModel: AgentModel? { models.first { $0.id == model } }
    private var placeholder: AgentModel {
        AgentModel(id: "", label: missingModelLabel, detail: nil, efforts: [], defaultEffort: nil)
    }
    var modelChoices: [AgentModel] { selectedModel == nil ? [placeholder] + models : models }

    var body: some View {
        let selected = selectedModel ?? placeholder
        let efforts = reasoningOptions ?? selected.efforts
        HStack(alignment: .top, spacing: Space.gap) {
            FormField(prefix.isEmpty ? "Model" : prefix + "model") {
                Select(values: modelChoices,
                       selection: Binding(get: { selected }, set: { selectModel($0) }),
                       label: { $0.label }, detail: \.detail)
                    .disabled(disabled)
            }.frame(maxWidth: .infinity)
            if !efforts.isEmpty {
                FormField(prefix.isEmpty ? "Reasoning" : prefix + "reasoning") {
                    Select(values: efforts, selection: Binding(
                        get: { reasoning.flatMap { efforts.contains($0) ? $0 : nil }
                            ?? selected.defaultEffort ?? efforts[0] },
                        set: { reasoning = $0 }), label: { $0.capitalized })
                        .disabled(disabled)
                }.frame(maxWidth: .infinity)
            }
        }
    }
}
