import Foundation

/// What AiTerm knows of a task's session beyond `state.json`: its live status, its tabs, a prompt
/// waiting on you, and what its last turn left. Gathered by the caller from the daemon snapshot and
/// git; `RunStatus` only arranges it.
public struct TaskLiveFacts: Equatable, Sendable {
    /// An extra worker tab the Operator added (`open_tab`), as `WorkerTab` counts it.
    public struct Tab: Equatable, Sendable {
        public var key: String, agent: AgentKind, model: String
        /// Its tab's live status; nil while none is listed.
        public var status: SessionState?
        /// Asked for, its agent not shown yet (`WorkerTab.isOpening`): at work.
        public var opening: Bool
        /// Opened and listed no more (`WorkerTab.isClosed`): never opened again.
        public var closed: Bool
        /// The prompt it waits on you with, if any.
        public var waitingPrompt: String?
        /// The model and effort it runs now, and what became of the slash commands sent to it: `TaskLiveFacts`'s, for this tab.
        public var liveModel: String?, liveReasoning: String?
        public var slashCommands: [SlashCommand]
        public var lastMessage: String?
        public var turnUnread: Bool
        /// Its session says working but its transcript went quiet, as `TaskLiveFacts.quiet` says of the first worker: its line
        /// reads `working?` and its task is uncertain.
        public var quiet: Bool
        public init(key: String, agent: AgentKind, model: String, status: SessionState? = nil, opening: Bool = false, closed: Bool = false,
                    waitingPrompt: String? = nil, liveModel: String? = nil, liveReasoning: String? = nil, slashCommands: [SlashCommand] = [],
                    lastMessage: String? = nil, turnUnread: Bool = false, quiet: Bool = false) {
            self.key = key; self.agent = agent; self.model = model; self.status = status; self.opening = opening; self.closed = closed
            self.waitingPrompt = waitingPrompt
            self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
            self.lastMessage = lastMessage; self.turnUnread = turnUnread; self.quiet = quiet
        }
        /// What it counts as: `WorkerTab.status`.
        public var counted: SessionState? { opening ? .working : status }
    }

    /// The first worker's live status.
    public var status: SessionState?
    /// Its first worker's launch is under way and it has named no conversation yet (`WorkerTab.isOpening`): at work,
    /// whatever its tab says.
    public var opening: Bool
    /// The classified prompt that waits on you in the first worker, `permission` or `unknown` (spec §7.2), if any.
    public var waitingPrompt: String?
    /// The task's extra worker tabs, in the order asked for.
    public var tabs: [Tab]
    /// What its workers left running in the background (`WorkerTab.background`): what one that ended its turn left, and
    /// the subagents that hold one at working after its turn ended.
    public var background: [String]
    /// The prompt you typed into one of its workers yourself, for the turn it started (`SessionInfo.yourPrompt`).
    public var yourPrompt: String?
    /// What its first worker's ended turn left (spec §J), read once each turn ends and only while that worker is idle at its
    /// prompt or done: its last message, and how many commits its branch has past where its work starts (a working task's
    /// only, `Repository.commitsAhead`; nil while unknown).
    public var lastMessage: String?, commitsAhead: Int?
    /// A reopened working task's HEAD is still the commit it was accepted on (`OperatedTask.reopenedFrom`): no new commit,
    /// and that one to accept again.
    public var atReopenedCommit: Bool
    /// An accepted, inReview or published task's worktree moved on from its accepted commit (`WorkerTurn.changedAfterAcceptance`).
    public var changedAfterAcceptance: Bool
    /// Its first worker ended its turn and AiTerm is still reading it: not ready, nor a quiet review, until what the turn
    /// left is known.
    public var turnUnread: Bool
    /// Its first worker's session says working but its transcript has not grown for `OperatorTiming.liveQuietMinutes`, and
    /// no tool call it started still runs (`StallWatch.isQuietWhileWorking`): the line reads `working?` and the task is uncertain.
    public var quiet: Bool
    /// The model and effort its first worker runs now, as Claude Code itself reported them (`SessionInfo.model`,
    /// `.reasoning`): changed once a /model or /effort has run, never by delivering one, and never a subagent's. Nil while
    /// it hasn't said.
    public var liveModel: String?, liveReasoning: String?
    /// What became of the slash commands `message_task` typed into its first worker (`SessionInfo.slashCommands`).
    public var slashCommands: [SlashCommand]
    /// What ended one of its workers' turns short, as a sentence (`StoppedOn.reason`): a usage limit and when it resets,
    /// or a billing or sign-in failure. Nil while none is.
    public var stoppedOn: String?
    public var testActivities: [TestActivity]

