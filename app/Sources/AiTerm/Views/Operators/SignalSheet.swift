import SwiftUI
import AiTermCore
import AiTermUI

/// Signal → Starts when → Prompt → Agents → Done, in the shared creation-sheet chrome.
struct SignalSheet: View {
    @Bindable var model: SignalModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = 1
    @State private var projectsOpen = false
    var body: some View {
        SteppedSheetFrame(title: model.title, height: Sheet.height, step: step, stepNames: SignalModel.stepNames,
                          onBackgroundTap: closeLists, onNavigate: navigate) {
            content
        } footer: {
            CreationFooter(step: step, steps: SignalModel.steps, error: model.error, availableAgents: [],
                           createLabel: model.createLabel, creating: model.starting, canAdvance: model.canAdvance(step: step),
                           closeList: closeOpenList, back: back, advance: advance, recover: {},
                           waiting: (BroadcastReadiness.title, model.readinessLines()))
        }
        .task(id: model.sourceKey) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await model.loadPreview()
        }
        .task { await model.loadMetadata() }
        .task { await model.loadCompletions() }
        .task { await model.checkReadiness() }
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
                Input(placeholder: model.sourceKind == .jira ? "Sprint tickets" : "My merge requests", text: $model.name)
                HelpText("Its heading under Operator in the sidebar.")
            }
        case 2:
            SignalStartsStep(model: model, projectsOpen: $projectsOpen)
        case 3:
            PromptStep(text: $model.prompt, agent: .claude, completions: model.completions, label: "Prompt", placeholder: nil,
                       help: "What the worker does with each item, start to end. Put the check in it too, such as /psg:review. Type / for skills, @ for files.") {
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
    private func closeLists() { projectsOpen = false; model.completions.close(); model.jqlCompletions.close() }
    private func closeOpenList() -> Bool {
        if model.completions.isOpen { model.completions.close(); return true }
        if model.jqlCompletions.isOpen { model.jqlCompletions.close(); return true }
        if projectsOpen { projectsOpen = false; return true }
        return false
    }
    private func navigate(_ target: Int) {
        guard !model.starting, SheetStepper.canNavigate(from: step, to: target, count: 5) else { return }
        closeLists(); step = target
    }
    private func back() { guard !model.starting else { return }; if step == 1 { dismiss.afterThisEvent() } else { closeLists(); step -= 1 } }
    private func advance() {
        if step < 5 { closeLists(); step += 1 }
        else { Task { if await model.create() { dismiss() } } }
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
