import Foundation
import AiTermCore

/// What the operators reach beyond the app's own owners: the home — run folders
/// (`OperatorCommand.runFolder`) and the agents' conversations (`~/.claude`, `~/.codex`) are under it —
/// git, the operator files, the notification centre and the clock. The app's are `live`; a test's reach
/// nothing real (`OperatorPorts.scratch`). Each later service adds the port it needs, defaulted.
struct OperatorPorts {
    var home: URL
    var git: any GitRunning
    /// The operator files, `~/Library/Application Support/AiTerm/operators/`; Move to Trash goes through it.
    var library: OperatorLibrary
    var notifications: any OperatorNotifications
    /// The Jira client `jira_search` runs through, while Settings has one.
    var jira: @Sendable () -> (any OperatorJira)? = { nil }
    var now: @MainActor () -> Date = { Date() }
    /// How long a burst of changes is gathered into one wake line.
    var wakeCoalesce: Duration = .seconds(OperatorTiming.wakeCoalesce)
    /// What this build carries out (spec §13). A test that pins one milestone's rules names it, so
    /// raising `OperatorMilestone.current` (F1, G6) leaves it as it was.
    var milestone: OperatorMilestone = .current

    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?) -> OperatorPorts {
        OperatorPorts(home: home, git: git, library: OperatorLibrary(directory: OperatorLibrary.defaultDirectory(home: home)),
                      notifications: LiveOperatorNotifications(), jira: { jiraSettings().map { JiraClient(config: $0) } })
    }
}

/// Every operation: its start, its operator's tab and token, and the services that answer the
/// operator's tools, start its workers, wake it, notify you and reconcile it. The workspace is the one
/// place a run is kept (`AppState.runs`), changed only through here; the app is its only writer.
///
/// The operator's window is a task window tagged with the run's id (`aiterm_task`): no row has that
/// id, so the window lock never plans it, and this controller finds the operator's tab by it.
@MainActor
@Observable
final class OperatorController {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let notices: Notices
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let taskFrame: @MainActor () -> Frame
    @ObservationIgnored let ports: OperatorPorts
    @ObservationIgnored let notifier: OperatorNotifier
    @ObservationIgnored let waker: OperatorWaker
    @ObservationIgnored let tools: OperatorToolHandler
    @ObservationIgnored let starter: WorkerStarter
    /// The latest start a pass made, for a test to await.
    @ObservationIgnored private(set) var lastStart: Task<Void, Never>?
    /// The operation whose overview a notification's click asked for (spec §10.3): the sidebar presents
    /// it and sets this back to nil. Observed, so the click reaches a sidebar already on screen.
    var presentOverview: UUID?
    /// The latest re-registration of the runs' tokens, for a test to await.
    @ObservationIgnored private(set) var registering: Task<Void, Never>?
    /// The latest revocation of a complete operation's token after its operator's window closed, for a test to await.
    @ObservationIgnored private(set) var revoking: Task<Void, Never>?
    /// Whether `live.sessions` is iTerm2's whole list — a connected snapshot has come since the helper
    /// attached and iTerm2 has not gone — so a tab missing from it is a tab closed.
    @ObservationIgnored private(set) var tabsKnown = false
    /// The tasks the operator is acting on right now — a `message_task` or `mark_task` in flight: their
    /// rows' operator mark breathes (spec §10.4).
    private(set) var acting: Set<UUID> = [] { didSet { if acting != oldValue { changed() } } }
    @ObservationIgnored private var changeHooks: [@MainActor () -> Void] = []
    /// The runs and operated tasks as the hooks last heard of them.
    @ObservationIgnored private var lastHeard: ([OperatorRun], [TaskItem]) = ([], [])

