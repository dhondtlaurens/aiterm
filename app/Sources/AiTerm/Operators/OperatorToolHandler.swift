import Foundation
import AiTermCore

/// A tool's answer: the result the operator reads, or an error it reads as the tool's failure.
enum ToolAnswer: Equatable, Sendable {
    case result(JSONValue), error(String)
    var value: JSONValue? { if case .result(let value) = self { value } else { nil } }
    var message: String? { if case .error(let message) = self { message } else { nil } }
}

/// Why a tool did not act, said to the operator as the tool's error.
struct ToolRefusal: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }

    /// Any tool of a broadcast that has ended.
    static let ended = ToolRefusal("This broadcast has ended; its tools no longer act.")
}

/// One call's arguments, read with the error the operator needs when one is missing.
struct ToolCall {
    let tool: String, arguments: JSONValue
    enum MarkOutcome: String { case accepted, noChange, blocked, failed }
    let markOutcome: MarkOutcome?

    init(tool: String, arguments: JSONValue) {
        self.tool = tool; self.arguments = arguments
        self.markOutcome = (arguments["outcome"]?.stringValue).said.flatMap(MarkOutcome.init(rawValue:))
    }

    /// The tool by its name; nil for a name AiTerm has no tool for.
    var operatorTool: OperatorTool? { OperatorTool(rawValue: tool) }

    func string(_ key: String) throws(ToolRefusal) -> String {
        guard let value = optionalString(key) else { throw ToolRefusal("\(tool) needs `\(key)`.") }
        return value
    }

    func optionalString(_ key: String) -> String? {
        (arguments[key]?.stringValue).said
    }

    func optionalBool(_ key: String) -> Bool? { arguments[key]?.boolValue }
}

/// A slice of the broadcast's profile that a tool's write needs (spec §5): off, the write is refused and left for the person.
enum WriteSlice {
    case jira, review
    var name: String { self == .jira ? "Jira" : "Review" }
    func isOn(in slices: Slices) -> Bool { self == .jira ? slices.jira : slices.review }
    /// The refusal while it is off.
    var off: String { "The \(name) slice is off for this broadcast." }
}

/// The Jira search behind `jira_search`: the app's client, or a test's.
protocol OperatorJira: Sendable {
    /// The site Settings is connected to: where the broadcast's chosen Jira projects live.
    var siteURL: URL { get }
    func search(jql: String, in projects: [JiraProjectRef]) async throws -> [JiraTicket]
    /// The Jira slice's writes (spec §5).
    /// `labels` mark it as this call's, so a retry after a lost answer finds it.
    func createIssue(project: String, type: String, summary: String, description: String, parent: String?, labels: [String]) async throws -> String
    /// False when the ticket was in that status already and nothing was made. `beforeWrite` runs after Jira's reads and
    /// right before the move, and its error stops it.
    func transition(key: String, to statusName: String, beforeWrite: @Sendable () async throws -> Void) async throws -> Bool
    func link(key: String, to other: String, type: String) async throws
    /// Boards and sprints (spec §L): `jira_board` reads them, `jira_sprint` writes. `beforeWrite` is as `transition`'s: it runs
    /// right before the write, and its error stops it.
    func boards(project: String) async throws -> [JiraBoard]
    func sprints(board: Int) async throws -> [JiraSprint]
    func columns(board: Int) async throws -> [JiraColumn]
    func addToSprint(_ sprint: Int, tickets: [String], beforeWrite: @Sendable () async throws -> Void) async throws
    func moveToBacklog(tickets: [String], beforeWrite: @Sendable () async throws -> Void) async throws
    /// `jira_edit` and `jira_comment` (spec §L); `beforeWrite` as above. A comment answers its id.
    func edit(key: String, fields: JiraEdit, beforeWrite: @Sendable () async throws -> Void) async throws
    /// A comment is tagged with `tag`, and `findComment` reads the id of the comment on `key` that carries it: a call whose
    /// answer was lost finds what it posted.
    func comment(key: String, body: String, tag: String?, beforeWrite: @Sendable () async throws -> Void) async throws -> String
    func findComment(key: String, tag: String) async throws -> String?
}

extension JiraClient: OperatorJira {}

/// One of the Operator's acts while AiTerm carries it out (`OperatorAct`): about one task, or the
/// broadcast's own (`task` nil). Each is its own, so two at once (a call and the Oracle it consults)
/// end apart.
struct OperatorActivity: Hashable, Sendable {
    let id = UUID()
    let run: UUID
    let task: UUID?
    let act: OperatorAct
}

