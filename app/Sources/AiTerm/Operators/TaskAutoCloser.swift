import Foundation
import AiTermCore

/// End-of-broadcast cleanup. Records are saved before any removal; rows still present distinguish
/// a kept worktree from a removed task. A person's turn defers only that task until its next event.
@MainActor
final class TaskAutoCloser {
    static let unsavedWork = "Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe."
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let tools: OperatorToolHandler
    private let remove: @MainActor (TaskItem, Bool) async throws -> Bool
    private var running: Set<UUID> = []
    static let waitingForTurn = "Not closed: waiting for your turn to end."

    init(workspace: WorkspaceStore, live: LiveSessions, tools: OperatorToolHandler,
         remove: @escaping @MainActor (TaskItem, Bool) async throws -> Bool) {
        self.workspace = workspace; self.live = live; self.tools = tools; self.remove = remove
        live.onSessionsChanged { [weak self] _ in
            guard let self else { return }
            for run in self.workspace.state.runs { changed(run.id) }
        }
        // Window closure and restart can give up on a summary without passing through runChanged.
        workspace.onChange { [weak self] in
            guard let self else { return }
            for run in self.workspace.state.runs { changed(run.id) }
        }
    }

    func changed(_ id: UUID) {
        guard !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        Task { [weak self] in await self?.close(id) }
    }

    static func eligible(_ task: TaskItem) -> Bool {
        guard let operated = task.operated, operated.publication?.leftForYou != true else { return false }
        return operated.state == .published || operated.state == .noChange
            || (operated.state == .accepted && operated.end == .commit)
    }

    private func ready(_ run: OperatorRun) -> Bool {
        run.taskSettings?.closeWhenDone == true
            && (run.hasEnded || (run.state == .complete && (run.summary != nil || run.summaryGivenUp)))
    }

    private func shouldClose(_ run: OperatorRun) -> Bool {
        guard ready(run) else { return false }
        guard let closed = run.closedAt else { return true }
        if let phase = run.hasEnded ? run.endedAt : run.completedAt, phase > closed { return true }
        return workspace.state.tasks(inRun: run.id).contains {
            Self.eligible($0) && waits($0.id, in: run)
                && !$0.workerTabs(in: live.sessions).contains(where: { $0.session?.yourPrompt != nil })
        }
    }

    private func waits(_ task: UUID, in run: OperatorRun) -> Bool {
        guard let record = run.finished.first(where: { $0.task == task }) else { return true }
        return record.result == Self.waitingForTurn
    }

    func close(_ id: UUID) async {
        guard !running.contains(id), let run = workspace.state.run(id: id), shouldClose(run) else { return }
        running.insert(id)
        defer {
            running.remove(id)
            // A turn may end while another task's removal is awaited, when its event was coalesced.
            if workspace.persistenceError == nil { changed(id) }
        }
        let phase = run.hasEnded ? run.endedAt : run.completedAt
        var displayRun = run
        if displayRun.hasEnded { displayRun.intent = nil; displayRun.state = .complete }
        let candidates = workspace.state.tasks(inRun: id).filter(Self.eligible)
        let onlyWaiting = run.closedAt.map { closed in phase.map { $0 <= closed } ?? true } ?? false
        var prepared: [UUID] = []
        // Capture every base before removing a parent. The second pass never consults a deleted row.
        for task in candidates where !onlyWaiting || waits(task.id, in: run) {
            guard let operated = task.operated else { continue }
            var record = FinishedTaskRecord(task: task.id, key: operated.key, title: task.title, ticket: task.jira?.key,
                                            project: task.projectId, agent: task.agent, model: task.model, reasoning: task.reasoning,
                                            end: operated.end, state: operated.state, acceptedSHA: operated.acceptance?.resultSHA,
                                            branch: task.branch, mergeRequestURL: operated.publication?.mergeRequestURL,
                                            mergedSHA: operated.publication?.mergedSHA,
                                            result: OperatorLine.task(task, run: displayRun, acting: nil, requests: [])?.text ?? operated.state.rawValue,
                                            branchDeleted: false, at: tools.ports.now())
            do {
                if record.acceptedSHA != nil {
                    if let prior = run.finished.first(where: { $0.task == task.id }), prior.acceptedSHA == record.acceptedSHA,
                       let base = prior.diffBaseSHA {
                        record.diffBaseSHA = base
                    } else if let parent = RunScheduler.baseCommit(for: task.id, in: workspace.state) {
                        record.diffBaseSHA = parent
                    } else {
                        let base = try await tools.diffBase(of: task, in: run)
                        let git = tools.ports.git, path = task.worktreePath
                        record.diffBaseSHA = try await BackgroundWork.run {
                            try git.run(["rev-parse", "--verify", base + "^{commit}"], in: path)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
                if task.workerTabs(in: live.sessions).contains(where: { $0.session?.yourPrompt != nil }) {
                    record.result = Self.waitingForTurn
                } else {
                    prepared.append(task.id)
                }
            } catch {
                record.result = "Not closed: " + OperationIssue.reason(of: error)
            }
            guard let current = workspace.state.run(id: id), ready(current), current.completedAt == run.completedAt,
                  current.endedAt == run.endedAt else { return }
            save(record, in: id)
        }
        guard workspace.flush() else { return }
        for taskID in prepared {
            guard let current = workspace.state.run(id: id), ready(current), current.completedAt == run.completedAt,
                  current.endedAt == run.endedAt else { return }
            guard let task = workspace.state.task(id: taskID), Self.eligible(task),
                  var record = current.finished.first(where: { $0.task == taskID }) else { continue }
            guard task.operated?.acceptance?.resultSHA == record.acceptedSHA, task.operated?.end == record.end,
                  task.branch == record.branch, task.projectId == record.project else {
                record.result = "Not closed: the task changed while its finished record was being prepared."
                save(record, in: id)
                continue
            }
            if task.workerTabs(in: live.sessions).contains(where: { $0.session?.yourPrompt != nil }) {
                record.result = Self.waitingForTurn
                save(record, in: id)
                continue
            }
            do { record.branchDeleted = try await remove(task, run.taskSettings?.deleteMergedBranch == true) }
            catch {
                let reason = OperationIssue.reason(of: error)
                record.result = reason.hasPrefix("Not closed:") ? reason : "Not closed: " + reason
            }
            save(record, in: id)
            guard workspace.flush() else { return }
        }
        workspace.mutate { $0.updateRun(id: id) { $0.closedAt = tools.ports.now() } }
        workspace.flush()
    }

    private func save(_ record: FinishedTaskRecord, in id: UUID) {
        workspace.mutate { state in
            state.updateRun(id: id) { run in
                if let index = run.finished.firstIndex(where: { $0.task == record.task }) { run.finished[index] = record }
                else { run.finished.append(record) }
            }
        }
    }
}
