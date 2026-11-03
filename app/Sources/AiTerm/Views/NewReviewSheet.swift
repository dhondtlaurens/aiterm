import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// New Review's three steps: Branch, Agent, Prompt. A review checks out a branch that already
/// exists — optionally the source branch of a merge request — instead of creating one, so step 1
/// picks rather than derives, and there is no base branch to choose. Its merge request and its
/// ticket fill each other: picking one looks the other up, and the field it filled says so.
struct NewReviewSheet: View {
    @Bindable var model: ReviewCreationModel
    private var _step = State(initialValue: 1)
    private var step: Int { get { _step.wrappedValue } nonmutating set { _step.wrappedValue = newValue } }
    private var _mrOpen = State(initialValue: false)
    private var mrOpen: Bool { get { _mrOpen.wrappedValue } nonmutating set { _mrOpen.wrappedValue = newValue } }
    private var _branchOpen = State(initialValue: false)
    private var branchOpen: Bool { get { _branchOpen.wrappedValue } nonmutating set { _branchOpen.wrappedValue = newValue } }
    private var _ticketsOpen = State(initialValue: false)
    private var ticketsOpen: Bool { get { _ticketsOpen.wrappedValue } nonmutating set { _ticketsOpen.wrappedValue = newValue } }
    /// As New Task's ticket key column.
    private static let ticketKeyWidth: CGFloat = 74

    /// A result row's `!iid` column: a four-digit merge request number in the mono code face, so
    /// the titles after it start on one line.
    private static let mrNumberWidth: CGFloat = 44

    init(model: ReviewCreationModel) { self.model = model }

