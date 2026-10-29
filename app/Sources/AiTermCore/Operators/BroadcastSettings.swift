import Foundation

// Current broadcast configuration, review evidence and completion records. Required fields are decoded
// explicitly by synthesized Codable; optional fields represent choices the person did not make.

/// One row of the Agents step: a combination the Operator may start workers, tabs and reviewers on. A row is its
/// combination, so two rows alike are one.
public struct AgentChoice: Codable, Equatable, Hashable, Sendable {
    public var agent: AgentKind
    public var model: String
    public var reasoning: String?

    public init(agent: AgentKind, model: String, reasoning: String?) {
        self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// The row as the brief and the tool refusals name it: "Agent · model · reasoning".
    public var label: String { [agent.displayName, model, reasoning].compactMap { $0 }.joined(separator: " · ") }
}

/// The Task step: what every task of the broadcast follows.
public struct TaskSettings: Codable, Equatable, Sendable {
    /// The open review prompt; nil: a task is accepted without a review.
    public var review: String?
    /// Every task's end as it starts; only the person changes one task's.
    public var end: TaskEnd
    /// Close a finished task's tabs and remove its worktree at the broadcast's end.
    public var closeWhenDone: Bool
    /// Also delete its local branch once merged into the default branch; ignored while `closeWhenDone` is false.
    public var deleteMergedBranch: Bool

    public init(review: String?, end: TaskEnd, closeWhenDone: Bool = true, deleteMergedBranch: Bool = false) {
        self.review = review; self.end = end; self.closeWhenDone = closeWhenDone; self.deleteMergedBranch = deleteMergedBranch
    }
}

/// The Done step: what must be true once every task is done, and how many times the Operator may plan what it still
/// misses.
public struct BroadcastGoal: Codable, Equatable, Sendable {
    public var text: String
    public var extraRounds: Int

    public init(text: String, extraRounds: Int = 2) { self.text = text; self.extraRounds = extraRounds }
}

/// How the broadcast's goal ended: met, not met, or not checked by the Oracle.
public enum GoalOutcome: String, Codable, Sendable { case met, notMet, unchecked }

/// One `check_goal` that acted: the Operator's verdict on the goal in its round, and the Oracle's.
public struct GoalCheck: Codable, Equatable, Sendable {
    public var round: Int
    public var met: Bool
    public var evidence: String
    /// The lines still to do, when not met.
    public var missing: [String]
    /// Nil: not checked by the Oracle (missing, failed or too slow).
    public var oracleAgreed: Bool?
    public var at: Date

    public init(round: Int, met: Bool, evidence: String, missing: [String] = [], oracleAgreed: Bool?, at: Date) {
        self.round = round; self.met = met; self.evidence = evidence; self.missing = missing; self.oracleAgreed = oracleAgreed
        self.at = at
    }
}

/// What a worker tab is for: more work on its task, or a review of its branch head (`open_tab`'s `role`).
public enum TabRole: String, Codable, Sendable { case work, review }

/// A review tab's verdict on one commit of its task, as the Operator recorded it (`record_review`): whether it passed by
/// the review prompt's own words, its fix round and the rounds the prompt names, and its findings counted.
public struct ReviewVerdict: Codable, Equatable, Sendable {
    /// The Operator's idempotency key within its task; nil for a verdict saved without a key.
    public var key: String?
    /// The review tab's key.
    public var tab: String
    /// The commit it reviewed.
    public var sha: String
    public var passed: Bool
    public var round: Int
    /// The rounds the review prompt names; nil when it names none.
    public var rounds: Int?
    public var critical: Int, important: Int, minor: Int
    public var summary: String
    public var at: Date

    public init(tab: String, sha: String, passed: Bool, round: Int, rounds: Int? = nil, critical: Int, important: Int, minor: Int,
                summary: String, at: Date, key: String? = nil) {
        self.key = key
        self.tab = tab; self.sha = sha; self.passed = passed; self.round = round; self.rounds = rounds
        self.critical = critical; self.important = important; self.minor = minor; self.summary = summary; self.at = at
    }
}

/// A task closed at the broadcast's end, as its card read just before its row, tabs and worktree went: the board's Done
/// column, the summary, `run_status` and the Shelf read it in place of the task.
public struct FinishedTaskRecord: Codable, Equatable, Sendable {
    public var task: UUID
    public var key: String, title: String, ticket: String?
    public var project: UUID
    public var agent: AgentKind, model: String, reasoning: String?
    public var end: TaskEnd, state: OperatedState
    public var acceptedSHA: String?
    /// The task's `OperatedTask.diffBaseSHA`, as it was when it closed: what `read_task` diffs the accepted commit
    /// against once its row is gone. Nil in a record without one, which reads the accepted commit's own patch.
    public var diffBaseSHA: String? = nil
    public var branch: String
    public var mergeRequestURL: String?, mergedSHA: String?
    /// The card's line, as it read.
    public var result: String
    public var branchDeleted: Bool
    public var at: Date

    public init(task: UUID, key: String, title: String, ticket: String?, project: UUID, agent: AgentKind, model: String,
                reasoning: String?, end: TaskEnd, state: OperatedState, acceptedSHA: String?, branch: String,
                mergeRequestURL: String?, mergedSHA: String?, result: String, branchDeleted: Bool, at: Date) {
        self.task = task; self.key = key; self.title = title; self.ticket = ticket; self.project = project
        self.agent = agent; self.model = model; self.reasoning = reasoning; self.end = end; self.state = state
        self.acceptedSHA = acceptedSHA; self.branch = branch; self.mergeRequestURL = mergeRequestURL; self.mergedSHA = mergedSHA
        self.result = result; self.branchDeleted = branchDeleted; self.at = at
    }
}
