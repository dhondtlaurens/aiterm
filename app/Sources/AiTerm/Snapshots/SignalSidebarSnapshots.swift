#if DEBUG
import SwiftUI
import AiTermCore
import AiTermUI

@MainActor enum SignalSidebarSnapshots {
    static var all: [Snapshot] {
        ["sidebar", "acting", "watching", "questions", "paused", "idle-paused", "folded", "taken-over", "fresh", "choosing", "blocked", "issue", "idle", "done", "window-closed", "section-folded",
         "worker-done", "described", "merging", "waiting-folded", "finished-folded", "all-finished-folded", "finished-signal-folded",
         "by-project", "by-project-divider", "by-project-folded", "removed-signal"].map { state in
            Snapshot("signals-" + state + ".png", hostedOnly: true) { make(state) }
        } + [Snapshot("signals-waiting-marks.png", hostedOnly: true) { waitingMarks() },
             Snapshot("signals-heading-icon.png") { headingIcon() }]
    }
    /// A failing source and a skipped item, step 9's: both headings' icons amber, the signals sheet saying each reason with
    /// its retry time, and the banner a source raises at its third failure in a row. Drawn after the rest.
    static var errors: [Snapshot] {
        [Snapshot("signals-heading-issue.png") { headingIssue() },
         Snapshot("signals-sheet-issues.png") { SignalsSheet(model: SheetSnapshots.signalIssuesModel()) },
         Snapshot("issue-signal-read.png") { readIssueBanner() }]
    }
    /// Amber icons: OPERATOR, open and folded (a task it runs gives it something to fold), with a source failing, over
    /// PROJECTS with a skipped item; then a plain PROJECTS heading for comparison. The fixture's workspace is never loaded, so a heading's controls draw disabled;
    /// the last line is the icon alone, enabled, amber and plain, in the inks the app draws. At the standard and the
    /// extra-large size.
    private static func headingIssue() -> some View {
        func controller(open: Bool) -> AppController {
            let fixture = Fixture(), controller = fixture.controller()
            let agents = [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")]
            let planned = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
                                 start: SignalTrigger(source: .jira, query: "labels = operator"),
                                 done: SignalTrigger(source: .gitLab, query: "reviewer:any"), work: SignalWork(prompt: "/psg:plan"),
                                 agents: agents, finish: SignalFinish(then: .keep))
            let reviews = Signal(name: "Reviews for me", createdAt: Snapshots.clock.now,
                                 start: SignalTrigger(source: .gitLab, query: "reviewer:@me"),
                                 done: SignalTrigger(source: .gitLab, query: "reviewer:@me review-state:approved"),
                                 work: SignalWork(prompt: "/psg:peer-review"), agents: agents, finish: SignalFinish(then: .archive), kind: .project)
            var issues = SignalReadIssues()
            issues.fail(planned.id, "The server answered 401 Unauthorized.", at: Snapshots.clock.now)
            controller.rows.readIssues = { issues }
            controller.workspace.mutate { state in
                state.signals = [planned, reviews]
                state.signalSeen = [SignalSeen(signal: reviews.id, item: .mergeRequest(SignalRequestRef(remote: "gitlab.example.com/shop/web", number: 12)),
                                               disposition: .skipped, at: Snapshots.clock.now, reason: "Several projects match: shop, web")]
                state.operatorOpen = open
                hold(fixture.working.id, by: planned, in: &state)
            }
            return controller
        }
        let open = controller(open: true), folded = controller(open: false), plain = Fixture().controller()
        plain.workspace.mutate { state in
            state.signals = [Signal(name: "Weekly dependency update", createdAt: Snapshots.clock.now,
                                    start: SignalTrigger(source: .gitLab, query: "reviewer:@me"),
                                    done: SignalTrigger(source: .person, query: ""), work: SignalWork(prompt: "Update."),
                                    agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
                                    finish: SignalFinish(then: .keep), kind: .project)]
        }
        return VStack(alignment: .leading, spacing: Space.base) {
            ForEach([InterfaceScale.standard, .extraLarge], id: \.factor) { scale in
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(controller: open, kind: .operator)
                    SectionHeading(controller: folded, kind: .operator)
                    SectionHeading(controller: folded, kind: .projects)
                    SectionHeading(controller: plain, kind: .projects)
                    HStack(spacing: scale(Space.gap)) {
                        SectionSignalsButton(section: .projects, count: 2, issue: "“Reviews for me” can’t read GitLab.", enabled: true) {}
                        SectionSignalsButton(section: .projects, count: 2, enabled: true) {}
                    }
                    .frame(maxWidth: .infinity, minHeight: scale(Size.menuRow), alignment: .leading)
                    .modifier(SidebarHeadingInset())
                }
                .padding(.horizontal, scale(Space.inset))
                .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset), alignment: .leading)
                .interfaceScale(scale)
            }
        }
        .padding(.vertical, Space.base)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }
    /// The banner a project signal's source raises at its third failure in a row, at the sidebar's width.
    private static func readIssueBanner() -> some View {
        let issue = OperationIssue.signalRead(signal: UUID(), name: "Reviews for me", source: "GitLab",
                                              reason: "The server answered 401 Unauthorized.",
                                              retry: SignalReadIssues.retry(at: Snapshots.clock.now + SignalPoller.failureBackOff,
                                                                           from: Snapshots.clock.now, calendar: Snapshots.clock.calendar))
        return IssueBanner(issue: issue, perform: { _ in }, dismiss: {})
            .frame(width: Size.sidebarWidth + 20)
            .background(Palette.sidebar)
    }
    /// The OPERATOR heading's signals icon and count, left of its "+": open with three signals, then folded (a task it
    /// runs gives it something to fold), over the PROJECTS heading, which has none yet; and at the extra-large size.
    private static func headingIcon() -> some View {
        func controller(open: Bool) -> AppController {
            let fixture = Fixture(), controller = fixture.controller()
            controller.workspace.mutate { state in
                state.signals = ["Plan labelled tickets", "Review requests", "Weekly dependency bumps"].map { name in
                    Signal(name: name, createdAt: Snapshots.clock.now, start: SignalTrigger(source: .jira, query: "labels = operator"),
                           done: SignalTrigger(source: .gitLab, query: "reviewer:any"), work: SignalWork(prompt: "/psg:plan"),
                           agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")], finish: SignalFinish(then: .keep))
                }
                state.operatorOpen = open
                hold(fixture.working.id, by: state.signals[0], in: &state)
            }
            return controller
        }
        let open = controller(open: true), folded = controller(open: false)
        return VStack(alignment: .leading, spacing: Space.base) {
            ForEach([InterfaceScale.standard, .extraLarge], id: \.factor) { scale in
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(controller: open, kind: .operator)
                    SectionHeading(controller: folded, kind: .operator)
                    SectionHeading(controller: folded, kind: .projects)
                }
                .padding(.horizontal, scale(Space.inset))
                .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset), alignment: .leading)
                .interfaceScale(scale)
            }
        }
        .padding(.vertical, Space.base)
        .background(Palette.sidebar)
        .surface(.sidebar)
    }
    /// Step 11's disc and card, drawn last: the disc on rows a signal started beside one you made, and the card the disc
    /// opens on an Operator task, a project task in each of its states, and a chain of signals.
    static var cards: [Snapshot] {
        [Snapshot("signals-disc.png") { disc() },
         Snapshot("signals-card-operator.png") { cardColumn(operatorCards()) },
         Snapshot("signals-card-project.png") { cardColumn(projectCards()) },
         Snapshot("signals-card-chain.png") { cardColumn(chainCards()) }]
    }

    /// Step 12's status line, drawn last: at rest, the Operator acting on a task, a task waking it, a question for you,
    /// and a folded project's stop at rest, acting and asking. Stacked, the Operator's section's rows as the list draws
    /// them, the list's 8 pt gap between them; hosted, the sidebar itself, whose rows the list's cells clip. Each at the
    /// standard, large and extra-large size.
    static var line: [Snapshot] {
        ["rest", "acting", "waking", "asking", "stop", "stop-acting", "stop-asking"].map { pose in
            Snapshot("signals-line-" + pose + ".png") { lineSizes(pose) }
        }
    }

    private static func lineSizes(_ pose: String) -> some View {
        HStack(alignment: .top, spacing: Snapshots.hosted ? 0 : Space.base) {
            ForEach(InterfaceSize.allCases, id: \.self) { size in
                let controller = lineController(pose, size: size), scale = size.scale
                if Snapshots.hosted {
                    SidebarView(controller: controller).frame(width: scale(Size.sidebarWidth), height: scale(Size.row) * 15)
                } else {
                    VStack(alignment: .leading, spacing: 2 * StatusLineReach.halfGap) {
                        SidebarView.operatorRows(in: controller.rows, controller: controller)
                    }
                    .padding(.horizontal, scale(Space.inset)).padding(.vertical, Space.base)
                    .frame(width: scale(Size.sidebarWidth), alignment: .top)
                    .interfaceScale(scale)
                    .background(Palette.sidebar)
                    .surface(.sidebar)
                }
            }
        }
        .background(Palette.sidebar)
    }

    /// The Operator running the fixture's two acme-storefront tasks and a dotfiles task behind the "Personal" divider,
    /// its section open; `stop` poses fold acme-storefront there. Nothing selected, so every mark keeps its ground.
    private static func lineController(_ pose: String, size: InterfaceSize) -> AppController {
        let fixture = Fixture(), preferences = InterfacePreferences(defaults: ScratchDefaults.make())
        preferences.interfaceSize = size
        let controller = fixture.controller(preferences: preferences)
        let dotfiles = TaskItem(id: UUID(), projectId: fixture.personal.id, title: "Tidy the shell prompt theme",
                                branch: "chore/ops-12-prompt", worktreePath: "/r/.worktrees/dot", baseBranch: "main",
                                jira: JiraRef(key: "OPS-12", summary: "Prompt theme", url: "https://example/OPS-12"),
                                agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil, appendTicket: true,
                                createdAt: Snapshots.clock.now, windowId: nil)
        controller.workspace.mutate { state in
            state.signals = [planning]
            state.tasks.append(dotfiles)
            for id in [fixture.working.id, fixture.other.id, dotfiles.id] { hold(id, by: planning, in: &state) }
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            state.operatorOpen = true
            if pose.hasPrefix("stop") { state.operatorFolded = [fixture.project.id] }
            let asked = pose == "asking" ? fixture.other.id : pose == "stop-asking" ? fixture.working.id : nil
            if let asked {
                state.operatorSession?.questions = [.init(id: "vat", task: asked,
                    text: "Block orders without a VAT number, or export them with the field empty?", openedAt: Snapshots.clock.now)]
            }
        }
        let activity = controller.signalController.activity
        switch pose {
        case "acting", "stop-acting": _ = activity.begin(task: fixture.other.id, act: "answering its worker")
        case "waking":
            // Long enough to outlast the capture.
            activity.pulseLength = .seconds(3600)
            activity.woke(task: dotfiles.id)
        default: break
        }
        controller.focus.browse(nil)
        controller.refreshRows()
        return controller
    }

    /// An Operator signal and a project signal for the disc and card poses.
    private static let planning = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
        start: SignalTrigger(source: .jira, query: "labels = operator"),
        done: SignalTrigger(source: .gitLab, description: "When a reviewer is asked on its merge request", query: "reviewer:any"),
        work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
        finish: SignalFinish(then: .keep))
    private static let reviews = Signal(name: "Reviews for me", createdAt: Snapshots.clock.now,
        start: SignalTrigger(source: .gitLab, query: "reviewer:@me"),
        done: SignalTrigger(source: .gitLab, query: "reviewer:@me review-state:approved"),
        work: SignalWork(prompt: "/psg:peer-review"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
        finish: SignalFinish(then: .archive), kind: .project)
    private static let request = ItemRef.request(remote: "gitlab.example/acme/storefront", number: 88)

    /// Task `task` of a fresh fixture as its row draws it, after `change`, with the controller that drew it.
    private static func drawn(_ task: (Fixture) -> UUID, operatorOpen: Bool = false,
                              live: (AppController, Fixture) -> Void = { _, _ in },
                              _ change: (Fixture, inout AppState) -> Void) -> (row: TaskRow, controller: AppController) {
        let fixture = Fixture(), controller = fixture.controller()
        controller.workspace.mutate { state in
            state.signals = [planning, reviews]
            change(fixture, &state)
            state.operatorOpen = operatorOpen
        }
        live(controller, fixture)
        controller.refreshRows()
        let id = task(fixture)
        let row = (controller.rows.operatorSections.flatMap(\.tasks) + controller.rows.sections.flatMap(\.tasks)).first { $0.id == id }!
        return (row, controller)
    }

    /// `id` marked by `signal` (a project signal's task, or one taken over), started `minutes` before the clock.
    private static func origin(_ id: UUID, by signal: Signal, minutes: Double, in state: inout AppState,
                               _ change: (inout SignalOrigin) -> Void = { _ in }) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        var origin = SignalOrigin(signal: signal.id, name: signal.name, item: request,
                                  startedAt: Snapshots.clock.now - minutes * 60)
        change(&origin)
        state.tasks[index].signalOrigin = origin
    }

    /// The disc beside a row you made: a project signal's task (stacked marks), an Operator task, a project signal's task
    /// with no window (its agent's mark faded under the disc), a selected one and a hovered one, at the standard and the
    /// extra-large size.
    private static func disc() -> some View {
        let mine = drawn({ $0.codexTask.id }) { _, _ in }
        let project = drawn({ $0.working.id }) { fixture, state in origin(fixture.working.id, by: reviews, minutes: 20, in: &state) }
        let held = drawn({ $0.other.id }) { fixture, state in hold(fixture.other.id, by: planning, in: &state) }
        let closedId = UUID()
        let closed = drawn({ _ in closedId }) { fixture, state in
            state.tasks.append(TaskItem(id: closedId, projectId: fixture.project.id, title: "Review the coupon stacking rules",
                                        branch: "feat/shop-1102-coupons", worktreePath: "/r/.worktrees/mr88", baseBranch: "main",
                                        jira: nil, agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil,
                                        appendTicket: false, createdAt: Snapshots.clock.now, windowId: nil))
            origin(closedId, by: reviews, minutes: 45, in: &state)
        }
        let selected = drawn({ $0.piTask.id }) { fixture, state in origin(fixture.piTask.id, by: reviews, minutes: 5, in: &state) }
        return VStack(alignment: .leading, spacing: Space.base) {
            ForEach([InterfaceScale.standard, .extraLarge], id: \.factor) { scale in
                SnapshotColumn(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset), spacing: scale(Space.base),
                               horizontalInset: scale(Space.inset), verticalInset: scale(Space.base)) {
                    TaskRowView(row: mine.row, controller: mine.controller)
                    TaskRowView(row: project.row, controller: project.controller)
                    TaskRowView(row: held.row, controller: held.controller)
                    TaskRowView(row: closed.row, controller: closed.controller)
                    TaskRowView(row: selected.row, controller: selected.controller)
                    TaskRowView(row: project.row, controller: project.controller)
                        .environment(\.seededHover, SeededHover(row: project.row.id))
                }
                .interfaceScale(scale)
            }
        }
        .background(Palette.sidebar)
        .surface(.sidebar)
    }

    /// Each pose's source row with its signal card open, over a neighbour the card lies across, as the native panel does.
    private static func cardColumn(_ poses: [(row: TaskRow, controller: AppController)]) -> some View {
        let neighbour = drawn({ $0.codexTask.id }) { _, _ in }
        return SnapshotColumn(width: Size.sidebarWidth + 2 * Space.inset, spacing: Space.base,
                              horizontalInset: Space.inset, verticalInset: Space.base) {
            ForEach(Array(poses.enumerated()), id: \.offset) { _, pose in
                VStack(spacing: Space.base) {
                    TaskRowView(row: pose.row, controller: pose.controller)
                        .environment(\.seededHover, SeededHover(signalCard: BackgroundCardHover(isOpen: true)))
                        .fixedSize(horizontal: false, vertical: true)
                        .zIndex(1)
                    TaskRowView(row: neighbour.row, controller: neighbour.controller)
                    // Room for the last card, which reaches below its neighbour.
                    Color.clear.frame(height: Space.margin)
                }
            }
        }
        .surface(.sidebar)
    }

    /// The Operator's tasks, their worker's turn ended: one it is acting on, one waiting on its Done trigger.
    private static func operatorCards() -> [(row: TaskRow, controller: AppController)] {
        func idle(_ controller: AppController, _ fixture: Fixture) {
            for index in controller.live.sessions.indices where controller.live.sessions[index].taskUUID == fixture.other.id {
                controller.live.sessions[index].state = .idle
            }
        }
        let acting = drawn({ $0.other.id }, operatorOpen: true, live: { controller, fixture in
            idle(controller, fixture)
            _ = controller.signalController.activity.begin(task: fixture.other.id, act: "answering its worker")
        }) { fixture, state in
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            hold(fixture.other.id, by: planning, in: &state)
        }
        let watching = drawn({ $0.other.id }, operatorOpen: true, live: idle) { fixture, state in
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            hold(fixture.other.id, by: planning, in: &state)
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.other.id }) { state.tasks[index].signalTask?.phase = .watching }
        }
        return [acting, watching]
    }

    /// A project signal's task: waiting for the pause to open its window, waiting for its worker held by the helper,
    /// at work, and done with its archive refused.
    private static func projectCards() -> [(row: TaskRow, controller: AppController)] {
        let launch = drawn({ $0.other.id }, live: { controller, fixture in
            controller.live.sessions.removeAll { $0.taskUUID == fixture.other.id }
        }) { fixture, state in
            origin(fixture.other.id, by: reviews, minutes: 2, in: &state) {
                $0.owed = OwedPrompt(text: "/psg:peer-review", at: Snapshots.clock.now, kind: .launch)
            }
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.other.id }) { state.tasks[index].windowId = nil }
        }
        let delivery = drawn({ $0.other.id }) { fixture, state in
            origin(fixture.other.id, by: reviews, minutes: 95, in: &state) {
                $0.owed = OwedPrompt(text: "/psg:peer-review", at: Snapshots.clock.now, kind: .delivery)
            }
            state.signalSeen = [SignalSeen(signal: reviews.id, item: request, disposition: .skipped, at: Snapshots.clock.now,
                                           reason: "Its prompt couldn’t be typed: the session is read-only.")]
        }
        let working = drawn({ $0.working.id }) { fixture, state in origin(fixture.working.id, by: reviews, minutes: 20, in: &state) }
        let done = drawn({ $0.working.id }) { fixture, state in
            origin(fixture.working.id, by: reviews, minutes: 60 * 26, in: &state) {
                $0.doneAt = Snapshots.clock.now; $0.thenApplied = true
                $0.thenNote = "Its worktree has unsaved changes."
            }
        }
        return [launch, delivery, working, done]
    }

    /// A chain of three signals, the first one removed; a task taken over from the Operator; and a removed signal's task.
    private static func chainCards() -> [(row: TaskRow, controller: AppController)] {
        let removed = UUID()
        let chain = drawn({ $0.working.id }) { fixture, state in
            origin(fixture.working.id, by: reviews, minutes: 15, in: &state) {
                $0.earlier = [SignalStep(signal: removed, name: "Triage new tickets", at: Snapshots.clock.now - 3 * 86_400),
                              SignalStep(signal: planning.id, name: planning.name, at: Snapshots.clock.now - 3 * 3600)]
            }
        }
        let takenOver = drawn({ $0.other.id }) { fixture, state in
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            hold(fixture.other.id, by: planning, in: &state)
            state.takeOver(fixture.other.id)
        }
        let gone = drawn({ $0.working.id }) { fixture, state in
            var signal = reviews; signal.id = removed; signal.name = "Nightly dependency bumps"
            origin(fixture.working.id, by: signal, minutes: 40, in: &state)
        }
        return [chain, takenOver, gone]
    }

    /// Hands task `id` to the Operator under `signal`, working.
    private static func hold(_ id: UUID, by signal: Signal, in state: inout AppState) {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        var record = SignalTask(current: SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-214"),
                                                     matchedAt: Snapshots.clock.now, configuration: signal),
                                startedAt: Snapshots.clock.now)
        record.phase = .working
        state.tasks[index].signalTask = record
    }
    /// A watching task by pose: its line is the Done trigger's query, or its description, or what its merge lacks.
    private static func waiting(_ pose: String) -> (description: String, facts: SignalWaitFacts?)? {
        switch pose {
        case "watching": ("", nil)
        case "described", "waiting-folded", "finished-signal-folded": ("When a reviewer is asked on its merge request", nil)
        case "merging": ("", SignalWaitFacts(mergeBlockers: [.approval, .checks]))
        default: nil
        }
    }
    private static func make(_ pose: String) -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        // An issue that kept failing: the Operator row's own "needs you", its source and reason as tooltip.
        if pose == "issue" { controller.rows.operatorIssue = { "Waking the Operator: The helper refused the wake: a wake line may not carry a digit" } }
        let signal = Signal(name: "Plan labelled tickets", createdAt: Snapshots.clock.now,
            start: SignalTrigger(source: .jira, query: "labels = operator"),
            done: SignalTrigger(source: .gitLab, description: waiting(pose)?.description ?? "", query: "reviewer:any"),
            work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(then: .keep, mergesWhenReady: pose == "merging"))
        // A second task beside the first, finished: its Done trigger fired and its closeout is through.
        let finishing = ["finished-folded", "all-finished-folded", "finished-signal-folded", "paused"].contains(pose)
        controller.workspace.mutate { state in
            state.signals = [signal]
            let stage = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-142"), matchedAt: Snapshots.clock.now, configuration: signal)
            var record = SignalTask(current: stage, startedAt: Snapshots.clock.now)
            record.phase = waiting(pose) == nil ? .working : .watching; record.waitingOn = waiting(pose)?.facts
            if pose == "choosing" { record.phase = .choosing; record.choosableRows = signal.agents + [AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium")] }
            if pose == "blocked" { record.phase = .blocked; record.blockedReason = "Its worker did not start after its saved launch. Inspect its window before resuming." }
            if ["done", "all-finished-folded"].contains(pose) { record.phase = .done; record.thenApplied = true }
            if let index = state.tasks.firstIndex(where: { $0.id == fixture.working.id }) { state.tasks[index].signalTask = ["idle", "idle-paused"].contains(pose) ? nil : record
                if waiting(pose) != nil { state.tasks[index].mr = MergeRequestRef(iid: 102, title: "Apple Pay", url: "https://gitlab.example.com/shop/web/-/merge_requests/102") }
                if pose == "window-closed" {
                    state.tasks[index].windowId = nil
                    state.tasks[index].conversations = [.init(agent: .claude, id: "saved-conversation")]
                }
            }
            if finishing, let index = state.tasks.firstIndex(where: { $0.id == fixture.other.id }) {
                let item = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-139"),
                                       matchedAt: Snapshots.clock.now, configuration: signal)
                var finished = SignalTask(current: item, startedAt: Snapshots.clock.now)
                finished.phase = .done; finished.thenApplied = true
                state.tasks[index].signalTask = finished
            }
            // Its signal removed: the task stays under its project, carrying on with the saved instructions.
            if pose == "removed-signal" { state.signals = [] }
            // A second signal's task in the same project, under one heading; with `-divider` and `-folded`, a third task
            // in dotfiles, so the projects' "Personal" divider heads it in the Operator's section too. Folded there,
            // acme-storefront counts its two tasks, though it stays open under PROJECTS.
            if pose.hasPrefix("by-project") {
                let reviews = Signal(name: "Review requests", createdAt: Snapshots.clock.now, start: SignalTrigger(source: .gitLab, query: "reviewer:@me"),
                                     done: SignalTrigger(source: .gitLab, query: "state:merged"), work: SignalWork(prompt: "/psg:peer-review"),
                                     agents: signal.agents, finish: SignalFinish(then: .keep))
                state.signals.append(reviews)
                if let index = state.tasks.firstIndex(where: { $0.id == fixture.other.id }) {
                    let request = SignalStage(signal: reviews.id, item: .mergeRequest(SignalRequestRef(remote: "gitlab.example/acme/storefront", number: 88)),
                                              matchedAt: Snapshots.clock.now, configuration: reviews)
                    var record = SignalTask(current: request, startedAt: Snapshots.clock.now)
                    record.phase = .working
                    state.tasks[index].signalTask = record
                }
                if pose != "by-project" {
                    var prompt = TaskItem(id: UUID(), projectId: fixture.personal.id, title: "Tidy the shell prompt theme",
                                          branch: "chore/ops-12-prompt", worktreePath: "/r/.worktrees/dot", baseBranch: "main",
                                          jira: JiraRef(key: "OPS-12", summary: "Prompt theme", url: "https://example/OPS-12"),
                                          agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil, appendTicket: true,
                                          createdAt: Snapshots.clock.now, windowId: nil)
                    var record = SignalTask(current: SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "OPS-12"),
                                                                 matchedAt: Snapshots.clock.now, configuration: signal),
                                            startedAt: Snapshots.clock.now)
                    record.phase = .watching
                    prompt.signalTask = record
                    state.tasks.append(prompt)
                }
            }
            // Folded in the Operator's section alone: the project's own fold is untouched.
            if ["folded", "waiting-folded", "finished-signal-folded", "by-project-folded"].contains(pose) { state.operatorFolded = [fixture.project.id] }
            state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now)
            if ["paused", "idle-paused"].contains(pose) { state.operatorSession?.paused = true }
            if pose == "fresh" { state.operatorSession?.lifecycle = .closing(then: .renew) }
            if pose == "taken-over" { state.takeOver(fixture.working.id) }
            // The Operator's section open, but where the pose is the projects': a taken-over task is theirs, and
            // section-folded is the default, OPERATOR folded with its status counts; every other pose folds the projects, whose
            // heading draws theirs.
            state.operatorOpen = !["taken-over", "section-folded", "finished-folded", "all-finished-folded"].contains(pose)
            if ["questions", "section-folded"].contains(pose) { state.operatorSession?.questions = [.init(id: "vat", task: fixture.working.id,
                text: "Block orders without a VAT number, or export them with the field empty?", openedAt: Snapshots.clock.now)] }
        }
        if pose == "acting" { _ = controller.signalController.activity.begin(task: fixture.working.id, act: "answering its worker") }
        if ["watching", "questions", "section-folded", "paused", "off", "choosing", "blocked", "done", "window-closed", "described", "merging", "waiting-folded",
            "all-finished-folded", "finished-signal-folded"].contains(pose) { controller.live.sessions.removeAll { $0.taskUUID == fixture.working.id } }
        if finishing { controller.live.sessions.removeAll { $0.taskUUID == fixture.other.id } }
        // Every worker ended its turn and the Operator does nothing yet: the turn is the Operator's to read.
        if pose == "worker-done" { for index in controller.live.sessions.indices where controller.live.sessions[index].taskUUID == fixture.working.id { controller.live.sessions[index].state = .done } }
        return SidebarView(controller: controller).frame(width: 420, height: 900)
    }
    /// The waiting ring on a driven row: plain, selected, held still for Reduce Motion, and the mark on the accent
    /// beside the background and working marks it is told from.
    private static func waitingMarks() -> some View {
        let fixture = Fixture(), controller = fixture.controller()
        let signal = Signal(name: "Review requests", createdAt: Snapshots.clock.now, start: SignalTrigger(source: .jira, query: "labels = operator"),
            done: SignalTrigger(source: .gitLab, description: "When it is approved", query: "review-state:approved"),
            work: SignalWork(prompt: "/psg:plan"), agents: [AgentChoice(agent: .claude, model: "claude-opus-5-5", reasoning: "high")],
            finish: SignalFinish(then: .keep))
        controller.workspace.mutate { state in
            // The section closed: these rows are drawn apart from it, so they carry no piece of the status line.
            state.signals = [signal]; state.operatorSession = OperatorSession(createdAt: Snapshots.clock.now); state.operatorOpen = false
            for (offset, id) in [fixture.working.id, fixture.other.id].enumerated() {
                guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { continue }
                let stage = SignalStage(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-14\(offset)"), matchedAt: Snapshots.clock.now, configuration: signal)
                var record = SignalTask(current: stage, startedAt: Snapshots.clock.now)
                record.phase = offset == 0 ? .watching : .working
                state.tasks[index].signalTask = record
                state.tasks[index].mr = MergeRequestRef(iid: 102 + offset, title: "Work", url: "https://gitlab.example.com/shop/web/-/merge_requests/\(102 + offset)")
            }
        }
        for index in controller.live.sessions.indices where [fixture.working.id, fixture.other.id].contains(controller.live.sessions[index].taskUUID) {
            controller.live.sessions[index].state = .idle
        }
        controller.focus.browse(.task(fixture.working.id))
        let rows = controller.rows.operatorSections.flatMap(\.tasks)
        let selected = rows.first { $0.id == fixture.working.id }!, plain = rows.first { $0.id == fixture.other.id }!
        // Driven tasks use the ordinary two-line row under the same status-mark rules.
        return SnapshotColumn(width: Size.sidebarWidth + 2 * Space.inset, spacing: Space.base, horizontalInset: Space.inset, verticalInset: Space.base) {
            TaskRowView(row: plain, controller: controller)
            TaskRowView(row: selected, controller: controller)
            TaskRowView(row: plain, controller: controller).environment(\.motionStill, .reduceMotion)
            HStack(spacing: Space.base) {
                ForEach([TaskStatus.working, .background, .waiting], id: \.self) { StatusMark(status: $0, size: Size.statusMark) }
            }
            .padding(Space.tight).background(Palette.accent).surface(.accent)
        }
        .surface(.sidebar)
    }
}
#endif
