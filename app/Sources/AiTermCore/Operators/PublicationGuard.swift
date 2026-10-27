import Foundation

/// Why `finish_task` will not carry out a task's end now (spec §6, §8, §9). `refusal` is checked before
/// the first step; `recheck`, through `TaskPublisher`'s `recheck`, before every later one that changes
/// something outside this machine.
public enum PublicationGuard {
    public static let notOperated = "This task isn’t the Operator’s: only a broadcast’s tasks are finished."
    public static let changedMidway = "The task was taken over, handed on or accepted again while it was being published. What was done so far is recorded; call finish_task again once it is yours."
    public static let gone = "The task or its broadcast is no longer in AiTerm."
    /// A merge, through the request or local, with the broadcast's frozen Merge slice off (spec §5).
    public static let mergeSliceOff = "The Merge slice is off for this broadcast."

    public static func refusal(task: TaskItem, run: OperatorRun, parent: TaskItem?, defaultBranch: String,
                               branchTip: String?) -> String? {
        if let why = landedRefusal(task: task, run: run) { return why }
        guard let operated = task.operated, let acceptance = operated.acceptance else { return notOperated }
        // The slices froze with the broadcast: the run's, never the profile in Settings.
        if operated.end.merges, !run.profile.slices.merge { return mergeSliceOff }
        // With the Oracle on, a merge goes ahead only on its yes for the commit accepted now (the tool handler asks it).
        if operated.end.merges, run.profile.oracle.isOn, !TaskPublisher.Context.entersReview(operated, run: run),
           operated.publication?.conditionsHeld != acceptance.resultSHA {
            return "The Oracle hasn’t said that the conditions written in the Review and the Done hold for \(operated.key), so AiTerm doesn’t merge it: call finish_task again."
        }
        // The way `Repository.push` compares: case-folded and without a leading refs/heads/.
        let branch = Repository.folded(Repository.shortBranch(task.branch))
        if branch.isEmpty || branch == Repository.folded(Repository.shortBranch(defaultBranch)) {
            return "\(operated.key)'s branch is the default branch, which AiTerm never pushes to."
        }
        guard branchTip == acceptance.resultSHA else {
            let now = branchTip.map { "it is at \($0.prefix(7)) now" } ?? "it is gone"
            return "\(task.branch) moved past the accepted commit \(acceptance.resultSHA.prefix(7)) (\(now)): accept it again first."
        }
        if operated.end == .mergeLocal {
            // Its commit holds the parent's: merged locally only once the parent's own end is done.
            if let parent = parent?.operated, parent.end == .commit ? ![.accepted, .published].contains(parent.state) : parent.publication?.merged != true {
                return "\(operated.key) builds on \(parent.key): finish \(parent.key) first."
            }
        } else if let parent = parent?.operated, parent.publication?.mergeRequestNumber == nil {
            return "\(operated.key) builds on \(parent.key), whose branch its request targets: finish \(parent.key) first."
        }
        return nil
    }

    /// Why a task is not finished now, whatever its end has still to write: the broadcast, the task's end, its owner, its
    /// accepted commit. A merge end whose accepted commit is already in its target branch (`Repository.landing`) is recorded
    /// as merged on these alone: the checks that only authorise a write that no longer happens (the Merge slice, the
    /// Oracle's yes, the branch's tip, a stacked parent's end) are `refusal`'s.
    public static func landedRefusal(task: TaskItem, run: OperatorRun) -> String? {
        guard let operated = task.operated else { return notOperated }
        if let why = runRefusal(run) { return why }
        if operated.end == .commit {
            return "\(operated.key) ends in a commit: its plan opens no merge request, so there is nothing to finish."
        }
        if operated.takenOver { return "You've taken \(operated.key) over; it is published only once you hand it back." }
        guard operated.state == .accepted, operated.acceptance != nil else {
            return "Only an accepted task is finished; \(operated.key) is \(operated.state.rawValue)."
        }
        if operated.flags.contains(.upstreamReplaced) { return upstreamReplaced(operated.key) }
        return nil
    }

    /// AiTerm's floor for a merge through the request (spec §5), read right before it: the host's head is the
    /// accepted commit, and every review thread on `request` is resolved. Nil when it may merge.
    public static func mergeFloor(head: String, acceptedSHA: String, threads: [ReviewThread], request: String) -> String? {
        guard head == acceptedSHA else {
            return "The request's branch is at \(head.prefix(7)) on the host, not the accepted \(acceptedSHA.prefix(7))."
        }
        return openThreads(threads, request: request)
    }

    /// Why `request` is not merged nor marked ready when its threads could not all be read: no answer is not "none open".
    public static func unreadThreads(_ request: String) -> String { "AiTerm couldn’t read every review thread on \(request)." }

    /// Why nothing more is written to the publication's request through `repository` (the host the project's origin
    /// resolves to now): the request was opened in another repository, or before AiTerm kept which. Nil when it is the same.
    public static func otherRepository(_ publication: TaskPublication, repository: String) -> String? {
        guard let number = publication.mergeRequestNumber else { return nil }
        let request = publication.mergeRequestURL.map { CodeHost(webURL: $0).reference(number) } ?? "#\(number)"
        guard let kept = publication.repository else {
            return "AiTerm didn’t keep which repository \(request) was opened in, so it won’t act on it."
        }
        return kept == repository ? nil : "The project’s origin changed since \(request) was opened, so AiTerm won’t act on it."
    }

    /// Why `threads` keep `request` from merging: any of them still open. Nil when every one is resolved.
    static func openThreads(_ threads: [ReviewThread], request: String) -> String? {
        let open = threads.filter { !$0.resolved }.count
        guard open == 0 else {
            return open == 1 ? "1 review thread is still open on \(request)." : "\(open) review threads are still open on \(request)."
        }
        return nil
    }

    /// What may have changed since the first step, read fresh before the next: the broadcast's state and
    /// your intent (a Pause or End), and the task's state, ownership (a takeover, even one handed back)
    /// and accepted commit.
    public static func recheck(task: TaskItem?, run: OperatorRun?, ownership: Int, acceptedSHA: String) -> String? {
        guard let task, let run else { return gone }
        guard let operated = task.operated else { return notOperated }
        if let why = runRefusal(run) { return why }
        if operated.takenOver || operated.ownership != ownership { return changedMidway }
        guard operated.state == .accepted, operated.acceptance?.resultSHA == acceptedSHA else { return changedMidway }
        if operated.flags.contains(.upstreamReplaced) { return upstreamReplaced(operated.key) }
        if operated.end.merges, !run.profile.slices.merge { return mergeSliceOff }
        return nil
    }

    /// A broadcast publishes while it is active or complete and you have neither paused nor ended it.
    public static func runRefusal(_ run: OperatorRun) -> String? {
        if run.intent == .stopped { return "The broadcast was stopped; it publishes nothing." }
        if run.intent == .paused { return "The broadcast is paused; nothing is published until it runs again." }
        switch run.state {
        case .active, .complete: return nil
        case .paused: return "The broadcast is paused; nothing is published until it runs again."
        case .operatorOffline: return "The Operator is offline; nothing is published until the broadcast resumes."
        case .stopped: return "The broadcast was stopped; it publishes nothing."
        case .planning: return "The broadcast's plan hasn't been submitted yet."
        }
    }

    static func upstreamReplaced(_ key: String) -> String {
        "\(key)'s parent was accepted again on another commit: have its worker rebase, accept it again, then finish it."
    }
}