    init(workspace: WorkspaceStore, live: LiveSessions, notices: Notices, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame, ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.notices = notices
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.ports = ports
        notifier = OperatorNotifier(notifications: ports.notifications, now: ports.now)
        waker = OperatorWaker(daemon: daemon,
                              session: { [live] run in Self.operatorTab(of: run, in: live.sessions) },
                              awake: { [workspace] run in
                                  guard let state = workspace.state.run(id: run)?.state else { return false }
                                  return state == .planning || state == .active || state == .complete
                              },
                              coalesce: ports.wakeCoalesce)
        tools = OperatorToolHandler(workspace: workspace, live: live, daemon: daemon, ports: ports, notifier: notifier, waker: waker)
        starter = WorkerStarter(workspace: workspace, live: live, daemon: daemon, taskFrame: taskFrame, ports: ports)
        lastHeard = (workspace.state.runs, workspace.state.tasks.filter { $0.operated != nil })
        workspace.onChange { [weak self] in
            self?.observeRuns()
            self?.heardWorkspace()
        }
        tools.onActing = { [weak self] task, on in self?.setActing(task, on) }
        tools.onChange = { [weak self] in self?.runChanged($0) }
        starter.onBlocked = { [weak self] task, reason in
            guard let self, let run = task.operated.flatMap({ self.run(id: $0.runId) }) else { return }
            notifier.taskBlocked(task, reason: reason, in: run)
            runChanged(run.id)
        }
    }

    /// Adds `handler` to what hears that a run, an operated task or `acting` changed: the UI's
    /// overview and rows.
    func onChange(_ handler: @escaping @MainActor () -> Void) { changeHooks.append(handler) }

    private func heardWorkspace() {
        let now = (workspace.state.runs, workspace.state.tasks.filter { $0.operated != nil })
        guard now.0 != lastHeard.0 || now.1 != lastHeard.1 else { return }
        let before = lastHeard.0
        lastHeard = now
        // A paused run's wake news was held: it goes the moment the run is not paused any more.
        for run in now.0 where run.state != .paused && before.first(where: { $0.id == run.id })?.state == .paused {
            waker.operatorSessionChanged(run.id)
        }
        changed()
    }

    private func changed() { for hook in changeHooks { hook() } }

    /// The tool handler's report of what the operator is acting on.
    func setActing(_ task: UUID, _ on: Bool) {
        if on { acting.insert(task) } else { acting.remove(task) }
    }

    var runs: [OperatorRun] { workspace.state.runs }
    func run(id: UUID) -> OperatorRun? { workspace.state.run(id: id) }
    func folder(of run: UUID) -> URL { OperatorCommand.runFolder(run, home: ports.home) }
    func operatorTab(of run: UUID) -> SessionInfo? { Self.operatorTab(of: run, in: live.sessions) }

    /// The operator's tab: the first tab tagged with the run, by its place in the window.
    static func operatorTab(of run: UUID, in sessions: [SessionInfo]) -> SessionInfo? {
        sessions.filter { $0.taskUUID == run }.min { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }
    }

    /// The run as `run_status` would show it now, numbered 0: the waker compares content.
    func status(of run: OperatorRun) -> RunStatus? {
        Self.status(of: run.id, state: workspace.state, sessions: live.sessions, revision: 0)
    }

    /// `run_status`'s snapshot: the run from the workspace, each task's live facts from its worker's tab.
    static func status(of run: UUID, state: AppState, sessions: [SessionInfo], revision: Int) -> RunStatus? {
        RunStatus.build(state: state, run: run, revision: revision, live: liveFacts(of: run, state: state, sessions: sessions))
    }

    /// What the tabs say of each of the run's tasks: its worker's live status, and the prompt it waits on
    /// you with (the open question D14 records for it).
    static func liveFacts(of run: UUID, state: AppState, sessions: [SessionInfo]) -> [UUID: TaskLiveFacts] {
        let questions = state.run(id: run)?.questions ?? []
        var facts: [UUID: TaskLiveFacts] = [:]
        for task in state.tasks(inRun: run) {
            let tab = sessions.filter { $0.taskUUID == task.id && $0.agent.agentKind != nil }.min { $0.tabIndex < $1.tabIndex }
            let prompt = questions.first { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix("prompt-") }?.text
            if tab != nil || prompt != nil { facts[task.id] = TaskLiveFacts(status: tab?.state, waitingPrompt: prompt) }
        }
        return facts
    }