/// Answers the operator's tools (spec §6), each forwarded by the daemon as an `operator.request` and
/// answered with an `operator.reply`. The app is the only writer of runs and tasks, so every tool's
/// effect is a workspace change made here; the operator's view of it is `run_status`, numbered by what
/// changed. Every mutating tool is safe to repeat: by its key, its revision, its outcome and SHA, or
/// the task's current state (spec §11) — the repeat returns what was recorded.
@MainActor
final class OperatorToolHandler {
    let workspace: WorkspaceStore
    let live: LiveSessions
    let daemon: @MainActor () -> (any DaemonCommands)?
    let ports: OperatorPorts
    let waker: OperatorWaker
    /// Opens `open_tab`'s extra worker tabs, which the reconciler adopts.
    let tabs: TabOpener
    /// Where `read_task` finds a worker's conversation.
    let transcripts: TranscriptLocator
    /// Each run's last `run_status`, and the revision it was numbered.
    private var numbered: [UUID: (content: RunStatus, revision: Int)] = [:]
    private let oracleJobs: OracleJobs
    private var lastOracleRevision: Int?
    private var oracleGenerations: [UUID: Int] = [:]
    /// The challenges whose acting call is performing now: a second call for one is refused, not performed too.
    private(set) var actingChallenges: Set<String> = []
    /// The `create_task` and `check_goal` invocations the Oracle said yes to, while the call performs: an addition past the
    /// threshold, a goal check it agreed with.
    private(set) var vettedCalls: Set<String> = []
    /// A message to one worker tab: `tab` is an extra tab's key, nil for the first worker.
    struct MessageKey: Hashable { let task: UUID; let tab: String?; let text: String }
    private var deliveredMessages: [MessageKey: (at: Date, answer: JSONValue)] = [:]
    /// How long the same text to the same tab is answered from `deliveredMessages` instead of typed again: a retry of a
    /// call whose answer the daemon gave up waiting for (`OperatorTiming.operatorRequestTimeout`) comes within it; a
    /// later one is a new message.
    static let messageReplayWindow = 2 * OperatorTiming.operatorRequestTimeout
    private var sendingMessages: Set<MessageKey> = []
    /// A keyed write being sent now: a second call for the same one leaves it to the first.
    struct WriteInFlight: Hashable {
        enum Kind { case jiraCreate, jiraComment, threadReply, find, pipelineRetry }
        let kind: Kind, run: UUID, key: String
    }
    private var writesInFlight: Set<WriteInFlight> = []
    /// Host reviewer assignment is a read/replace sequence, owned once per published request.
    struct ReviewRequestKey: Hashable { let repository: String?; let number: Int }
    struct ReviewWaiter { let id: UUID; let continuation: CheckedContinuation<Void, any Error> }
    private var reviewAssignments: [ReviewRequestKey: [ReviewWaiter]] = [:]
    /// A request reading belongs to this repository and accepted commit, even when its URL stays the same.
    struct HostReadKey: Hashable, Sendable {
        let project: UUID, repository: String?, url: String, number: Int, acceptedSHA: String?
    }
    struct HostRead { let id: UUID; let task: Task<HostReading, Never> }
    private var hostStates: [HostReadKey: (at: Date, state: MergeRequestState)] = [:]
    private var hostReads: [HostReadKey: HostRead] = [:]
    /// When `diffBase` last fetched, or tried to fetch, each task base from origin, by worktree and branch: within
    /// `OperatorTiming.diffBaseFetchInterval` it reads origin's copy as it is.
    private(set) var diffBaseFetches: [String: Date] = [:]
    /// The Oracle's critiques of review threads running now (`critique_thread`), by task, thread, note and commit: a call
    /// that comes while one runs waits for that one, and each is recorded on its task when it answers, whoever waits.
    struct CritiqueKey: Hashable { let task: UUID, thread: String, note: String, head: String? }
    /// The activity log's serial tail: each write waits for the one before it, so the
    /// lines land in the order the calls ended.
    private var lastRecording: Task<Void, Never>?
    /// Said once a call's line has landed in its run's `activity.jsonl`: the controller's counter the Operator sheet watches.
    var onActivity: @MainActor (UUID) -> Void = { _ in }
    /// Told when one of the Operator's acts starts and ends: the controller's `acting`, which the status
    /// lines say (`OperatorLine`).
    var onActing: @MainActor (OperatorActivity, Bool) -> Void = { _, _ in }
    /// Said for every tool call a known, running broadcast's Operator makes: the quiet time starts again (`OperatorWatchdog`).
    var onCall: @MainActor (UUID) -> Void = { _ in }
    /// Said after an operator's own change to its run: what may start now starts.
    var onChange: @MainActor (UUID) -> Void = { _ in }
    /// What each worker's last ended turn left (`WorkerTurnReader.readings`), which `relay_question` passes on; a
    /// message delivered answers it (spec §J).
    let turns: WorkerTurnReader
    /// Which workers went quiet while they say working (`WorkerQuietWatch`).
    let quiet: WorkerQuietWatch
    /// Reads the addressed worker's screen after a delivery or a refusal that suggests a prompt.
    let prompts: WorkerPrompts
    /// What `run_status` would answer now (`RunStatusSource`).
    let statuses: RunStatusSource
    /// Carries out a task's recorded end (G10), past the push hooks when told (`noVerify`), opening its request with the
    /// Operator's content when given, within the call's reply budget: the controller's `TaskFinisher`.
    var finish: @MainActor (UUID, TaskFinisher.Call) async -> TaskFinisher.Result = { _, _ in
        TaskFinisher.Result(result: .refused, reason: "AiTerm isn’t ready to publish yet.")
    }
    /// Whether a `finish_task` of the task now only joins a publication in flight or answers one that outlived its call
    /// (`TaskFinisher.pending`): the challenge gate leaves such a call alone.
    var pendingFinish: @MainActor (UUID) -> Bool = { _ in false }

    /// Starts a retried task now and waits for its launch within the call's reply budget: what `retry_task` answers of it
    /// (the controller's `launchNow`).
    var launchNow: @MainActor (UUID, Duration?) async -> LaunchReport = { _, _ in
        LaunchReport(result: "queued", note: "AiTerm isn’t ready to start it yet.")
    }
    /// Whether a publication of the task is in flight (`TaskFinisher.running`): finish_task, a retry or a merge watch's poll.
    var publishing: @MainActor (UUID) -> Bool = { _ in false }
    /// Holds an accepted task's publication while message_task or open_tab steers it, and lets it go once the call ends
    /// (`TaskFinisher.hold`, `release`): no merge of it runs meanwhile.
    var holdPublication: @MainActor (UUID) -> Void = { _ in }
    var releasePublication: @MainActor (UUID) -> Void = { _ in }

