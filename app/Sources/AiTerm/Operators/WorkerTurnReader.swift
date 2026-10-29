import Foundation
import AiTermCore

/// Reads each worker's turn once it ends (spec §E, §J), on a task in any state with its first worker's tab open: the
/// worker's last message (`WorkerTranscript.lastMessage`, as `read_task` reads it), and its worktree, how many commits a
/// working task's branch has past where its work starts and whether an accepted, inReview or published one moved on from
/// its accepted commit. A turn's end is read once: when its session's state changed since the last read, or the task was
/// accepted again or reopened since (its `Basis`), when what was read is dropped at once and read again. Git and the
/// transcript are read off the main thread. What it read is `run_status`'s `TaskLiveFacts` (`OperatorController.liveFacts`)
/// until the worker's next turn starts, or until `message_task` reaches it. A task you took over, not started yet or
/// stopped, or in an ended broadcast, is not read.
@MainActor
final class WorkerTurnReader {
    /// What one ended turn left, by the session it was read for, the state it was read at and the task it was read of.
    struct Reading: Equatable, Sendable {
        var session: String, state: SessionState
        var basis: Basis
        var lastMessage: String?, commitsAhead: Int?, changedAfterAcceptance: Bool
        /// A reopened working task's HEAD is the commit it was accepted on (`TaskLiveFacts.atReopenedCommit`).
        var atReopenedCommit = false
        /// `message_task` reached the worker after its turn ended: what the turn left is answered, and its next turn's end
        /// is what counts. Nothing of this reading is shown, and a working task is not ready until that turn is read.
        var messaged = false
        var conversation: String? = nil
        var replyIdentity: Int? = nil
        var observedOrder = 0
    }

