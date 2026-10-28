import Foundation

/// The person's change of one running task's end, from its card (broadcast setup v2, Board): in a broadcast set up with
/// the Task step the one way an end changes, since `create_task` and `update_task` take none. Decided here, apart from
/// `OperatorController.changeEnd`, which saves it and wakes the Operator.
///
/// It sets the end. Of the publication it clears what was under way for the old end — the merge's wait and its reads, a
/// problem, the Oracle's refusal and its yes — and keeps what already happened: the push and the request. A switch to
/// Commit is below a request already open: the request is left for you (`TaskPublication.leftForYou`), so AiTerm neither
/// merges nor closes it and the closing skips the task, and that is said in Left for you. Accepted, or in people's
/// review of its request, the task is then finished as it stands; at work, once it is accepted. Anything else is the next
/// `finish_task`'s, which follows the new end.
public enum TaskEndChange {
    /// Whether `end` can be picked in `run`: Merge and Local merge only while its Merge slice is on.
    public static func isSelectable(_ end: TaskEnd, in run: OperatorRun) -> Bool { !end.merges || run.profile.slices.merge }

    /// Why `task`'s end can't change to `end` now; nil when it can. Only a broadcast set up with the Task step changes
    /// one, only until the task finishes, never while you hold it, and only to another end.
    public static func refusal(_ end: TaskEnd, for task: TaskItem, in run: OperatorRun) -> String? {
        guard let operated = task.operated, operated.runId == run.id else { return "That task isn’t the Operator’s." }
        guard run.taskSettings != nil else { return "This broadcast started before a task’s end could change." }
        guard !run.hasEnded else { return "This broadcast has ended." }
        guard !operated.isFinished else { return "\(task.title) has finished, so its end can’t change." }
        guard !operated.takenOver else { return "You took \(task.title) over: hand it back to change its end." }
        guard end != operated.end else { return "\(task.title) already ends at \(end.displayName)." }
        guard isSelectable(end, in: run) else { return "Merge is off for this broadcast, so a task ends at a commit or a draft MR." }
        return nil
    }

    /// `end` set on the task with this id in `state`, as the type says; a refusal is the caller's to check first.
    public static func apply(_ end: TaskEnd, toTask id: UUID, in state: inout AppState) {
        guard let task = state.task(id: id), let operated = task.operated else { return }
        let request = end == .commit ? operated.publication?.mergeRequestNumber : nil
        state.updateOperated(id) { operated in
            operated.end = end
            operated.publication?.waitingSince = nil
            operated.publication?.readySince = nil
            operated.publication?.problem = nil
            operated.publication?.mergeRefusal = nil
            operated.publication?.conditionsHeld = nil
            // A commit end has no review: the task was accepted before it went into review, and is again.
            if end == .commit, operated.state == .inReview {
                operated.state = .accepted
                operated.peopleReview?.ended = true
            }
            if request != nil { operated.publication?.leftForYou = true }
        }
        guard let request else { return }
        let reference = CodeHost(webURL: operated.publication?.mergeRequestURL ?? "").reference(request)
        let project = state.project(id: task.projectId)?.name ?? "its project"
        let left = "Close or merge \(reference) in \(project) yourself: you changed \(operated.key)’s end to commit, so AiTerm left it open."
        state.updateRun(id: operated.runId) { if !$0.leftForYou.contains(left) { $0.leftForYou.append(left) } }
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
    /// or with its publication left for you. The one rule for it: the broadcast's closing closes these tasks, and the
    /// board says which of them it kept.
    var reachedItsEnd: Bool {
        state == .published || state == .noChange || (state == .accepted && end == .commit && publication?.leftForYou != true)
    }
}
