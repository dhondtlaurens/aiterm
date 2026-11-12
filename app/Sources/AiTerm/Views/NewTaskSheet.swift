import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

struct NewTaskSheet: View {
    @Bindable var model: TaskCreationModel
    @State private var step: Int = 1
    @State private var ticketsOpen: Bool = false
    /// The branch-type popup's column: its longest type, `chore`, in monospace plus the popup's
    /// chevron and bezel — no wider, since every point it takes comes out of the branch name
    /// beside it.
    private static let branchTypeWidth: CGFloat = 96
    /// The base-branch popup's column: room for `main`, `develop` or a short release branch in
    /// monospace, the rest of the row left to the new branch's name.
    private static let baseBranchWidth: CGFloat = 190

    init(model: TaskCreationModel) { self.model = model }

    var body: some View {
        CreationSheet(model: model, step: $step, title: "New task in \(model.project.name)",
                      stepNames: ["Task", "Agent", "Prompt"], destination: destination, createLabel: "Create Task",
                      canAdvance: Self.canAdvance(step: step, model: model), pickers: [$ticketsOpen]) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: ticketStep
        case 2: AgentStep(model: model)
        default: PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
            if model.draft.ticket != nil {
                Toggle("Include ticket details", isOn: $model.draft.appendTicket)
                    .toggleStyle(.checkbox).font(Typography.body)
            }
        }
        }
    }

    // -- step 1: ticket -------------------------------------------------------------

    private var ticketStep: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField("Ticket (optional)") {
                TicketPickerField(placeholder: model.ticketPlaceholder,
                                  query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                                  open: $ticketsOpen, items: model.results, selection: model.draft.ticket,
                                  onPick: { ticket in model.cancelSearch(); model.draft.apply(ticket: ticket) },
                                  onClear: { model.draft.apply(ticket: nil); model.reopenSearch(); ticketsOpen = true })
                if model.draft.ticket == nil {
                    if let message = model.searchError {
                        HelpText(message, tone: .warning)
                    } else {
                        HelpText("Select a ticket to fill in the name, type and branch.")
                    }
                }
            }

            FormField("Task name") {
                Input(placeholder: "Describe the task", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }

            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Type") {
                    Select(values: BranchType.allCases, selection: Binding(get: { model.draft.branchType }, set: { model.draft.setBranchType($0) }),
                           label: { $0.rawValue }, detail: { $0.summary }, monospaced: true)
                }.frame(width: Self.branchTypeWidth)
                FormField("New branch") {
                    Input(placeholder: "branch-name", text: Binding(get: { model.draft.branchName }, set: { model.draft.setBranch($0) }), monospaced: true)
                }
                FormField("Base branch") {
                    Select(values: baseBranchChoices, selection: $model.draft.baseBranch, label: { $0 }, monospaced: true)
                }.frame(width: Self.baseBranchWidth)
            }

            // The step's last field, so it sits above the destination line `CreationSheet` draws
            // after the step: a choice about the worktree, among the fields.
            if !model.worktreeIncludes.isEmpty {
                WorktreeIncludeToggle(files: model.worktreeIncludes, isOn: $model.draft.copiesWorktreeInclude)
            }
        }
    }

    /// The popup always offers the branch the model.draft is on, even if git has not heard of it yet —
    /// an `NSPopUpButton` whose selection is not in its menu shows nothing at all.
    private var baseBranchChoices: [String] {
        model.branches.contains(model.draft.baseBranch) || model.draft.baseBranch.isEmpty ? model.branches : [model.draft.baseBranch] + model.branches
    }

    // -- what the scaffold is handed ------------------------------------------------

    /// Step 1 needs a name and nothing else: the branch follows the title. The agent and prompt
    /// steps need an agent that can run too — with no CLI installed, Create Task is dead and the
    /// footer says why.
    static func canAdvance(step: Int, model: TaskCreationModel) -> Bool {
        guard !model.creating, TaskCreator.isNamed(model.draft.title) else { return false }
        return step == 1 || model.agentIsReady
    }

    /// Where the task opens: its new worktree, on steps 1 and 3 only — finding the unused slug
    /// looks at the disk. Nothing until the task has a name to make a worktree of.
    private var destination: Destination? {
        guard TaskCreation.steps.showsDestination(onStep: step) else { return nil }
        let slug = model.worktreeSlug
        guard !slug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: slug, branch: model.draft.branchName.isEmpty ? "" : model.draft.branch)
    }
}

#if DEBUG
extension NewTaskSheet {
    /// The sheet already on `step`, its ticket list open or not: what only clicks reach in the app,
    /// for the snapshots and the tests that host the sheet.
    func seeded(step: Int, ticketsOpen: Bool = false) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        sheet._ticketsOpen = State(initialValue: ticketsOpen)
        return sheet
    }
}
#endif
