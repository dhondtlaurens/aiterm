import Foundation
import AiTermCore

/// Operator time, shared by reconciliation and publication. A wait's purpose lets fixtures control
/// one kind of wait without changing the others; the live clock sleeps identically for all of them.
struct OperatorClock: Sendable {
    enum Wait: Sendable, Equatable { case wake, summary, prompt, merge }

    var now: @Sendable () -> Date = { Date() }
    var sleep: @MainActor @Sendable (Wait, Duration) async throws -> Void = { _, duration in
        try await Task.sleep(for: duration)
    }
}

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
    /// How long `jira_search` waits for Jira before it answers that Jira didn't (`OperatorTiming.jiraSearchBudget`).
    var jiraSearchBudget: Duration = .seconds(OperatorTiming.jiraSearchBudget)
    /// The Oracle's runner.
    var secondOpinion: SecondOpinionRunner = .unavailable
    /// How long a challenged call waits for its critique before answering that it is still coming: well
    /// inside the daemon's `operatorRequestTimeout`, which the challenge's own limit is not.
    var challengeReplyBudget: Duration = .seconds(20)
    var clock = OperatorClock()
    var now: @Sendable () -> Date { clock.now }
    /// The version of AiTerm that is running, for the snags the Operator reports: "dev" for a build with none.
    var appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// How long a burst of changes is gathered into one wake line.
    var wakeCoalesce: Duration = .seconds(OperatorTiming.wakeCoalesce)
    /// How often the run reconciler looks at the real tabs.
    var reconcileInterval: Duration = .seconds(OperatorTiming.reconcileInterval)
    /// The code host a project's requests are published on, with the connections Settings saved (G10):
    /// `remote` is origin's, the repository the push goes to. The tokens stay in the clients.
    var publisher: @Sendable (RemoteInfo) throws -> any MergeRequestPublishing = { remote in
        try MergeRequestPublisher.publisher(for: remote, gitLab: GitLabSettings.load(), gitHub: GitHubSettings.load())
    }
    /// How long the host's view of a task's request is waited for (`OperatorTiming.hostReadTimeout`) and kept (`hostReadCache`):
    /// what `run_status` and `read_task` show of each request.
    var hostTimeout: Duration = .seconds(OperatorTiming.hostReadTimeout)
    var hostCache: TimeInterval = OperatorTiming.hostReadCache
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
    /// The preferences Settings keeps: where each start saves its Agents rows as the last broadcast's
    /// (`OperatorProfileStore.lastAgents`), and where New Broadcast reads them and Settings › Agents' defaults. Nil is
    /// `UserDefaults.standard`, which `AppController` replaces with the app's own preferences.
    var preferences: UserDefaults?

    @MainActor static func live(home: URL, git: any GitRunning, jiraSettings: @escaping @Sendable () -> JiraConfig?,
                                claudeConfig: ClaudeConfig = ClaudeConfig()) -> OperatorPorts {
        OperatorPorts(home: home, claudeConfig: claudeConfig, git: git, notifications: LiveOperatorNotifications(),
                      jira: { jiraSettings().map { JiraClient(config: $0) } }, secondOpinion: .live)
    }
}