    /// What a call on `task` is, as its status line says it: answering its agent, or, with people's review
    /// under way, relaying their feedback; checking the work; opening the MR or merging, by the task's end.
    static func act(for tool: OperatorTool, on task: TaskItem) -> OperatorAct? {
        let operated = task.operated
        switch tool {
        case .messageTask: return operated?.state == .inReview ? .relayingFeedback : .answering
        case .markTask: return .checkingTheWork
        case .requestReview: return .assigning
        case .replyThread: return .relayingFeedback
        case .finishTask:
            switch operated?.end ?? .commit {
            case .commit: return .checkingTheWork
            case .draftMR: return .openingTheMR
            case .merge: return operated?.publication?.mergeRequestURL == nil ? .openingTheMR : .merging
            case .mergeLocal: return .merging
            }
        default: return nil
        }
    }

    /// The act a call carries out while it runs, if it is one of the Operator's.
    func activity(for call: ToolCall, in run: UUID) -> OperatorActivity? {
        guard let tool = call.operatorTool else { return nil }
        switch tool.actKind {
        case .onTask:
            guard let task = call.optionalString("task").flatMap({ state.task(inRun: run, named: $0) }),
                  let act = Self.act(for: tool, on: task) else { return nil }
            return OperatorActivity(run: run, task: task.id, act: act)
        case .onBroadcast(let act): return OperatorActivity(run: run, task: nil, act: act)
        case .none: return nil
        }
    }

    /// Whether `call` changes the run, its tasks or its records.
    static func isMutating(_ call: ToolCall) -> Bool { call.operatorTool?.isMutating ?? false }

    init(workspace: WorkspaceStore, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?, ports: OperatorPorts,
         waker: OperatorWaker, tabs: TabOpener, transcripts: TranscriptLocator, turns: WorkerTurnReader, quiet: WorkerQuietWatch,
         prompts: WorkerPrompts, statuses: RunStatusSource) {
        self.workspace = workspace
        self.live = live
        self.daemon = daemon
        self.ports = ports
        self.waker = waker
        self.tabs = tabs
        self.transcripts = transcripts
        self.turns = turns
        self.quiet = quiet
        self.prompts = prompts
        self.statuses = statuses
        self.oracleJobs = OracleJobs(work: ports.work)
    }

    var state: AppState { workspace.state }

    func recordingsSettled() async { await lastRecording?.value }

    func vet(_ call: ToolCall) { vettedCalls.insert(Self.invocation(call)) }
    func beginChallengeAct(_ id: String) { actingChallenges.insert(id) }
    func endChallengeAct(_ id: String) { actingChallenges.remove(id) }
    func beginWrite(_ flight: WriteInFlight) -> Bool { writesInFlight.insert(flight).inserted }
    func endWrite(_ flight: WriteInFlight) { writesInFlight.remove(flight) }
    func recordDiffFetch(_ key: String, at date: Date) { diffBaseFetches[key] = date }
    func oracleGeneration(_ run: UUID) -> Int { oracleGenerations[run, default: 0] }
    func advanceOracleGeneration(_ run: UUID) { oracleGenerations[run, default: 0] += 1 }
    func observeOracleRevision(_ revision: Int) -> Bool {
        let changed = lastOracleRevision.map { $0 != revision } ?? false
        lastOracleRevision = revision
        return changed
    }
    func replayedDelivery(_ key: MessageKey, at now: Date) -> JSONValue? {
        deliveredMessages = deliveredMessages.filter { now.timeIntervalSince($0.value.at) < Self.messageReplayWindow }
        return deliveredMessages[key]?.answer
    }
    func beginMessage(_ key: MessageKey) -> Bool { sendingMessages.insert(key).inserted }
    func endMessage(_ key: MessageKey) { sendingMessages.remove(key) }
    func recordDelivery(_ answer: JSONValue, for key: MessageKey) { deliveredMessages[key] = (ports.now(), answer) }
    func cancelOracleJobs(inRun run: UUID? = nil) { oracleJobs.cancel(inRun: run) }
    func retainOracleJobs(in state: AppState) { oracleJobs.retain(in: state) }
    func isOracleRunning(_ key: OracleJobs.Key) -> Bool { oracleJobs.contains(key) }
    func runningOracle(_ key: OracleJobs.Key) -> Task<SecondOpinionRunner.Verdict?, Never>? { oracleJobs.running(key) }
    @discardableResult
    func startOracleJob(_ key: OracleJobs.Key, run: UUID, task: UUID?, runner: SecondOpinionRunner, opinion: OracleSetting,
                        prompt: String, folder: URL, projects: [String], capped: Bool = true, keepCancelled: Bool = false,
                        acting: @escaping @MainActor (Bool) -> Void,
                        settle: @escaping @MainActor (SecondOpinionRunner.Verdict) -> Void = { _ in }) -> Task<SecondOpinionRunner.Verdict?, Never> {
        oracleJobs.start(key, run: run, task: task, runner: runner, opinion: opinion, prompt: prompt, folder: folder,
                         projects: projects, capped: capped, keepCancelled: keepCancelled, acting: acting, settle: settle)
    }

