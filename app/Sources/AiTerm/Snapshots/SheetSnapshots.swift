import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// Every step of the New Task and New Review sheets, a failed create's footer, the `NameSheet`
/// flows, and Backpack Mode's sheet in each state. The sheets need the fixture's project and tasks
/// but no controller: each is handed a model of its own, as the app hands it one.
@MainActor
enum SheetSnapshots {
    static var all: [Snapshot] {
        [
            Snapshot("step1-closed.png") { taskSheet(step: 1, draft: draft()) },
            Snapshot("step1-empty.png") { taskSheet(step: 1, draft: draft(), ticketsOpen: true) },
            Snapshot("step1-picked.png") { taskSheet(step: 1, draft: picked(), ticketsOpen: true) },
            // A project whose .worktreeinclude selects files: the checkbox above the destination line.
            Snapshot("step1-worktreeinclude.png") {
                taskSheet(step: 1, draft: picked(), worktreeIncludes: [".env", "certs/dev.pem"])
            },
            Snapshot("step2-agent.png") { taskSheet(step: 2, draft: picked()) },
            Snapshot("step3-prompt.png") {
                var draft = picked()
                draft.promptText = "/superpowers:brainstorming\nStart with the worker's shutdown path and the queue drain."
                return taskSheet(step: 3, draft: draft)
            },
            Snapshot("step3-completions.png") { completions() },
            Snapshot("review-step1.png") { reviewSheet(step: 1, mergeRequestsOpen: true) },
            Snapshot("review-step2.png") { reviewSheet(step: 2) },
            // Step 3 is reached only with a branch, which its destination line names.
            Snapshot("review-step3.png") { reviewSheet(step: 3) { $0.draft.apply(mr: mergeRequests[0]) } },
            // A branch that is already a task's: the sheet says the review opens there.
            Snapshot("review-in-task.png") {
                let working = Fixture().working
                return reviewSheet(step: 1, owner: working) {
                    $0.draft.setTitle(working.title)
                    $0.draft.setBranch(working.branch)
                }
            },
            // A review that gets a worktree of its own offers the same checkbox.
            Snapshot("review-step1-worktreeinclude.png") {
                reviewSheet(step: 1) {
                    $0.draft.apply(mr: mergeRequests[0])
                    $0.worktreeIncludes = [".env", "certs/dev.pem"]
                }
            },
            Snapshot("sheet-git-error.png") { gitError() },
            // A review's branch git refused, with the footer's fix for it.
            Snapshot("review-switch-folder.png") {
                refusedReview(WorktreeError.branchInProjectFolder("feat-gift-card", at: "/Users/sam/Sites/acme-storefront",
                                                                  switchTo: "main", hasChanges: false))
            },
            Snapshot("review-folder-changes.png") {
                refusedReview(WorktreeError.branchInProjectFolder("feat-gift-card", at: "/Users/sam/Sites/acme-storefront",
                                                                  switchTo: "main", hasChanges: true))
            },
            Snapshot("review-rebase.png") { refusedReview(WorktreeError.branchDiverged("feat-gift-card", local: 2, remote: 5)) },
            Snapshot("terminal.png") {
                NameSheet.newTerminal(project: Fixture().project, suggestedName: "shell 2", branch: "main", canCreate: true,
                                      createTerminal: { _ in })
            },
        ] + nameSheets + backpackSheets + archiveSheets + fixFooters
    }

    /// New Review's footer through a Fix, as the picked design draws it (footer states 1–5 and 7–9;
    /// 6 is the toast): offered alone and beside Rebase, looking, the proposal, applying, no fix,
    /// failed, and with Help with problems off or Claude Code missing. Drawn last, after the images before them.
    private static var fixFooters: [Snapshot] {
        let conflict = WorktreeError.rebaseConflicted("feat-gift-card", detail: nil)
        return [
            Snapshot("review-fix-offered.png") { fixFooter(.offered, error: conflict) },
            Snapshot("review-fix-offered-beside-rebase.png") {
                fixFooter(.offered, error: WorktreeError.branchDiverged("feat-gift-card", local: 2, remote: 4))
            },
            Snapshot("review-fix-looking.png") { fixFooter(.looking, error: conflict) },
            Snapshot("review-fix-proposal.png") { fixFooter(.proposal(fixProposal), error: conflict) },
            Snapshot("review-fix-applying.png") { fixFooter(.applying, error: conflict) },
            Snapshot("review-fix-nofix.png") {
                fixFooter(.noFix("Claude found no fix it can stand behind: both sides rewrite the same alert handler."), error: conflict)
            },
            Snapshot("review-fix-failed.png") {
                fixFooter(.failed("pnpm typecheck failed (status 2) after the fix, so nothing was changed."), error: conflict)
            },
            Snapshot("review-fix-unavailable.png") { fixFooter(nil, error: conflict, fixer: .off) },
        ]
    }

