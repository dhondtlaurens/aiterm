import Foundation
import AiTermCore

/// The workspace as the operator services read and change an operation in it.
extension AppState {
    /// The run's task an operator names: by its id, or by the key it created it with.
    func task(inRun run: UUID, named ref: String) -> TaskItem? {
        tasks(inRun: run).first { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame || $0.operated?.key == ref }
    }

    /// Changes an operated task's record; nothing for a task that has gone or was never an operator's.
    mutating func updateOperated(_ id: UUID, _ change: (inout OperatedTask) throws -> Void) rethrows {
        guard let i = tasks.firstIndex(where: { $0.id == id }), var operated = tasks[i].operated else { return }
        try change(&operated)
        tasks[i].operated = operated
    }

    /// Whether anything in the run can move without you: a worker at work that is not waiting on you
    /// (the task that asked is waiting on you, so it is not one), or a task the scheduler could start now.
    func otherWorkCanProceed(in run: OperatorRun) -> Bool {
        let working = tasks(inRun: run.id).contains { $0.operated?.state == .working && $0.operated?.flags.contains(.waitingOnYou) == false }
        return working || (run.state == .active && !RunScheduler.startable(in: self, run: run.id).isEmpty)
    }
}
