import SwiftUI
import AiTermUI
import AiTermCore

/// Shared controls; callers retain their policy for missing models and reasoning levels.
struct ModelReasoningFields: View {
    let models: [AgentModel]
    let model: String
    @Binding var reasoning: String?
    var prefix = ""
    var disabled = false
    var reasoningOptions: [String]? = nil
    /// Off, the two `Select`s go without their labels: New Broadcast's Agents rows label their columns once.
    var labelled = true
    let selectModel: (AgentModel) -> Void

    var selectedModel: AgentModel? { models.first { $0.id == model } }
    private var placeholder: AgentModel {
        AgentModel(id: "", label: "Choose a current model…", detail: nil, efforts: [], defaultEffort: nil)
    }
    var modelChoices: [AgentModel] { selectedModel == nil ? [placeholder] + models : models }

    var body: some View {
        HStack(alignment: .top, spacing: Space.gap) { modelField; reasoningField }
    }
    var modelField: some View {
        field(prefix.isEmpty ? "Model" : prefix + "model") {
            Select(values: modelChoices, selection: Binding(get: { selectedModel ?? placeholder }, set: { selectModel($0) }),
                   label: { $0.label }, detail: \.detail)
                .disabled(disabled).opacity(disabled ? Opacity.disabled : 1)
        }
    }
    @ViewBuilder var reasoningField: some View {
        let selected = selectedModel ?? placeholder
        let efforts = reasoningOptions ?? selected.efforts
        if !efforts.isEmpty {
            field(prefix.isEmpty ? "Reasoning" : prefix + "reasoning") {
                Select(values: efforts, selection: Binding(
                    get: { reasoning.flatMap { efforts.contains($0) ? $0 : nil } ?? selected.defaultEffort ?? efforts[0] },
                    set: { reasoning = $0 }), label: { $0.capitalized })
                    .disabled(disabled).opacity(disabled ? Opacity.disabled : 1)
            }
        } else if !labelled { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
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
