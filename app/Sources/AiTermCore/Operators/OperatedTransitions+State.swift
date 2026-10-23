import Foundation

public extension OperatedTransitions {
    /// What a failed or stopped parent writes on the dependents it holds back.
    enum Upstream: String, Sendable { case failed, stopped }

    static func upstreamReason(_ upstream: Upstream, key: String) -> String { "upstream \(upstream.rawValue): \(key)" }

    /// `action` on the task `id` in `state`, with the rest of spec §8's "What else happens":
    ///
    /// - a task that **fails** or is **stopped** blocks every queued task that depends on it,
    ///   directly or through another, with `upstreamReason` — a planned one stays planned, as it
    ///   is not released to start yet;
    /// - a **retried** task puts the tasks its failure blocked, none of which ever ran, back in
    ///   the queue.
    ///
    /// The context comes from the task's run: its state, its snapshot's retry limit and runtime. Returns
    /// the ids of every task it changed, the task's first; none when the action was a repeat.
    @discardableResult
    static func apply(_ action: OperatedAction, toTask id: UUID, in state: inout AppState,
                      by actor: OperatedActor) throws(OperatedTransitionError) -> [UUID] {
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw .unknownTask(id) }
        guard let task = state.tasks[index].operated else { throw .notOperated(id) }
        guard let run = state.run(id: task.runId) else { throw .unknownRun(task.runId) }
        let runTasks = state.tasks(inRun: run.id)
        let context = OperatedContext(runState: run.state, retryLimit: OperatorTiming.retries,
                                      runtimeLimit: TimeInterval(OperatorTiming.runtimeMinutes * 60))

        let next = try apply(action, to: task, by: actor, context: context)
        guard next != task else { return [] }
        state.tasks[index].operated = next
        var changed = [id]

        if next.state != task.state, next.state == .failed || next.state == .stopped {
            let reason = upstreamReason(next.state == .failed ? .failed : .stopped, key: task.key)
            for dependent in dependents(of: id, in: runTasks) {
                guard let i = state.tasks.firstIndex(where: { $0.id == dependent }),
                      state.tasks[i].operated?.state == .queued else { continue }
                state.tasks[i].operated?.state = .blocked
                state.tasks[i].operated?.blockedReason = reason
                // It never ran: resume puts it back in the queue, where it was.
                state.tasks[i].operated?.blockedFrom = .queued
                changed.append(dependent)
            }
        }
        if case .retry = action {
            let reason = upstreamReason(.failed, key: task.key)
            for i in state.tasks.indices {
                guard let o = state.tasks[i].operated, o.runId == run.id, o.state == .blocked,
                      o.blockedReason == reason, !o.started else { continue }
                state.tasks[i].operated?.state = .queued
                state.tasks[i].operated?.blockedReason = nil
                state.tasks[i].operated?.blockedFrom = nil
                changed.append(state.tasks[i].id)
            }
        }
        return changed
    }

    /// Every task that depends on `id`, directly or through another, each once, nearest first.
    static func dependents(of id: UUID, in tasks: [TaskItem]) -> [UUID] {
        var found: [UUID] = [], frontier: Set<UUID> = [id], seen: Set<UUID> = [id]
        while !frontier.isEmpty {
            let next = tasks.filter { task in
                !seen.contains(task.id) && (task.operated?.dependsOn.contains { frontier.contains($0.task) } ?? false)
            }.map(\.id)
            found += next
            seen.formUnion(next)
            frontier = Set(next)
        }
        return found
    }
}