    /// The projects a brief's tickets belong to, by the Jira projects linked to each (spec §5.3); every
    /// project when it names a ticket of none of them.
    static func projects(for brief: String, in state: AppState) -> [UUID] {
        let prefixes = Set(brief.uppercased().matches(of: /\b([A-Z][A-Z0-9_]+)-[0-9]+\b/).map { String($0.output.1) })
        let linked = state.projects.filter { project in project.jiraProjects.contains { prefixes.contains($0.key.uppercased()) } }
        return (linked.isEmpty ? state.projects : linked).map(\.id)
    }

    /// The first line of the brief, as the run's row names it until the person renames it.
    static func operationName(from brief: String) -> String {
        let line = brief.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Operation"
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    /// Changes one run, saved like every workspace change. Nothing for a run that has gone.
    func mutateRun(_ id: UUID, _ change: (inout OperatorRun) -> Void) {
        workspace.mutate { state in
            guard let i = state.runs.firstIndex(where: { $0.id == id }) else { return }
            change(&state.runs[i])
        }
    }

    /// Approve plan (spec §8): you approve one exact revision — the latest submitted — and its planned
    /// tasks are released (`PlanRevision.approve`). A click on a revision since replaced is stale: it
    /// fails with the reason and releases nothing.
    func approvePlan(run id: UUID, revision: Int) throws {
        guard self.run(id: id) != nil else { throw ActionUnavailable("This operation is no longer in AiTerm.") }
        let before = self.run(id: id)?.approvedRevision
        do {
            try workspace.mutate { state in
                try PlanRevision.approve(revision, run: id, in: &state)
                state.updateRun(id: id) { if $0.state == .planning || $0.state == .complete { $0.state = .active } }
            }
        } catch let failure as PlanRevision.Failure {
            throw ActionUnavailable(failure.description)
        }
        // Approving the approved revision again changes nothing, so it wakes nothing.
        if self.run(id: id)?.approvedRevision != before { waker.say("plan approved", to: id) }
        runChanged(id)
    }

    // -- starting workers -------------------------------------------------------------------
    /// Agents at once, as M1 has it; part F reads it from Settings › Agents.
    static let agentsAtOnce = 1

    /// The one start pass. What the scheduler says may start — dependencies satisfied, oldest operation
    /// first, operations taking turns — is claimed and saved one task at a time while a slot is free
    /// across every operation, so each claim counts against the cap before the next. A task that cannot
    /// start now (`start` returns nil: no helper, or its claim could not be saved and was taken back) is passed over, and the next may
    /// still take the slot.
    func startReadyTasks() {
        let cap = ports.milestone.maxParallel(setting: Self.agentsAtOnce)
        for id in RunScheduler.startable(in: workspace.state, maxParallel: .max) where !starter.starting.contains(id) {
            guard workspace.state.tasks.count(where: { $0.operated?.state == .working }) < cap else { return }
            guard let started = starter.start(id) else { continue }
            let run = workspace.state.task(id: id)?.operated?.runId
            lastStart = Task { [weak self] in
                await started.value
                if let run { self?.runChanged(run) }
            }
        }
    }

    /// Something in the run changed: whatever may start now starts.
    func runChanged(_ id: UUID) {
        settle(id)
        startReadyTasks()
    }

    /// An operation whose every task has ended and with no question open is complete (spec §9): the
    /// operator is told, and you are notified. A later `submit_plan` makes it active again.
    func settle(_ id: UUID) {
        guard let run = run(id: id), run.state == .active, RunScheduler.isComplete(run, in: workspace.state) else { return }
        mutateRun(id) { $0.state = .complete }
        waker.say("operation complete", to: id)
        if let complete = self.run(id: id) { notifier.runComplete(complete) }
    }

    // -- starting ---------------------------------------------------------------------------
    /// Starts an operation: the run saved with a snapshot of `persona`, its folder written — `brief.md`,
    /// `mcp.json`, the token, `first-message.md` — the token registered with the helper, and the operator's window opened in
    /// front with the brief as its first message. The run is on disk before its window opens: a
    /// relaunch must know the window is its. Its projects are `projectIds`, or by default those the
    /// brief's tickets belong to (`projects(for:in:)`).
    @discardableResult
    func startOperation(operator persona: OperatorPersona, brief: String, doneWhen: String?, projectIds: [UUID]? = nil) async throws -> UUID {
        guard workspace.canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before starting an operation.") }
        guard !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionUnavailable("Tell the operator what to work on.") }
        let projectIds = projectIds ?? Self.projects(for: brief, in: workspace.state)
        let projects = projectIds.compactMap(workspace.state.project(id:))
        guard !projects.isEmpty, projects.count == projectIds.count else {
            throw ActionUnavailable("Choose the projects this operation may work in.")
        }
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        let doneWhen = doneWhen.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let run = OperatorRun(id: UUID(), name: Self.operationName(from: brief), persona: persona, projectIds: projectIds, brief: brief,
                              doneWhen: doneWhen, createdAt: ports.now())
        let home = ports.home, milestone = ports.milestone
        // A fresh start: `prepare` makes the token and writes the first message the command reads.
        let prepared = try await BackgroundWork.run {
            try OperatorCommand.prepare(run: run, projects: projects, home: home, milestone: milestone)
        }
        // The workspace may have been locked while the folder was written.
        guard workspace.canChangeWorkspace else {
            await discardToken(in: prepared.folder)
            throw ActionUnavailable("Save or recover the workspace before starting an operation.")
        }
        workspace.mutate { $0.runs.append(run) }
        // From here a failure takes the run out again: no row without a window, no token left behind.
        var registered = false
        do {
            guard workspace.flush() else { throw ActionUnavailable("The operation couldn’t be saved, so it didn’t start.") }
            ports.notifications.requestAuthorization()
            try await daemon.registerOperator(runId: run.id.uuidString, token: prepared.token)
            registered = true
            let window = try await daemon.createTaskWindow(taskId: run.id.uuidString, cwd: prepared.folder.path, title: run.name,
                                                           agentCommand: prepared.command, frame: taskFrame(), background: false)
            mutateRun(run.id) { $0.operatorWindowId = window }
        } catch {
            workspace.mutate { $0.runs.removeAll { $0.id == run.id } }
            _ = workspace.flush()
            waker.forget(run.id)
            await discardToken(in: prepared.folder)
            if registered {
                await Log.daemon.attempt("Revoking the token of operation \(run.id.uuidString) that did not start") {
                    try await daemon.revokeOperator(runId: run.id.uuidString)
                }
            }
            throw error
        }
        return run.id
    }