    /// Answers `request` through the helper. A reply that cannot be sent is the daemon's to time out:
    /// the operator reads "AiTerm isn't answering" and calls again, which the tool's key makes safe.
    @discardableResult
    func handle(_ request: OperatorRequest) -> Task<Void, Never> {
        ports.work.start { [self] in
            let answer = await self.answer(request)
            guard let daemon = daemon() else { return }
            await Log.daemon.attempt("Replying to the operator’s \(request.tool) request \(request.requestId)") {
                switch answer {
                case .result(let value): try await daemon.replyToOperator(requestId: request.requestId, result: value, error: nil)
                case .error(let message): try await daemon.replyToOperator(requestId: request.requestId, result: nil, error: message)
                }
            }
        }
    }

    /// The answer to `request`, whatever it was: every call a known run's Operator makes is written to its activity log.
    /// A shell command's gate writes its own line, naming the command (`gate(_:in:)`).
    func answer(_ request: OperatorRequest) async -> ToolAnswer {
        let (answer, outcome) = await respond(request)
        if request.tool != Self.gateTool { record(request, answer: answer, outcome: outcome) }
        return answer
    }

    /// The answer, and how the call went, which the activity log keeps.
    func respond(_ request: OperatorRequest) async -> (ToolAnswer, ActivityEntry.Outcome) {
        // A finish_task answers by then, its publication done or not, and a retry_task, its launch done or not: the daemon
        // stops waiting soon after.
        let deadline = ContinuousClock.now + ports.finishReplyBudget
        // A shell command is the gate's alone: never a tool, a challenge or a replayed message. It answers an ended
        // broadcast itself, with a deny rather than an error, which the hook would let run.
        if request.tool == Self.gateTool { return (.result(await gate(request)), .ok) }
        guard let id = UUID(uuidString: request.runId), let run = state.run(id: id) else {
            return (.error("This broadcast is no longer in AiTerm."), .refused)
        }
        guard !run.hasEnded else { return (.error(ToolRefusal.ended.message), .refused) }
        onCall(id)
        let call = ToolCall(tool: request.tool, arguments: request.arguments)
        let activity = activity(for: call, in: id)
        if let activity { onActing(activity, true) }
        defer { if let activity { onActing(activity, false) } }
        do {
            if let recorded = try replayedMessage(call, in: run) { return (.result(recorded), .repeated) }
            // A finish_task that only joins its publication or answers what it did decides nothing new: no Oracle, no fetch.
            let joins = finishJoins(call, in: run)
            // A relay runs its own Oracle rounds (`relayQuestion`): the gate never sees it.
            let relays = call.operatorTool == .relayQuestion
            if !joins, !relays, let instead = try await challengeGate(call, in: run, deadline: deadline) {
                // The critique, or the answer to a challenged call that acted already, said again.
                return (.result(instead), instead["challenged"] == true ? .challenged : .repeated)
            }
            // The gate's yes to an addition holds for this call only.
            let invocation = Self.invocation(call)
            defer { vettedCalls.remove(invocation) }
            // The gate marks a challenge it lets act; whatever way this call ends, the mark goes with it.
            let acting = call.optionalString("challengeId").flatMap { actingChallenges.contains($0) ? $0 : nil }
            defer { if let acting { actingChallenges.remove(acting) } }
            guard let current = state.run(id: id) else { throw ToolRefusal("This broadcast is no longer in AiTerm.") }
            guard !current.hasEnded else { throw ToolRefusal.ended }
            if Self.isMutating(call), current.state != run.state || current.intent != run.intent, current.isPaused {
                try acceptsWork(current)
            }
            let value = try await perform(call, in: current, deadline: deadline, joinOnly: joins)
            // A relay keeps its own rounds: a critique delivered stays delivered, so a repeat says it again.
            if !relays { recordActed(call, in: id, answer: value) }
            if Self.isMutating(call) { onChange(id) }
            return (.result(value), relays && value["challenged"] == true ? .challenged : .ok)
        } catch let refusal as ToolRefusal {
            return (.error(refusal.message), .refused)
        } catch {
            return (.error(error.localizedDescription), .failed)
        }
    }

    /// Only this synchronous write is the call's own news; changes during an await stay unread.
    @discardableResult
    func mutate<T>(in id: UUID?, _ body: (inout AppState) throws -> T) rethrows -> T {
        let before = id.flatMap { state.run(id: $0) }.flatMap(currentStatus(of:))
        let result = try workspace.mutate(body)
        if let id, let before, let after = state.run(id: id).flatMap(currentStatus(of:)), before != after {
            waker.ownChange(from: before, to: after, of: id)
        }
        return result
    }

