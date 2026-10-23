import Foundation
import AiTermCore

/// Doubts a worker's `working` when nothing shows it (spec §H): the daemon's session state can stick at working long after
/// its worker did anything, and nothing else looks at a worker once its task leaves `working`. A task whose first worker's
/// session says working while its transcript (`TranscriptLocator`) has not grown for `OperatorTiming.liveQuietMinutes`
/// (`StallWatch.isQuietWhileWorking`) is `quiet`: `run_status` reads it `working?` and lists it as uncertain, on a task in
/// any state but one you took over or not started. The transcripts' dates are read off the main thread on each reconcile
/// tick (`refresh`), never when a status is built; what the session changes is noted as it happens (`observe`).
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
    /// When each task's transcript last grew, as read for the session it names.
    private var grew: [UUID: (session: String, at: Date)] = [:]
    private var isReading = false
    /// A working worker whose transcript is to be found, and what was found of it.
    private struct Ask: Sendable { let task: UUID, session: String, agent: AgentKind, conversation: String }
    private struct Reading: Sendable { let task: UUID, session: String, modified: Date? }
    /// What the quiet set changed: what `run_status` and the waker show.
    var changed: @MainActor () -> Void = {}
    /// The latest read, for a test to await.
    private(set) var lastRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, transcripts: TranscriptLocator) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.transcripts = transcripts
    }

    /// The first worker of `task`, when its task is judged and its session says working.
    private func workingWorker(of task: TaskItem, in sessions: [SessionInfo]) -> WorkerTab? {
        guard let operated = task.operated, !operated.takenOver, ![.planned, .queued, .stopped].contains(operated.state) else { return nil }
        let worker = task.workerTabs(in: sessions)[0]
        return worker.session?.state == .working ? worker : nil
    }

    /// The session of each judged task's first worker that says working now, by task.
    private func workingSessions() -> [UUID: String] {
        let sessions = live.sessions
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

    /// Reads the transcripts of every working worker, off the main thread, and works out the quiet set again.
    func refresh() {
        observe()
        guard !isReading else { return }
        let sessions = live.sessions, transcripts = self.transcripts
        let asked: [Ask] = workspace.state.tasks.compactMap { task in
            guard let worker = workingWorker(of: task, in: sessions), let session = worker.session?.sessionId,
                  let conversation = worker.conversation else { return nil }
            return Ask(task: task.id, session: session, agent: worker.agent, conversation: conversation)
        }
        guard !asked.isEmpty else { return }
        isReading = true
        lastRead = Task { [weak self] in
            let read = await BackgroundWork.run {
                asked.map { ask in
                    Reading(task: ask.task, session: ask.session,
                            modified: transcripts.file(agent: ask.agent, conversation: ask.conversation).flatMap(WorkerTranscript.modified))
                }
            }
            guard let self else { return }
            isReading = false
            // Read fresh: a worker may have left working, or been replaced, while the files were read.
            let working = workingSessions()
            for item in read {
                guard working[item.task] == item.session else { continue }
                grew[item.task] = item.modified.map { (item.session, $0) }
            }
            evaluate(working)
        }
    }

    /// The quiet set from what is known: `working` is each task whose worker's session says working now.
    private func evaluate(_ working: [UUID: String]) {
        let now = ports.now()
        let quiet = Set(working.filter { task, session in
            StallWatch.isQuietWhileWorking(transcriptGrewAt: grew[task]?.at, sessionWorkingSince: workingSince[session], now: now)
        }.keys)
        guard quiet != self.quiet else { return }
        self.quiet = quiet
        changed()
    }
}