    /// A start that failed: the token file it wrote goes, a secret the daemon would adopt again after a restart.
    /// The brief and the MCP file stay. Best effort, logged when it fails.
    private func discardToken(in folder: URL) async {
        let file = folder.appendingPathComponent(OperatorCommand.tokenFile)
        await Log.workspace.attempt("Removing the token file of an operation that did not start") {
            try await BackgroundWork.run { try FileManager.default.removeItem(at: file) }
        }
    }

    // -- the helper -------------------------------------------------------------------------
    /// The helper's events, after the window lock and the live sessions have taken theirs.
    func handle(_ event: DaemonEvent) {
        switch event {
        case .snapshot(let snapshot):
            tabsKnown = snapshot.connected
            sessionsChanged()
        case .itermDisconnected, .itermAuthFailed: tabsKnown = false
        case .sessionOpened, .sessionChanged, .sessionClosed, .windowClosed: sessionsChanged()
        case .operatorRequest(let request): tools.handle(request)
        default: break
        }
    }

    /// A daemon attached — after AiTerm's launch, or the daemon's restart, which forgets the tokens:
    /// every run's token is registered again but a stopped run's (a revoke that failed is tried again), and each operator that may be woken
    /// is told `reconnected` (spec §11).
    func daemonAttached() {
        // A new daemon's tabs are known once its first connected snapshot comes.
        tabsKnown = false
        guard let daemon = daemon() else { return }
        let open = runs.filter { $0.state != .stopped && $0.intent != .stopped }.map { ($0.id, folder(of: $0.id)) }
        // Runs you ended: a revocation that failed before is tried again while their token file is there.
        let ended = runs.filter { $0.intent == .stopped }.map { ($0.id, folder(of: $0.id)) }
        registering = Task {
            for (id, folder) in open {
                guard let token = await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) else { continue }
                await Log.daemon.attempt("Registering the token of operation \(id.uuidString)") {
                    try await daemon.registerOperator(runId: id.uuidString, token: token)
                }
            }
            for (id, folder) in ended {
                guard await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) != nil else { continue }
                await Log.daemon.attempt("Revoking the token of operation \(id.uuidString)") {
                    try await daemon.revokeOperator(runId: id.uuidString)
                }
            }
        }
        for (id, _) in open {
            waker.say("reconnected", to: id)
            // News that was waiting before the daemon went is tried again now.
            waker.operatorSessionChanged(id)
        }
    }

    /// Each run's operator tab as the helper reports it — its session, its window, and the
    /// conversation a resume continues — then whatever the tabs changed in what `run_status` shows.
    /// A tab seen before and missing from iTerm2's whole list is a window closed: the run forgets it.
    private func sessionsChanged() {
        let sessions = live.sessions, known = tabsKnown
        var closed: [UUID] = []
        workspace.mutate { state in
            for i in state.runs.indices {
                guard let tab = Self.operatorTab(of: state.runs[i].id, in: sessions) else {
                    // Only a tab once seen: a window just asked for may not be listed yet.
                    if known, state.runs[i].operatorSessionId != nil {
                        state.runs[i].operatorSessionId = nil
                        state.runs[i].operatorWindowId = nil
                        closed.append(state.runs[i].id)
                    }
                    continue
                }
                state.runs[i].operatorSessionId = tab.sessionId
                state.runs[i].operatorWindowId = tab.windowId
                if let conversation = tab.conversationId, TaskConversation.isResumable(conversation) {
                    state.runs[i].operatorConversation = conversation
                }
            }
        }
        for id in closed { operatorWindowClosed(id) }
        observeRuns()
        for run in runs { waker.operatorSessionChanged(run.id) }
    }

    /// The operator's window closed (spec §9). A complete operation ends: your stop, persisted, and its
    /// token revoked. Any other waits for a click on its row, which reopens it (`focusOperatorWindow`,
    /// D16), or goes offline on the next reconcile (D14).
    private func operatorWindowClosed(_ id: UUID) {
        guard let run = run(id: id), run.state == .complete, run.intent != .stopped else { return }
        mutateRun(id) { $0.intent = .stopped }
        _ = workspace.flush()
        waker.forget(id)
        guard let daemon = daemon() else { return }
        revoking = Task {
            await Log.daemon.attempt("Revoking the token of operation \(id.uuidString)") { try await daemon.revokeOperator(runId: id.uuidString) }
        }
    }

    /// What each open run's `run_status` would show now, for the waker.
    private func observeRuns() {
        for run in runs where run.state != .stopped && run.intent != .stopped {
            if let status = status(of: run) { waker.observe(status, of: run.id) }
        }
    }
}
