import SwiftUI
import AiTermUI
import AiTermCore

/// New Review's three steps: Review, Prompt, Agent. The first holds where the review comes from and
/// what it checks out — the merge request, the ticket, the name and the branch — on one page, as New
/// Task's does.
struct NewReviewSheet: View {
    @Bindable var model: ReviewCreationModel
    @State private var step = 1
    @State private var mrOpen = false
    @State private var branchOpen = false
    @State private var ticketsOpen = false
    init(model: ReviewCreationModel) { self.model = model }
    var body: some View {
        SteppedSheet(title: "New review in \(model.project.name)", height: Sheet.creationHeight, steps: steps, step: $step,
                     createLabel: Self.createLabel(owner: model.owningTask), creating: model.creating, create: model.create) {
            content
        } notices: {
            CreationNotices(error: model.error, availableAgents: step == ReviewCreation.lastStep ? model.availableAgents : nil,
                            creating: model.creating, recoverAndCreate: model.recoverAndCreate)
        } closing: {
            CreationSummary(model: model, destination: Self.destination(step: step, project: model.project, owner: model.owningTask,
                                                                        slug: model.worktreeSlug, branch: model.draft.branch))
        }
        .creationLoads(model)
        .task { await model.loadCheckouts() }
        .task { await model.searchTickets(text: "") }
        .onChange(of: model.requestListOffers) { mrOpen = true }
    }
    /// The Review step's lists close merge requests first, then tickets, then branches; the Prompt
    /// step's list is the completion popup.
    private var steps: [Step] {
        let canChange = model.canChangeWorkspace()
        let completions = model.completions
        return [
            Step(name: "Review", canAdvance: canChange && Self.canAdvance(step: 1, model: model), closeList: {
                if mrOpen { mrOpen = false; return true }
                if ticketsOpen { ticketsOpen = false; return true }
                if branchOpen { branchOpen = false; return true }
                return false
            }),
            Step(name: "Prompt", canAdvance: canChange && Self.canAdvance(step: 2, model: model), closeList: {
                guard completions.isOpen else { return false }
                completions.close(); return true
            }),
            Step(name: "Agent", canAdvance: canChange && Self.canAdvance(step: 3, model: model)),
        ]
    }
    @ViewBuilder private var content: some View {
        switch step {
        case 1: NewReviewFirstStep(model: model, mrOpen: $mrOpen, branchOpen: $branchOpen, ticketsOpen: $ticketsOpen)
        case 2:
            PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
                if model.draft.mr?.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    DescriptionToggle("Add the merge request’s description", isOn: $model.draft.appendRequest,
                                      help: "It goes to the agent under your prompt.")
                }
                if model.draft.ticket?.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    DescriptionToggle("Add the ticket’s description", isOn: $model.draft.appendTicket,
                                      help: "When it has one, under the merge request’s.")
                }
            }
        default: AgentStep(model: model)
        }
    }
    /// Every step needs a name and a branch, which the first step asks for: a review derives neither.
    static func canAdvance(step: Int, title: String, branch: String, creating: Bool) -> Bool {
        !creating && TaskCreator.isNamed(title) && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func canAdvance(step: Int, model: ReviewCreationModel) -> Bool {
        canAdvance(step: step, title: model.draft.title, branch: model.draft.branch, creating: model.creating)
            && (step != ReviewCreation.lastStep || model.agentIsReady)
    }
    static func destination(step: Int, project: Project, owner: TaskItem?, slug: @autoclosure () -> String, branch: String) -> Destination? {
        guard step == ReviewCreation.lastStep, !branch.isEmpty else { return nil }
        if let owner { return .existing(owner) }
        return .worktree(project: project, slug: slug(), branch: branch)
    }
    static func createLabel(owner: TaskItem?) -> String { owner.map { "Open in \($0.kindName)" } ?? "Create Review" }
    static func worktreeIncludes(_ files: [String], owner: TaskItem?) -> [String] { owner == nil ? files : [] }
}

#if DEBUG
extension NewReviewSheet {
    func seeded(step: Int, mergeRequestsOpen: Bool = false, branchesOpen: Bool = false, ticketsOpen: Bool = false) -> Self {
        var sheet = self; sheet._step = State(initialValue: step); sheet._mrOpen = State(initialValue: mergeRequestsOpen)
        sheet._branchOpen = State(initialValue: branchesOpen); sheet._ticketsOpen = State(initialValue: ticketsOpen); return sheet
    }
}
#endif

/// The Review step: the merge request and the ticket, which fill each other and the name and
/// branch, then the name, the branch to check out, and the worktree's copied files.
struct NewReviewFirstStep: View {
    @Bindable var model: ReviewCreationModel
    @Binding var mrOpen: Bool
    @Binding var branchOpen: Bool
    @Binding var ticketsOpen: Bool
    var body: some View {
        FrontToBackStack(spacing: Space.block) {
            FormField(model.codeHost.reviewField) {
                ChipsPicker(placeholder: model.codeHost.reviewPlaceholder, picks: model.draft.mr.map { [$0] } ?? [], open: $mrOpen,
                            matches: { _ in model.results }, mark: { .brand($0.host.brand) }, label: { $0.reference + " · " + $0.title },
                            row: { PickerResultRow(mark: .brand($0.host.brand), key: $0.reference, keyWidth: Size.pickerRequestKey, title: $0.title, detail: $0.lane) },
                            onPick: { model.pick($0) }, onRemove: { _ in model.clearPick(); model.reopenSearch(); mrOpen = true },
                            query: Binding(get: { model.query }, set: { model.setQuery($0) }), selectionLimit: 1)
                if let error = model.pickRefusal ?? model.searchError { HelpText(error, tone: .warning) }
                else if let note = model.ticketLookupNote { HelpText(note) }
                else if model.draft.mr == nil { HelpText("It fills in the name and branch.") }
            }
            FormField("Ticket (optional)") {
                TicketPickerField(placeholder: model.ticketPlaceholder,
                                  query: Binding(get: { model.ticketQuery }, set: { model.setTicketQuery($0) }),
                                  open: $ticketsOpen, items: model.ticketResults, selection: model.draft.ticket,
                                  onPick: { model.pickTicket($0) },
                                  onClear: { model.clearTicket(); model.reopenTicketSearch(); ticketsOpen = true })
                if let error = model.ticketSearchError { HelpText(error, tone: .warning) }
                else if model.draft.ticket == nil { HelpText("A ticket finds its merge request.") }
            }
            FormField("Name") {
                Input(placeholder: "Describe the review", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }
            FormField("Branch") {
                BranchInput(text: Binding(get: { model.draft.branch }, set: { model.draft.setBranch($0); model.branchQuery = $0 }),
                            open: $branchOpen, choices: model.branchMatches)
                if model.branchesLoaded && !model.draft.branch.isEmpty && !model.branches.contains(model.draft.branch) {
                    HelpText("That branch doesn’t exist in this repository.", tone: .warning)
                } else { HelpText("An existing branch. AiTerm checks it out for the review.") }
            }
            let includes = NewReviewSheet.worktreeIncludes(model.worktreeIncludes, owner: model.owningTask)
            if !includes.isEmpty { WorktreeIncludeToggle(files: includes, isOn: $model.draft.copiesWorktreeInclude) }
        }
    }
}
