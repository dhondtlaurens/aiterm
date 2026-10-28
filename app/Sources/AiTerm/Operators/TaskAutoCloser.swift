import Foundation
import AiTermCore

/// End-of-broadcast cleanup. Records are saved before any removal; rows still present distinguish
/// a kept worktree from a removed task. A person's turn defers only that task until its next event.
@MainActor
final class TaskAutoCloser {
    nonisolated static let unsavedWork = "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe."
    nonisolated static let waitingForTurn = "Not closed: waiting for your turn to end."

    struct WaitingForTurn: LocalizedError {
        var errorDescription: String? { TaskAutoCloser.waitingForTurn }
    }

    private struct Phase: Equatable {
        let completed: Date?, ended: Date?
        init(_ run: OperatorRun) { completed = run.completedAt; ended = run.endedAt }
    }
    private struct Pass {
        let phase: Phase
        var attempted: Set<UUID> = []
        var waiting: Set<UUID> = []
    }
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let tools: OperatorToolHandler
    private let remove: @MainActor (TaskItem, Bool) async throws -> Bool
    private var running: Set<UUID> = []
    private var passes: [UUID: Pass] = [:]

    init(workspace: WorkspaceStore, live: LiveSessions, tools: OperatorToolHandler,
         remove: @escaping @MainActor (TaskItem, Bool) async throws -> Bool) {
        self.workspace = workspace; self.live = live; self.tools = tools; self.remove = remove
        // LiveSessions lives as long as the workspace. Its listener holds no owner alive.
        live.onSessionsChanged { [weak self] _ in
            guard let self else { return }
            for (id, pass) in passes where !pass.waiting.isEmpty { changed(id) }
        }
    }

    func changed(_ id: UUID) {
        guard !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        Task { [weak self] in await self?.close(id) }
    }

    static func isDriving(_ task: TaskItem, in live: LiveSessions) -> Bool {
        task.workerTabs(in: live.sessions).contains { $0.session?.yourPrompt != nil }
    }

    static func failureReason(_ error: Error) -> String {
        let reason = OperationIssue.reason(of: error)
        return reason.hasPrefix("Not closed:") ? reason : "Not closed: " + reason
    }

    /// Only tasks that reached their chosen end, with nothing left for the person, may close.
    static func eligible(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, operated.publication?.leftForYou != true else { return false }
        return operated.state == .published || operated.state == .noChange
            || (operated.state == .accepted && operated.end == .commit)
    }

    /// Legacy runs and unfinished summaries never initiate cleanup; End needs no summary.
    private func ready(_ run: OperatorRun) -> Bool {
        run.taskSettings?.closeWhenDone == true
            && (run.hasEnded || (run.state == .complete && (run.summary != nil || run.summaryGivenUp)))
    }

    /// A pass runs once per completion or End, then resumes only work deferred for a person's turn.
    private func shouldClose(_ run: OperatorRun) -> Bool {
        guard ready(run) else { return false }
        if let pass = passes[run.id], pass.phase == Phase(run) {
            return workspace.state.tasks(inRun: run.id).contains {
                Self.eligible($0) && waits($0.id, in: pass) && !Self.isDriving($0, in: live)
            }
        }
        guard let closed = run.closedAt else { return true }
        return (run.hasEnded ? run.endedAt : run.completedAt).map { $0 > closed } ?? false
    }

    /// Attempted failures stay for the person; deferred turns have not had their removal attempted.
    private func waits(_ task: UUID, in pass: Pass) -> Bool { !pass.attempted.contains(task) }

    private func samePhase(_ run: OperatorRun) -> OperatorRun? {
        guard let current = workspace.state.run(id: run.id), ready(current), Phase(current) == Phase(run) else { return nil }
        return current
    }

    /// A snapshot usable before publication as well as before removal. The live row remains authoritative
    /// until removed; keeping the base here at acceptance survives publication and an app restart.
    static func record(_ task: TaskItem, in run: OperatorRun, base: String?, at: Date) -> FinishedTaskRecord? {
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
        record.diffBaseSHA = base
        return record
    }

    static func save(_ record: FinishedTaskRecord, in id: UUID, workspace: WorkspaceStore) {
        workspace.mutate { state in
            state.updateRun(id: id) { run in
                if let index = run.finished.firstIndex(where: { $0.task == record.task }) { run.finished[index] = record }
                else { run.finished.append(record) }
            }
        }
    }

    /// Saves every candidate before removing any parent, then removes each once. A pass with a person's
    /// turn still pending stays open (`closedAt` nil), so a fresh closer can finish it after restart.
    func close(_ id: UUID) async {
        guard !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        running.insert(id)
        if passes[id]?.phase != Phase(run) { passes[id] = Pass(phase: Phase(run)) }
        defer {
            running.remove(id)
            // A turn may end while another removal is awaited, coalescing its event.
            if workspace.persistenceError == nil { changed(id) }
        }
        guard let pass = passes[id] else { return }
        let candidates = workspace.state.tasks(inRun: id).filter {
            Self.eligible($0) && waits($0.id, in: pass)
        }
        for task in candidates {
            let prior = run.finished.first { $0.task == task.id && $0.acceptedSHA == task.operated?.acceptance?.resultSHA }
            let base = prior?.diffBaseSHA ?? RunScheduler.baseCommit(for: task.id, in: workspace.state)
            guard var record = Self.record(task, in: run, base: base, at: tools.ports.now()) else { continue }
            if Self.isDriving(task, in: live) {
                passes[id]?.waiting.insert(task.id)
                record.result = Self.waitingForTurn
            }
            Self.save(record, in: id, workspace: workspace)
        }
        guard workspace.flush() else { return }
        for original in candidates {
            guard let current = samePhase(run) else { return }
            guard let task = workspace.state.task(id: original.id), Self.eligible(task),
                  var record = current.finished.first(where: { $0.task == task.id }) else { continue }
            if Self.isDriving(task, in: live) {
                passes[id]?.waiting.insert(task.id)
                record.result = Self.waitingForTurn
                Self.save(record, in: id, workspace: workspace)
                guard workspace.flush() else { return }
                continue
            }
            passes[id]?.waiting.remove(task.id)
            passes[id]?.attempted.insert(task.id)
            do {
                guard task.operated?.acceptance?.resultSHA == record.acceptedSHA, task.operated?.end == record.end,
                      task.branch == record.branch, task.projectId == record.project else {
                    throw ActionUnavailable("The task changed while its finished record was being prepared.")
                }
                record.branchDeleted = try await remove(task, run.taskSettings?.deleteMergedBranch == true)
            } catch is WaitingForTurn {
                passes[id]?.attempted.remove(task.id)
                passes[id]?.waiting.insert(task.id)
                record.result = Self.waitingForTurn
            } catch { record.result = Self.failureReason(error) }
            Self.save(record, in: id, workspace: workspace)
            guard workspace.flush() else { return }
        }
        guard samePhase(run) != nil else { return }
        guard let pass = passes[id] else { return }
        let pending = workspace.state.tasks(inRun: id).contains { Self.eligible($0) && waits($0.id, in: pass) }
        workspace.mutate { $0.updateRun(id: id) { $0.closedAt = pending ? nil : tools.ports.now() } }
        workspace.flush()
    }
}
