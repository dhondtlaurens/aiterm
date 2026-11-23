import SwiftUI
import AiTermCore
import AiTermUI

/// Signal → Starts when → Agents → Prompt → Done when, in the shared `SteppedSheet`.
struct SignalSheet: View {
    @Bindable var model: SignalModel
    @State private var step = 1
    var body: some View {
        SteppedSheet(title: model.title, height: Sheet.height, steps: steps, step: $step,
                     createLabel: model.createLabel, creating: model.starting, create: model.create) {
            content
        } notices: {
            if let error = model.error { Notice(title: error) }
            switch model.readiness(ModelChoice.pair.filter { agent in model.agents.contains { $0.agent == agent } }) {
            case .checking: Notice(title: SignalReadiness.checkingTitle)
            case .notReady(let lines): Notice(title: SignalReadiness.title, description: lines.joined(separator: "\n"))
            case .ready: EmptyView()
            }
        } closing: {
            SignalDoneSummary(model: model)
        }
        .task(id: model.startKey) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.loadPreview()
        }
        .task { await model.loadCompletions() }
        .task { await model.checkReadiness() }
    }
    /// Each editor's step closes its completion popup first.
    private var steps: [Step] {
        let popups = [SignalModel.startStep: model.startCompletions, SignalModel.promptStep: model.completions,
                      SignalModel.doneStep: model.doneCompletions]
        return SignalModel.stepNames.enumerated().map { index, name in
            let number = index + 1, completions = popups[number]
            return Step(name: name, canAdvance: model.canAdvance(step: number), whyNot: number == SignalModel.agentsStep ? model.agentsWhyNot : nil,
                        closeList: {
                            guard let completions, completions.isOpen else { return false }
                            completions.close(); return true
                        })
        }
    }
    @ViewBuilder private var content: some View {
        switch step {
        case SignalModel.nameStep:
            HelpText(Text("A signal starts tasks for you. ").fontWeight(.semibold)
                     + Text("It starts on an item a query finds in Jira, GitLab or GitHub, or on a schedule. It is done when a query matches, or when the Operator decides."))
            FormField("Name") {
                Input(placeholder: "Name the signal", text: $model.name)
                HelpText("Its heading under Operator in the sidebar.")
            }
        case SignalModel.startStep:
            SignalTriggerStep(model: model, start: true)
            if model.startRefusal == nil, !model.isScheduled { SignalMatchPreview(model: model) }
        case SignalModel.agentsStep: AgentsStep(model: model)
        case SignalModel.promptStep:
            // A run has no ticket or merge request to describe.
            PromptStep(text: $model.prompt, agent: .claude, completions: model.completions, label: "Prompt",
                       placeholder: model.isScheduled ? "Describe what the worker does on each run."
                           : "Describe what the worker does with each \(model.start.source == .jira ? "ticket" : "merge request").",
                       help: "Start to end, including how the work is checked. Type / for skills, @ for files.") {
                if model.isScheduled { EmptyView() }
                else if model.start.source == .jira { ticketToggle; requestToggle }
                else { requestToggle; ticketToggle }
            }
        default: SignalDoneStep(model: model)
        }
    }
    private var ticketToggle: some View {
        DescriptionToggle("Add the ticket’s description", isOn: $model.ticketDescription,
                          help: model.start.source == .jira ? "It goes to the worker under your prompt." : "When it has one, under the merge request’s.")
    }
    private var requestToggle: some View {
        DescriptionToggle("Add the merge request’s description", isOn: $model.requestDescription,
                          help: model.start.source == .jira ? "When the task has one, for its later stages." : "It goes to the worker under your prompt.")
    }
}

#if DEBUG
extension SignalSheet {
    func seeded(step: Int) -> Self { var sheet = self; sheet._step = State(initialValue: step); return sheet }
}
#endif
