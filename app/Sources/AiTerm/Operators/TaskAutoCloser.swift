import Foundation
import AiTermCore

/// End-of-broadcast cleanup (spec, Auto-close). A task's `FinishedTaskRecord` is written just before its
/// removal starts and taken back when the removal fails or waits, so `finished` holds only tasks whose row
/// is gone; why a task stays is on the task, for its card (`OperatedTask.keptReason`). A person's turn, an
/// agent's, or the helper being away defers only that task (`ClosingWait`, on the task as `closingWait` for its card): a
/// turn until its end, the helper until it is back (`sweep`).
@MainActor
final class TaskAutoCloser {
    nonisolated static let unsavedWork = "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe."

    private struct Phase: Equatable {
        let completed: Date?, ended: Date?
        init(_ run: OperatorRun) { completed = run.completedAt; ended = run.endedAt }
    }
    private struct Pass {
        let phase: Phase
        var attempted: Set<UUID> = []
        var deferred: [UUID: ClosingWait] = [:]
    }
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let git: any GitRunning
    private let now: @MainActor () -> Date
    private let remove: @MainActor (TaskItem, _ starting: @MainActor () -> Bool) async throws -> Void
    /// Until the helper's first connected snapshot (`sweep`) an empty session list is unknown, not "nobody is driving".
    private var sessionsKnown = false
    private var running: Set<UUID> = []
    private var passes: [UUID: Pass] = [:]
    /// The tasks whose branch is being deleted now, which `checkBranchRecords` leaves alone.
    private var deleting: Set<UUID> = []
    private var branchRecordsChecked = false
    /// The latest closing `changed` started, for a test to await.
    private(set) var lastClose: Task<Void, Never>?

    /// `remove` is the person's Remove without its questions (`TaskRemover.removeAutomatically`): it calls
    /// `starting` once nothing is left to keep the task, and stops when that returns false.
    init(workspace: WorkspaceStore, live: LiveSessions, git: any GitRunning, now: @escaping @MainActor () -> Date,
         remove: @escaping @MainActor (TaskItem, _ starting: @MainActor () -> Bool) async throws -> Void) {
        self.workspace = workspace; self.live = live; self.git = git; self.now = now; self.remove = remove
        // LiveSessions lives as long as the workspace. Its listener holds no owner alive.
        live.onSessionsChanged { [weak self] _ in
            guard let self else { return }
            for (id, pass) in passes where !pass.deferred.isEmpty { changed(id) }
        }
    }

    /// The live sessions are known, and the helper is there: whatever is due in any run, ended ones included,
    /// is closed, and a task that waited for the helper is tried again. At launch this finishes a closing the
    /// app quit or crashed in.
    func sweep() {
        sessionsKnown = true
        if !branchRecordsChecked {
            branchRecordsChecked = true
            Task { [weak self] in await self?.checkBranchRecords() }
        }
        passes = passes.mapValues { pass in
            var pass = pass
            pass.deferred = pass.deferred.filter { $0.value != .helper }
            return pass
        }
        for run in workspace.state.runs { changed(run.id) }
    }

    /// A record saved as deleting its branch just before the app quit, or whose taking back could not be saved, can say
    /// so of a branch that is still here. It is set back to kept: the deletion's rule was read from a row that is gone.
    private func checkBranchRecords() async {
        let records = workspace.state.runs.flatMap { run in run.finished.filter(\.branchDeleted).map { (run.id, $0) } }
        for (id, record) in records where !deleting.contains(record.task) {
            guard let project = workspace.state.project(id: record.project) else { continue }
            let git = git, path = project.path, ref = "refs/heads/" + record.branch
            // Unknown when git fails: the record is left as it is.
            guard let stayed = try? await BackgroundWork.run({
                try git.ask(["rev-parse", "--verify", "--quiet", ref], in: path, none: [1]) != nil
            }), stayed, !deleting.contains(record.task),
                  var kept = workspace.state.run(id: id)?.finished.first(where: { $0.task == record.task }), kept.branchDeleted else { continue }
            kept.branchDeleted = false
            guard save(kept, in: id) else { return }
        }
    }

    func changed(_ id: UUID) {
        guard sessionsKnown, !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        lastClose = Task { [weak self] in await self?.close(id) }
    }

    static func isDriving(_ task: TaskItem, in live: LiveSessions) -> Bool {
        task.workerTabs(in: live.sessions).contains { $0.session?.yourPrompt != nil }
    }

    static func failureReason(_ error: Error) -> String {
        let reason = OperationIssue.reason(of: error)
        return reason.hasPrefix("Not closed:") ? reason : "Not closed: " + reason
    }

    /// Only tasks finished by reaching their end, with nothing left for the person, may close.
    static func eligible(_ task: TaskItem) -> Bool {
        guard let operated = task.operated else { return false }
        return operated.isFinished && operated.state != .stopped && operated.publication?.leftForYou != true
    }

    /// A pass runs once per completion or End, then resumes only what it deferred, once that may go on.
    private func shouldClose(_ run: OperatorRun) -> Bool {
        guard run.closingIsDue else { return false }
        if let pass = passes[run.id], pass.phase == Phase(run) {
            return workspace.state.tasks(inRun: run.id).contains { task in
                guard Self.eligible(task), waits(task.id, in: pass) else { return false }
                switch pass.deferred[task.id] {
                case .turn?: return !Self.isDriving(task, in: live)
                case .agentTurn?: return !TaskRemover.turnInFlight(task.id, in: live)
                case .helper?: return false
                case nil: return true
                }
            }
        }
        guard let closed = run.closedAt else { return true }
        return (run.hasEnded ? run.endedAt : run.completedAt).map { $0 > closed } ?? false
    }

