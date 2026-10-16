import Foundation

/// Why `finish_task` will not carry out a task's end now (spec §6, §8, §9). `refusal` is checked before
/// the first step; `recheck`, through `TaskPublisher`'s `recheck`, before every later one that changes
/// something outside this machine.
public enum PublicationGuard {
    public static let notOperated = "This task isn't an operator's: only an operation's tasks are finished."
    public static let changedMidway = "The task was taken over, handed on or accepted again while it was being published. What was done so far is recorded; call finish_task again once it is yours."
    public static let gone = "The task or its operation is no longer in AiTerm."

    public static func refusal(task: TaskItem, run: OperatorRun, parent: TaskItem?, defaultBranch: String,
                               branchTip: String?) -> String? {
        guard let operated = task.operated else { return notOperated }
        if let why = runRefusal(run) { return why }
        if operated.end == .commit {
            return "\(operated.key) ends in a commit: its plan opens no merge request, so there is nothing to finish."
        }
        if operated.takenOver { return "You've taken \(operated.key) over; it is published only once you hand it back." }
        guard operated.state == .accepted, let acceptance = operated.acceptance else {
            return "Only an accepted task is finished; \(operated.key) is \(operated.state.rawValue)."
        }
        if operated.flags.contains(.upstreamReplaced) { return upstreamReplaced(operated.key) }
        // The way `Repository.push` compares: case-folded and without a leading refs/heads/.
        let branch = Repository.folded(Repository.shortBranch(task.branch))
        if branch.isEmpty || branch == Repository.folded(Repository.shortBranch(defaultBranch)) {
            return "\(operated.key)'s branch is the default branch, which AiTerm never pushes to."
        }
        guard branchTip == acceptance.resultSHA else {
            let now = branchTip.map { "it is at \($0.prefix(7)) now" } ?? "it is gone"
            return "\(task.branch) moved past the accepted commit \(acceptance.resultSHA.prefix(7)) (\(now)): accept it again first."
        }
        if let parent = parent?.operated, parent.publication?.mergeRequestNumber == nil {
            return "\(operated.key) builds on \(parent.key), whose branch its request targets: finish \(parent.key) first."
        }
        return nil
    }

    /// What may have changed since the first step, read fresh before the next: the operation's state and
    /// your intent (a Pause or End), and the task's state, ownership (a takeover, even one handed back)
    /// and accepted commit.
    public static func recheck(task: TaskItem?, run: OperatorRun?, ownership: Int, acceptedSHA: String) -> String? {
        guard let task, let run else { return gone }
        guard let operated = task.operated else { return notOperated }
        if let why = runRefusal(run) { return why }
        if operated.takenOver || operated.ownership != ownership { return changedMidway }
        guard operated.state == .accepted, operated.acceptance?.resultSHA == acceptedSHA else { return changedMidway }
        if operated.flags.contains(.upstreamReplaced) { return upstreamReplaced(operated.key) }
        return nil
    }

    /// An operation publishes while it is active or complete and you have neither paused nor ended it.
    static func runRefusal(_ run: OperatorRun) -> String? {
        if run.intent == .stopped { return "The operation was stopped; it publishes nothing." }
        if run.intent == .paused { return "The operation is paused; nothing is published until it runs again." }
        switch run.state {
        case .active, .complete: return nil
        case .paused: return "The operation is paused; nothing is published until it runs again."
        case .operatorOffline: return "The operator is offline; nothing is published until the operation resumes."
        case .stopped: return "The operation was stopped; it publishes nothing."
        case .planning: return "The operation's plan isn't approved yet."
        }
    }

    static func upstreamReplaced(_ key: String) -> String {
        "\(key)'s parent was accepted again on another commit: have its worker rebase, accept it again, then finish it."
    }
}
