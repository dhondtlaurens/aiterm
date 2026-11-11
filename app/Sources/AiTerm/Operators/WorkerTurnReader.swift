import Foundation
import AiTermCore

/// Reads each worker's turn once it ends (spec §E, §J), on a task in any state with its first worker's tab open: the
/// worker's last message (`WorkerTranscript.lastMessage`, as `read_task` reads it), and its worktree, how many commits a
/// working task's branch has past where its work starts and whether an accepted, inReview or published one moved on from
/// its accepted commit. A turn's end is read once: when its session's state changed since the last read, or the task was
/// accepted again or reopened since (its `Basis`), when what was read is dropped at once and read again. Git and the
/// transcript are read off the main thread, the transcript's tail only once its file was written since it was last
/// read (`TranscriptLocator.reply`), and git only once its reply changed. What it read is `run_status`'s `TaskLiveFacts` (`TaskLiveFacts.of`)
/// until the worker's next turn starts, or until `message_task` reaches it. A task you took over, not started yet or
/// stopped, or in an ended broadcast, is not read.
@MainActor
final class WorkerTurnReader {
    typealias Reading = WorkerTurnReading
    typealias Basis = WorkerTurnReading.Basis

    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let transcripts: TranscriptLocator
    struct WorkerID: Hashable { let task: UUID; let tab: String? }
    /// What is kept of one worker tab, its task's first worker (`tab` nil) or an extra tab, while the tab is listed for a
    /// task: dropped whole once neither is (`observe`).
    private struct Worker {
        /// Its session as last seen: one read when this changes, or its basis does.
        var seen: Seen?
        /// What its last ended turn left, as read.
        var reading: Reading?
        /// `message_task` reached it while its turn was being read: the reading lands answered.
        var messagedWhileReading = false
        /// The read under way: which request, for which basis, and its task, which a newer read replaces.
        var asked: UUID?
        var requestedBasis: Basis?
        var inFlight: Task<Void, Never>?
        /// Whether the read under way reads the transcript in full: one that does not gives way to a full read asked for
        /// meanwhile, which would otherwise be lost to it (`observe(fullRead:)`).
        var inFlightFull = false

