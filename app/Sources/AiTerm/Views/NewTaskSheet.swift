import SwiftUI
import AiTermUI
import AiTermCore

struct NewTaskSheet: View {
    @Bindable var model: TaskCreationModel
    @State private var step = 1
    @State private var ticketsOpen = false
    init(model: TaskCreationModel) { self.model = model }
    var body: some View {
        CreationSheet(model: model, step: $step, title: "New task in \(model.project.name)",
                      stepNames: ["Ticket", "Name and branch", "Prompt", "Agent"], destination: destination,
                      createLabel: "Create Task", canAdvance: Self.canAdvance(step: step, model: model), pickers: [$ticketsOpen]) {
            content
        }
    }
    @ViewBuilder private var content: some View {
        switch step {
        case 1: NewTaskFirstStep(model: model, ticketsOpen: $ticketsOpen)
        case 2: NewTaskNamingStep(model: model)
        case 3:
            PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
                if model.draft.ticket?.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    DescriptionToggle("Add the ticket’s description", isOn: $model.draft.appendTicket,
                                      help: "It goes to the agent under your prompt.")
                }
            }
        default: AgentStep(model: model)
        }
    }
    static func canAdvance(step: Int, model: TaskCreationModel) -> Bool {
        guard !model.creating else { return false }
        if step == 1 { return true }
        guard TaskCreator.isNamed(model.draft.title), !model.draft.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return step != TaskCreation.steps.agentStep || model.agentIsReady
    }
    private var destination: Destination? {
        guard TaskCreation.steps.showsDestination(onStep: step), !model.worktreeSlug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: model.worktreeSlug, branch: model.draft.branch)
    }
}

#if DEBUG
extension NewTaskSheet {
    func seeded(step: Int, ticketsOpen: Bool = false) -> Self {
        var sheet = self; sheet._step = State(initialValue: step); sheet._ticketsOpen = State(initialValue: ticketsOpen); return sheet
    }
}
#endif

struct NewTaskFirstStep: View {
    @Bindable var model: TaskCreationModel
    @Binding var ticketsOpen: Bool
    var body: some View {
        FormField("Ticket (optional)") {
            TicketPickerField(placeholder: model.ticketPlaceholder,
                              query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                              open: $ticketsOpen, items: model.results, selection: model.draft.ticket,
                              onPick: { model.cancelSearch(); model.draft.apply(ticket: $0) },
                              onClear: { model.draft.apply(ticket: nil); model.reopenSearch(); ticketsOpen = true })
            if let error = model.searchError { HelpText(error, tone: .warning) }
            else { HelpText("A ticket fills in the name and branch. Empty: start without a ticket.") }
        }
    }
}

struct NewTaskNamingStep: View {
    @Bindable var model: TaskCreationModel
    var body: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField("Name") {
                Input(placeholder: "Describe the task", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
                HelpText("Its name in the sidebar. The branch follows until you change it.")
            }
            FormField("Branch") {
                Input(placeholder: "feat/my-task", text: Binding(get: { model.draft.branch }, set: { model.draft.setFullBranch($0) }), monospaced: true)
                HelpText("A new branch for the task, in its own worktree.")
            }
            FormField("Base branch") {
                Select(values: choices, selection: $model.draft.baseBranch, label: { $0 }, monospaced: true)
                HelpText("The branch it starts from.")
            }
            if !model.worktreeIncludes.isEmpty { WorktreeIncludeToggle(files: model.worktreeIncludes, isOn: $model.draft.copiesWorktreeInclude) }
        }
    }
    private var choices: [String] {
        model.branches.contains(model.draft.baseBranch) || model.draft.baseBranch.isEmpty ? model.branches : [model.draft.baseBranch] + model.branches
    }
}