    /// The design's force-pushed merge request: no conflict to resolve, an older copy to replace.
    private static let fixProposal = FixProposal(
        headline: "Your 2 local commits are an older copy of what’s on origin.",
        why: "The merge request was rebased and force-pushed since you last fetched it: the same 2 changes are in origin’s 4, "
            + "rewritten. Replace your copy with origin’s, then create the review.",
        steps: ["Keep your 2 commits as aiterm/backup/feat-gift-card", "Point feat-gift-card at origin’s",
                "Create the review. Nothing is pushed."],
        moves: ["feat-gift-card"], drops: [], verify: nil)

    /// Step 3's footer after git refused the review's branch for `error`, its Fix in `state` — or in
    /// the state `fixer` starts it in, when nil — with `fixProposal` the one kept on screen while applying.
    private static func fixFooter(_ state: FixSession.State?, error: WorktreeError,
                                  fixer: FixerResolution = .ready(.claude)) -> some View {
        let failure = CreationFailure(error, projectPath: "/Users/sam/Sites/acme-storefront")
        let session = FixSession.snapshot(state, fixer: fixer, request: failure.fix!, proposal: fixProposal)
        return CreationFooter(step: 3, error: failure, availableAgents: [.claude], createLabel: "Create Review", creating: false,
                              canAdvance: true, closeList: { false }, back: {}, advance: {}, recover: {}, fix: session)
            .padding(Space.margin).frame(width: Sheet.width).background(Palette.surfaceRaised)
    }

    /// The Archive sheet with the proposal's five rows, a search that finds one by its merge request,
    /// nothing archived, and a search that finds nothing. Drawn last: an added image goes after the
    /// ones before it (`Snapshots.regressionSet`).
    private static var archiveSheets: [Snapshot] {
        [
            Snapshot("archive.png") { ArchiveSheet(model: ArchiveSnapshots.model(query: "")) },
            Snapshot("archive-search.png") { ArchiveSheet(model: ArchiveSnapshots.model(query: "482")) },
            Snapshot("archive-empty.png") { ArchiveSheet(model: ArchiveSnapshots.model(entries: [], query: "")) },
            // Not the proposal's "paymnet": the fuzzy tier finds "payment" in it.
            Snapshot("archive-no-match.png") { ArchiveSheet(model: ArchiveSnapshots.model(query: "refund")) },
        ]
    }

    static let tickets = [
        JiraTicket(key: "PAY-214", summary: "Add Apple Pay to the checkout flow", description: nil, issueType: "Story", status: "In Progress", url: "u"),
        JiraTicket(key: "SHOP-1711", summary: "Migrate the storefront to a monorepo", description: nil, issueType: "Task", status: "DEV", url: "u"),
        JiraTicket(key: "SHOP-1731", summary: "Add customer reviews to the product page", description: nil, issueType: "Story", status: "DEV", url: "u"),
        JiraTicket(key: "PAY-230", summary: "Retry failed payment webhooks with backoff", description: nil, issueType: "Task", status: "In Progress", url: "u"),
        JiraTicket(key: "SHOP-1088", summary: "Cut product page load time in half", description: nil, issueType: "Task", status: "In Progress", url: "u"),
        JiraTicket(key: "SHOP-1640", summary: "Fix the storefront's Lighthouse accessibility score", description: nil, issueType: "Bug", status: "To Do", url: "u"),
    ]

