import SwiftUI
import AiTermCore
import AiTermUI

/// Signal → Starts when → Prompt → Agents → Done, in the shared `SteppedSheet`.
struct SignalSheet: View {
    @Bindable var model: SignalModel
    @State private var step = 1
    @State private var projectsOpen = false
    var body: some View {
        SteppedSheet(title: model.title, height: Sheet.height, steps: steps, step: $step,
                     createLabel: model.createLabel, creating: model.starting, create: model.create) {
            content
        } notices: {
            if let error = model.error { Notice(title: error) }
            let waiting = model.readinessLines()
            if !waiting.isEmpty { Notice(title: SignalReadiness.title, description: waiting.joined(separator: "\n")) }
        } closing: {
            SignalDoneSummary(model: model)
        }
        .task(id: model.sourceKey) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.loadPreview()
        }
        .task { await model.loadMetadata() }
        .task { await model.loadCompletions() }
        .task { await model.checkReadiness() }
    }
    /// The Starts when step closes its projects picker, then the JQL completions; the Prompt step its
    /// completion popup.
    private var steps: [Step] {
        let completions = model.completions, jqlCompletions = model.jqlCompletions
        let closesPrompt = {
            guard completions.isOpen else { return false }
            completions.close(); return true
        }
        let closesConditions = {
            if projectsOpen { projectsOpen = false; return true }
            if jqlCompletions.isOpen { jqlCompletions.close(); return true }
            return false
        }
        return SignalModel.stepNames.enumerated().map { index, name in
            let number = index + 1
            return Step(name: name, canAdvance: model.canAdvance(step: number),
                        closeList: number == 2 ? closesConditions : number == 3 ? closesPrompt : { false })
        }
    }
    @ViewBuilder private var content: some View {
        switch step {
        case 1:
            HelpText(Text("A signal starts tasks for you. ").fontWeight(.semibold)
                     + Text("It watches Jira, GitLab or GitHub. When a ticket or a merge request matches, the Operator starts a task for it in the right project, gives it your prompt and follows it until it’s done."))
            FormField("Starts from") {
                SegmentedControl(values: SignalModel.SourceKind.allCases, selection: Binding(get: { model.sourceKind }, set: model.selectSource)) { kind, _ in
                    HStack(spacing: Space.snug) { Icon(kind.mark, size: Size.pickerRowLogo); Text(kind.label) }
                }
                HelpText(model.sourceKind == .jira ? "A task for each Jira ticket that matches your conditions. You set them on the next step."
                         : "A task when you’re asked to review, or when your own merge request needs you. You pick which on the next step.")
            }
            FormField("Name") {
                Input(placeholder: "Name the signal", text: $model.name)
                HelpText("Its heading under Operator in the sidebar.")
            }
        case 2:
            SignalStartsStep(model: model, projectsOpen: $projectsOpen)
        case 3:
            PromptStep(text: $model.prompt, agent: .claude, completions: model.completions, label: "Prompt",
                       placeholder: "Describe what the worker does with each \(model.sourceKind == .jira ? "ticket" : "merge request").",
                       help: "Start to end, including how the work is checked. Type / for skills, @ for files.") {
                if model.sourceKind == .jira { ticketToggle; requestToggle }
                else { requestToggle; ticketToggle }
            }
        case 4: AgentsStep(model: model)
        default: SignalDoneStep(model: model)
        }
    }
    private var ticketToggle: some View {
        DescriptionToggle("Add the ticket’s description", isOn: $model.ticketDescription,
                          help: model.sourceKind == .jira ? "It goes to the worker under your prompt." : "When it has one, under the merge request’s.")
    }
    private var requestToggle: some View {
        DescriptionToggle("Add the merge request’s description", isOn: $model.requestDescription,
                          help: model.sourceKind == .jira ? "When the task has one, for its later stages." : "It goes to the worker under your prompt.")
    }
}

extension SignalModel.SourceKind {
    var label: String { switch self { case .jira: "Jira"; case .gitLab: "GitLab"; case .gitHub: "GitHub" } }
    var mark: IconSource { switch self { case .jira: .brand(Palette.jira); case .gitLab: .brand(Palette.gitlab); case .gitHub: .brand(Palette.github) } }
}

#if DEBUG
extension SignalSheet {
    func seeded(step: Int) -> Self { var sheet = self; sheet._step = State(initialValue: step); return sheet }
}
#endif