        /// Nothing more is read for its turn until it ends again: what it had left, and a read under way, go.
        mutating func atWork() -> Bool {
            messagedWhileReading = false
            asked = nil
            inFlight = nil
            inFlightFull = false
            defer { reading = nil }
            return reading != nil
        }
    }
    private var workers: [WorkerID: Worker] = [:]
    var readings: [UUID: Reading] {
        Dictionary(uniqueKeysWithValues: workers.compactMap { id, worker in id.tab == nil ? worker.reading.map { (id.task, $0) } : nil })
    }
    var extraReadings: [UUID: [String: Reading]] {
        var result: [UUID: [String: Reading]] = [:]
        for (id, worker) in workers { if let tab = id.tab, let reading = worker.reading { result[id.task, default: [:]][tab] = reading } }
        return result
    }
    private struct Seen: Equatable { let session: String; let state: SessionState; let conversation: String? }
    private var nextReadOrder = 0
    /// What the readings changed: what `run_status` and the rows show.
    var changed: @MainActor () -> Void = {}

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, transcripts: TranscriptLocator) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.transcripts = transcripts
    }

    /// Every read under way is cancelled and forgotten, and every session as if not seen; the readings stay.
    func stop() {
        for id in workers.keys {
            workers[id]?.inFlight?.cancel()
            workers[id]?.inFlight = nil
            workers[id]?.inFlightFull = false
            workers[id]?.asked = nil
            workers[id]?.requestedBasis = nil
            workers[id]?.seen = nil
        }
    }

    /// Whether `task`'s worker turns are read: started and not stopped, still the Operator's, in a broadcast not ended.
    func isRead(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, !operated.takenOver, ![.planned, .queued, .stopped].contains(operated.state),
              let run = workspace.state.run(id: operated.runId) else { return false }
        return !run.hasEnded
    }

    /// The tabs changed, or a reconcile tick came (`fullRead`, every ended turn's transcript read in full, whatever its
    /// stamp says: `TranscriptLocator`): each first worker whose turn ended since it was last read is read, and
    /// what a worker at work again, or gone, had left is dropped. A first worker still opening (`TaskItem.workerTabs(in:now:)`:
    /// launched, no conversation named yet) is at work whatever its tab says, so its idle is read once its launch is over.
    func observe(fullRead: Bool = false) {
        let sessions = live.sessions, now = ports.now()
        let workersByTask = WorkerSessions(sessions)
        var dropped = false
        var listed: Set<WorkerID> = []
        for task in workspace.state.tasks {
            let watched = isRead(task)
            for tab in task.workerTabs(in: workersByTask, now: now) {
                let id = WorkerID(task: task.id, tab: tab.key)
                listed.insert(id)
                var worker = workers[id] ?? Worker()
                defer { workers[id] = worker }
                guard watched, let session = tab.session, session.state.turnEnded, !tab.isOpening, let operated = task.operated else {
                    worker.seen = tab.session.map { Seen(session: $0.sessionId, state: .working, conversation: tab.conversation) }
                    if worker.atWork() { dropped = true }
                    continue
                }
                let identity = Seen(session: session.sessionId, state: session.state, conversation: tab.conversation), basis = Basis(operated)
                if let earlier = worker.reading,
                   earlier.session != session.sessionId || earlier.conversation != tab.conversation || earlier.basis != basis {
                    if earlier.messaged && earlier.conversation == tab.conversation { worker.messagedWhileReading = true }
                    worker.reading = nil
                    dropped = true
                }
                let changed = worker.seen != identity || worker.requestedBasis != basis
                worker.seen = identity
                // Even without a working hook, a new reply in the same idle conversation is a new turn.
                // The background read compares reply identity before asking git again. A read under way for an unchanged
                // turn is left to finish, unless a full read is asked for and it is not one: the full read takes its place.
                // A turn that ended, or a basis that changed, is read in full.
                if changed || worker.inFlight == nil || (fullRead && !worker.inFlightFull) {
                    read(task, tab, operated, &worker, id: id, fullRead: fullRead || changed)
                }
            }
        }
        // A worker no task lists any more: all of it goes, and a read under way for it lands nowhere.
        for (id, worker) in workers where !listed.contains(id) {
            if worker.reading != nil { dropped = true }
            workers[id] = nil
        }
        if dropped { changed() }
    }

    /// An answer clears only the addressed worker's ended turn.
    func messaged(_ task: UUID, tab: String? = nil) {
        let id = WorkerID(task: task, tab: TabReference(tab).key)
        guard var reading = workers[id]?.reading else { workers[id, default: Worker()].messagedWhileReading = true; return }
        guard !reading.messaged else { return }
        reading.messaged = true
        workers[id]?.reading = reading
        changed()
    }

    /// Reads the turn `worker` ended, as `record` asks it: the read replaces one under way.
    private func read(_ task: TaskItem, _ worker: WorkerTab, _ operated: OperatedTask, _ record: inout Worker, id: WorkerID,
                      fullRead: Bool) {
        let tab = worker.session!
        nextReadOrder += 1
        let order = nextReadOrder
        let state = tab.state, session = tab.sessionId, previous = record.reading, request = UUID()
        let git = ports.git, transcripts = self.transcripts, agent = worker.agent
        let conversation = worker.conversation, worktree = task.hasCheckout ? task.worktreePath : nil, baseBranch = task.baseBranch
        let counts = operated.state == .working, reopenedFrom = operated.reopenedFrom, savedBase = operated.diffBaseSHA
        let parent = RunScheduler.baseCommit(for: task.id, in: workspace.state)
        let basis = Basis(operated), accepted = basis.accepted
        record.asked = request
        record.requestedBasis = basis
        // A read under way for this worker is for a turn this one replaces.
        record.inFlight?.cancel()
        record.inFlightFull = fullRead
        record.inFlight = ports.work.start { [weak self] in
            guard !Task.isCancelled else { return }
            let (read, tailRead) = await BackgroundWork.run { () -> (Reading?, Bool) in
                let found = conversation.map { transcripts.reply(agent: agent, conversation: $0, fullRead: fullRead) }
                // A full read counts as one whether or not the file was there to read.
                let reply = found?.reply, tailRead = fullRead || found?.read == true
                if let previous, previous.basis == basis, previous.replyIdentity == reply?.identity { return (nil, tailRead) }
                let message = reply?.text
                guard let worktree else {
                    return (Reading(session: session, state: state, basis: basis, lastMessage: message, commitsAhead: nil,
                                    changedAfterAcceptance: false, conversation: conversation, replyIdentity: reply?.identity), tailRead)
                }
                let ahead = counts
                    ? Repository(worktree, git: git).commitsAhead(reopenedFrom: reopenedFrom, stackedOn: parent, baseBranch: baseBranch, savedBase: savedBase)
                    : nil
                let atReopened = counts && ahead == 0 && reopenedFrom.map { earlier in
                    (try? git.run(["rev-parse", "HEAD"], in: worktree)).map { OperatedTransitions.sameCommit($0, earlier) } ?? false
                } ?? false
                let changed = accepted.map { sha in
                    WorkerTurn.changedAfterAcceptance(head: try? git.run(["rev-parse", "HEAD"], in: worktree), accepted: sha,
                        fingerprint: basis.fingerprint.flatMap { _ in try? Repository(worktree, git: git).worktreeFingerprint() },
                        acceptedFingerprint: basis.fingerprint)
                } ?? false
                return (Reading(session: session, state: state, basis: basis, lastMessage: message, commitsAhead: ahead,
                                changedAfterAcceptance: changed, atReopenedCommit: atReopened,
                                conversation: conversation, replyIdentity: reply?.identity), true)
            }
            // Read: its transcript's tail, in full or past the stamp, or git asked about its branch. An unchanged turn between
            // ticks costs neither.
            if tailRead { WorkMeter.note(.turnRead) }
            // Read fresh: the worker may have started its next turn, or ended it again, and the task may have been accepted
            // again or reopened, while git was asked.
            guard !Task.isCancelled, let self, self.workers[id]?.asked == request else { return }
            self.workers[id]?.inFlight = nil
            self.workers[id]?.inFlightFull = false
            guard var reading = read,
                  self.workers[id]?.seen == Seen(session: session, state: state, conversation: conversation),
                  let current = self.workspace.state.task(id: id.task), self.isRead(current), current.operated.map(Basis.init) == basis,
                  let worker = current.workerTab(id.tab, in: self.live.sessions), worker.session?.sessionId == session,
                  worker.conversation == conversation else { return }
            reading.messaged = self.workers[id]?.messagedWhileReading == true
            self.workers[id]?.messagedWhileReading = false
            reading.observedOrder = order
            guard self.workers[id]?.reading != reading else { return }
            self.workers[id]?.reading = reading
            self.changed()
        }
    }
}