    static let mergeRequests = [
        MergeRequest(iid: 4, title: "Add a gift-card field to checkout", sourceBranch: "feat-gift-card",
                     targetBranch: "main", author: "Sam Rivera", state: "opened", draft: false,
                     url: "https://git.example.net/acme/storefront/-/merge_requests/4"),
        MergeRequest(iid: 7, title: "Drop the unused CDN origin", sourceBranch: "chore-drop-cdn-origin",
                     targetBranch: "main", author: "Alex Kim", state: "opened", draft: true,
                     url: "https://git.example.net/acme/storefront/-/merge_requests/7"),
    ]

    /// A new task's draft on Claude Code and the first model of the bare home's catalogue. Built
    /// rather than `TaskDraft.initial`, which asks git for the base branch of whatever directory
    /// the renderer runs in.
    private static func draft() -> TaskDraft {
        let preference = TaskDraft.preference(for: .claude, state: .empty, catalog: Fixture.catalogue(.claude),
                                              defaults: Fixture.defaults)
        return TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: preference.model, reasoning: preference.reasoning)
    }

    /// The draft with a ticket picked, which names the task and its branch.
    private static func picked() -> TaskDraft {
        var draft = draft()
        draft.apply(ticket: tickets[3])
        return draft
    }

    /// New Task on `step`, its ticket search answered with `tickets`, and `worktreeIncludes` as if
    /// the project's `.worktreeinclude` had selected them.
    private static func taskSheet(step: Int, draft: TaskDraft, ticketsOpen: Bool = false,
                                  worktreeIncludes: [String] = []) -> NewTaskSheet {
        let model = taskModel(draft)
        model.worktreeIncludes = worktreeIncludes
        return NewTaskSheet(model: model).seeded(step: step, ticketsOpen: ticketsOpen)
    }

    private static func taskModel(_ draft: TaskDraft) -> TaskCreationModel {
        let model = TaskCreationModel(project: Fixture().project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue,
                                      defaults: Fixture.defaults, git: Fixture.git, searchIssues: { _ in tickets }, createTask: { _ in })
        model.results = tickets
        return model
    }

    /// The completion popup open on the prompt's third line, where it hangs past the field and over
    /// the hint, the checkbox and the command preview below it.
    private static func completions() -> some View {
        var draft = picked()
        draft.promptText = "Start with the worker's shutdown path.\nThen the queue drain.\n/s"
        let model = taskModel(draft)
        let skills = [
            AgentCompletion(name: "superpowers:brainstorming", kind: .skill, detail: "You MUST use this before any creative work", source: .plugin("superpowers")),
            AgentCompletion(name: "superpowers:finishing-a-development-branch", kind: .skill, detail: "Use when implementation is complete", source: .plugin("superpowers")),
            AgentCompletion(name: "pdf", kind: .skill, detail: "Use this skill whenever the user wants to do anything with PDF files", source: .user),
            AgentCompletion(name: "review", kind: .command, detail: "Review a pull request", source: .builtIn),
            AgentCompletion(name: "simplify", kind: .skill, detail: "Review the changed code for reuse", source: .user),
            AgentCompletion(name: "loop", kind: .skill, detail: "Run a prompt on a recurring interval", source: .user),
            AgentCompletion(name: "security-review", kind: .skill, detail: "Review the pending changes", source: .user),
            AgentCompletion(name: "statusline", kind: .command, detail: "Set up the status line", source: .builtIn),
        ]
        let completions = model.completions
        func open() {
            completions.visible = skills
            completions.anchor = CGPoint(x: Space.snug, y: 64)
            completions.fieldWidth = Sheet.width - 2 * Space.margin
        }
        return CompletingSheet(model: model, open: open)
    }

    /// New Task on its prompt step with the popup opened as the sheet appears, after the editor is
    /// made — setting its text moves the caret, which closes the popup — and that is what
    /// `ImageRenderer` draws. Hosted, opened again once the sheet's catalogue load, which runs on
    /// appear and closes the popup, has landed: a view of its own, so its body reads the flag.
    private struct CompletingSheet: View {
        let model: TaskCreationModel
        let open: () -> Void

        var body: some View {
            NewTaskSheet(model: model).seeded(step: 3)
                .onAppear(perform: open)
                .onChange(of: model.catalogueLoaded) { _, loaded in if loaded { open() } }
        }
    }

    /// New Review on `step`, its merge request search answered with `mergeRequests`, and `prepare`
    /// run on its model first. `owner` is the task that already has the review's branch, if any.
    private static func reviewSheet(step: Int, mergeRequestsOpen: Bool = false, owner: TaskItem? = nil,
                                    prepare: (ReviewCreationModel) -> Void = { _ in }) -> NewReviewSheet {
        let task = draft()
        let model = ReviewCreationModel(project: Fixture().project, draft: ReviewDraft(mr: nil, agent: .claude, model: task.model, reasoning: task.reasoning),
                                        home: Fixture.home, catalogue: Fixture.catalogue, defaults: Fixture.defaults,
                                        git: Fixture.git, owningTask: { branch, _ in branch == owner?.branch ? owner : nil },
                                        searchMergeRequests: { _ in mergeRequests }, createReview: { _ in }, recover: { _ in })
        model.results = mergeRequests
        prepare(model)
        return NewReviewSheet(model: model).seeded(step: step, mergeRequestsOpen: mergeRequestsOpen)
    }

    /// What the footer makes of a refused `worktree add`: the `fatal:` line as a sentence
    /// (`GitError.sentence`), not the command and git's "Preparing worktree" narration that used to
    /// fill the three lines — those are the tooltip. At a path of its own, so the image is the
    /// same from any checkout.
    private static func gitError() -> some View {
        let path = "/Users/sam/Sites/acme-storefront"
        let fatal = "fatal: 'feat/pay-214-apple-pay' is already used by worktree at '\(path)/.worktrees/pay-214-apple-pay'"
        let refused = CreationFailure(GitError(args: ["worktree", "add", "\(path)/.worktrees/review-pay-214-apple-pay", "feat/pay-214-apple-pay"],
                                               code: 128, stderr: "Preparing worktree (checking out 'feat/pay-214-apple-pay')\n" + fatal),
                                      projectPath: path)
        return footer(refused)
    }

    /// New Review's footer after git refused the review's branch for `error`.
    private static func refusedReview(_ error: WorktreeError) -> some View {
        footer(CreationFailure(error, projectPath: "/Users/sam/Sites/acme-storefront"))
    }

    /// Step 3's footer showing `failure`, as wide as a sheet.
    private static func footer(_ failure: CreationFailure) -> some View {
        CreationFooter(step: 3, error: failure, availableAgents: [.claude], createLabel: "Create Review", creating: false,
                       canAdvance: true, closeList: { false }, back: {}, advance: {}, recover: {})
            .padding(Space.margin).frame(width: Sheet.width).background(Palette.surfaceRaised)
    }

    /// The other `NameSheet` flows, built as `SidebarSheet` builds them: Add divider, and the
    /// renames of a divider, a task and a terminal, each with its band's sentence.
    private static var nameSheets: [Snapshot] {
        [
            Snapshot("name-new-divider.png") { NameSheet.newDivider(canSubmit: true, submit: { _ in }) },
            Snapshot("name-rename-divider.png") {
                NameSheet.rename(.divider(SidebarDivider(id: UUID(), name: "Clients")), canSubmit: true, submit: { _ in })
            },
            Snapshot("name-rename-task.png") {
                NameSheet.rename(.task(Fixture().working), canSubmit: true, submit: { _ in })
            },
            Snapshot("name-rename-terminal.png") {
                let terminal = TerminalItem(id: UUID(), projectId: Fixture().project.id, name: "shell", windowId: "w",
                                            createdAt: Snapshots.clock.now)
                return NameSheet.rename(.terminal(terminal), canSubmit: true, submit: { _ in })
            },
        ]
    }

    /// Backpack Mode's sheet in each of its states, on an inert controller set to draw it: its
    /// `.task` — the load, the scans and the lid — does not run in an offscreen render.
    private static var backpackSheets: [Snapshot] {
        let ready = BackpackSetup(sleepRule: true, location: true, network: hotspot)
        let safe = BackpackState.on(BackpackStatus(network: hotspot, joined: true, power: PowerReading(level: 64, onBattery: true)))
        return [
            backpackSheet("hotspot", setup: ready, chosen: hotspot),
            backpackSheet("looking", setup: ready, chosen: nil),
            backpackSheet("allow", setup: BackpackSetup(sleepRule: false, location: false, network: hotspot), chosen: hotspot),
            backpackSheet("connecting", setup: ready, chosen: hotspot, started: true, phase: .keepingAwake, busy: true),
            backpackSheet("not-found", setup: ready, chosen: hotspot, started: true, phase: .notInRange, busy: true),
            backpackSheet("failed", setup: ready, chosen: hotspot, started: true, phase: .failed(.joinFailed(network: hotspot))),
            backpackSheet("safe", setup: ready, chosen: hotspot, started: true, phase: .safe, state: safe),
            // The next trip after a push that did not go out: Notifies says why, in the warning tone.
            backpackSheet("push-failed", setup: ready, chosen: hotspot,
                          pushFailure: "No paired companion device is registered for notifications."),
        ]
    }

    private static let hotspot = "Laurens’s iPhone"

    /// `backpack-sheet-<name>.png`: the hotspot chosen as a scan would choose it, and Connect pressed
    /// when `started`.
    private static func backpackSheet(_ name: String, setup: BackpackSetup, chosen: String?, started: Bool = false,
                                      phase: ConnectPhase? = nil, busy: Bool = false, state: BackpackState = .off,
                                      pushFailure: String? = nil) -> Snapshot {
        Snapshot("backpack-sheet-\(name).png") {
            let backpack = BackpackController.inert()
            backpack.network = hotspot
            backpack.preview(state: state, setup: setup, phase: phase, busy: busy, pushFailure: pushFailure)
            let model = BackpackSheetModel(backpack: backpack)
            model.choose(chosen)
            if started { model.previewStarted() }
            return BackpackSheet(model: model)
        }
    }
}

