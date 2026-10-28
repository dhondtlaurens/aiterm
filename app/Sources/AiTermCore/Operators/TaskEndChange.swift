import Foundation

/// The person's change of one running task's end, from its card (broadcast setup v2, Board): in a broadcast set up with
/// the Task step the one way an end changes, since `create_task` and `update_task` take none. Decided here, apart from
/// `OperatorController.changeEnd`, which saves it and wakes the Operator.
///
/// It sets the end. Of the publication it clears what was under way for the old end — the merge's wait and its reads, a
/// problem, the Oracle's refusal and its yes — and keeps what already happened: the push and the request. A switch below
/// what is done, Commit with a request open, finishes the task as it stands: the request is left open, and said in Left
/// for you. Anything else is the next `finish_task`'s, which follows the new end.
public enum TaskEndChange {
    /// Whether `end` can be picked in `run`: Merge and Local merge only while its Merge slice is on.
    public static func isSelectable(_ end: TaskEnd, in run: OperatorRun) -> Bool { !end.merges || run.profile.slices.merge }

    /// Why `task`'s end can't change to `end` now; nil when it can. Only a broadcast set up with the Task step changes
    /// one, and only until the task finishes.
    public static func refusal(_ end: TaskEnd, for task: TaskItem, in run: OperatorRun) -> String? {
        guard let operated = task.operated, operated.runId == run.id else { return "That task isn’t the Operator’s." }
        guard run.taskSettings != nil else { return "This broadcast started before a task’s end could change." }
        guard !run.hasEnded else { return "This broadcast has ended." }
        guard !operated.isFinished else { return "\(task.title) has finished, so its end can’t change." }
        guard isSelectable(end, in: run) else { return "Merge is off for this broadcast, so a task ends at a commit or a draft MR." }
        return nil
    }

    /// `end` set on the task with this id in `state`, as the type says; a refusal is the caller's to check first. Returns
    /// what went to Left for you, nil when nothing did.
    @discardableResult
    public static func apply(_ end: TaskEnd, toTask id: UUID, in state: inout AppState) -> String? {
        guard let task = state.task(id: id), let operated = task.operated else { return nil }
        let request = end == .commit ? operated.publication?.mergeRequestNumber : nil
        state.updateOperated(id) { operated in
            operated.end = end
            operated.publication?.waitingSince = nil
            operated.publication?.readySince = nil
            operated.publication?.problem = nil
            operated.publication?.mergeRefusal = nil
            operated.publication?.conditionsHeld = nil
            // Its people's review is over with it: the task was accepted before its request went into review.
            if request != nil, operated.state == .inReview {
                operated.state = .accepted
                operated.peopleReview?.ended = true
            }
        }
        guard let request else { return nil }
        let reference = CodeHost(webURL: operated.publication?.mergeRequestURL ?? "").reference(request)
        let project = state.project(id: task.projectId)?.name ?? "its project"
        let left = "Close or merge \(reference) in \(project) yourself: you changed \(operated.key)’s end to commit, so AiTerm left it open."
        state.updateRun(id: operated.runId) { if !$0.leftForYou.contains(left) { $0.leftForYou.append(left) } }
        return left
    }

    /// What the Operator is woken with: `[AiTerm] You changed cart-drawer’s end to draft MR, call run_status`.
    public static func wakeReason(key: String, end: TaskEnd) -> String { "You changed \(key)’s end to \(end.displayName)" }
}

public extension TaskEnd {
    /// The end as its card's menu and the Task step name it: `Draft MR`.
    var title: String { displayName.prefix(1).uppercased() + displayName.dropFirst() }
}

public extension OperatedTask {
    /// Finished by reaching its end: published, accepted on a commit end, or ended with no change; not failed, stopped
    /// or with its publication left for you. What the broadcast's closing closes.
    var reachedItsEnd: Bool {
        state == .published || state == .noChange || (state == .accepted && end == .commit && publication?.leftForYou != true)
    }
}
