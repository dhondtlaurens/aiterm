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
    /// Off, the two `Select`s go without their labels: New Broadcast's Agents rows label their columns once.
    var labelled = true
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
            field(prefix.isEmpty ? "Model" : prefix + "model") {
                Select(values: modelChoices,
                       selection: Binding(get: { selected }, set: { selectModel($0) }),
                       label: { $0.label }, detail: \.detail)
                    .disabled(disabled)
            }
            if !efforts.isEmpty {
                field(prefix.isEmpty ? "Reasoning" : prefix + "reasoning") {
                    Select(values: efforts, selection: Binding(
                        get: { reasoning.flatMap { efforts.contains($0) ? $0 : nil }
                            ?? selected.defaultEffort ?? efforts[0] },
                        set: { reasoning = $0 }), label: { $0.capitalized })
                        .disabled(disabled)
                }
            }
        }
    }

    /// A control under its label; unlabelled, the control alone, for a caller that labels its columns once above rows.
    @ViewBuilder private func field(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        if labelled {
            FormField(label) { control() }.frame(maxWidth: .infinity)
        } else {
            control().frame(maxWidth: .infinity)
        }
    }
}