/// The Archive sheet's rows for the snapshots: the proposal's five, at fixed dates against a fixed now.
@MainActor enum ArchiveSnapshots {
    static let now = Date(timeIntervalSince1970: 1_791_800_000)

    static func model(entries: [ArchiveSearch.Entry]? = nil, query: String) -> ArchiveSheetModel {
        let shown = entries ?? rows
        let model = ArchiveSheetModel(entries: { shown }, restore: { _ in }, remove: { _ in })
        model.query = query
        model.now = { now }
        return model
    }

    static var rows: [ArchiveSearch.Entry] {
        func row(_ title: String, _ agent: AgentKind, jira: String? = nil, mr: Int? = nil, branch: String, project: String,
                 ago: TimeInterval) -> ArchiveSearch.Entry {
            let task = TaskItem(id: UUID(), projectId: UUID(), title: title, branch: branch, worktreePath: "/w", baseBranch: "main",
                                jira: jira.map { JiraRef(key: $0, summary: title, url: "") }, kind: mr == nil ? .task : .review,
                                mr: mr.map { MergeRequestRef(iid: $0, title: title, url: "") }, agent: agent, model: "m", reasoning: nil,
                                firstPrompt: nil, appendTicket: false, createdAt: now, windowId: nil)
            return .init(archived: ArchivedTask(task: task, archivedAt: now.addingTimeInterval(-ago)), projectName: project, provider: .gitlab)
        }
        return [row("Login flow", .claude, jira: "SHOP-123", branch: "feat/SHOP-123-login", project: "acme-storefront", ago: 7_200),
                row("Header refactor", .claude, mr: 482, branch: "feat/header-refactor", project: "acme-storefront", ago: 86_400),
                row("Checkout payment retry", .codex, jira: "SHOP-118", branch: "fix/SHOP-118-payment-retry", project: "acme-storefront",
                    ago: 259_200),
                row("Daemon backoff", .claude, branch: "feat/daemon-backoff", project: "aiterm", ago: 777_600),
                row("Jira project picker", .codex, jira: "AIT-41", mr: 37, branch: "feat/jira-projects", project: "aiterm", ago: 1_296_000)]
    }
}
#endif
