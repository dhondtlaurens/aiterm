import Foundation

public extension OperatorRun {
    /// Ended, or being ended: stopped, or asked to stop.
    var hasEnded: Bool { state == .stopped || intent == .stopped }

    /// Paused by you, its window closed, or being paused: what its header and board say as paused.
    var isPaused: Bool { state == .paused || state == .operatorOffline || intent == .paused }
}

/// Finding a broadcast and its tasks in the workspace, for the engines and the app alike.
public extension AppState {
    func run(id: UUID) -> OperatorRun? { runs.first { $0.id == id } }

    /// The one broadcast that has not ended (spec §3): its state and its intent both short of stopped, so a
    /// broadcast being ended is gone at once. At most one; while there is one, no other starts. The
    /// broadcast's group, the selection and the Operator controller all read this.
    var activeRun: OperatorRun? { runs.first { !$0.hasEnded } }

    /// The run's tasks in sidebar order, which is the plan's order: the order they were created.
    func tasks(inRun id: UUID) -> [TaskItem] { tasks.filter { $0.operated?.runId == id } }

    /// The run's task an Operator names: by its id, or by the key it created it with.
    func task(inRun run: UUID, named ref: String) -> TaskItem? {
        tasks(inRun: run).first { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.operated?.key == ref }
    }

    /// Changes an operated task's record; nothing for a task that has gone or was never an Operator's.
    mutating func updateOperated(_ id: UUID, _ change: (inout OperatedTask) throws -> Void) rethrows {
        guard let i = tasks.firstIndex(where: { $0.id == id }), var operated = tasks[i].operated else { return }
        try change(&operated)
        tasks[i].operated = operated
    }

    mutating func updateRun(id: UUID, _ change: (inout OperatorRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }
}
