import Foundation
import AiTermCore

/// What the operators reach beyond the app's own owners: the home — run folders
/// (`OperatorCommand.runFolder`) and the agents' conversations (Claude's folder, `~/.codex`) are under it —
/// git, the notification centre and the clock. The app's are `live`; a test's reach
/// nothing real (`OperatorPorts.scratch`). Each later service adds the port it needs, defaulted.
struct OperatorPorts {
    var home: URL
    /// Where under `home` Claude keeps its conversations and skills: the app's `ClaudeConfig`, from the login shell.
    var claudeConfig = ClaudeConfig()
    var git: any GitRunning
    var notifications: any OperatorNotifications
    /// The Jira client `jira_search` runs through, while Settings has one.
    var jira: @Sendable () -> (any OperatorJira)? = { nil }
    /// The Oracle's runner.
    var secondOpinion: SecondOpinionRunner = .unavailable
    /// The runner of `review_task`'s agent reviews: the Oracle's recipe in a task's worktree.
    var agentReviewer: SecondOpinionRunner = .unavailable
    /// How long a challenged call waits for its critique before answering that it is still coming: well
    /// inside the daemon's `operatorRequestTimeout`, which the challenge's own limit is not.
    var challengeReplyBudget: Duration = .seconds(20)
    var now: @MainActor () -> Date = { Date() }
    /// The version of AiTerm that is running, for the snags the Operator reports: "dev" for a build with none.
    var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// How long a burst of changes is gathered into one wake line.
    var wakeCoalesce: Duration = .seconds(OperatorTiming.wakeCoalesce)
    var wakeSleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// The wait for the Operator's summary once a broadcast is complete (`OperatorTiming.summaryWait`).
    var summarySleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// How often the run reconciler looks at the real tabs.
    var reconcileInterval: Duration = .seconds(OperatorTiming.reconcileInterval)
    /// What this build carries out (spec §13). A test that pins one milestone's rules names it, so
    /// raising `OperatorMilestone.current` (F1, G6) leaves it as it was.
    var milestone: OperatorMilestone = .current
    /// The code host a project's requests are published on, with the connections Settings saved (G10):
    /// `remote` is origin's, the repository the push goes to. The tokens stay in the clients.
    var publisher: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing = { remote in
        try MergeRequestPublisher.publisher(for: remote, gitLab: GitLabSettings.load(), gitHub: GitHubSettings.load())
    }
    /// How long the host's view of a task's request is waited for (`OperatorTiming.hostReadTimeout`) and kept (`hostReadCache`):
    /// what `run_status` and `read_task` show of each request.
    var hostTimeout: Duration = .seconds(OperatorTiming.hostReadTimeout)
    var hostCache: TimeInterval = OperatorTiming.hostReadCache
    /// The merge watch's wait between polls.
    var mergeSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    /// The clock a publication reads — its bounded wait, its two ready reads apart.
    var publishNow: @Sendable () -> Date = { Date() }
    /// The agents the login shell found, which a task may run (spec §15). Nil is the app's own
    /// `AgentIntegrations.availableAgents`, which `AppController` fills in.
    var installedAgents: (@MainActor () -> Set<AgentKind>)?
    /// An agent's model list in Settings › Agents (`ModelCatalogue.models(for:)`). Blocking: read through
    /// `BackgroundWork`. Nil is the app's own catalogue, which `AppController` fills in.
    var agentModels: (@Sendable (AgentKind) -> [AgentModel])?
    /// The version each agent CLI installed here reports (`AgentVersions`). Blocking: read through `BackgroundWork`.
    /// Nil is the app's own, which `AppController` fills in.
    var installedVersions: (@Sendable ([AgentKind]) -> [AgentKind: String])?
    /// Each agent's weekly use in percent, windows past their reset left out (`SidebarModel.weeklyUsage`): what
    /// a task's launch reads to start on the other agent. Nil is `live.usage`, which the controller fills in.
    var weeklyUsage: (@MainActor () -> [AgentKind: Int])?
    /// Settings › Operator's profile, as a new broadcast freezes it (`OperatorProfileStore.load`). Blocking: read
    /// through `BackgroundWork`. Nil is `UserDefaults.standard`'s, on Claude's default from `agentModels`, which
    /// `AppController` replaces with the app's own defaults.
    var profile: (@Sendable () -> OperatorProfile)?

    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?,
                                claudeConfig: ClaudeConfig = ClaudeConfig()) -> OperatorPorts {
        OperatorPorts(home: home, claudeConfig: claudeConfig, git: git, notifications: LiveOperatorNotifications(),
                      jira: { jiraSettings().map { JiraClient(config: $0) } }, secondOpinion: .live,
                      agentReviewer: .live)
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
    /// `open_tab`'s extra worker tabs.
    @ObservationIgnored let tabs: TabOpener
    /// `finish_task` and the merge watch (G10).
    @ObservationIgnored let finisher: TaskFinisher
    @ObservationIgnored let reconciler: RunReconciler
    /// The requests people review (spec §5, the Review slice), read on every reconcile tick.
    @ObservationIgnored let reviewWatcher: ReviewWatcher
    /// That each worker commits on its task branch, read on every reconcile tick.
    @ObservationIgnored let branchWatch: BranchWatch
    /// What each worker's ended turn left (spec §J), read once each turn ends.
    @ObservationIgnored let turns: WorkerTurnReader
    /// Which workers say working with a transcript gone quiet (spec §H): what `run_status` reads `working?`.
    @ObservationIgnored let quiet: WorkerQuietWatch
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// An attach whose first connected snapshot is still to come: it reconciles and sets ownership again.
    @ObservationIgnored private var reattached = false
    /// The worker tabs, by session, whose open prompt is being read.
    @ObservationIgnored private var probing: Set<String> = []
    /// When each working task last showed a sign of life (spec §8, *possibly stalled*): any change the
    /// daemon reports for one of its tabs — status, title, context, conversation.
    @ObservationIgnored private var stallWatch = StallWatch()
    /// The latest prompt probe, for a test to await.
    @ObservationIgnored private(set) var lastProbe: Task<Void, Never>?
    /// The latest start a pass made, for a test to await.
    @ObservationIgnored private(set) var lastStart: Task<Void, Never>?
    /// Each complete broadcast's wait for its summary, by run: one per completion.
    @ObservationIgnored private var summaryWaits: [UUID: Task<Void, Never>] = [:]
    /// The latest wait for a summary, for a test to await.
    @ObservationIgnored private(set) var summaryWait: Task<Void, Never>?
    /// The operation whose overview a notification's click asked for (spec §10.3): the sidebar presents
    /// it and sets this back to nil. Observed, so the click reaches a sidebar already on screen.
    var presentOverview: UUID?
    /// The broadcasts whose Operator's window could not be reopened behind the board, its conversation
    /// gone (spec §13): the board's footer says so and offers Start Fresh. Cleared by a reopening that
    /// opens one, and by Start Fresh. Observed, so the board open in front of it changes at once.
    var reopenFailed: Set<UUID> = []
    /// The Operator's wake line refused for anything but a prompt waiting on you: the sidebar's Notice. Taken
    /// down once the Operator calls `run_status`, a later wake line is delivered, or its broadcast is forgotten.
    var wakeNotice: OperatorWakeNotice?
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
    /// Whether `live.sessions` is iTerm2's whole list — a connected snapshot has come since the helper
    /// attached and iTerm2 has not gone — so a tab missing from it is a tab closed.
    @ObservationIgnored private(set) var tabsKnown = false
    /// The Operator's acts AiTerm is carrying out now, in the order each began: a tool call in flight, the
    /// Oracle consulted, a worker starting or its window reopening. The status lines say them (`acting`).
    private(set) var activities: [OperatorActivity] = [] { didSet { if activities != oldValue { changed() } } }
    /// What the Operator is doing, as the status lines read it: each task's latest act, and each
    /// broadcast's latest, its task named by its key.
    var acting: OperatorActs {
        var acts = OperatorActs()
        for activity in activities {
            if let task = activity.task { acts.tasks[task] = activity.act }
            let key = activity.task.flatMap { workspace.state.task(id: $0)?.operated?.key }
            acts.runs[activity.run] = OperatorActs.Broadcast(act: activity.act, task: key)
        }
        for (task, reading) in turns.readings where !reading.messaged {
            if let ending = WorkerTurn.ending(lastMessage: reading.lastMessage, commitsAhead: reading.commitsAhead) { acts.turns[task] = ending }
        }
        return acts
    }
    /// How many lines each run's activity log has been written since this launch: the Operator sheet watches it to
    /// read the file again (`activityGeneration(of:)`).
    private var activityWritten: [UUID: Int] = [:]
    /// Changes after each line of the run's activity log lands. Observed.
    func activityGeneration(of run: UUID) -> Int { activityWritten[run, default: 0] }
    @ObservationIgnored private var changeHooks: [@MainActor () -> Void] = []
    /// The runs and operated tasks as the hooks last heard of them.
    @ObservationIgnored private var lastHeard: ([OperatorRun], [TaskItem]) = ([], [])

    init(workspace: WorkspaceStore, live: LiveSessions, notices: Notices, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame, ports: OperatorPorts) {
        var ports = ports
        if ports.weeklyUsage == nil {
            let now = ports.now
            ports.weeklyUsage = { [live] in SidebarModel.weeklyUsage(live.usage, now: now()) }
        }
        if ports.profile == nil {
            let models = ports.agentModels, installed = ports.installedAgents?() ?? Set(AgentKind.allCases)
            ports.profile = { OperatorProfileStore.load(claudeDefault: OperatorProfileStore.claudeDefault(models: models?(.claude) ?? []), installed: installed) }
        }
        self.workspace = workspace
        self.live = live
        self.notices = notices
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.ports = ports
        notifier = OperatorNotifier(notifications: ports.notifications, state: { [workspace] in workspace.state })
        waker = OperatorWaker(daemon: daemon,
                              session: { [live] run in Self.operatorTab(of: run, in: live.sessions) },
                              awake: { [workspace] run in
                                  guard let state = workspace.state.run(id: run)?.state else { return false }
                                  return state == .planning || state == .active || state == .complete
                              },
                              coalesce: ports.wakeCoalesce, sleep: ports.wakeSleep)
        tabs = TabOpener(workspace: workspace, daemon: daemon, ports: ports)
        tools = OperatorToolHandler(workspace: workspace, live: live, daemon: daemon, ports: ports, waker: waker, tabs: tabs)
        starter = WorkerStarter(workspace: workspace, live: live, daemon: daemon, taskFrame: taskFrame, ports: ports)
        // It captures nothing of `self`: its callbacks are installed once every stored property is set.
        finisher = TaskFinisher(store: workspace, git: ports.git, connect: ports.publisher, now: ports.publishNow, sleep: ports.mergeSleep)
        reconciler = RunReconciler(workspace: workspace, live: live, starter: starter, tabs: tabs, waker: waker, ports: ports)
        reviewWatcher = ReviewWatcher(workspace: workspace, ports: ports, waker: waker)
        branchWatch = BranchWatch(workspace: workspace, live: live, ports: ports, waker: waker)
        turns = WorkerTurnReader(workspace: workspace, live: live, ports: ports)
        quiet = WorkerQuietWatch(workspace: workspace, live: live, ports: ports)
        lastHeard = (workspace.state.runs, workspace.state.tasks.filter { $0.operated != nil })
        workspace.onChange { [weak self] in
            // A task taken over, stopped or moved on: what its worker's turn left is read again or dropped first.
            self?.turns.observe()
            self?.quiet.observe()
            self?.observeRuns()
            self?.heardWorkspace()
        }
        turns.changed = { [weak self] in
            self?.observeRuns()
            self?.changed()
        }
        quiet.changed = { [weak self] in
            self?.observeRuns()
            self?.changed()
        }
        waker.refused = { [weak self] run, delivery in
            guard let self else { return }
            wakeNotice = OperatorWakeNotice(run: run, status: self.run(id: run).flatMap(status(of:)), refusal: delivery)
        }
        waker.cleared = { [weak self] run in
            if self?.wakeNotice?.run == run { self?.wakeNotice = nil }
        }
        tools.onActing = { [weak self] activity, on in self?.setActing(activity, on) }
        starter.onActing = { [weak self] activity, on in self?.setActing(activity, on) }
        tools.onChange = { [weak self] in self?.runChanged($0) }
        tools.onActivity = { [weak self] run in self?.activityWritten[run, default: 0] += 1 }
        tools.turnReadings = { [weak self] in self?.turns.readings ?? [:] }
        tools.quietTasks = { [weak self] in self?.quiet.quiet ?? [] }
        tools.onMessaged = { [weak self] task in self?.turns.messaged(task) }
        starter.onUncertain = { [weak self] task in
            guard let operated = task.operated else { return }
            self?.waker.say("one task is uncertain: its window has only a shell; no worker is confirmed", to: operated.runId)
        }
        starter.onBlocked = { [weak self] task, _ in
            guard let self, let runId = task.operated?.runId else { return }
            runChanged(runId)
        }
        finisher.changed = { [weak self] id in self?.publicationChanged(id) }
        finisher.mergedOnHost = { [weak self] id, why in self?.askAboutMergeOnHost(id, why) }
        finisher.watchStopped = { [weak self] id, why in self?.mergeWatchStopped(id, why) }
        tools.finish = { [weak self] id, noVerify in
            guard let self else { return TaskFinisher.Result(result: "refused", reason: "AiTerm is closing.") }
            return await self.finisher.finish(id, noVerify: noVerify)
        }
        notices.onIssueChanged { [weak self] old, new in self?.bannerChanged(from: old, to: new) }
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
        // What needs you follows the state: posted and withdrawn whatever changed it.
        for run in now.0 { notifier.requestsChanged(run: run) }
        changed()
    }

    /// Posts what the run now asks of you and withdraws what is answered or over (`OperatorNotifier`).
    func notifyRequests(of id: UUID) {
        if let run = run(id: id) { notifier.requestsChanged(run: run) }
    }

    func changed() { for hook in changeHooks { hook() } }

    /// The tool handler's and the starter's report of an act beginning or ending.
    func setActing(_ activity: OperatorActivity, _ on: Bool) {
        if on { activities.append(activity) } else { activities.removeAll { $0.id == activity.id } }
    }

    var runs: [OperatorRun] { workspace.state.runs }
    /// The one broadcast not ended (spec §3): there is at most one, and while there is, no other starts.
    var activeRun: OperatorRun? { workspace.state.activeRun }
    func run(id: UUID) -> OperatorRun? { workspace.state.run(id: id) }
    func folder(of run: UUID) -> URL { OperatorCommand.runFolder(run, home: ports.home) }
    func operatorTab(of run: UUID) -> SessionInfo? { Self.operatorTab(of: run, in: live.sessions) }

    /// The operator's tab: the first tab tagged with the run, by its place in the window.
    static func operatorTab(of run: UUID, in sessions: [SessionInfo]) -> SessionInfo? {
        SidebarModel.operatorTab(of: run, in: sessions)
    }

    /// The run as `run_status` would show it now, numbered 0: the waker compares content.
    func status(of run: OperatorRun) -> RunStatus? {
        Self.status(of: run.id, state: workspace.state, sessions: live.sessions, revision: 0,
                    usage: SidebarModel.weeklyUsage(live.usage, now: ports.now()), turns: turns.readings, quiet: quiet.quiet, now: ports.now())
    }

    /// `run_status`'s snapshot: the run from the workspace, each task's live facts from its worker's tab and what its
    /// worker's last ended turn left (`WorkerTurnReader.readings`). `usage` is each agent's weekly percent
    /// (`SidebarModel.weeklyUsage`). `quiet` is the tasks whose working worker's transcript went quiet (`WorkerQuietWatch`); `now` is what a quiet review (spec §K) is measured against.
    static func status(of run: UUID, state: AppState, sessions: [SessionInfo], revision: Int,
                       usage: [AgentKind: Int] = [:], turns: [UUID: WorkerTurnReader.Reading], quiet: Set<UUID> = [],
                       now: Date = Date()) -> RunStatus? {
        RunStatus.build(state: state, run: run, revision: revision,
                        live: liveFacts(of: run, state: state, sessions: sessions, turns: turns, quiet: quiet),
                        runLive: RunLiveFacts(weeklyUsage: usage), now: now)
    }

    /// What the tabs say of each of the run's tasks: each worker tab's live status (`WorkerTab`), and the prompt
    /// each waits on you with (the open question D14 records for it). While its first worker is idle or done, what that
    /// turn left (`turns`, spec §J): a working task whose turn is not read yet, or answered by `message_task` since, is
    /// `turnUnread`. A first worker at work whose task is in `quiet` has gone quiet (spec §H).
    static func liveFacts(of run: UUID, state: AppState, sessions: [SessionInfo],
                          turns: [UUID: WorkerTurnReader.Reading], quiet: Set<UUID> = []) -> [UUID: TaskLiveFacts] {
        let questions = state.run(id: run)?.questions ?? []
        var facts: [UUID: TaskLiveFacts] = [:]
        for task in state.tasks(inRun: run) {
            let open = questions.filter { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix(OperatorQuestion.promptPrefix) }
            let workers = task.workerTabs(in: sessions), tab = workers[0].session, prompt = open.first { $0.tab == nil }?.text
            let extra = workers.dropFirst().compactMap { worker in
                worker.key.map { key in
                    TaskLiveFacts.Tab(key: key, agent: worker.agent, model: worker.model, status: worker.session?.state,
                                      opening: worker.isOpening, closed: worker.isClosed, waitingPrompt: open.first { $0.tab == key }?.text)
                }
            }
            if tab != nil || prompt != nil || !extra.isEmpty {
                var live = TaskLiveFacts(status: tab?.state, waitingPrompt: prompt, tabs: Array(extra),
                                         background: workers.flatMap(\.background),
                                         yourPrompt: workers.lazy.compactMap { $0.session?.yourPrompt }.first,
                                         quiet: quiet.contains(task.id))
                if let tab, live.status == .idle || live.status == .done {
                    if let turn = turns[task.id], turn.session == tab.sessionId, !turn.messaged {
                        live.lastMessage = turn.lastMessage
                        live.commitsAhead = turn.commitsAhead
                        live.changedAfterAcceptance = turn.changedAfterAcceptance
                    } else {
                        live.turnUnread = task.operated?.state == .working
                    }
                }
                facts[task.id] = live
            }
        }
        return facts
    }

    /// The first line of the brief, whole, as the run's row names it until the person renames it: each
    /// place that shows it cuts it at its own width, the board's title wider than the sidebar's row.
    static func operationName(from brief: String) -> String {
        brief.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Operation"
    }

    /// Changes one run, saved like every workspace change. Nothing for a run that has gone.
    func mutateRun(_ id: UUID, _ change: (inout OperatorRun) -> Void) {
        workspace.mutate { state in
            guard let i = state.runs.firstIndex(where: { $0.id == id }) else { return }
            change(&state.runs[i])
        }
    }

    // -- starting workers -------------------------------------------------------------------
    /// The one start pass (spec §8, §11): what may start now — every task whose dependencies are satisfied,
    /// in every active operation, oldest first, with no cap — is claimed in one change, saved so the launch
    /// intents are on disk before any window is asked for, then launched. A pass that overlaps another — two
    /// tasks finishing at once, or one while a launch awaits its window — finds the other's claims taken, so
    /// no task is claimed twice. Nothing while no helper is attached: there is no window to ask for. Called
    /// from `runChanged(_:)` (a tool's change, a submitted plan, a block, a start ended, a resume, a hand
    /// back) and `reconcileTick()`.
    func startReadyTasks() {
        guard daemon() != nil else { return }
        let claimed = starter.claimReady()
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

    /// Something in the run changed: whatever may start now starts, a summary overdue is given up on, and a
    /// merge it was waiting for is watched again once it runs — your Resume, or its operator back from offline.
    func runChanged(_ id: UUID) {
        settle(id)
        giveUpOnSummary(id)
        notifyRequests(of: id)
        finisher.resumeWatching(inRun: id)
        startReadyTasks()
    }

    /// An operation whose every task has ended and with no question open is complete (spec §9): when is
    /// recorded, the operator is told — which asks it for its summary — and the wait for that summary begins.
    /// You are notified once the summary is written or given up on (`OperatorNotifier`). A later `submit_plan`
    /// makes it active again.
    func settle(_ id: UUID) {
        guard let run = run(id: id), run.state == .active, RunScheduler.isComplete(run, in: workspace.state) else { return }
        let now = ports.now()
        mutateRun(id) { $0.state = .complete; $0.completedAt = now }
        waker.say("broadcast complete", to: id)
        awaitSummary(id, completedAt: now)
    }

    /// Waits `OperatorTiming.summaryWait` for the summary of the completion at `completedAt`, then gives up on it
    /// if none came. A new completion's wait replaces the one before.
    private func awaitSummary(_ id: UUID, completedAt: Date) {
        summaryWaits[id]?.cancel()
        let sleep = ports.summarySleep
        let wait = Task { [weak self] in
            guard (try? await sleep(.seconds(OperatorTiming.summaryWait))) != nil, !Task.isCancelled, let self else { return }
            giveUpOnSummary(id, waited: completedAt)
            runChanged(id)
        }
        summaryWaits[id] = wait
        summaryWait = wait
    }

    /// AiTerm stops waiting for the Operator's summary (the Operator sheet spec, Summary): `summaryWait` after the
    /// run completed with none written — `waited` is a completion whose wait has ended — or at once when its window
    /// is gone (`windowGone`, or `.operatorOffline`). Saved, as the notification that follows is. A summary
    /// written later still replaces it. A run that completed before AiTerm recorded when starts its wait now.
    func giveUpOnSummary(_ id: UUID, waited: Date? = nil, windowGone: Bool = false) {
        guard let run = run(id: id), !run.hasEnded, run.summary == nil, !run.summaryGivenUp else { return }
        guard let completedAt = run.completedAt else {
            guard run.state == .complete else { return }
            let now = ports.now()
            mutateRun(id) { $0.completedAt = now }
            if windowGone { giveUpOnSummary(id, windowGone: true) } else { awaitSummary(id, completedAt: now) }
            return
        }
        let due = waited == completedAt || ports.now() >= completedAt.addingTimeInterval(OperatorTiming.summaryWait)
        guard due || windowGone || run.state == .operatorOffline else { return }
        mutateRun(id) { $0.summaryGivenUp = true }
        _ = workspace.flush()
    }

    // -- starting ---------------------------------------------------------------------------
    /// What a second New Broadcast is told while one runs (spec §3).
    static let oneBroadcast = "A broadcast is already running."

    /// Starts a broadcast (spec §3.1): refused while another is not ended. The run is saved with Settings ›
    /// Operator's profile frozen in it (`OperatorPorts.profile`), its folder written — `brief.md`, `mcp.json`,
    /// the token, `first-message.md` — the token registered with the helper, and the Operator's window opened
    /// in front with the broadcast as its first message, so it starts planning at once. The run is on disk
    /// before its window opens: a relaunch must know the window is its. Its name is `name`, or with none the
    /// prompt's first line; `jiraProjectKeys` and `projectIds` are New Broadcast's picks. Ended while it
    /// starts, it stays ended: its id is returned with no window of its own and its token revoked again.
    @discardableResult
    func startBroadcast(name: String?, jiraProjectKeys: [String], projectIds: [UUID], prompt: String, review: String?,
                        done: String?) async throws -> UUID {
        guard activeRun == nil else { throw ActionUnavailable(Self.oneBroadcast) }
        guard workspace.canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before starting a broadcast.") }
        guard OperatorCommand.said(prompt) != nil else { throw ActionUnavailable("Tell the Operator what to work on.") }
        let projects = projectIds.compactMap(workspace.state.project(id:))
        guard !projects.isEmpty, projects.count == projectIds.count else {
            throw ActionUnavailable("Choose the projects this broadcast may work in.")
        }
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        let readProfile = ports.profile
        let profile = await BackgroundWork.run {
            readProfile?() ?? OperatorProfileStore.load(claudeDefault: OperatorProfileStore.claudeDefault(models: []))
        }
        let run = OperatorRun(id: UUID(), name: OperatorCommand.said(name) ?? Self.operationName(from: prompt), profile: profile,
                              projectIds: projectIds, jiraProjectKeys: jiraProjectKeys, prompt: prompt,
                              review: OperatorCommand.said(review), done: OperatorCommand.said(done), createdAt: ports.now())
        let home = ports.home, milestone = ports.milestone
        // A fresh start: `prepare` makes the token and writes the first message the command reads.
        let prepared = try await BackgroundWork.run {
            try OperatorCommand.prepare(run: run, projects: projects, home: home, milestone: milestone)
        }
        // The workspace may have been locked while the folder was written, or another start got there first.
        guard workspace.canChangeWorkspace, activeRun == nil else {
            await discardToken(in: prepared.folder)
            throw ActionUnavailable(activeRun == nil ? "Save or recover the workspace before starting a broadcast." : Self.oneBroadcast)
        }
        workspace.mutate { $0.runs.append(run) }
        // Definite failures roll back; an uncertain window request keeps its tag and token for adoption.
        // An End that lands during an await stays the end: the token registered since goes again, the window
        // that arrives late is closed and never the run's, and nothing undoes the stop (`reopenOperatorWindow`
        // guards its late results the same way). Another broadcast may have started meanwhile.
        var registered = false
        do {
            guard workspace.flush() else { throw ActionUnavailable("The broadcast couldn’t be saved, so it didn’t start.") }
            ports.notifications.requestAuthorization()
            try await daemon.registerOperator(runId: run.id.uuidString, token: prepared.token)
            registered = true
            guard !hasEnded(run.id) else {
                await revokeAfterEnd(run.id, window: nil, daemon: daemon)
                return run.id
            }
            let window = try await daemon.createTaskWindow(taskId: run.id.uuidString, cwd: prepared.folder.path, title: run.name,
                                                           agentCommand: prepared.command, frame: taskFrame(), background: false)
            guard !hasEnded(run.id) else {
                await revokeAfterEnd(run.id, window: window, daemon: daemon)
                return run.id
            }
            mutateRun(run.id) { $0.operatorWindowId = window }
        } catch where hasEnded(run.id) {
            // Ended while its token registered or its window opened: the end stands, and what came after it goes.
            if registered { await revokeAfterEnd(run.id, window: nil, daemon: daemon) }
            return run.id
        } catch let error as DaemonError where registered && [.timeout, .disconnected, .itermUnavailable].contains(error.code) {
            mutateRun(run.id) { $0.state = .operatorOffline }
            _ = workspace.flush()
        } catch {
            workspace.mutate { $0.runs.removeAll { $0.id == run.id } }
            _ = workspace.flush()
            waker.forget(run.id)
            await discardToken(in: prepared.folder)
            if registered {
                await Log.daemon.attempt("Revoking the token of broadcast \(run.id.uuidString) that did not start") {
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
        await Log.workspace.attempt("Removing the token file of a broadcast that did not start") {
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
        let open = runs.filter { !$0.hasEnded }.map { ($0.id, folder(of: $0.id)) }
        // Runs you ended: a revocation that failed before is tried again while their token file is there.
        let ended = runs.filter { $0.intent == .stopped }.map { ($0.id, folder(of: $0.id)) }
        registering = Task {
            for (id, folder) in open {
                guard let token = await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) else { continue }
                await Log.daemon.attempt("Registering the token of broadcast \(id.uuidString)") {
                    try await daemon.registerOperator(runId: id.uuidString, token: token)
                }
            }
            for (id, folder) in ended {
                guard await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) != nil else { continue }
                await Log.daemon.attempt("Revoking the token of broadcast \(id.uuidString)") {
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
        stallWatch.observe(live.sessions, at: ports.now())
        turns.observe()
        quiet.observe()
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
        let held = starter.tabsListed(sessions)
        for id in closed { operatorWindowClosed(id) }
        recordWindowAnswers(sessions)
        observeRuns()
        probePrompts()
        for run in runs { waker.operatorSessionChanged(run.id) }
        // A retried task held back until its worker's window was listed: the retry goes to that worker now.
        if held { startReadyTasks() }
    }

    /// An answer typed in a worker's window instead of the Operator's chat (spec §I): while a prompt you typed into a task's
    /// worker is set (`SessionInfo.yourPrompt`, cleared when its turn ends), its first line goes onto each open `ask_you`
    /// question about that task, once per distinct prompt, so it is on the question after the prompt is gone. The question
    /// stays open: only the Operator's `resolve_question` closes it. AiTerm's own questions (`aitermPrefixes`) are not
    /// the Operator's to resolve this way.
    private func recordWindowAnswers(_ sessions: [SessionInfo]) {
        var typed: [UUID: String] = [:]
        for task in workspace.state.tasks where task.operated != nil {
            let prompt = task.workerTabs(in: sessions).lazy.compactMap { $0.session?.yourPrompt }.first
            if let line = prompt?.split(whereSeparator: \.isNewline).first.map(String.init) { typed[task.id] = line }
        }
        guard !typed.isEmpty else { return }
        let news = workspace.state.runs.flatMap { run in
            run.questions.compactMap { question in
                question.task.flatMap { typed[$0] }.flatMap { Self.takesWindowAnswer(question, $0) ? (run.id, question.id, $0) : nil }
            }
        }
        guard !news.isEmpty else { return }
        for (run, question, prompt) in news {
            mutateRun(run) { run in
                if let i = run.questions.firstIndex(where: { $0.id == question }) { run.questions[i].answeredInWindow = prompt }
            }
        }
    }

    /// Whether `prompt`, typed in the question's task's worker, is news for `question`: an open `ask_you` question the
    /// prompt is not already written on.
    private static func takesWindowAnswer(_ question: OperatorQuestion, _ prompt: String) -> Bool {
        question.task != nil && question.resolution == nil && question.answeredInWindow != prompt
            && !OperatorQuestion.aitermPrefixes.contains(where: question.id.hasPrefix)
    }

    /// The Operator's window closed (spec §9): it ends nothing. A broadcast under way goes offline at once,
    /// and a click on its row reopens the window and resumes it (`reopenOperator`). A complete one stays
    /// complete until End, and a click reopens its window as it is; a summary it had not written is not coming,
    /// so AiTerm stops waiting for it. A pause of yours stays a pause.
    private func operatorWindowClosed(_ id: UUID) {
        giveUpOnSummary(id, windowGone: true)
        guard let run = run(id: id), run.intent == nil, run.state == .planning || run.state == .active else { return }
        mutateRun(id) { $0.state = .operatorOffline }
    }

    // -- reconciling ------------------------------------------------------------------------
    /// The reconcile tick (spec §7.3): every `reconcileInterval` while AiTerm runs, and on the first
    /// connected snapshot after the helper attaches. What it changed is scheduled and settled, and
    /// whatever it freed or the helper's return allows to start starts — the way the tool paths do.
    func reconcileTick() {
        // The code hosts are read whether or not iTerm2's tabs are known: a wake waits for the Operator's tab.
        reviewWatcher.poll()
        // Time alone can make a review quiet (spec §K): what `run_status` would show is read again on every tick.
        observeRuns()
        // A summary overdue while AiTerm was not running, or whose wait went with it, is given up on here.
        for run in runs where run.state == .complete { giveUpOnSummary(run.id) }
        guard reconciler.synced else { return }
        for id in reconciler.tick() { runChanged(id) }
        applyStallFlags()
        quiet.refresh()
        branchWatch.poll()
        // A prompt whose tab left it without an event, or one an event raced.
        probePrompts()
        startReadyTasks()
    }

    /// On every reconcile tick (spec §8, *possibly stalled*): the tasks quiet for `stallAfter`, each on
    /// its own clock, are flagged and those that showed a sign since are cleared; each newly quiet one is
    /// probed for an open prompt without being given work — a prompt found open makes it *waiting on you*
    /// instead — and each operation's operator is woken once for its quiet tasks. Nothing is ever
    /// launched in place of a worker that may still be running.
    func applyStallFlags() {
        let now = ports.now()
        stallWatch.observe(live.sessions, at: now)
        stallWatch.settle(in: workspace.state, at: now)
        let changes = stallWatch.flagChanges(in: workspace.state, now: now)
        guard !changes.flag.isEmpty || !changes.clear.isEmpty else { return }
        workspace.mutate { StallWatch.apply(changes, to: &$0) }
        var quiet: [UUID: [String]] = [:]
        for id in changes.flag {
            probePrompt(id)
            guard let operated = workspace.state.task(id: id)?.operated else { continue }
            quiet[operated.runId, default: []].append(operated.key)
        }
        for (run, keys) in quiet { waker.say(keys.count == 1 ? "one task may be stalled" : "some tasks may be stalled", to: run) }
    }

    /// Starts the reconcile loop; AiTerm's `start()` calls it. The merges AiTerm was waiting for when it
    /// last quit are watched again.
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
        finisher.resumeWatching()
        tools.settleLostReviews()
    }

    // -- publishing -------------------------------------------------------------------------
    /// A watched merge ended — merged, blocked, or out of time: its operator is told, and the run is
    /// settled, so an operation's last merge completes it (spec §9).
    func publicationChanged(_ id: UUID) {
        guard let operated = workspace.state.task(id: id)?.operated else { return }
        waker.say(operated.state == .published ? "one task merged" : "one task can’t merge", to: operated.runId)
        runChanged(operated.runId)
    }

    /// A merge watch stopped for what it found — the branch moved, the task changed hands: its operator
    /// is told once, with the reason recorded on the task.
    func mergeWatchStopped(_ id: UUID, _ why: String) {
        guard let operated = workspace.state.task(id: id)?.operated else { return }
        waker.say("one task’s merge watch stopped", to: operated.runId, colon: true)
    }

    /// The host merged the task's request with a head nobody accepted (spec §6): only you can say how the
    /// operation goes on, so it is a question for you, asked once — as `ask_you` asks it — on the task.
    func askAboutMergeOnHost(_ id: UUID, _ why: String) {
        guard let operated = workspace.state.task(id: id)?.operated, let run = run(id: operated.runId) else { return }
        let key = OperatorQuestion.mergedOnHostPrefix + id.uuidString
        guard !run.questions.contains(where: { $0.id == key }) else { return }
        let question = OperatorQuestion(id: key, text: "\(why) AiTerm publishes nothing more of it or on top of it: decide how the broadcast goes on.",
                                        task: id, askedAt: ports.now(), resolution: nil)
        workspace.mutate { state in
            state.updateRun(id: run.id) { $0.questions.append(question) }
            state.updateOperated(id) { $0.flags.insert(.waitingOnYou) }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        finisher.stopAll()
    }

    /// Each operated task's tab, in any state (spec §H): one that needs input has its prompt read (spec §7.2), and a
    /// question left open for one whose tab has left the prompt is resolved. A task with no tab open has nothing to read.
    func probePrompts() {
        for task in workspace.state.tasks where task.operated != nil { probePrompt(task.id) }
    }

    /// A worker that waits on a prompt: recorded as a question waiting on you, on its task, saying what
    /// the prompt is, and you are notified with its window; once the tab leaves the prompt the question
    /// is resolved and the row stops waiting on you. Codex's update offer is declined instead (`dismissStartup`).
    /// Each worker tab of the task (`WorkerTab`) on its own: a prompt in an extra tab is its question, on that tab.
    func probePrompt(_ id: UUID) {
        guard let task = workspace.state.task(id: id) else { return }
        for worker in task.workerTabs(in: live.sessions) { probePrompt(id, worker) }
    }

    private func probePrompt(_ id: UUID, _ worker: WorkerTab) {
        guard let task = workspace.state.task(id: id), let operated = task.operated, let run = run(id: operated.runId) else { return }
        let prefix = "\(OperatorQuestion.promptPrefix)\(id.uuidString)-"
        let open = run.questions.first { $0.id.hasPrefix(prefix) && $0.tab == worker.key && $0.resolution == nil }
        let tab = worker.session
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
        guard open == nil, let tab, tab.state == .needsInput, !probing.contains(tab.sessionId), let daemon = daemon() else { return }
        probing.insert(tab.sessionId)
        lastProbe = Task { [weak self] in
            // The helper gone is not a prompt AiTerm can't read: nothing is recorded, and the next pass asks again.
            let kind: PromptKind?
            do { kind = try await daemon.prompt(sessionId: tab.sessionId) } catch {
                self?.probing.remove(tab.sessionId)
                return
            }
            // Codex's update offer is AiTerm's to decline (spec §7.1): the daemon sends Esc only when the
            // screen shows that dialog. Anything else at startup — a trust question — is yours, and so is
            // a dismissal that did not happen: only a dismissed offer is never put to you.
            let declined = kind == .startup ? (try? await daemon.dismissStartup(sessionId: tab.sessionId)) == true : false
            guard let self else { return }
            probing.remove(tab.sessionId)
            guard !declined else { return }
            // The tab may have left the prompt while it was read: nothing is asked of you then.
            guard live.sessions.contains(where: { $0.sessionId == tab.sessionId && $0.state == .needsInput }) else { return }
            let now = ports.now()
            workspace.mutate { state in
                // Numbered as it is recorded: another tab of the task may have recorded one while this was read.
                let number = (state.run(id: run.id)?.questions.filter { $0.id.hasPrefix(prefix) }.count ?? 0) + 1
                let question = OperatorQuestion(id: prefix + String(number), text: Self.promptText(kind, agent: worker.agent), task: id,
                                                askedAt: now, resolution: nil, tab: worker.key)
                state.updateRun(id: run.id) { $0.questions.append(question) }
                state.updateOperated(id) { $0.flags.insert(.waitingOnYou) }
            }
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
        for run in runs where !run.hasEnded {
            if let status = status(of: run) { waker.observe(status, of: run.id) }
        }
    }
}