    /// ⎋ closes the merge request list first, then the ticket list, then the branch list, and only
    /// then steps back.
    var body: some View {
        CreationSheet(model: model, step: _step.projectedValue, title: "New review in \(model.project.name)",
                      stepNames: ["Branch", "Agent", "Prompt"],
                      destination: Self.destination(step: step, project: model.project, owner: model.owningTask,
                                                    slug: model.worktreeSlug, branch: model.draft.branch),
                      createLabel: Self.createLabel(owner: model.owningTask), canAdvance: Self.canAdvance(step: step, model: model),
                      pickers: [_mrOpen.projectedValue, _ticketsOpen.projectedValue, _branchOpen.projectedValue]) {
            content
        }
        .task { await model.loadCheckouts() }
        .task { await model.searchTickets(text: "") }
        // The ticket's lookup found several requests: the list opens on them.
        .onChange(of: model.requestListOffers) { mrOpen = true }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: branchStep
        case 2: AgentStep(model: model)
        default: PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
            if model.draft.ticket != nil {
                Toggle("Include ticket details", isOn: $model.draft.appendTicket)
                    .toggleStyle(.checkbox).font(Typography.body)
            }
        }
        }
    }

    // -- step 1: branch -------------------------------------------------------------

    private var branchStep: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField(model.codeHost.reviewField) {
                SearchPicker(placeholder: model.codeHost.reviewPlaceholder,
                             query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                             open: _mrOpen.projectedValue,
                             items: model.results, selection: model.draft.mr,
                             row: mrRow, selected: selectedMR,
                             onPick: { mr in model.pick(mr) },
                             toggleHelp: { $0 ? "Hide \(model.codeHost.reviewNoun)s" : "Show open \(model.codeHost.reviewNoun)s" })
                if let message = model.pickRefusal ?? model.searchError {
                    HelpText(message, tone: .warning)
                } else if let key = model.draft.mrFoundFrom {
                    HelpText("Found from \(key).")
                } else if let note = model.ticketLookupNote {
                    HelpText(note)
                } else if model.draft.mr == nil {
                    // As New Task guards its ticket help line: an instruction to pick one reads
                    // wrong sitting under one already picked.
                    HelpText(model.codeHost.reviewHint)
                }
            }

            FormField("Ticket (optional)") {
                SearchPicker(placeholder: model.ticketPlaceholder,
                             query: Binding(get: { model.ticketQuery }, set: { model.setTicketQuery($0) }),
                             open: _ticketsOpen.projectedValue,
                             items: model.ticketResults, selection: model.draft.ticket,
                             row: { ticket in
                                 PickerResultRow(mark: .brand(ticket.brand), key: ticket.key, keyWidth: Self.ticketKeyWidth,
                                                 title: ticket.summary, detail: ticket.status ?? "")
                             },
                             selected: selectedTicket,
                             onPick: { model.pickTicket($0) },
                             toggleHelp: { $0 ? "Hide tickets" : "Show open tickets" })
                if let reference = model.draft.ticketFoundFrom {
                    HelpText("Found from \(reference).")
                } else if model.draft.ticket == nil {
                    if let message = model.ticketSearchError {
                        HelpText(message, tone: .warning)
                    } else {
                        HelpText("Select a ticket to find its \(model.codeHost.reviewNoun).")
                    }
                }
            }

            FormField("Review name") {
                Input(placeholder: "Describe the review", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }

            FormField("Branch") {
                SearchPicker(placeholder: "Search branches",
                             query: $model.branchQuery,
                             open: _branchOpen.projectedValue,
                             items: model.branchMatches.map(BranchChoice.init),
                             selection: model.draft.branch.isEmpty ? nil : BranchChoice(model.draft.branch),
                             row: { BranchResultRow(name: $0.name) },
                             selected: selectedBranch,
                             onPick: { choice in model.draft.setBranch(choice.name) },
                             toggleHelp: { $0 ? "Hide branches" : "Show all branches" })
            }

            // As New Task's: the step's last field, above the destination line — and only when
            // the review gets a worktree of its own.
            let includes = Self.worktreeIncludes(model.worktreeIncludes, owner: model.owningTask)
            if !includes.isEmpty {
                WorktreeIncludeToggle(files: includes, isOn: $model.draft.copiesWorktreeInclude)
            }
        }
    }

    /// `SearchPicker` keys on `Identifiable`; a branch is a bare `String`, so it travels wrapped.
    private struct BranchChoice: Identifiable, Equatable {
        let name: String
        var id: String { name }
        init(_ name: String) { self.name = name }
    }

    /// A branch in the results, in the ink of the ground its row declares — white while highlighted.
    private struct BranchResultRow: View {
        let name: String
        @Environment(\.surface) private var surface

        var body: some View {
            Text(name).font(Typography.monoCode).foregroundStyle(surface.ink).lineLimit(1)
        }
    }

    private func mrRow(_ mr: MergeRequest) -> some View {
        PickerResultRow(mark: .brand(mr.host.brand), key: mr.reference, keyWidth: Self.mrNumberWidth,
                        title: mr.title, detail: mr.lane)
    }

    private func selectedMR(_ mr: MergeRequest) -> some View {
        PickedItemField(mark: .brand(mr.host.brand), key: mr.reference, title: mr.title, trailing: {
            LaneChip(lane: mr.lane, brand: mr.host.brand, ink: mr.host.brand.color)
        }, clearHelp: "Clear \(model.codeHost.reviewNoun)") {
            model.clearPick(); model.reopenSearch(); mrOpen = true
        }
    }

    private func selectedTicket(_ ticket: JiraTicket) -> some View {
        PickedItemField(mark: .brand(ticket.brand), key: ticket.key, title: ticket.summary, trailing: {
            if let status = ticket.status { LaneChip(lane: status, brand: ticket.brand, ink: ticket.laneInk) }
        }, clearHelp: "Clear ticket") {
            model.clearTicket(); model.reopenTicketSearch(); ticketsOpen = true
        }
    }

    private func selectedBranch(_ choice: BranchChoice) -> some View {
        PickedItemField(title: choice.name, monospaced: true, clearHelp: "Change branch") {
            model.draft.setBranch(""); model.branchQuery = ""; branchOpen = true
        }
    }

    // -- what the scaffold is handed ------------------------------------------------

    /// Step 1 needs both a name and a branch. A review derives neither — there is nothing to fall
    /// back on if the branch is blank, unlike a task whose branch follows its title.
    static func canAdvance(step: Int, title: String, branch: String, creating: Bool) -> Bool {
        guard !creating else { return false }
        let named = TaskCreator.isNamed(title)
        guard step == 1 else { return named }
        return named && !branch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rule above, and past step 1 an agent that can run.
    static func canAdvance(step: Int, model: ReviewCreationModel) -> Bool {
        guard canAdvance(step: step, title: model.draft.title, branch: model.draft.branch, creating: model.creating) else { return false }
        return step == 1 || model.agentIsReady
    }

    // A branch that is already a task's opens in that task (see `TaskLauncher.createReview`), and
    // each of these says so before anything is created — never a surprise after.

    /// Where the review opens, on steps 1 and 3, once it has a branch: the task that already has it,
    /// or a new worktree. `slug` is read only when the new worktree is named — finding the unused
    /// slug looks at the disk.
    static func destination(step: Int, project: Project, owner: TaskItem?, slug: @autoclosure () -> String,
                            branch: String) -> Destination? {
        guard ReviewCreation.steps.showsDestination(onStep: step), !branch.isEmpty else { return nil }
        if let owner { return .existing(owner) }
        return .worktree(project: project, slug: slug(), branch: branch)
    }

    static func createLabel(owner: TaskItem?) -> String { owner.map { "Open in \($0.kindName)" } ?? "Create Review" }

    /// What step 1's checkbox offers: the project's `.worktreeinclude` files, or none when the
    /// review opens in `owner`, the task that already has its branch — no worktree is made there.
    static func worktreeIncludes(_ files: [String], owner: TaskItem?) -> [String] { owner == nil ? files : [] }
}

#if DEBUG
extension NewReviewSheet {
    /// The sheet already on `step`, with its lists open or not: what only clicks reach in the app,
    /// for the snapshots and the tests that host the sheet.
    func seeded(step: Int, mergeRequestsOpen: Bool = false, branchesOpen: Bool = false, ticketsOpen: Bool = false) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        sheet._mrOpen = State(initialValue: mergeRequestsOpen)
        sheet._branchOpen = State(initialValue: branchesOpen)
        sheet._ticketsOpen = State(initialValue: ticketsOpen)
        return sheet
    }
}
#endif