    /// A failed removal stays for the person; a deferred one has not been attempted.
    private func waits(_ task: UUID, in pass: Pass) -> Bool { !pass.attempted.contains(task) }

    private func samePhase(_ run: OperatorRun) -> OperatorRun? {
        guard let current = workspace.state.run(id: run.id), current.closingIsDue, Phase(current) == Phase(run) else { return nil }
        return current
    }

    /// The task's card as it read when it closed, with the diff base it kept from its acceptance.
    static func record(_ task: TaskItem, in run: OperatorRun, at: Date) -> FinishedTaskRecord? {
        guard let operated = task.operated else { return nil }
        // End hides live task lines. Read the completed presentation to retain the task's outcome.
        var displayRun = run
        if displayRun.hasEnded { displayRun.intent = nil; displayRun.state = .complete }
        var record = FinishedTaskRecord(task: task.id, key: operated.key, title: task.title, ticket: task.jira?.key,
                                        project: task.projectId, agent: task.agent, model: task.model, reasoning: task.reasoning,
                                        end: operated.end, state: operated.state, acceptedSHA: operated.acceptance?.resultSHA,
                                        branch: task.branch, mergeRequestURL: operated.publication?.mergeRequestURL,
                                        mergedSHA: operated.publication?.mergedSHA,
                                        result: OperatorLine.task(task, run: displayRun, acting: nil, requests: [])?.text ?? operated.state.rawValue,
                                        branchDeleted: false, at: at)
        record.diffBaseSHA = operated.diffBaseSHA
        return record
    }

    private func save(_ record: FinishedTaskRecord, in id: UUID) -> Bool {
        workspace.mutate { state in
            state.updateRun(id: id) { run in
                if let index = run.finished.firstIndex(where: { $0.task == record.task }) { run.finished[index] = record }
                else { run.finished.append(record) }
            }
        }
        return workspace.flush()
    }

    /// `finished` holds only tasks whose row is gone: a record whose row is still here, written just before a
    /// removal that then failed or waited, or before the app quit mid-removal, is taken back.
    private func takeBack(_ task: UUID, in id: UUID) -> Bool {
        guard workspace.state.task(id: task) != nil,
              workspace.state.run(id: id)?.finished.contains(where: { $0.task == task }) == true else { return workspace.persistenceError == nil }
        workspace.mutate { $0.updateRun(id: id) { $0.finished.removeAll { $0.task == task } } }
        return workspace.flush()
    }

    /// Closes each eligible task of the run not yet tried in this completion or End, one at a time. A pass
    /// with a task deferred stays open (`closedAt` nil), so a sweep after a restart finishes it.
    func close(_ id: UUID) async {
        guard sessionsKnown, !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        running.insert(id)
        if passes[id]?.phase != Phase(run) { passes[id] = Pass(phase: Phase(run)) }
        defer {
            running.remove(id)
            // A turn may end while another removal is awaited, coalescing its event.
            if workspace.persistenceError == nil { changed(id) }
        }
        guard let pass = passes[id] else { return }
        let candidates = workspace.state.tasks(inRun: id).filter { Self.eligible($0) && waits($0.id, in: pass) }.map(\.id)
        for candidate in candidates {
            guard let current = samePhase(run) else { return }
            guard let task = workspace.state.task(id: candidate), Self.eligible(task) else { continue }
            passes[id]?.deferred[task.id] = nil
            passes[id]?.attempted.insert(task.id)
            guard await close(task, in: current) else { return }
        }
        guard samePhase(run) != nil, let pass = passes[id] else { return }
        let pending = workspace.state.tasks(inRun: id).contains { Self.eligible($0) && waits($0.id, in: pass) }
        workspace.mutate { $0.updateRun(id: id) { $0.closedAt = pending ? nil : now() } }
        workspace.flush()
    }

    /// One task removed, its record written as the removal starts, then its merged branch deleted once its
    /// row is gone, so a failed branch check only keeps the branch. False when something could not be saved.
    private func close(_ task: TaskItem, in run: OperatorRun) async -> Bool {
        guard let record = Self.record(task, in: run, at: now()) else { return workspace.persistenceError == nil }
        do {
            try await remove(task) { [self] in save(record, in: run.id) }
        } catch let deferred as ClosingWait {
            passes[run.id]?.attempted.remove(task.id)
            passes[run.id]?.deferred[task.id] = deferred
            return takeBack(task.id, in: run.id)
        } catch {
            return takeBack(task.id, in: run.id)
        }
        guard run.taskSettings?.deleteMergedBranch == true, let operated = task.operated,
              let project = workspace.state.project(id: task.projectId) else { return workspace.persistenceError == nil }
        var deleted = record
        deleted.branchDeleted = true
        deleting.insert(task.id)
        defer { deleting.remove(task.id) }
        let gone = await MergedBranchCheck.delete(branch: task.branch, acceptedSHA: operated.acceptance?.resultSHA, end: operated.end,
                                                  publication: operated.publication, kind: task.kind, path: project.path, git: git,
                                                  saveDeletion: { [self] in save(deleted, in: run.id) })
        // A kept branch reads as kept, including one whose deletion was saved, or failed to save, before git refused it.
        return gone ? workspace.persistenceError == nil : save(record, in: run.id)
    }
}
