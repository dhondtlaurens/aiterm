import SwiftUI
import AiTermUI
import AiTermCore

/// New Task's three steps: Task, Agent, Prompt. The first holds everything about where the task
/// comes from and where it lives — an optional ticket, its name, its branch and base — so a new
/// task opens on its name, not on a ticket search.
struct NewTaskSheet: View {
    @Bindable var model: TaskCreationModel
    @State private var step = 1
    @State private var ticketsOpen = false
    @State private var baseOpen = false
    init(model: TaskCreationModel) { self.model = model }
    var body: some View {
        SteppedSheet(title: "New task in \(model.project.name)", height: Sheet.creationHeight, steps: steps, step: $step,
                     createLabel: "Create Task", creating: model.creating, create: model.create) {
            content
        } notices: {
            CreationNotices(error: model.error,
                            creating: model.creating, recoverAndCreate: model.recoverAndCreate)
        } closing: {
            CreationSummary(model: model, destination: destination)
        }
        .creationLoads(model)
    }
    /// Leaving the Task step closes its ticket and base lists; the Prompt step's list is the completion popup.
    private var steps: [Step] {
        let canChange = model.canChangeWorkspace()
        let completions = model.completions
        return [
            Step(name: "Task", canAdvance: canChange && Self.canAdvance(step: 1, model: model), closeList: {
                if ticketsOpen { ticketsOpen = false; return true }
                if baseOpen { baseOpen = false; return true }
                return false
            }),
            Step(name: "Agent", canAdvance: canChange && Self.canAdvance(step: TaskCreation.agentStep, model: model)),
            Step(name: "Prompt", canAdvance: canChange && Self.canAdvance(step: TaskCreation.promptStep, model: model), closeList: {
                guard completions.isOpen else { return false }
                completions.close(); return true
            }),
        ]
    }
    @ViewBuilder private var content: some View {
        switch step {
        case 1: NewTaskFirstStep(model: model, ticketsOpen: $ticketsOpen, baseOpen: $baseOpen)
        case TaskCreation.agentStep: AgentStep(model: model)
        default:
            PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
                if model.draft.ticket?.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    DescriptionToggle("Add the ticket’s description", isOn: $model.draft.appendTicket,
                                      help: "It goes to the agent under your prompt.")
                }
            }
        }
    }
    /// Every step needs a name and a branch, which the first step asks for; the agent's step and
    /// the prompt's after it need an agent that can run too.
    static func canAdvance(step: Int, model: TaskCreationModel) -> Bool {
        guard !model.creating else { return false }
        guard TaskCreator.isNamed(model.draft.title), !model.draft.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.draft.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return step < TaskCreation.agentStep || model.agentIsReady
    }
    private var destination: Destination? {
        guard step == TaskCreation.lastStep, !model.worktreeSlug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: model.worktreeSlug, branch: model.draft.branch)
    }
}

#if DEBUG
extension NewTaskSheet {
    func seeded(step: Int, ticketsOpen: Bool = false, baseOpen: Bool = false) -> Self {
        var sheet = self; sheet._step = State(initialValue: step); sheet._ticketsOpen = State(initialValue: ticketsOpen); sheet._baseOpen = State(initialValue: baseOpen); return sheet
    }
}
#endif

/// The Task step: the ticket, which fills in the name and branch, then the name, the branch beside
/// its base, and the worktree's copied files.
struct NewTaskFirstStep: View {
    @Bindable var model: TaskCreationModel
    @Binding var ticketsOpen: Bool
    @Binding var baseOpen: Bool
    /// The base-branch field’s column: room for `main`, `develop` or a short release branch in
    /// monospace, the rest of the row left to the new branch.
    private static let baseBranchWidth: CGFloat = 190
    var body: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField("Ticket (optional)") {
                TicketPickerField(placeholder: model.ticketPlaceholder,
                                  query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                                  open: $ticketsOpen, items: model.results, selection: model.draft.ticket,
                                  onPick: { model.cancelSearch(); model.draft.apply(ticket: $0) },
                                  onClear: { model.draft.apply(ticket: nil); model.reopenSearch(); ticketsOpen = true })
                if let error = model.searchError { HelpText(error, tone: .warning) }
                else if model.draft.ticket == nil { HelpText("A ticket fills in the name and branch.") }
            }
            FormField("Name") {
                Input(placeholder: "Describe the task", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
                HelpText("Its name in the sidebar. The branch follows until you change it.")
            }
            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Branch") {
                    Input(placeholder: "feat/my-task", text: Binding(get: { model.draft.branch }, set: { model.draft.setFullBranch($0) }), monospaced: true)
                    HelpText("A new branch, in its own worktree.")
                }
                FormField("Base branch") {
                    BranchInput(placeholder: "main", text: Binding(get: { model.draft.baseBranch }, set: {
                        model.draft.baseBranch = $0; model.branchQuery = $0
                    }), open: $baseOpen, choices: model.branchMatches)
                    if model.branchesLoaded, !model.draft.baseBranch.isEmpty, !model.branches.contains(model.draft.baseBranch) {
                        HelpText("That branch doesn’t exist in this repository.", tone: .warning)
                    } else { HelpText("The branch it starts from.") }
                }.frame(width: Self.baseBranchWidth)
            }
            if !model.worktreeIncludes.isEmpty { WorktreeIncludeToggle(files: model.worktreeIncludes, isOn: $model.draft.copiesWorktreeInclude) }
        }
    }
}
