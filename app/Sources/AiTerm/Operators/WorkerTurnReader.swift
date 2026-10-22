import Foundation
import AiTermCore

/// Reads each worker's turn once it ends (spec §E, §J), on a task in any state with its first worker's tab open: the
/// worker's last message (`WorkerTranscript.lastMessage`, as `read_task` reads it), and its worktree, how many commits a
/// working task's branch has past where its work starts and whether an accepted, inReview or published one moved on from
/// its accepted commit. A turn's end is read once: when its session's state changed since the last read. Git and the
/// transcript are read off the main thread. What it read is `run_status`'s `TaskLiveFacts` (`OperatorController.liveFacts`)
/// until the worker's next turn starts, or until `message_task` reaches it. A task you took over, not started yet or
/// stopped, or in an ended broadcast, is not read.
@MainActor
final class WorkerTurnReader {
    /// What one ended turn left, by the session it was read for and the state it was read at.
    struct Reading: Equatable, Sendable {
        var session: String, state: SessionState
        var lastMessage: String?, commitsAhead: Int?, changedAfterAcceptance: Bool
        /// A reopened working task's HEAD is the commit it was accepted on (`TaskLiveFacts.atReopenedCommit`).
        var atReopenedCommit = false
        /// `message_task` reached the worker after its turn ended: what the turn left is answered, and its next turn's end
        /// is what counts. Nothing of this reading is shown, and a working task is not ready until that turn is read.
        var messaged = false
    }

    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    /// The latest reading of each task's first worker, by task.
    private(set) var readings: [UUID: Reading] = [:]
    /// The state each session was last read at, or seen at while at work: a turn's end is new when it differs.
    private var seen: [String: SessionState] = [:]
    /// The tasks `message_task` reached while their turn was still being read: that reading lands answered.
    private var messagedWhileReading: Set<UUID> = []
    /// What the readings changed: what `run_status` and the rows show.
    var changed: @MainActor () -> Void = {}
    /// The latest read, for a test to await.
    private(set) var lastRead: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
    }

    /// Whether `task`'s worker turns are read: started and not stopped, still the Operator's, in a broadcast not ended.
    func isRead(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, !operated.takenOver, ![.planned, .queued, .stopped].contains(operated.state),
              let run = workspace.state.run(id: operated.runId) else { return false }
        return !run.hasEnded
    }

    /// The tabs changed: each first worker whose turn ended since it was last read is read, and what a worker at work
    /// again, or gone, had left is dropped.
    func observe() {
        let sessions = live.sessions
        var dropped = false
        for task in workspace.state.tasks {
            let worker = task.firstWorker(in: sessions), watched = isRead(task)
            // A task not read now (taken over, say) forgets its worker's last read: once it is read again, a turn that
            // ended meanwhile, or before it was handed back, is new.
            if !watched, let worker { seen[worker.sessionId] = nil }
            let tab = watched ? worker : nil
            guard let tab, tab.state == .idle || tab.state == .done else {
                // A turn under way, or no worker: what its last turn left no longer holds, and its end will be new.
                if let tab { seen[tab.sessionId] = tab.state }
                messagedWhileReading.remove(task.id)
                if readings.removeValue(forKey: task.id) != nil { dropped = true }
                continue
            }
            if let reading = readings[task.id], reading.session != tab.sessionId {
                readings[task.id] = nil
                dropped = true
            }
            guard seen[tab.sessionId] != tab.state else { continue }
            seen[tab.sessionId] = tab.state
            read(task, tab)
        }
        let open = Set(sessions.map(\.sessionId))
        seen = seen.filter { open.contains($0.key) }
        if dropped { changed() }
    }

    /// `message_task` reached the task's first worker: what its last turn left is answered.
    func messaged(_ id: UUID) {
        guard var reading = readings[id] else {
            messagedWhileReading.insert(id)
            return
        }
        guard !reading.messaged else { return }
        reading.messaged = true
        readings[id] = reading
        changed()
    }

    private func read(_ task: TaskItem, _ tab: SessionInfo) {
        guard let operated = task.operated else { return }
        let id = task.id, worker = task.workerTabs(in: live.sessions)[0], state = tab.state, session = tab.sessionId
        let git = ports.git, home = ports.home, claudeConfig = ports.claudeConfig, agent = worker.agent
        let conversation = worker.conversation, worktree = task.hasCheckout ? task.worktreePath : nil, baseBranch = task.baseBranch
        let counts = operated.state == .working, reopenedFrom = operated.reopenedFrom
        let parent = RunScheduler.baseCommit(for: id, in: workspace.state)
        let accepted = [.accepted, .inReview, .published].contains(operated.state) ? operated.acceptance?.resultSHA : nil
        lastRead = Task { [weak self] in
            let read = await BackgroundWork.run {
                let message = conversation.flatMap {
                    WorkerTranscript.lastMessage(agent: agent, conversation: $0, home: home, claudeConfig: claudeConfig)
                }
                guard let worktree else { return (message: message, ahead: Int?.none, changed: false, atReopened: false) }
                let ahead = counts
                    ? Repository(worktree, git: git).commitsAhead(reopenedFrom: reopenedFrom, stackedOn: parent, baseBranch: baseBranch)
                    : nil
                let atReopened = counts && ahead == 0 && reopenedFrom.map { earlier in
                    (try? git.run(["rev-parse", "HEAD"], in: worktree)).map { OperatedTransitions.sameCommit($0, earlier) } ?? false
                } ?? false
                let changed = accepted.map { sha in
                    WorkerTurn.changedAfterAcceptance(porcelain: (try? git.run(["status", "--porcelain"], in: worktree)) ?? "",
                                                      head: try? git.run(["rev-parse", "HEAD"], in: worktree), accepted: sha)
                } ?? false
                return (message: message, ahead: ahead, changed: changed, atReopened: atReopened)
            }
            // Read fresh: the worker may have started its next turn, or ended it again, while git was asked.
            guard let self, self.seen[session] == state,
                  let current = self.workspace.state.task(id: id), self.isRead(current),
                  current.firstWorker(in: self.live.sessions)?.sessionId == session else { return }
            let reading = Reading(session: session, state: state, lastMessage: read.message, commitsAhead: read.ahead,
                                  changedAfterAcceptance: read.changed, atReopenedCommit: read.atReopened,
                                  messaged: self.messagedWhileReading.remove(id) != nil)
            guard self.readings[id] != reading else { return }
            self.readings[id] = reading
            self.changed()
        }
    }
}