    /// Refuses a write `slice` does not allow, and leaves `left` (what was not done) for the person once.
    func requireSlice(_ slice: WriteSlice, in run: OperatorRun, otherwise left: String) throws(ToolRefusal) {
        guard !slice.isOn(in: run.profile.slices) else { return }
        let sentence = "\(left): the \(slice.name) slice is off."
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { if !$0.leftForYou.contains(sentence) { $0.leftForYou.append(sentence) } }
        }
        throw ToolRefusal(slice.off)
    }

    /// One tool, by its name. `deadline`: when a `finish_task` answers, its publication done or not; none waits for it.
    /// `joinOnly`: a `finish_task` that may only join its publication or answer what it did (`finishJoins`).
    func perform(_ call: ToolCall, in run: OperatorRun, deadline: ContinuousClock.Instant? = nil, joinOnly: Bool = false) async throws -> JSONValue {
        guard let tool = call.operatorTool else { throw ToolRefusal("AiTerm has no tool called \(call.tool).") }
        switch tool {
        case .runStatus: return try await runStatus(run)
        case .jiraSearch: return try await jiraSearch(call, in: run)
        case .jiraCreate:
            // The finds' own keys (`fileFind`) are AiTerm's.
            guard !(try call.string("key")).hasPrefix("find/") else {
                throw ToolRefusal("jira_create keys starting with “find/” are reserved for off-brief finds. Choose another key.")
            }
            return try await jiraCreate(call, in: run)
        case .jiraMove: return try await jiraMove(call, in: run)
        case .jiraLink: return try await jiraLink(call, in: run)
        case .jiraBoard: return try await jiraBoard(in: run)
        case .jiraSprint: return try await jiraSprint(call, in: run)
        case .jiraEdit: return try await jiraEdit(call, in: run)
        case .jiraComment: return try await jiraComment(call, in: run)
        case .askYou: return try askYou(call, in: run)
        case .relayQuestion: return try await relayQuestion(call, in: run)
        case .resolveQuestion: return try resolveQuestion(call, in: run)
        case .leaveForYou: return try leaveForYou(call, in: run)
        case .logDecision: return try logDecision(call, in: run)
        case .writeSummary: return try writeSummary(call, in: run)
        case .reportFind: return try await reportFind(call, in: run)
        case .reportSnag: return try reportSnag(call, in: run)
        case .createTask: return try await createTask(call, in: run)
        case .updateTask: return try await updateTask(call, in: run)
        case .submitPlan: return try submitPlan(call, in: run)
        case .readTask: return try await readTask(call, in: run)
        case .messageTask: return try await messageTask(call, in: run)
        case .openTab: return try await openTab(call, in: run)
        case .markTask: return try await markTask(call, in: run)
        case .resumeTask: return try resumeTask(call, in: run)
        case .retryTask: return try await retryTask(call, in: run, deadline: deadline)
        case .recordReview: return try await recordReview(call, in: run)
        case .checkGoal: return try checkGoal(call, in: run)
        case .reviewTask: return try await reviewTask(call, in: run)
        case .requestReview: return try await requestReview(call, in: run)
        case .replyThread: return try await replyThread(call, in: run)
        case .resolveThread: return try await resolveThread(call, in: run)
        case .critiqueThread: return try await critiqueThread(call, in: run)
        case .updateRequest: return try await updateRequest(call, in: run)
        case .retryPipeline: return try await retryPipeline(call, in: run)
        case .findUser: return try await findUser(call, in: run)
        case .finishTask:
            let task = try self.task(call, in: run)
            let content = RequestContent(title: call.optionalString("title"), description: call.optionalString("description"),
                                         assignee: call.optionalString("assignee"))
            let budget = deadline.map { max(.zero, $0 - ContinuousClock.now) }
            let result = await finish(task.id, TaskFinisher.Call(noVerify: call.optionalBool("noVerify") ?? false,
                                                                 content: content.isEmpty ? nil : content, budget: budget,
                                                                 joinOnly: joinOnly))
            return try JSONValue(encoding: result)
        }
    }

    func currentStatus(of run: OperatorRun) -> RunStatus? { currentStatus(of: run, hostThreads: [:]) }

    /// `hostThreads`: each task's request's threads as the host has them now, which run_status reads first (`readThreads`);
    /// every other caller counts them as AiTerm last read them.
    func currentStatus(of run: OperatorRun, hostThreads: [UUID: [String: Bool]]) -> RunStatus? {
        statuses.status(of: run.id, hostThreads: hostThreads)
    }

    /// The task an operator names in `key`, in this run.
    func task(_ call: ToolCall, _ key: String = "task", in run: OperatorRun) throws(ToolRefusal) -> TaskItem {
        let ref = try call.string(key)
        guard let task = state.task(inRun: run.id, named: ref) else { throw ToolRefusal("No task \(ref) in this broadcast.") }
        return task
    }

    // -- reading -------------------------------------------------------------------------------
    /// The snapshot, numbered by the per-run counter here: the same content keeps its revision,
    /// anything changed gets the next one. It carries what each installed agent may run, its model list read
    /// off the main actor, what each host says of its tasks' requests (`fillMergeRequests`), and their review threads as
    /// the host has them now (`readThreads`); the rest is read after that, as it is when the answer goes.
    private func runStatus(_ run: OperatorRun) async throws -> JSONValue {
        let delivery = await deliveryStatus()
        var agents = await agentChoices()
        for (agent, messaging) in delivery ?? [:] { agents[agent]?.delivery = messaging }
        let hosts = StatusHosts(workspace: workspace, codeHost: ports.codeHost)
        let requests = ports.work.start { [self] in await readMergeRequests(inRun: run.id, hosts: hosts) }
        let threads = await readThreads(inRun: run.id, hosts: hosts)
        guard let current = state.run(id: run.id),
              var content = currentStatus(of: current, hostThreads: threads.compactMapValues(\.resolutions)) else {
            requests.cancel()
            throw ToolRefusal("This broadcast is no longer in AiTerm.")
        }
        for index in content.tasks.indices {
            if case .note(let note)? = threads[content.tasks[index].id] { content.tasks[index].peopleReview?.threadsNote = note }
        }
        content.run.agents.installed = Dictionary(agents.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first })
        await fillMergeRequests(&content, hosts: hosts, ready: await requests.value)
        let previous = numbered[run.id]
        let revision = previous?.content == content ? previous?.revision ?? 1 : (previous?.revision ?? 0) + 1
        numbered[run.id] = (content, revision)
        var status = content
        status.revision = revision
        waker.acknowledged(status, of: run.id)
        return try JSONValue(encoding: status)
    }

    /// Whether each installed agent's workers can be messaged now (`AgentDelivery`): the helper's delivery verdicts held
    /// against the versions installed, read off the main actor. Nil while no helper answers: not known, which run_status
    /// leaves out and create_task doesn't refuse on.
    func deliveryStatus() async -> [AgentKind: AgentDelivery]? {
        guard let daemon = daemon(), let verdicts = try? await daemon.deliveryPolicy() else { return nil }
        let agents = ModelChoice.pair.filter(installedAgents.contains), versions = ports.installedVersions
        let installed = await BackgroundWork.run { versions(agents) }
        return Dictionary(agents.map { ($0, AgentDelivery.of($0, verdict: verdicts[$0], installed: installed[$0])) }, uniquingKeysWith: { first, _ in first })
    }

    /// Each installed agent the Operator chooses from (Claude, Codex): its own models and its default (spec §15).
    private func agentChoices() async -> [AgentKind: RunStatus.AgentChoice] {
        let agents = ModelChoice.pair.filter(installedAgents.contains), models = agentModels
        let lists = await BackgroundWork.run { Dictionary(agents.map { ($0, models($0).map(\.id)) }, uniquingKeysWith: { first, _ in first }) }
        return Dictionary(agents.map { agent in
            let fallback = defaultModel(for: agent)
            return (agent, RunStatus.AgentChoice(models: lists[agent] ?? [], defaultModel: fallback.model, defaultReasoning: fallback.reasoning))
        }, uniquingKeysWith: { first, _ in first })
    }

    private func jiraSearch(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let jql = try call.string("jql")
        guard let jira = ports.jira() else { throw ToolRefusal("Jira isn’t connected in AiTerm’s Settings › Integrations.") }
        let linked = run.projectIds.compactMap(state.project(id:)).flatMap(\.jiraProjects).linkedOnce
        // The Jira projects chosen for the broadcast are on the connected site; a linked one is checked against it.
        let keys = Set(linked.map { $0.key.uppercased() })
        let chosen = run.jiraProjectKeys.map { $0.uppercased() }.filter { !keys.contains($0) }
            .map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: jira.siteURL) }
        let scope = linked + chosen
        guard !scope.isEmpty else {
            throw ToolRefusal("None of this broadcast’s projects is linked to a Jira project, so there is nothing jira_search may search.")
        }
        // A Jira slower than the budget is said inside the daemon's wait for the app (`OperatorTiming.operatorRequestTimeout`),
        // so the Operator reads why instead of "AiTerm isn't answering"; the search is cancelled.
        let budget = ports.jiraSearchBudget
        let tickets: [JiraTicket]
        switch await BackgroundWork.within(budget, { try await jira.search(jql: jql, in: scope) }) {
        case .success(let found): tickets = found
        case .failure(let error) where error is BackgroundWork.NoAnswer:
            throw ToolRefusal("Jira didn’t answer within \(Int(budget.components.seconds)) s; try a narrower JQL.")
        case .failure(let error): throw error
        }
        return .array(tickets.map { ticket in
            ["key": .string(ticket.key), "summary": .string(ticket.summary), "status": ticket.status.map(JSONValue.string) ?? .null,
             "type": ticket.issueType.map(JSONValue.string) ?? .null, "url": .string(ticket.url),
             "description": ticket.description.map { .string(String($0.prefix(4000))) } ?? .null]
        })
    }

    // -- the records ----------------------------------------------------------------------------
    private func askYou(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), text = try call.string("question")
        guard !OperatorQuestion.aitermPrefixes.contains(where: key.hasPrefix) else {
            throw ToolRefusal("Keys starting with “prompt-”, “merged-on-host-” or “gate-” are AiTerm’s own questions. Choose another key.")
        }
        let about = call.optionalString("about")
        guard about == nil || about == OperatorQuestion.fixRounds else { throw ToolRefusal("about is \(OperatorQuestion.fixRounds), or left out.") }
        let taskId = try call.optionalString("task").map { _ in try task(call, in: run).id }
        let holds = try Self.holds(call, task: taskId, about: about), choices = try Self.choices(call, about: about)
        if let open = run.questions.first(where: { $0.id == key }) { return Self.askAnswer(open) }
        let question = OperatorQuestion(id: key, text: text, task: taskId, askedAt: ports.now(), resolution: nil, about: about,
                                        holds: holds == false ? false : nil, choices: choices)
        mutate(in: run.id) { $0.open(question, inRun: run.id) }
        return Self.askAnswer(question)
    }

    /// `ask_you`'s `holds`: false only for a question about a task, and never for its fix rounds, which always hold.
    static func holds(_ call: ToolCall, task: UUID?, about: String?) throws -> Bool? {
        guard let value = call.arguments["holds"], value != .null else { return nil }
        guard let holds = value.boolValue else { throw ToolRefusal("holds must be true or false.") }
        guard !holds else { return true }
        guard task != nil else {
            throw ToolRefusal("Only a question about a task holds one, so holds false needs a task. Leave holds out for a question on no task.")
        }
        guard about != OperatorQuestion.fixRounds else {
            throw ToolRefusal("A question about fix rounds always holds its task. Leave holds out.")
        }
        return false
    }

    /// The most characters in one of `ask_you`'s choices.
    static let choiceLimit = 60

    /// `ask_you`'s `choices`: two to four short answers, each one line, and none for fix rounds, whose answers are fixed.
    static func choices(_ call: ToolCall, about: String?) throws -> [String]? {
        guard let value = call.arguments["choices"], value != .null else { return nil }
        guard about != OperatorQuestion.fixRounds else {
            throw ToolRefusal("A question about fix rounds has its answers already: One More Round and Accept As It Is. Leave choices out.")
        }
        let said = value.arrayValue?.map { $0.stringValue?.trimmingCharacters(in: .whitespaces) ?? "" } ?? []
        guard (2...4).contains(said.count), !said.contains(where: \.isEmpty) else {
            throw ToolRefusal("choices are two to four short answers, as strings, or left out.")
        }
        if let long = said.first(where: { $0.count > choiceLimit || $0.rangeOfCharacter(from: .newlines) != nil }) {
            throw ToolRefusal("Each choice is one line of \(choiceLimit) characters at most: “\(long)” isn’t.")
        }
        return said
    }

    /// `allow` is for a command the Oracle stopped (a `gate-` question) alone: true lets it pass the gate once, and
    /// left out it stays stopped (spec §A.3). Withdrawing a moot question records its reason and grants nothing.
    private func resolveQuestion(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), summary = try call.string("summary")
        guard var question = run.questions.first(where: { $0.id == key }) else { throw ToolRefusal("No question \(key) in this broadcast.") }
        // A merge on the host is the person's to decide, so the Operator closes that one once they have answered.
        guard question.kind != .prompt else {
            throw ToolRefusal("\(key) is a worker’s prompt: AiTerm closes its question itself once the worker leaves the prompt. If it looks stale, record it with report_snag.")
        }
        if let value = call.arguments["withdrawn"], value != .null, value.boolValue == nil {
            throw ToolRefusal("withdrawn must be true or false.")
        }
        guard question.resolution == nil else { return Self.questionAnswer(question) }
        let withdrawn = call.optionalBool("withdrawn") == true
        if withdrawn {
            guard question.kind != .mergedOnHost else {
                throw ToolRefusal("\(key) is a question about a merge on the host: only the person decides it. It cannot be withdrawn.")
            }
            guard question.answeredInWindow == nil else {
                throw ToolRefusal("\(key) may already be answered in its worker’s window; check it and resolve it as an answer.")
            }
            guard call.optionalBool("allow") != true else {
                throw ToolRefusal("Withdrawing a question grants nothing. Call resolve_question with withdrawn true and without allow true.")
            }
            guard summary.rangeOfCharacter(from: .newlines) == nil else {
                throw ToolRefusal("A withdrawal needs its reason in one line.")
            }
        }
        let allow = call.arguments["allow"].flatMap { $0 == .null ? nil : $0 }
        guard allow == nil || question.gate != nil else {
            throw ToolRefusal("allow is only for a command the Oracle stopped (a gate- question). Call resolve_question for \(key) without it.")
        }
        question.resolution = summary
        question.withdrawn = withdrawn ? true : nil
        let allowed = !withdrawn && allow == true ? question.gate : nil
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { run in
                if let i = run.questions.firstIndex(where: { $0.id == key }) {
                    run.questions[i].resolution = summary
                    run.questions[i].withdrawn = question.withdrawn
                }
                if let allowed { run.gateAllowances.append(allowed) }
            }
            // The row stops waiting on you once no open question holds it.
            if let taskId = question.task { state.release(taskId, unlessHeldIn: run.id) }
        }
        return Self.questionAnswer(question)
    }

    private func leaveForYou(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), text = try call.string("text")
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) {
                guard $0.leftForYouRecords[key] == nil else { return }
                $0.leftForYouRecords[key] = text
                $0.leftForYou.append(text)
            }
        }
        return ["key": .string(key), "recorded": true]
    }

    /// `why` is the reason in a sentence, and `objection` the Oracle's, when the Operator decided against it: both
    /// kept with the decision, and its `why` in the brief a fresh conversation starts from.
    private func logDecision(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), text = try call.string("text")
        let taskId = try call.optionalString("task").map { _ in try task(call, in: run).id }
        if !run.decisions.contains(where: { $0.key == key }) {
            let decision = OperatorDecision(key: key, text: text, task: taskId, at: ports.now(), challenge: nil,
                                            why: call.optionalString("why"), objection: call.optionalString("objection"))
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.decisions.append(decision) } }
        }
        return ["decision": .string(key), "logged": true]
    }

    /// The Operator's summary of the broadcast, accepted once the run is complete: its words (trimmed) and the time they came.
    /// Calling it again replaces them. Refused while the goal is still to check, which the run's completion waits for.
    private func writeSummary(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let text = try call.string("text")
        guard !run.goalCheckDue else { throw ToolRefusal("Every task is done but the goal is still to check: call check_goal first.") }
        guard run.state == .complete else { throw ToolRefusal("The broadcast isn\u{2019}t complete yet.") }
        let at = ports.now()
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.summary = text; $0.summaryAt = at } }
        return ["written": true]
    }

    /// An off-brief find (spec §4.1): never worked on, kept for the summary, once per key, and filed in Jira when
    /// the broadcast's Jira slice is on (`ticket` says which; `notFiled` says why not).
    private func reportFind(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try call.string("key"), title = try call.string("title"), why = try call.string("why")
        if !run.finds.contains(where: { $0.key == key }) {
            let find = OffBriefFind(key: key, title: title, why: why)
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.finds.append(find) } }
        }
        var answer: [String: JSONValue] = ["find": .string(key), "recorded": true]
        switch await fileFind(key: key, in: run.id) {
        case .filed(let ticket): answer["ticket"] = .string(ticket)
        case .notFiled(let reason): answer["notFiled"] = .string(reason)
        case .notAttempted: break
        }
        return .object(answer)
    }

    /// What AiTerm got wrong (`report_snag`): kept beside the summary once per key, with the task it happened on. Unlike a
    /// find it is about AiTerm and not the project, so it needs no slice and is filed nowhere.
    private func reportSnag(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        let key = try call.string("key"), title = try call.string("title"), showed = try call.string("showed")
        let actual = try call.string("actual"), workaround = try call.string("workaround")
        let task = try call.optionalString("task").map { _ in try self.task(call, in: run) }
        if !run.snags.contains(where: { $0.key == key }) {
            let snag = OperatorSnag(key: key, title: title, showed: showed, actual: actual, workaround: workaround,
                                    evidence: call.optionalString("evidence"), task: task?.id, taskKey: task?.operated?.key,
                                    branch: task?.branch, appVersion: ports.appVersion, at: ports.now())
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.snags.append(snag) } }
        }
        return ["snag": .string(key), "recorded": true]
    }

    /// `ask_you`'s answer: an open question on a task also says what that does, so the Operator knows it is no plain note.
    /// A repeat of one already resolved says only that.
    private static func askAnswer(_ question: OperatorQuestion) -> JSONValue {
        var answer = questionAnswer(question)
        if question.task != nil, question.resolution == nil, case .object(var fields) = answer {
            fields["note"] = question.holdsTask
                ? "The person sees it under Waiting on you in AiTerm and answers it there or in this chat, and your row shows waiting on them, naming this task. The task waits: it isn't ready to accept and isn't watched for stalls until you resolve the question."
                : "The person sees it on this task's card and under Waiting on you in AiTerm, and answers it there or in this chat. The task doesn't wait: it stays ready to accept and watched for stalls."
            answer = .object(fields)
        }
        return answer
    }

    private static func questionAnswer(_ question: OperatorQuestion) -> JSONValue {
        var answer: [String: JSONValue] = ["question": .string(question.id), "open": .bool(question.resolution == nil),
                                           "resolution": question.resolution.map(JSONValue.string) ?? .null]
        if question.withdrawn == true { answer["withdrawn"] = true }
        return .object(answer)
    }
}