    public init(status: SessionState? = nil, waitingPrompt: String? = nil,
                tabs: [Tab] = [], background: [String] = [], yourPrompt: String? = nil, lastMessage: String? = nil,
                commitsAhead: Int? = nil, atReopenedCommit: Bool = false, changedAfterAcceptance: Bool = false, turnUnread: Bool = false,
                quiet: Bool = false, liveModel: String? = nil, liveReasoning: String? = nil, slashCommands: [SlashCommand] = [],
                stoppedOn: String? = nil, opening: Bool = false, testActivities: [TestActivity] = []) {
        self.status = status; self.waitingPrompt = waitingPrompt; self.opening = opening
        self.tabs = tabs; self.background = background; self.yourPrompt = yourPrompt
        self.lastMessage = lastMessage; self.commitsAhead = commitsAhead; self.atReopenedCommit = atReopenedCommit
        self.changedAfterAcceptance = changedAfterAcceptance
        self.turnUnread = turnUnread; self.quiet = quiet
        self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
        self.stoppedOn = stoppedOn
        self.testActivities = testActivities
    }

    /// Its first worker is idle at its prompt or done: what its turn left is its final word.
    var turnEnded: Bool { counted?.turnEnded == true }
    /// What its first worker counts as: `WorkerTab.status`.
    var counted: SessionState? { opening ? .working : status }
}

/// What one ended turn of a worker left (`WorkerTurnReader`), by the session it was read for, the state it was read at and
/// the task it was read of.
public struct WorkerTurnReading: Equatable, Sendable {
    public var session: String, state: SessionState
    public var basis: Basis
    public var lastMessage: String?, commitsAhead: Int?, changedAfterAcceptance: Bool
    /// A reopened working task's HEAD is the commit it was accepted on (`TaskLiveFacts.atReopenedCommit`).
    public var atReopenedCommit: Bool
    /// `message_task` reached the worker after its turn ended: what the turn left is answered, and its next turn's end
    /// is what counts. Nothing of this reading is shown, and a working task is not ready until that turn is read.
    public var messaged: Bool
    public var conversation: String?
    public var replyIdentity: Int?
    public var observedOrder: Int

    public init(session: String, state: SessionState, basis: Basis, lastMessage: String?, commitsAhead: Int?,
                changedAfterAcceptance: Bool, atReopenedCommit: Bool = false, messaged: Bool = false, conversation: String? = nil,
                replyIdentity: Int? = nil, observedOrder: Int = 0) {
        self.session = session; self.state = state; self.basis = basis; self.lastMessage = lastMessage
        self.commitsAhead = commitsAhead; self.changedAfterAcceptance = changedAfterAcceptance
        self.atReopenedCommit = atReopenedCommit; self.messaged = messaged; self.conversation = conversation
        self.replyIdentity = replyIdentity; self.observedOrder = observedOrder
    }

    /// What a reading holds for beyond its session: the task's state, accepted commit and content baseline.
    /// Reaccepting, refreshing the baseline or reopening invalidates it even without a new worker turn.
    public struct Basis: Equatable, Sendable {
        public var state: OperatedState, accepted: String?, fingerprint: String?
        public init(_ task: OperatedTask) {
            state = task.state
            accepted = [.accepted, .inReview, .published].contains(task.state) ? task.acceptance?.resultSHA : nil
            fingerprint = accepted == nil ? nil : task.acceptanceWorktreeFingerprint
        }
    }
}

public extension TaskLiveFacts {
    /// What the tabs say of each of the run's tasks: each worker tab's live status (`WorkerTab`), and the prompt
    /// each waits on you with (the open question D14 records for it). While its first worker is idle or done, what that
    /// turn left (`turns`, spec §J): a task whose turn is not read yet, read again after it was accepted again or reopened,
    /// or answered by `message_task` since, is `turnUnread`. A first worker at work whose task is in `quiet` has gone quiet (spec §H).
    /// A worker an API error stopped says why (`StoppedOn.reason`), a limit's reset as of `now`. A first worker whose launch is
    /// under way as of `now` and that has named no conversation yet is opening (`TaskItem.workerTabs(in:now:)`): at work,
    /// its turn not ended. The pass's one live projection of its tasks, as of `now`, which `RunStatus.build` arranges.
    static func of(run: UUID, state: AppState, sessions: [SessionInfo],
                   turns: [UUID: WorkerTurnReading], extraTurns: [UUID: [String: WorkerTurnReading]] = [:],
                   quiet: Set<UUID> = [], quietTabs: [UUID: Set<String>] = [:], now: Date) -> [UUID: TaskLiveFacts] {
        let questions = state.run(id: run)?.questions ?? []
        var facts: [UUID: TaskLiveFacts] = [:]
        let workersByTask = WorkerSessions(sessions)
        for task in state.tasks(inRun: run) {
            let open = questions.filter { $0.task == task.id && $0.resolution == nil && $0.kind == .prompt }
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
                                             lastMessage: ended ? read?.lastMessage : nil, turnUnread: ended && read == nil,
                                             quiet: prompt == nil && quietTabs[task.id]?.contains(key) == true)
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
                let completed = workers.compactMap { worker -> WorkerTurnReading? in
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
}