/// Every broadcast: its start, its operator's tab and token, and the services that answer the
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
    @ObservationIgnored let prompts: WorkerPrompts
    /// Where the workers' and the Operator's conversations are, shared by every reader of them.
    @ObservationIgnored let transcripts: TranscriptLocator
    @ObservationIgnored private var loop: PollLoop?
    @ObservationIgnored private var isStopped = false
    /// An attach whose first connected snapshot is still to come: it reconciles and sets ownership again.
    @ObservationIgnored private var reattached = false
    /// When each working task last showed a sign of life (spec §8, *possibly stalled*): any change the
    /// daemon reports for one of its tabs — status, title, context, conversation — and, on each tab's own clock, its
    /// transcript's growth or a tool call it still runs (`WorkerQuietWatch.sign`).
    @ObservationIgnored private var stallWatch = StallWatch()
    /// The ownership being set again on a new daemon's tabs (`resendOwnership`), for a test to await; `stop()` cancels it.
    @ObservationIgnored private(set) var resending: Task<Void, Never>?
    /// The latest start a pass made, for a test to await.
    @ObservationIgnored private(set) var lastStart: Task<Void, Never>?
    /// Each complete broadcast's wait for its summary, by run, while it waits: one per completion.
    @ObservationIgnored private(set) var summaryWaits: [UUID: Task<Void, Never>] = [:]
    /// The latest wait for a summary, for a test to await.
    @ObservationIgnored private(set) var summaryWait: Task<Void, Never>?
    /// The broadcast whose board a notification's click asked for (spec §10.3): the sidebar presents
    /// it and sets this back to nil. Observed, so the click reaches a sidebar already on screen.
    var presentBoard: UUID?
    /// The broadcasts whose Operator's window could not be reopened behind the board, its conversation
    /// gone (spec §13): the board's footer says so and offers Start Fresh. Cleared by a reopening that
    /// opens one, and by Start Fresh. Observed, so the board open in front of it changes at once.
    var reopenFailed: Set<UUID> = []
    /// The Operator's wake line refused for anything but a prompt waiting on you: the sidebar's Notice. Taken
    /// down once the Operator calls `run_status`, a later wake line is delivered, or its broadcast is forgotten.
    var wakeNotice: OperatorWakeNotice?
    /// The broadcasts whose operator window is being opened now (`reopenOperatorWindow`, D16): a second
    /// click on the row meanwhile opens no second operator.
    @ObservationIgnored var reopeningOperator: Set<UUID> = []
    /// When each broadcast's operator window was last opened by `reopenOperatorWindow`, until its tab is
    /// listed: a click in the gap before iTerm2 lists it (or past `launchAdoptAfter`) opens no second one.
    @ObservationIgnored var reopenedOperator: [UUID: Date] = [:]
    /// The latest close of ended broadcasts' operator windows after an attach, for a test to await.
    @ObservationIgnored var closingEnded: Task<Void, Never>?
    /// The latest re-registration of the runs' tokens, for a test to await.
    @ObservationIgnored private(set) var registering: Task<Void, Never>?
    /// Whether `live.sessions` is iTerm2's whole list — a connected snapshot has come since the helper
    /// attached and iTerm2 has not gone — so a tab missing from it is a tab closed.
    @ObservationIgnored private(set) var tabsKnown = false
    /// The Operator's acts AiTerm is carrying out now, in the order each began: a tool call in flight, the
    /// Oracle consulted, a worker starting or its window reopening. The status lines say them (`acting`), read by the rows'
    /// projection when `changed()` says so, never by a view: not observed.
    @ObservationIgnored private(set) var activities: [OperatorActivity] = [] { didSet { if activities != oldValue { changed() } } }
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
            if let ending = WorkerTurn.ending(lastMessage: reading.lastMessage, commitsAhead: reading.commitsAhead,
                                             atReopenedCommit: reading.atReopenedCommit) { acts.turns[task] = ending }
        }
        for (task, readings) in turns.extraReadings {
            if readings.values.contains(where: { !$0.messaged && WorkerTurn.ending(lastMessage: $0.lastMessage, commitsAhead: $0.commitsAhead) == .asks }) {
                acts.turns[task] = .asks
            }
        }
        return acts
    }
    /// How many lines each run's activity log has been written since this launch: the Operator sheet watches it to
    /// read the file again (`activityGeneration(of:)`).
    private var activityWritten: [UUID: Int] = [:]
    /// Changes after each line of the run's activity log lands. Observed.
    func activityGeneration(of run: UUID) -> Int { activityWritten[run, default: 0] }
    @ObservationIgnored private var changeHooks: [@MainActor () -> Void] = []
    /// Told after each change to a run has been settled (`runChanged`), with its id.
    @ObservationIgnored var onRunChanged: @MainActor (UUID) -> Void = { _ in }
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
        prompts = WorkerPrompts(workspace: workspace, live: live, ports: ports, daemon: daemon)
        notifier = OperatorNotifier(notifications: ports.notifications, state: { [workspace] in workspace.state })
        let clock = ports.clock
        waker = OperatorWaker(daemon: daemon,
                              session: { [live] run in Self.operatorTab(of: run, in: live.sessions) },
                              awake: { [workspace] run in
                                  guard let state = workspace.state.run(id: run)?.state else { return false }
                                  return state == .planning || state == .active || state == .complete
                              },
                              coalesce: ports.wakeCoalesce, sleep: { try await clock.sleep(.wake, $0) }, now: clock.now)
        tabs = TabOpener(workspace: workspace, daemon: daemon, ports: ports)
        let transcripts = TranscriptLocator(home: ports.home, claudeConfig: ports.claudeConfig)
        self.transcripts = transcripts
        tools = OperatorToolHandler(workspace: workspace, live: live, daemon: daemon, ports: ports, waker: waker, tabs: tabs,
                                    transcripts: transcripts)
        NotificationCenter.default.addObserver(forName: OperatorProfileStore.didSave, object: nil, queue: .main) { [weak tools] _ in
            MainActor.assumeIsolated { tools?.refreshOracleSettings() }
        }
        starter = WorkerStarter(workspace: workspace, live: live, daemon: daemon, taskFrame: taskFrame, ports: ports)
        // It captures nothing of `self`: its callbacks are installed once every stored property is set.
        finisher = TaskFinisher(store: workspace, git: ports.git, connect: ports.publisher, now: clock.now,
                                sleep: { try await clock.sleep(.merge, .seconds($0)) })
        reconciler = RunReconciler(workspace: workspace, live: live, starter: starter, tabs: tabs, waker: waker, ports: ports)
        reviewWatcher = ReviewWatcher(workspace: workspace, ports: ports, waker: waker)
        branchWatch = BranchWatch(workspace: workspace, live: live, ports: ports, waker: waker, transcripts: transcripts)
        turns = WorkerTurnReader(workspace: workspace, live: live, ports: ports, transcripts: transcripts)
        quiet = WorkerQuietWatch(workspace: workspace, live: live, ports: ports, transcripts: transcripts)
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
        // A transcript that grew, or a call still running, is a sign of life on its own tab's clock (spec §8).
        quiet.sign = { [weak self] task, tab, at in self?.stallWatch.noteSign(of: task, tab: tab, at: at) }
        waker.refused = { [weak self] run, delivery in
            guard let self else { return }
            wakeNotice = OperatorWakeNotice(run: run, status: self.run(id: run).flatMap(status(of:)), refusal: delivery, held: true)
        }
        waker.cleared = { [weak self] run in
            if self?.wakeNotice?.run == run { self?.wakeNotice = nil }
        }
        reconciler.tabsKnown = { [weak self] in self?.tabsKnown ?? false }
        prompts.tabsKnown = { [weak self] in self?.tabsKnown ?? false }
        prompts.changed = { [weak self] in self?.runChanged($0) }
        reconciler.waitsForProgress = { [weak self] task in
            task.operated?.runtimeHead != nil && self?.branchWatch.isWatched(task) == true
        }
        branchWatch.checked = { [weak self] task in
            guard let self else { return }
            for id in reconciler.checkLimits(for: task) { runChanged(id) }
        }
        tools.onActing = { [weak self] activity, on in self?.setActing(activity, on) }
        starter.onActing = { [weak self] activity, on in self?.setActing(activity, on) }
        tools.onChange = { [weak self] in self?.runChanged($0) }
        tools.onActivity = { [weak self] run in self?.activityWritten[run, default: 0] += 1 }
        tools.turnReadings = { [weak self] in self?.turns.readings ?? [:] }
        tools.extraTurnReadings = { [weak self] in self?.turns.extraReadings ?? [:] }
        tools.quietTasks = { [weak self] in self?.quiet.quiet ?? [] }
        tools.onMessaged = { [weak self] task, tab in self?.turns.messaged(task, tab: tab) }
        tools.onMessageResult = { [weak self] task, tab in
            // Reading a screen must not delay the delivery result or its replay cache.
            self?.prompts.afterMessage(task, tab: tab)
        }
        starter.onUncertain = { [weak self] task in
            guard let operated = task.operated else { return }
            self?.waker.say("one task is uncertain, no worker confirmed in its window", to: operated.runId)
        }
        starter.onBlocked = { [weak self] task in
            guard let self, let runId = task.operated?.runId else { return }
            runChanged(runId)
        }
        finisher.changed = { [weak self] id in self?.publicationChanged(id) }
        finisher.mergedOnHost = { [weak self] id, why in self?.askAboutMergeOnHost(id, why) }
        finisher.watchStopped = { [weak self] id, _ in self?.mergeWatchStopped(id) }
        tools.finish = { [weak self] id, noVerify in
            guard let self else { return TaskFinisher.Result(result: .refused, reason: "AiTerm is closing.") }
            return await self.finisher.finish(id, noVerify: noVerify)
        }
        notices.onIssueChanged { [weak self] old, new in self?.bannerChanged(from: old, to: new) }
    }

    /// Adds `handler` to what hears that what the Operator is doing changed (`acting`: its acts, what its workers'
    /// turns left): the UI's board and rows. A change to a run or a task is the workspace's own news (`onChange`),
    /// which they hear already.
    func onChange(_ handler: @escaping @MainActor () -> Void) { changeHooks.append(handler) }

    /// A workspace change that touched the runs or the operated tasks: a run no longer paused has its held news
    /// delivered, and what needs you is posted or withdrawn.
    private func heardWorkspace() {
        guard !isStopped else { return }
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
                    usage: SidebarModel.weeklyUsage(live.usage, now: ports.now()), turns: turns.readings, extraTurns: turns.extraReadings, quiet: quiet.quiet, now: ports.now())
    }

    /// `run_status`'s snapshot: the run from the workspace, each task's live facts from its worker's tab and what its
    /// worker's last ended turn left (`WorkerTurnReader.readings`). `usage` is each agent's weekly percent
    /// (`SidebarModel.weeklyUsage`). `quiet` is the tasks whose working worker's transcript went quiet (`WorkerQuietWatch`); `now` is what a quiet review (spec §K) is measured against.
    static func status(of run: UUID, state: AppState, sessions: [SessionInfo], revision: Int,
                       usage: [AgentKind: Int] = [:], turns: [UUID: WorkerTurnReader.Reading],
                       extraTurns: [UUID: [String: WorkerTurnReader.Reading]] = [:], quiet: Set<UUID> = [],
                       now: Date = Date()) -> RunStatus? {
        RunStatus.build(state: state, run: run, revision: revision,
                        live: liveFacts(of: run, state: state, sessions: sessions, turns: turns, extraTurns: extraTurns, quiet: quiet, now: now),
                        runLive: RunLiveFacts(weeklyUsage: usage), now: now)
    }

    /// What the tabs say of each of the run's tasks: each worker tab's live status (`WorkerTab`), and the prompt
    /// each waits on you with (the open question D14 records for it). While its first worker is idle or done, what that
    /// turn left (`turns`, spec §J): a task whose turn is not read yet, read again after it was accepted again or reopened,
    /// or answered by `message_task` since, is `turnUnread`. A first worker at work whose task is in `quiet` has gone quiet (spec §H).
    /// A worker an API error stopped says why (`StoppedOn.reason`), a limit's reset as of `now`. A first worker whose launch is
    /// under way as of `now` and that has named no conversation yet is opening (`TaskItem.workerTabs(in:now:)`): at work,
    /// its turn not ended.
    static func liveFacts(of run: UUID, state: AppState, sessions: [SessionInfo],
                          turns: [UUID: WorkerTurnReader.Reading], extraTurns: [UUID: [String: WorkerTurnReader.Reading]] = [:],
                          quiet: Set<UUID> = [], now: Date = Date()) -> [UUID: TaskLiveFacts] {
        let questions = state.run(id: run)?.questions ?? []
        var facts: [UUID: TaskLiveFacts] = [:]
        let workersByTask = WorkerSessions(sessions)
        for task in state.tasks(inRun: run) {
            let open = questions.filter { $0.task == task.id && $0.resolution == nil && $0.id.hasPrefix(OperatorQuestion.promptPrefix) }
            let workers = task.workerTabs(in: workersByTask, now: now), tab = workers[0].session, prompt = open.first { $0.tab == nil }?.text
            let extra = workers.dropFirst().compactMap { worker in
                worker.key.map { key in
                    let prompt = open.first { $0.tab == key }?.text
                    let reading = extraTurns[task.id]?[key]
                    let ended = worker.status?.turnEnded == true
                    let read = reading.flatMap { $0.session == worker.session?.sessionId && !$0.messaged ? $0 : nil }
                    return TaskLiveFacts.Tab(key: key, agent: worker.agent, model: worker.model,
                                             status: prompt == nil || worker.session == nil ? worker.session?.state : .needsInput,
                                             opening: worker.isOpening, closed: worker.isClosed, waitingPrompt: prompt,
                                             liveModel: worker.session?.liveModel, liveReasoning: worker.session?.liveReasoning,
                                             slashCommands: worker.session?.slashCommands ?? [],
                                             lastMessage: ended ? read?.lastMessage : nil, turnUnread: ended && read == nil)
                }
            }
            if tab != nil || prompt != nil || !extra.isEmpty || workers[0].isOpening {
                var live = TaskLiveFacts(status: prompt == nil || tab == nil ? tab?.state : .needsInput, waitingPrompt: prompt, tabs: Array(extra),
                                         background: workers.flatMap(\.background),
                                         yourPrompt: workers.lazy.compactMap { $0.session?.yourPrompt }.first,
                                         quiet: prompt == nil && quiet.contains(task.id), liveModel: tab?.liveModel,
                                         liveReasoning: tab?.liveReasoning, slashCommands: tab?.slashCommands ?? [],
                                         stoppedOn: workers.lazy.compactMap { $0.session?.stoppedOn }.first?.reason(now: now),
                                         opening: workers[0].isOpening, testActivities: workers.compactMap { $0.session?.testActivity })
                if let tab, !live.opening, live.status?.turnEnded == true {
                    if let turn = turns[task.id], turn.session == tab.sessionId, !turn.messaged {
                        live.lastMessage = turn.lastMessage
                        live.commitsAhead = turn.commitsAhead
                        live.atReopenedCommit = turn.atReopenedCommit
                        live.changedAfterAcceptance = turn.changedAfterAcceptance
                    } else {
                        live.turnUnread = true
                    }
                }
                // Git belongs to the shared checkout. A newer extra-worker result supersedes
                // an idle main worker's old count and changed-after-acceptance reading.
                let completed = workers.compactMap { worker -> WorkerTurnReader.Reading? in
                    guard worker.status?.turnEnded == true else { return nil }
                    let reading = worker.key.flatMap { extraTurns[task.id]?[$0] } ?? (worker.key == nil ? turns[task.id] : nil)
                    guard let reading, !reading.messaged, reading.session == worker.session?.sessionId else { return nil }
                    return reading
                }
                if let newest = completed.max(by: { $0.observedOrder < $1.observedOrder }) {
                    live.commitsAhead = newest.commitsAhead
                    live.atReopenedCommit = newest.atReopenedCommit
                    live.changedAfterAcceptance = newest.changedAfterAcceptance
                }
                facts[task.id] = live
            }
        }
        return facts
    }

    /// The first line of the brief, whole, as the run's row names it until the person renames it: each
    /// place that shows it cuts it at its own width, the board's title wider than the sidebar's row. Nil for a
    /// brief with nothing in it.
    static func broadcastName(from brief: String) -> String? {
        brief.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
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
    /// in every active broadcast, oldest first, with no cap — is claimed in one change, saved so the launch
    /// intents are on disk before any window is asked for, then launched. A pass that overlaps another — two
    /// tasks finishing at once, or one while a launch awaits its window — finds the other's claims taken, so
    /// no task is claimed twice. Nothing while no helper is attached: there is no window to ask for. Called
    /// from `runChanged(_:)` (a tool's change, a submitted plan, a block, a start ended, a resume, a hand
    /// back) and `reconcileTick()`.
    func startReadyTasks() {
        guard !isStopped, daemon() != nil else { return }
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
    /// Then `onRunChanged` is told.
    func runChanged(_ id: UUID) {
        guard !isStopped else { return }
        settle(id)
        giveUpOnSummary(id)
        notifyRequests(of: id)
        finisher.resumeWatching(inRun: id)
        startReadyTasks()
        onRunChanged(id)
    }

    /// A broadcast whose every task has ended and with no question open is complete (spec §9): when is
    /// recorded, the operator is told — which asks it for its summary — and the wait for that summary begins.
    /// You are notified once the summary is written or given up on (`OperatorNotifier`). A later `submit_plan`
    /// makes it active again. One with a goal not yet resolved completes only once `check_goal` resolves it: until
    /// then it stays active, with `goalCheckDue` set while a check is due (`BroadcastCompletion.goalCheckIsDue`), and
    /// the operator is woken for it.
    func settle(_ id: UUID) {
        guard let run = run(id: id), run.state == .active else { return }
        let due = BroadcastCompletion.goalCheckIsDue(run, in: workspace.state)
        if due != run.goalCheckDue {
            mutateRun(id) { $0.goalCheckDue = due }
            if due { waker.say(Self.goalCheckReason, to: id) }
        }
        guard BroadcastCompletion.isComplete(run, in: workspace.state) else { return }
        let now = ports.now()
        mutateRun(id) { $0.state = .complete; $0.completedAt = now }
        waker.say("broadcast complete", to: id)
        awaitSummary(id, completedAt: now)
    }

    /// What wakes the operator once a goal check is due.
    static let goalCheckReason = "every task is done: check the goal with check_goal"

    /// Tells the operator `reconnected`, in one line with a goal check still due, which the restart or its time offline may
    /// have lost the wake of.
    private func sayReconnected(_ id: UUID) {
        waker.say(run(id: id)?.goalCheckDue == true ? "reconnected, and \(Self.goalCheckReason)" : "reconnected", to: id)
    }

    /// Waits `OperatorTiming.summaryWait` for the summary of the completion at `completedAt`, then gives up on it
    /// if none came. A new completion's wait replaces the one before.
    private func awaitSummary(_ id: UUID, completedAt: Date) {
        summaryWaits[id]?.cancel()
        let clock = ports.clock
        let wait = Task { [weak self] in
            guard (try? await clock.sleep(.summary, .seconds(OperatorTiming.summaryWait))) != nil, !Task.isCancelled, let self else { return }
            // Not cancelled, so still this completion's wait: a later one cancels it.
            summaryWaits[id] = nil
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
    /// True when it gave up: a caller outside `runChanged` then goes through it, so `onRunChanged` hears of it.
    @discardableResult
    func giveUpOnSummary(_ id: UUID, waited: Date? = nil, windowGone: Bool = false) -> Bool {
        guard let run = run(id: id), !run.hasEnded, run.summary == nil, !run.summaryGivenUp else { return false }
        guard let completedAt = run.completedAt else {
            guard run.state == .complete else { return false }
            let now = ports.now()
            mutateRun(id) { $0.completedAt = now }
            if windowGone { return giveUpOnSummary(id, windowGone: true) }
            awaitSummary(id, completedAt: now)
            return false
        }
        let due = waited == completedAt || ports.now() >= completedAt.addingTimeInterval(OperatorTiming.summaryWait)
        guard due || windowGone || run.state == .operatorOffline else { return false }
        mutateRun(id) { $0.summaryGivenUp = true }
        _ = workspace.flush()
        return true
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
    /// `agents`, `taskSettings` and `goal` are the Agents, Task and Done steps, frozen in the run as the profile is, the
    /// goal's words trimmed; with `taskSettings` the run has no Review or Done text, and with the Oracle off no goal, which
    /// needs it. Its rows are saved as the last broadcast's. Without `taskSettings` it is started as before those steps:
    /// no rows and no goal, whatever was given.
    @discardableResult
    func startBroadcast(name: String?, jiraProjectKeys: [String], projectIds: [UUID], prompt: String,
                        agents: [AgentChoice], taskSettings: TaskSettings,
                        goal: BroadcastGoal? = nil) async throws -> UUID {
        guard activeRun == nil else { throw ActionUnavailable(Self.oneBroadcast) }
        guard workspace.canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before starting a broadcast.") }
        guard let firstLine = Self.broadcastName(from: prompt) else { throw ActionUnavailable("Tell the Operator what to work on.") }
        let projects = projectIds.compactMap(workspace.state.project(id:))
        guard !projects.isEmpty, projects.count == projectIds.count else {
            throw ActionUnavailable("Choose the projects this broadcast may work in.")
        }
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        let readProfile = ports.profile
        let profile = await BackgroundWork.run {
            readProfile?() ?? OperatorProfileStore.load(claudeDefault: OperatorProfileStore.claudeDefault(models: []))
        }
        let goal = goal.flatMap { goal in
            OperatorCommand.said(goal.text).map { BroadcastGoal(text: $0, extraRounds: goal.extraRounds) }
        }
        let run = OperatorRun(id: UUID(), name: OperatorCommand.said(name) ?? firstLine, profile: profile,
                              projectIds: projectIds, jiraProjectKeys: jiraProjectKeys, prompt: prompt,
                              createdAt: ports.now(), agents: agents, taskSettings: taskSettings,
                              goal: !profile.oracle.isOn ? nil : goal)
        let home = ports.home, claudeConfig = ports.claudeConfig
        // A fresh start: `prepare` makes the token and writes the first message the command reads.
        let prepared = try await BackgroundWork.run {
            try OperatorCommand.prepare(run: run, projects: projects, home: home, claudeConfig: claudeConfig)
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
            if !agents.isEmpty {
                Log.workspace.attempt("Saving the broadcast’s Agents rows as the last broadcast’s") {
                    try OperatorProfileStore.saveLastAgents(agents, ports.preferences ?? .standard)
                }
            }
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
        guard !isStopped else { return }
        switch event {
        case .snapshot(let snapshot):
            tabsKnown = snapshot.connected
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
            // iTerm2 back with the helper still there: its tabs are looked at on the next snapshot, as after an attach.
            reattached = true
        case .sessionOpened, .sessionChanged, .sessionClosed, .windowClosed: sessionsChanged()
        case .operatorRequest(let request): tools.handle(request)
        default: break
        }
    }

    /// A daemon attached — after AiTerm's launch, or the daemon's restart, which forgets the tokens:
    /// every run's token is registered again but a stopped run's (a revoke that failed is tried again), and each operator that may be woken
    /// is told `reconnected` (spec §11), and that its goal is to check when a check is due.
    func daemonAttached() {
        guard !isStopped else { return }
        // A new daemon's tabs are known once its first connected snapshot comes.
        tabsKnown = false
        guard let daemon = daemon() else { return }
        reattached = true
        let open = runs.filter { !$0.hasEnded }.map { ($0.id, folder(of: $0.id)) }
        // Runs you ended: a revocation that failed before is tried again while their token file is there.
        let ended = runs.filter { $0.intent == .stopped }.map { ($0.id, folder(of: $0.id)) }
        registering = Task {
            for (id, folder) in open {
                guard let token = await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) else { continue }
                guard !Task.isCancelled else { return }
                await Log.daemon.attempt("Registering the token of broadcast \(id.uuidString)") {
                    try await daemon.registerOperator(runId: id.uuidString, token: token)
                }
            }
            for (id, folder) in ended {
                guard await BackgroundWork.run({ OperatorCommand.existingToken(in: folder) }) != nil else { continue }
                guard !Task.isCancelled else { return }
                await Log.daemon.attempt("Revoking the token of broadcast \(id.uuidString)") {
                    try await daemon.revokeOperator(runId: id.uuidString)
                }
            }
        }
        for (id, _) in open {
            sayReconnected(id)
            // News that was waiting before the daemon went is tried again now.
            waker.operatorSessionChanged(id)
        }
    }

    /// Each run's operator tab as the helper reports it — its session, its window, and the
    /// conversation a resume continues — then whatever the tabs changed in what `run_status` shows.
    /// A tab seen before and missing from iTerm2's whole list is a window closed: the run forgets it.
    private func sessionsChanged() {
        guard !isStopped else { return }
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
        if giveUpOnSummary(id, windowGone: true) { runChanged(id) }
        guard let run = run(id: id), run.intent == nil, run.state == .planning || run.state == .active else { return }
        mutateRun(id) { $0.state = .operatorOffline }
    }

    // -- reconciling ------------------------------------------------------------------------
    /// The reconcile tick (spec §7.3): every `reconcileInterval` while AiTerm runs, and on the first
    /// connected snapshot after the helper attaches. What it changed is scheduled and settled, and
    /// whatever it freed or the helper's return allows to start starts — the way the tool paths do.
    func reconcileTick() {
        guard !isStopped else { return }
        tools.refreshOracleSettings()
        // The code hosts are read whether or not iTerm2's tabs are known: a wake waits for the Operator's tab.
        reviewWatcher.poll()
        // Time alone can make a review quiet (spec §K): what `run_status` would show is read again on every tick.
        observeRuns()
        // A summary overdue while AiTerm was not running, or whose wait went with it, is given up on here.
        for run in runs where run.state == .complete {
            if giveUpOnSummary(run.id) { runChanged(run.id) }
        }
        guard tabsKnown else { return }
        let offline = Set(runs.filter { $0.state == .operatorOffline }.map(\.id))
        for id in reconciler.tick() {
            runChanged(id)
            // Its Operator back from offline, told `reconnected` already: a goal check still due goes in the same line.
            if offline.contains(id), run(id: id)?.state == .active { sayReconnected(id) }
        }
        applyStallFlags()
        quiet.refresh()
        // A first worker whose launch is over, still idle, has its turn read now (`TaskItem.workerTabs(in:now:)`).
        turns.observe()
        branchWatch.poll()
        // A prompt whose tab left it without an event, or a menu no hook announced.
        probePrompts(.reconcile)
        startReadyTasks()
    }

    /// On every reconcile tick (spec §8, *possibly stalled*): the tasks quiet for `stallAfter`, each on
    /// its own clock, are flagged and those that showed a sign since are cleared; each newly quiet one is
    /// probed for an open prompt without being given work — a prompt found open makes it *waiting on you*
    /// instead — and each broadcast's operator is woken once for its quiet tasks. Nothing is ever
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
            probePrompt(id, source: .reconcile)
            guard let operated = workspace.state.task(id: id)?.operated else { continue }
            quiet[operated.runId, default: []].append(operated.key)
        }
        for (run, keys) in quiet { waker.say(keys.count == 1 ? "one task may be stalled" : "some tasks may be stalled", to: run) }
    }

    /// Starts the reconcile loop; AiTerm's `start()` calls it. The merges AiTerm was waiting for when it
    /// last quit are watched again.
    func start() {
        guard loop == nil else { return }
        isStopped = false
        prompts.start()
        waker.start()
        starter.start()
        tabs.start()
        finisher.start()
        let interval = ports.reconcileInterval
        loop = PollLoop(interval: interval, sleepFirst: true) { [weak self] in
            // A sleep that ended just as stop ran must not tick after it.
            guard !Task.isCancelled, let self else { return nil }
            reconcileTick()
            return interval
        }
        finisher.resumeWatching()
    }

    // -- publishing -------------------------------------------------------------------------
    /// A watched merge ended — merged, blocked, or out of time: its operator is told, and the run is
    /// settled, so a broadcast's last merge completes it (spec §9).
    func publicationChanged(_ id: UUID) {
        guard let operated = workspace.state.task(id: id)?.operated else { return }
        waker.say(operated.state == .published ? "one task merged" : "one task can’t merge", to: operated.runId)
        runChanged(operated.runId)
    }

    /// A merge watch stopped for what it found — the branch moved, the task changed hands: its operator
    /// is told once, with the reason recorded on the task.
    func mergeWatchStopped(_ id: UUID) {
        guard let operated = workspace.state.task(id: id)?.operated else { return }
        waker.say("one task’s merge watch stopped", to: operated.runId, colon: true)
    }

    /// The host merged the task's request with a head nobody accepted (spec §6): only you can say how the
    /// broadcast goes on, so it is a question for you, asked once — as `ask_you` asks it — on the task.
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

    /// Ends the runtime's polling, transcript reads, prompt probes, wake/summary timers, registration,
    /// merge watches and Oracle checks. Late callbacks cannot start another scheduling pass.
    func stop() {
        isStopped = true
        starter.stop()
        tabs.stop()
        loop?.cancel()
        loop = nil
        resending?.cancel()
        resending = nil
        registering?.cancel()
        registering = nil
        for wait in summaryWaits.values { wait.cancel() }
        summaryWaits = [:]
        summaryWait = nil
        prompts.stop()
        turns.stop()
        quiet.stop()
        branchWatch.stop()
        reviewWatcher.stop()
        waker.stop()
        finisher.stopAll()
        tools.cancelHostReads()
        tools.cancelChallenges()
    }

    typealias PromptProbe = WorkerPrompts.Source
    var lastProbe: Task<Void, Never>? { prompts.lastProbe }
    func probePrompts(_ source: PromptProbe = .event) { prompts.observe(source) }
    func probePrompt(_ id: UUID, source: PromptProbe = .event) { prompts.probePrompt(id, source: source) }
    static func promptText(_ kind: PromptKind?, agent: AgentKind) -> String { WorkerPrompts.promptText(kind, agent: agent) }

    /// The daemon keeps ownership generations in memory only (part A): after its restart each operated
    /// task's is set again on its tabs.
    func resendOwnership() {
        guard let daemon = daemon() else { return }
        let owned = workspace.state.tasks.compactMap { task in task.operated.map { (task.id, $0.ownership) } }
        let sessions = live.sessions
        resending?.cancel()
        resending = Task {
            for (id, ownership) in owned {
                for tab in sessions where tab.taskUUID == id {
                    guard !Task.isCancelled else { return }
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