extension OperatorToolHandler {
    /// Successful prefetches go through hostState again, so expiry or a newer pending read still wins.
    /// A failed prefetch is used only for this response and never enters the success cache.
    func prefetchedHostNote(_ kept: StatusHostReading, for task: TaskItem) -> HostReading? {
        guard Self.hostReadKey(of: task) == kept.key, case .note = kept.reading else { return nil }
        if hostReads[kept.key] != nil { return nil }
        if let cached = hostStates[kept.key], ports.now().timeIntervalSince(cached.at) < ports.hostCache {
            return .state(cached.state)
        }
        return kept.reading
    }

    /// A successful request-state reading is retained for hostCache; a failed read is never kept.
    func hostState(of task: TaskItem, hosts: StatusHosts? = nil) async -> HostReading? {
        guard let publication = task.operated?.publication, let number = publication.mergeRequestNumber,
              let url = publication.mergeRequestURL else { return nil }
        let key = HostReadKey(project: task.projectId, repository: publication.repository, url: url,
                              number: number, acceptedSHA: task.operated?.acceptance?.resultSHA)
        if let kept = hostStates[key], ports.now().timeIntervalSince(kept.at) < ports.hostCache { return .state(kept.state) }
        if let pending = hostReads[key] { return await pending.task.value }
        let id = UUID()
        let reading = Task { await self.readHost(task, publication: publication, number: number, url: url, hosts: hosts) }
        hostReads[key] = HostRead(id: id, task: reading)
        let answer = await reading.value
        // A stop may have discarded this job and a resumed caller started another one for the same request.
        if hostReads[key]?.id == id {
            hostReads[key] = nil
            if case .state(let value) = answer {
                let now = ports.now()
                hostStates = hostStates.filter { now.timeIntervalSince($0.value.at) < ports.hostCache }
                hostStates[key] = (now, value)
            }
        }
        return answer
    }

