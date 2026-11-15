import Foundation
import AiTermCore

/// Remembers the workers told to finish their turn, including across an app restart.
@MainActor final class SignalPauseSignaller {
    static let pauseNote = "[AiTerm] The person paused the Operator for this task. Finish the step you are on, then end your turn without starting anything new. If background work wakes you before you hear more, end your turn again. You will be told when to carry on."
    static let carryOnNote = "[AiTerm] The Operator is resumed for this task. Carry on with your task where you left off."
    let workspace: WorkspaceStore, live: LiveSessions, native: SignalWorkerIO
    let enabled: @MainActor () -> Bool, now: @MainActor () -> Date
    private var running = false
    private var attempted: Set<PausedWorker> = []
    init(workspace: WorkspaceStore, live: LiveSessions, native: SignalWorkerIO,
         enabled: @escaping @MainActor () -> Bool, now: @escaping @MainActor () -> Date) {
        self.workspace = workspace; self.live = live; self.native = native; self.enabled = enabled; self.now = now
    }
    func paused(_ task: TaskItem) -> Bool {
        workspace.state.operatorSession?.paused == true || task.signalTask.flatMap { workspace.state.signal(id: $0.signal) }?.enabled == false
    }
    func reconcile() async {
        guard enabled(), workspace.canChangeWorkspace, !running else { return }
        running = true; defer { running = false }
        let targets = workspace.state.tasks.flatMap { task -> [PausedWorker] in
            guard task.signalTask?.takenOver == false, task.signalTask?.phase == .working, paused(task) else { return [] }
            return task.workerTabs(in: live.sessions, now: now()).filter { $0.isStillAtWork && $0.session?.agent.agentKind != nil }
                .map { PausedWorker(task: task.id, tab: $0.reference.name, ownership: task.signalTask!.ownership) }
        }
        attempted = attempted.filter { item in workspace.state.task(id: item.task).map(paused) == true }
        for target in targets where !attempted.contains(target) && workspace.state.operatorSession?.pausedWorkers?.contains(target) != true {
            guard enabled(), !Task.isCancelled, let task = workspace.state.task(id: target.task), paused(task) else { continue }
            attempted.insert(target)
            workspace.mutate { state in
                if state.operatorSession?.pausedWorkers == nil { state.operatorSession?.pausedWorkers = [] }
                state.operatorSession?.pausedWorkers?.append(target)
            }
            guard workspace.flush() else { continue }
            do { try await native.control(task, tab: target.tab ?? "main", text: Self.pauseNote, resuming: false) }
            catch { /* The saved intent still receives carry-on: a lost reply may have delivered. */ }
        }
        for target in workspace.state.operatorSession?.pausedWorkers ?? [] {
            guard enabled(), !Task.isCancelled else { return }
            guard let task = workspace.state.task(id: target.task), task.signalTask?.takenOver == false,
                  task.signalTask?.ownership == target.ownership else { forget(target); continue }
            guard !paused(task) else { continue }
            do {
                try await native.control(task, tab: target.tab ?? "main", text: Self.carryOnNote, resuming: true)
                forget(target)
            } catch { /* Keep the intent; no stage may advance until this worker can carry on. */ }
        }
    }
    private func forget(_ target: PausedWorker) {
        workspace.mutate { $0.operatorSession?.pausedWorkers?.removeAll { $0 == target } }; workspace.flush()
    }
}
