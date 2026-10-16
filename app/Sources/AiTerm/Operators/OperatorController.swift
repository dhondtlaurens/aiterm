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
    /// The second opinion's runner (spec §4.4).
    var secondOpinion: SecondOpinionRunner = .unavailable
    /// How long a challenged call waits for its critique before answering that it is still coming: well
    /// inside the daemon's `operatorRequestTimeout`, which the challenge's own limit is not.
    var challengeReplyBudget: Duration = .seconds(20)
    var now: @MainActor () -> Date = { Date() }
    /// How long a burst of changes is gathered into one wake line.
    var wakeCoalesce: Duration = .seconds(OperatorTiming.wakeCoalesce)
    /// Settings › Agents' Agents at once (F1), read at every start pass.
    var agentsAtOnce: @MainActor () -> Int = { OperatorSettings.agentsAtOnce() }
    /// How often the run reconciler looks at the real tabs.
    var reconcileInterval: Duration = .seconds(OperatorTiming.reconcileInterval)
    /// What this build carries out (spec §13). A test that pins one milestone's rules names it, so
    /// raising `OperatorMilestone.current` (F1, G6) leaves it as it was.
    var milestone: OperatorMilestone = .current

    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?) -> OperatorPorts {
        OperatorPorts(home: home, git: git, library: OperatorLibrary(directory: OperatorLibrary.defaultDirectory(home: home)),
                      notifications: LiveOperatorNotifications(), jira: { jiraSettings().map { JiraClient(config: $0) } }, secondOpinion: .live)
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
    let workspace: WorkspaceStore
    let live: LiveSessions
    let notices: Notices
    let daemon: @MainActor () -> (any DaemonCommands)?
    let taskFrame: @MainActor () -> Frame
    @ObservationIgnored let ports: OperatorPorts
    @ObservationIgnored let notifier: OperatorNotifier
    @ObservationIgnored let waker: OperatorWaker
    @ObservationIgnored let tools: OperatorToolHandler
    @ObservationIgnored let starter: WorkerStarter
    @ObservationIgnored let reconciler: RunReconciler
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// An attach whose first connected snapshot is still to come: it reconciles and sets ownership again.
    @ObservationIgnored private var reattached = false
    /// The tasks whose open prompt is being read.
    @ObservationIgnored private var probing: Set<UUID> = []
    /// The latest prompt probe, for a test to await.
    @ObservationIgnored private(set) var lastProbe: Task<Void, Never>?
    /// The latest start a pass made, for a test to await.
    @ObservationIgnored private(set) var lastStart: Task<Void, Never>?
    /// The operation whose overview a notification's click asked for (spec §10.3): the sidebar presents
    /// it and sets this back to nil. Observed, so the click reaches a sidebar already on screen.
    var presentOverview: UUID?
    /// The operations whose operator window is being opened now (`reopenOperatorWindow`, D16): a second
    /// click on the row meanwhile opens no second operator.
    @ObservationIgnored var reopeningOperator: Set<UUID> = []
    /// When each operation's operator window was last opened by `reopenOperatorWindow`, until its tab is
    /// listed: a click in the gap before iTerm2 lists it (or past `launchAdoptAfter`) opens no second one.
    @ObservationIgnored var reopenedOperator: [UUID: Date] = [:]
    /// The latest close of ended operations' operator windows after an attach, for a test to await.
    @ObservationIgnored var closingEnded: Task<Void, Never>?
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
    /// Every operator, as its file says, by name: the sidebar's OPERATORS group. Set only by `reloadOperators()`
    /// (`OperatorController+Library.swift`); internal rather than `private(set)` because that is another file.
    var operators: [OperatorPersona] = []
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
        reconciler = RunReconciler(workspace: workspace, live: live, starter: starter, waker: waker, notifier: notifier, ports: ports)
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
        reloadOperators()
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

    func changed() { for hook in changeHooks { hook() } }

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
    /// The one start pass (spec §8, §11): what may start now — dependencies satisfied, a slot free across
    /// every operation under Settings › Agents' Agents at once, operations taking turns oldest first — is
    /// claimed in one change, saved so the launch intents are on disk before any window is asked for, then
    /// launched. A pass that overlaps another — two tasks finishing at once, or one while a launch awaits its
    /// window — counts the other's claims, so the cap holds and no task is claimed twice. Nothing while no
    /// helper is attached: there is no window to ask for. Called from `runChanged(_:)` (a tool's change, an
    /// approval, a block, a start ended, a resume, a hand back), `reconcileTick()`, the end of an operation
    /// and a change of Agents at once.
    func startReadyTasks() {
        guard daemon() != nil else { return }
        let cap = ports.milestone.maxParallel(setting: ports.agentsAtOnce())
        let claimed = starter.claimReady(maxParallel: cap)
        guard !claimed.isEmpty else { return }
        // Not on disk, a crash would leave nothing saying a worker may be running: the claims are taken back.
        guard workspace.flush() else {
            starter.release(claimed)
            return
        }
        for id in claimed {
            guard let operated = workspace.state.task(id: id)?.operated, let attempt = operated.launch else {
                starter.release([id])
                continue
            }
            let run = operated.runId
            lastStart = Task { [weak self] in
                await self?.starter.launchClaimed(id, attempt: attempt)
                self?.runChanged(run)
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
            reconciler.synced = snapshot.connected
            sessionsChanged()
            // After a reconnect: the daemon forgot every ownership generation, and what happened meanwhile
            // is looked at now rather than in a minute (spec §11).
            if snapshot.connected, reattached {
                reattached = false
                resendOwnership()
                closeEndedOperatorWindows()
                reconcileTick()
            }
        case .itermDisconnected, .itermAuthFailed:
            tabsKnown = false
            reconciler.synced = false
            // iTerm2 back with the helper still there: its tabs are looked at on the next snapshot, as after an attach.
            reattached = true
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
        reconciler.synced = false
        guard let daemon = daemon() else { return }
        reattached = true
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
        for id in reopenedOperator.keys where Self.operatorTab(of: id, in: sessions) != nil { reopenedOperator[id] = nil }
        let held = starter.tabsListed(for: Set(sessions.compactMap(\.taskUUID)))
        for id in closed { operatorWindowClosed(id) }
        observeRuns()
        probePrompts()
        for run in runs { waker.operatorSessionChanged(run.id) }
        // A retried task held back until its worker's window was listed: the retry goes to that worker now.
        if held { startReadyTasks() }
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

    // -- reconciling ------------------------------------------------------------------------
    /// The reconcile tick (spec §7.3): every `reconcileInterval` while AiTerm runs, and on the first
    /// connected snapshot after the helper attaches. What it changed is scheduled and settled, and
    /// whatever it freed or the helper's return allows to start starts — the way the tool paths do.
    func reconcileTick() {
        guard reconciler.synced else { return }
        for id in reconciler.tick() { runChanged(id) }
        // A prompt whose tab left it without an event, or one an event raced.
        probePrompts()
        startReadyTasks()
    }

    /// Starts the reconcile loop; AiTerm's `start()` calls it.
    func start() {
        guard loop == nil else { return }
        let interval = ports.reconcileInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // A sleep that ended just as `stop()` ran still resumes: it must not tick after it.
                guard (try? await Task.sleep(for: interval)) != nil, !Task.isCancelled, let self else { return }
                reconcileTick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Each operated task's tab: one that needs input has its prompt read (spec §7.2), and a question
    /// left open for one whose tab has left the prompt is resolved, whatever the task's state now.
    func probePrompts() {
        for task in workspace.state.tasks {
            guard let operated = task.operated else { continue }
            let open = run(id: operated.runId)?.questions.contains { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix("prompt-") }
            if operated.state == .working || operated.state == .blocked || open == true { probePrompt(task.id) }
        }
    }

    /// A worker that waits on a prompt: recorded as a question waiting on you, on its task, saying what
    /// the prompt is, and you are notified with its window; once the tab leaves the prompt the question
    /// is resolved and the row stops waiting on you. Codex's update offer is declined instead (`dismissStartup`).
    func probePrompt(_ id: UUID) {
        guard let task = workspace.state.task(id: id), let operated = task.operated, let run = run(id: operated.runId) else { return }
        let prefix = "prompt-\(id.uuidString)-"
        let open = run.questions.first { $0.id.hasPrefix(prefix) && $0.resolution == nil }
        let tab = live.sessions.filter { $0.taskUUID == id && $0.agent.agentKind != nil }.min { $0.tabIndex < $1.tabIndex }
        if let open, tab?.state != .needsInput {
            // No tab at all is not an answer: a window that is not listed (yet) leaves the question open.
            guard tab != nil || tabsKnown else { return }
            workspace.mutate { state in
                state.updateRun(id: run.id) { run in
                    if let i = run.questions.firstIndex(where: { $0.id == open.id }) { run.questions[i].resolution = "Answered in its window." }
                }
                if state.run(id: run.id)?.questions.contains(where: { $0.task == id && $0.resolution == nil }) == false {
                    state.updateOperated(id) { $0.flags.remove(.waitingOnYou) }
                }
            }
            // The last open question may be what kept the operation from completing.
            runChanged(run.id)
            return
        }
        guard open == nil, let tab, tab.state == .needsInput, !probing.contains(id), let daemon = daemon() else { return }
        probing.insert(id)
        let number = run.questions.filter { $0.id.hasPrefix(prefix) }.count + 1
        lastProbe = Task { [weak self] in
            // The helper gone is not a prompt AiTerm can't read: nothing is recorded, and the next pass asks again.
            let kind: PromptKind?
            do { kind = try await daemon.prompt(sessionId: tab.sessionId) } catch {
                self?.probing.remove(id)
                return
            }
            // Codex's update offer is AiTerm's to decline (spec §7.1): the daemon sends Esc only when the
            // screen shows that dialog. Anything else at startup — a trust question — is yours, and so is
            // a dismissal that did not happen: only a dismissed offer is never put to you.
            let declined = kind == .startup ? (try? await daemon.dismissStartup(sessionId: tab.sessionId)) == true : false
            guard let self else { return }
            probing.remove(id)
            guard !declined else { return }
            // The tab may have left the prompt while it was read: nothing is asked of you then.
            guard live.sessions.contains(where: { $0.sessionId == tab.sessionId && $0.state == .needsInput }) else { return }
            let question = OperatorQuestion(id: prefix + String(number), text: Self.promptText(kind, agent: task.agent), task: id,
                                            askedAt: ports.now(), resolution: nil)
            workspace.mutate { state in
                state.updateRun(id: run.id) { $0.questions.append(question) }
                state.updateOperated(id) { $0.flags.insert(.waitingOnYou) }
            }
            if let current = self.run(id: run.id) { notifier.workerPrompt(kind, task: task, in: current) }
        }
    }

    /// What a prompt asks, as the overview and the row say it. The daemon names the prompt's kind,
    /// not its words, so this is what AiTerm can say of it.
    static func promptText(_ kind: PromptKind?, agent: AgentKind) -> String {
        let name = agent.harness.displayName
        switch kind {
        case .permission: return "\(name) asks for permission"
        case .menu: return "\(name) shows a menu"
        case .startup: return "\(name) shows a startup question"
        case nil: return "\(name) waits for input AiTerm can’t read"
        }
    }

    /// The daemon keeps ownership generations in memory only (part A): after its restart each operated
    /// task's is set again on its tabs.
    func resendOwnership() {
        guard let daemon = daemon() else { return }
        let owned = workspace.state.tasks.compactMap { task in task.operated.map { (task.id, $0.ownership) } }
        let sessions = live.sessions
        Task {
            for (id, ownership) in owned {
                for tab in sessions where tab.taskUUID == id {
                    await Log.daemon.attempt("Setting the ownership of task \(id.uuidString) on its tab") {
                        try await daemon.setOwnership(sessionId: tab.sessionId, ownership: ownership)
                    }
                }
            }
        }
    }

    /// What each open run's `run_status` would show now, for the waker.
    private func observeRuns() {
        for run in runs where run.state != .stopped && run.intent != .stopped {
            if let status = status(of: run) { waker.observe(status, of: run.id) }
        }
    }
}