    func cancelHostReads() {
        for reading in hostReads.values { reading.task.cancel() }
        hostReads.removeAll()
        hostStates.removeAll()
    }

    /// Cancellation removes a queued waiter; other requests have independent queues.
    func acquireReviewAssignment(_ key: ReviewRequestKey) async throws {
        try Task.checkCancellation()
        guard reviewAssignments[key] != nil else { reviewAssignments[key] = []; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                reviewAssignments[key, default: []].append(ReviewWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = reviewAssignments[key]?.firstIndex(where: { $0.id == id }) else { return }
                let waiter = reviewAssignments[key]!.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func releaseReviewAssignment(_ key: ReviewRequestKey) {
        guard var waiting = reviewAssignments[key], !waiting.isEmpty else { reviewAssignments[key] = nil; return }
        let next = waiting.removeFirst()
        reviewAssignments[key] = waiting
        next.continuation.resume()
    }

    /// Appends after the prior activity write, without exposing the serial tail to consumers.
    func append(_ entry: ActivityEntry, to id: UUID) {
        let folder = OperatorCommand.runFolder(id, home: ports.home), before = lastRecording
        lastRecording = ports.work.start { [self] in
            await before?.value
            guard state.run(id: id) != nil else { return }
            await Log.daemon.attempt("Recording the Operator’s \(entry.tool) call in broadcast \(id.uuidString)’s activity log") {
                try await BackgroundWork.run {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try ActivityLog.append(entry, runFolder: folder)
                }
            }
            onActivity(id)
        }
    }
}
