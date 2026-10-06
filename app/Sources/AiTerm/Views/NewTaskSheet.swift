import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

struct NewTaskSheet: View {
    @Bindable var model: TaskCreationModel
    var _step = State(initialValue: 1)
    private var step: Int { get { _step.wrappedValue } nonmutating set { _step.wrappedValue = newValue } }
    var _ticketsOpen = State(initialValue: false)
    private var ticketsOpen: Bool { get { _ticketsOpen.wrappedValue } nonmutating set { _ticketsOpen.wrappedValue = newValue } }
    /// A result row's key column: a Jira key of up to eight characters in the mono code face, so
    /// the summaries after it start on one line.
    private static let ticketKeyWidth: CGFloat = 74
    /// The branch-type popup's column: its longest type, `chore`, in monospace plus the popup's
    /// chevron and bezel — no wider, since every point it takes comes out of the branch name
    /// beside it.
    private static let branchTypeWidth: CGFloat = 96
    /// The base-branch popup's column: room for `main`, `develop` or a short release branch in
    /// monospace, the rest of the row left to the new branch's name.
    private static let baseBranchWidth: CGFloat = 190

    init(model: TaskCreationModel, previewStep: Int = 1, previewTickets: [JiraTicket]? = nil,
         previewTicketsOpen: Bool = true) {
        self.model = model
        if let previewTickets {
            model.results = previewTickets
            _step = State(initialValue: previewStep)
            _ticketsOpen = State(initialValue: previewTicketsOpen)
        }
    }

    var body: some View {
        CreationSheet(model: model, step: _step.projectedValue, title: "New task in \(model.project.name)",
                      stepNames: ["Task", "Agent", "Prompt"], destination: destination, createLabel: "Create Task",
                      canAdvance: canAdvance, pickers: [_ticketsOpen.projectedValue]) {
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: ticketStep
        case 2: AgentStep(model: model)
        default: PromptStep(text: $model.promptText, agent: model.draft.agent, completions: model.completions) {
            if model.draft.ticket != nil {
                Toggle("Include Jira ticket details", isOn: $model.draft.appendTicket)
                    .toggleStyle(.checkbox).font(Typography.body)
            }
        }
        }
    }

    // -- step 1: ticket -------------------------------------------------------------

    private var ticketStep: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("Jira ticket (optional)") {
                SearchPicker(placeholder: model.ticketPlaceholder,
                             query: Binding(get: { model.query }, set: { model.query = $0; model.scheduleSearch(text: $0) }),
                             open: Binding(get: { ticketsOpen }, set: { ticketsOpen = $0 }),
                             items: model.results, selection: model.draft.ticket,
                             row: { ticket, isSelected in
                                 // The lane column stays for a ticket without one, so every summary
                                 // is cut at the same place.
                                 PickerResultRow(mark: .brand(Palette.jira), key: ticket.key, keyWidth: Self.ticketKeyWidth,
                                                 title: ticket.summary, detail: ticket.status ?? "", selected: isSelected)
                             },
                             selected: { selectedTicket($0) },
                             onPick: { ticket in
                                 model.cancelSearch()
                                 model.draft.apply(ticket: ticket)
                             },
                             toggleHelp: { $0 ? "Hide tickets" : "Show my open tickets" })
                    // The picker's results hang under the field instead of pushing the rest of the
                    // sheet down — the whole point of a dropdown. The zIndex is what puts them over
                    // the help line below, which is a later sibling in this same stack.
                    .zIndex(3)
                if model.draft.ticket == nil {
                    if let message = model.searchError {
                        HelpText(message, tone: .warning)
                    } else {
                        HelpText("Select a ticket to fill in the name, type and branch.")
                    }
                }
            }
            .zIndex(2)

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
        }
    }

    /// The popup always offers the branch the model.draft is on, even if git has not heard of it yet —
    /// an `NSPopUpButton` whose selection is not in its menu shows nothing at all.
    private var baseBranchChoices: [String] {
        model.branches.contains(model.draft.baseBranch) || model.draft.baseBranch.isEmpty ? model.branches : [model.draft.baseBranch] + model.branches
    }

    private func selectedTicket(_ ticket: JiraTicket) -> some View {
        PickedItemField(mark: .brand(Palette.jira), key: ticket.key, title: ticket.summary, trailing: {
            if let status = ticket.status { LaneChip(lane: status, brand: Palette.jira, ink: Palette.link) }
        }, clearHelp: "Clear ticket") {
            model.draft.apply(ticket: nil); model.query = ""; ticketsOpen = true; model.scheduleSearch(text: "")
        }
    }

    // -- what the scaffold is handed ------------------------------------------------

    var canAdvance: Bool {
        guard !model.creating, TaskCreator.isNamed(model.draft.title) else { return false }
        return step == 1 || canCreate
    }

    /// Where the task opens: its new worktree, on steps 1 and 3 only — finding the unused slug
    /// looks at the disk. Nothing until the task has a name to make a worktree of.
    private var destination: Destination? {
        guard Destination.isShown(onStep: step) else { return nil }
        let slug = model.worktreeSlug
        guard !slug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: slug, branch: model.draft.branchName.isEmpty ? "" : model.draft.branch)
    }

    /// Creating a task needs a title and an agent that exists; with neither CLI installed the button
    /// is dead and the footer says why.
    var canCreate: Bool {
        !model.creating && TaskCreator.isNamed(model.draft.title)
            && model.availableAgents.contains(model.draft.agent) && model.selectedModelIsCurrent
    }
}