    /// What a reading holds for beyond its session: the task's state, and the commit `changedAfterAcceptance` is measured
    /// against while it is accepted, inReview or published. Accepted again on another commit, or reopened, with no turn
    /// since, what was read no longer holds.
    struct Basis: Equatable, Sendable {
        var state: OperatedState, accepted: String?
        init(_ task: OperatedTask) {
            state = task.state
            accepted = [.accepted, .inReview, .published].contains(task.state) ? task.acceptance?.resultSHA : nil
        }
    }

    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let transcripts: TranscriptLocator
    struct WorkerID: Hashable { let task: UUID; let tab: String? }
    private var workerReadings: [WorkerID: Reading] = [:]
    var readings: [UUID: Reading] {
        Dictionary(uniqueKeysWithValues: workerReadings.compactMap { $0.key.tab == nil ? ($0.key.task, $0.value) : nil })
    }
    var extraReadings: [UUID: [String: Reading]] {
        var result: [UUID: [String: Reading]] = [:]
        for (id, reading) in workerReadings { if let tab = id.tab { result[id.task, default: [:]][tab] = reading } }
        return result
    }
    private struct Seen: Equatable { let state: SessionState; let conversation: String? }
    private var seen: [String: Seen] = [:]
    private var messagedWhileReading: Set<WorkerID> = []
    private var asked: [WorkerID: UUID] = [:]
    private var requestedBasis: [WorkerID: Basis] = [:]
    private var inFlight: [WorkerID: Task<Void, Never>] = [:]
    private var nextReadOrder = 0
    /// What the readings changed: what `run_status` and the rows show.
    var changed: @MainActor () -> Void = {}
    /// The latest read, for a test to await.
    private(set) var lastRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, transcripts: TranscriptLocator) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.transcripts = transcripts
    }

    func stop() {
        for read in inFlight.values { read.cancel() }
        inFlight = [:]
        asked = [:]
        requestedBasis = [:]
        seen = [:]
        lastRead?.cancel()
    }

    /// Whether `task`'s worker turns are read: started and not stopped, still the Operator's, in a broadcast not ended.
    func isRead(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, !operated.takenOver, ![.planned, .queued, .stopped].contains(operated.state),
              let run = workspace.state.run(id: operated.runId) else { return false }
        return !run.hasEnded
    }

    /// The tabs changed, or a reconcile tick came: each first worker whose turn ended since it was last read is read, and
    /// what a worker at work again, or gone, had left is dropped. A first worker still opening (`TaskItem.workerTabs(in:now:)`:
    /// launched, no conversation named yet) is at work whatever its tab says, so its idle is read once its launch is over.
    func observe() {
        let sessions = live.sessions, now = ports.now()
        let workersByTask = WorkerSessions(sessions)
        var dropped = false, pending: [Task<Void, Never>] = []
        var retained: Set<WorkerID> = []
        for task in workspace.state.tasks {
            let watched = isRead(task)
            for worker in task.workerTabs(in: workersByTask, now: now) {
                let id = WorkerID(task: task.id, tab: worker.key)
                if !watched, let tab = worker.session { seen[tab.sessionId] = nil }
                guard watched, let tab = worker.session, tab.state.turnEnded, !worker.isOpening, let operated = task.operated else {
                    if let tab = worker.session { seen[tab.sessionId] = Seen(state: .working, conversation: worker.conversation) }
                    messagedWhileReading.remove(id)
                    asked[id] = nil
                    inFlight[id] = nil
                    if workerReadings.removeValue(forKey: id) != nil { dropped = true }
                    continue
                }
                retained.insert(id)
                let identity = Seen(state: tab.state, conversation: worker.conversation), basis = Basis(operated)
                if let earlier = workerReadings[id], earlier.session != tab.sessionId || earlier.conversation != worker.conversation || earlier.basis != basis {
                    if earlier.messaged && earlier.conversation == worker.conversation { messagedWhileReading.insert(id) }
                    workerReadings[id] = nil
                    dropped = true
                }
                let changed = seen[tab.sessionId] != identity || requestedBasis[id] != basis
                seen[tab.sessionId] = identity
                // Even without a working hook, a new reply in the same idle conversation is a new turn.
                // The background read compares reply identity before asking git again.
                if changed || workerReadings[id] == nil || inFlight[id] == nil {
                    if let current = inFlight[id], !changed { pending.append(current) }
                    else { pending.append(read(task, worker, id: id)) }
                }
            }
        }
        for id in workerReadings.keys where !retained.contains(id) {
            workerReadings[id] = nil
            asked[id] = nil
            dropped = true
        }
        let open = Set(sessions.map(\.sessionId))
        seen = seen.filter { open.contains($0.key) }
        if !pending.isEmpty { lastRead = Task { for read in pending { await read.value } } }
        if dropped { changed() }
    }

    /// An answer clears only the addressed worker's ended turn.
    func messaged(_ task: UUID, tab: String? = nil) {
        let id = WorkerID(task: task, tab: tab == WorkerTab.firstKey ? nil : tab)
        guard var reading = workerReadings[id] else { messagedWhileReading.insert(id); return }
        guard !reading.messaged else { return }
        reading.messaged = true
        workerReadings[id] = reading
        changed()
    }

    private func read(_ task: TaskItem, _ worker: WorkerTab, id: WorkerID) -> Task<Void, Never> {
        let operated = task.operated!, tab = worker.session!
        nextReadOrder += 1
        let order = nextReadOrder
        let state = tab.state, session = tab.sessionId, previous = workerReadings[id], request = UUID()
        let git = ports.git, transcripts = self.transcripts, agent = worker.agent
        let conversation = worker.conversation, worktree = task.hasCheckout ? task.worktreePath : nil, baseBranch = task.baseBranch
        let counts = operated.state == .working, reopenedFrom = operated.reopenedFrom, savedBase = operated.diffBaseSHA
        let parent = RunScheduler.baseCommit(for: task.id, in: workspace.state)
        let basis = Basis(operated), accepted = basis.accepted
        asked[id] = request
        requestedBasis[id] = basis
        let readingTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let read = await BackgroundWork.run {
                let reply = conversation.flatMap { transcripts.lastReply(agent: agent, conversation: $0) }
                if let previous, previous.basis == basis, previous.replyIdentity == reply?.identity { return nil as Reading? }
                let message = reply?.text
                guard let worktree else {
                    return Reading(session: session, state: state, basis: basis, lastMessage: message, commitsAhead: nil,
                                   changedAfterAcceptance: false, conversation: conversation, replyIdentity: reply?.identity)
                }
                let ahead = counts
                    ? Repository(worktree, git: git).commitsAhead(reopenedFrom: reopenedFrom, stackedOn: parent, baseBranch: baseBranch, savedBase: savedBase)
                    : nil
                let atReopened = counts && ahead == 0 && reopenedFrom.map { earlier in
                    (try? git.run(["rev-parse", "HEAD"], in: worktree)).map { OperatedTransitions.sameCommit($0, earlier) } ?? false
                } ?? false
                let changed = accepted.map { sha in
                    WorkerTurn.changedAfterAcceptance(porcelain: (try? git.run(["status", "--porcelain"], in: worktree)) ?? "",
                                                      head: try? git.run(["rev-parse", "HEAD"], in: worktree), accepted: sha)
                } ?? false
                return Reading(session: session, state: state, basis: basis, lastMessage: message, commitsAhead: ahead,
                               changedAfterAcceptance: changed, atReopenedCommit: atReopened,
                               conversation: conversation, replyIdentity: reply?.identity)
            }
            // Read fresh: the worker may have started its next turn, or ended it again, and the task may have been accepted
            // again or reopened, while git was asked.
            guard !Task.isCancelled, let self, self.asked[id] == request else { return }
            self.inFlight[id] = nil
            guard var reading = read,
                  self.seen[session] == Seen(state: state, conversation: conversation),
                  let current = self.workspace.state.task(id: id.task), self.isRead(current), current.operated.map(Basis.init) == basis,
                  let worker = current.workerTab(id.tab, in: self.live.sessions), worker.session?.sessionId == session,
                  worker.conversation == conversation else { return }
            reading.messaged = self.messagedWhileReading.remove(id) != nil
            reading.observedOrder = order
            guard self.workerReadings[id] != reading else { return }
            self.workerReadings[id] = reading
            self.changed()
        }
        inFlight[id] = readingTask
        return readingTask
    }
}
