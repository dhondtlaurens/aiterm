import Foundation
import AiTermCore

/// Doubts a worker's `working` when nothing shows it (spec §H): the daemon's session state can stick at working long after
/// its worker did anything, and nothing else looks at a worker once its task leaves `working`. A task whose first worker's
/// session says working while neither its transcript (`TranscriptLocator`) nor its subagents' (as the daemon last read
/// them, `SessionInfo.subagentsWrittenAt`) has grown for `OperatorTiming.liveQuietMinutes`, and no tool call it started is
/// still running (`WorkerTranscript.OpenCalls`, for up to `OperatorTiming.openCallMinutes`), is `quiet`
/// (`StallWatch.isQuietWhileWorking`): `run_status` reads it `working?` and lists it as uncertain, on a task in any state
/// but one you took over or not started. The transcripts are read off the main thread on each reconcile tick (`refresh`),
/// never when a status is built; what the session changes is noted as it happens (`observe`).
///
/// Every worker tab at work is read, its first worker and each extra tab (`open_tab`): what each read shows of it (its
/// transcript's growth, a call still running) is a sign of life on that tab's own clock (`sign`, `StallWatch`).
@MainActor
final class WorkerQuietWatch {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let transcripts: TranscriptLocator
    /// The tasks whose worker is quiet now, by task: what `run_status` shows.
    private(set) var quiet: Set<UUID> = []
    /// When each session was first seen working since it last was not: a turn only just begun is not quiet, whatever its
    /// transcript's age.
    private var workingSince: [String: Date] = [:]
    /// What each task's first worker's transcript last showed, as read for the session it names: when it last grew, and
    /// when the newest call still open in it started.
    private var grew: [UUID: (session: String, at: Date, callSince: Date?)] = [:]
    /// Each conversation's open calls as last read, by agent and conversation: the next read goes on from there.
    private var calls: [String: WorkerTranscript.OpenCalls] = [:]
    private var isReading = false
    /// A working worker tab whose transcript is to be found, and what was found of it.
    private struct Ask: Sendable { let task: UUID, tab: String?, session: String, agent: AgentKind, conversation: String }
    private struct Reading: Sendable {
        let ask: Ask, modified: Date?, calls: WorkerTranscript.OpenCalls?
        var key: String { Self.key(ask.agent, ask.conversation) }
        static func key(_ agent: AgentKind, _ conversation: String) -> String { agent.rawValue + "/" + conversation }
    }
    /// What the quiet set changed: what `run_status` and the waker show.
    var changed: @MainActor () -> Void = {}
    /// A sign of life read for one of a task's worker tabs (nil for its first worker), and when: its transcript last
    /// grew, or now while a call it started still runs.
    var sign: @MainActor (_ task: UUID, _ tab: String?, _ at: Date) -> Void = { _, _, _ in }
    /// The latest read, for a test to await.
    private(set) var lastRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, transcripts: TranscriptLocator) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.transcripts = transcripts
    }

    func stop() {
        lastRead?.cancel()
        isReading = false
    }

    /// Whether `task`'s workers are judged: started, not stopped, and not yours.
    private func isJudged(_ task: TaskItem) -> Bool {
        guard let operated = task.operated else { return false }
        return !operated.takenOver && ![.planned, .queued, .stopped].contains(operated.state)
    }

    /// The first worker of `task`, when its task is judged and its session says working.
    private func workingWorker(of task: TaskItem, in sessions: WorkerSessions) -> WorkerTab? {
        guard isJudged(task) else { return nil }
        let workers = task.workerTabs(in: sessions)
        guard !workers.contains(where: { $0.session?.testActivity?.isActive == true }) else { return nil }
        let worker = workers[0]
        return worker.session?.state == .working ? worker : nil
    }

    /// The session of each judged task's first worker that says working now, by task.
    private func workingSessions() -> [UUID: String] {
        let sessions = WorkerSessions(live.sessions)
        return Dictionary(workspace.state.tasks.compactMap { task in
            workingWorker(of: task, in: sessions)?.session.map { (task.id, $0.sessionId) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The sessions or the tasks changed: a session newly working starts its clock, one that left working or went is
    /// forgotten, and the quiet set is worked out again from what was last read.
    func observe() {
        let now = ports.now(), working = workingSessions()
        let sessionIds = Set(working.values)
        workingSince = workingSince.filter { sessionIds.contains($0.key) }
        for session in sessionIds where workingSince[session] == nil { workingSince[session] = now }
        grew = grew.filter { working[$0.key] == $0.value.session }
        evaluate(working)
    }

    /// Reads the transcripts of every working worker tab, off the main thread, notes what each shows as a sign of life on
    /// its tab's clock, and works out the quiet set again.
    func refresh() {
        observe()
        guard !isReading else { return }
        let sessions = WorkerSessions(live.sessions), transcripts = self.transcripts, now = ports.now()
        let asked: [Ask] = workspace.state.tasks.filter(isJudged).flatMap { task in
            task.workerTabs(in: sessions).compactMap { worker -> Ask? in
                guard let session = worker.session, session.state == .working, let conversation = worker.conversation else { return nil }
                return Ask(task: task.id, tab: worker.key, session: session.sessionId, agent: worker.agent, conversation: conversation)
            }
        }
        // A conversation no longer read starts afresh if it is read again.
        let keys = Set(asked.map { Reading.key($0.agent, $0.conversation) })
        calls = calls.filter { keys.contains($0.key) }
        guard !asked.isEmpty else { return }
        isReading = true
        let earlier = calls
        lastRead = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let read = await BackgroundWork.run {
                asked.map { ask in
                    let file = transcripts.file(agent: ask.agent, conversation: ask.conversation)
                    let key = Reading.key(ask.agent, ask.conversation)
                    return Reading(ask: ask, modified: file.flatMap(WorkerTranscript.modified),
                                   calls: file.flatMap { WorkerTranscript.openCalls(in: $0, agent: ask.agent, after: earlier[key], now: now) })
                }
            }
            guard !Task.isCancelled, let self else { return }
            isReading = false
            for item in read { calls[item.key] = item.calls }
            // Read fresh: a worker may have left working, or been replaced, while the files were read.
            let sessions = live.sessions, working = workingSessions(), now = ports.now()
            for item in read {
                let ask = item.ask, callSince = item.calls?.since
                guard let task = workspace.state.task(id: ask.task),
                      task.workerTab(ask.tab, in: sessions)?.session?.sessionId == ask.session else { continue }
                if let modified = item.modified { sign(ask.task, ask.tab, modified) }
                if StallWatch.isCallRunning(since: callSince, now: now) { sign(ask.task, ask.tab, now) }
                guard ask.tab == nil, working[ask.task] == ask.session else { continue }
                grew[ask.task] = item.modified.map { (ask.session, $0, callSince) }
            }
            evaluate(working)
        }
    }

    /// The quiet set from what is known: `working` is each task whose worker's session says working now. Its subagents'
    /// transcripts, as the daemon last read them (`SessionInfo.subagentsWrittenAt`), grow with its own: a turn that ended
    /// on a subagent says nothing while the child works. A call still running in its own keeps it from quiet.
    private func evaluate(_ working: [UUID: String]) {
        let now = ports.now()
        let children = Dictionary(live.sessions.compactMap { s in s.subagentsWrittenAt.map { (s.sessionId, Date(timeIntervalSince1970: $0)) } },
                                  uniquingKeysWith: { first, _ in first })
        let quiet = Set(working.filter { task, session in
            let grewAt = (grew[task]?.at).map { at in children[session].map { max(at, $0) } ?? at }
            return StallWatch.isQuietWhileWorking(transcriptGrewAt: grewAt, sessionWorkingSince: workingSince[session],
                                                  callOpenSince: grew[task]?.callSince, now: now)
        }.keys)
        guard quiet != self.quiet else { return }
        self.quiet = quiet
        changed()
    }
}
