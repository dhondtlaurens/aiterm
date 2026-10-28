import Foundation

// What a broadcast set up with the Agents, Task and Done steps keeps (broadcast setup v2): the combinations its workers may
// run, what every task follows, the broadcast's goal and its checks, each review tab's verdict, and the record a task
// leaves once it is closed. Plain data beside `OperatorModels.swift`, which holds it. Every field may be missing on
// decode and reads as its default; keys this build does not know are preserved.

/// One row of the Agents step: a combination the Operator may start workers, tabs and reviewers on. A row is its
/// combination, so two rows alike are one.
public struct AgentChoice: Codable, Equatable, Hashable, Sendable {
    private var preservedFields = PreservedFields()
    public var agent: AgentKind
    public var model: String
    public var reasoning: String?

    public init(agent: AgentKind, model: String, reasoning: String?) {
        self.agent = agent; self.model = model; self.reasoning = reasoning
    }

    /// The row as the brief and the tool refusals name it: "Agent · model · reasoning".
    public var label: String { [agent.displayName, model, reasoning].compactMap { $0 }.joined(separator: " · ") }

    public static func == (a: Self, b: Self) -> Bool { a.agent == b.agent && a.model == b.model && a.reasoning == b.reasoning }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(agent); hasher.combine(model); hasher.combine(reasoning)
    }

    private enum CodingKeys: String, CodingKey { case agent, model, reasoning }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(agent, forKey: .agent)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
    }
}

/// The Task step: what every task of the broadcast follows. A run that has none was started before it, and keeps the
/// Review and Done text it had (`OperatorRun.taskSettings`).
public struct TaskSettings: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
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

    private enum CodingKeys: String, CodingKey { case review, end, closeWhenDone, deleteMergedBranch }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        review = try c.decodeIfPresent(String.self, forKey: .review)
        end = try c.decodeIfPresent(TaskEnd.self, forKey: .end) ?? .draftMR
        closeWhenDone = try c.decodeIfPresent(Bool.self, forKey: .closeWhenDone) ?? true
        deleteMergedBranch = try c.decodeIfPresent(Bool.self, forKey: .deleteMergedBranch) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(review, forKey: .review)
        try c.encode(end, forKey: .end)
        try c.encode(closeWhenDone, forKey: .closeWhenDone)
        try c.encode(deleteMergedBranch, forKey: .deleteMergedBranch)
    }
}

/// The Done step: what must be true once every task is done, and how many times the Operator may plan what it still
/// misses.
public struct BroadcastGoal: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
    public var text: String
    public var extraRounds: Int

    public init(text: String, extraRounds: Int = 2) { self.text = text; self.extraRounds = extraRounds }

    private enum CodingKeys: String, CodingKey { case text, extraRounds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        extraRounds = try c.decodeIfPresent(Int.self, forKey: .extraRounds) ?? 2
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(extraRounds, forKey: .extraRounds)
    }
}

/// How the broadcast's goal ended: met, not met, or not checked by the Oracle.
public enum GoalOutcome: String, Codable, Sendable { case met, notMet, unchecked }

/// One `check_goal` that acted: the Operator's verdict on the goal in its round, and the Oracle's.
public struct GoalCheck: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
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

    private enum CodingKeys: String, CodingKey { case round, met, evidence, missing, oracleAgreed, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        met = try c.decodeIfPresent(Bool.self, forKey: .met) ?? false
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        oracleAgreed = try c.decodeIfPresent(Bool.self, forKey: .oracleAgreed)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(round, forKey: .round)
        try c.encode(met, forKey: .met)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(missing, forKey: .missing)
        try c.encodeIfPresent(oracleAgreed, forKey: .oracleAgreed)
        try c.encode(at, forKey: .at)
    }
}

/// What a worker tab is for: more work on its task, or a review of its branch head (`open_tab`'s `role`).
public enum TabRole: String, Codable, Sendable { case work, review }

/// A review tab's verdict on one commit of its task, as the Operator recorded it (`record_review`): whether it passed by
/// the review prompt's own words, its fix round and the rounds the prompt names, and its findings counted.
public struct ReviewVerdict: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
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
                summary: String, at: Date) {
        self.tab = tab; self.sha = sha; self.passed = passed; self.round = round; self.rounds = rounds
        self.critical = critical; self.important = important; self.minor = minor; self.summary = summary; self.at = at
    }

    private enum CodingKeys: String, CodingKey { case tab, sha, passed, round, rounds, critical, important, minor, summary, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        tab = try c.decodeIfPresent(String.self, forKey: .tab) ?? ""
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        passed = try c.decodeIfPresent(Bool.self, forKey: .passed) ?? false
        round = try c.decodeIfPresent(Int.self, forKey: .round) ?? 0
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds)
        critical = try c.decodeIfPresent(Int.self, forKey: .critical) ?? 0
        important = try c.decodeIfPresent(Int.self, forKey: .important) ?? 0
        minor = try c.decodeIfPresent(Int.self, forKey: .minor) ?? 0
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tab, forKey: .tab)
        try c.encode(sha, forKey: .sha)
        try c.encode(passed, forKey: .passed)
        try c.encode(round, forKey: .round)
        try c.encodeIfPresent(rounds, forKey: .rounds)
        try c.encode(critical, forKey: .critical)
        try c.encode(important, forKey: .important)
        try c.encode(minor, forKey: .minor)
        try c.encode(summary, forKey: .summary)
        try c.encode(at, forKey: .at)
    }
}

/// A task closed at the broadcast's end, as its card read just before its row, tabs and worktree went: the board's Done
/// column, the summary, `run_status` and the Shelf read it in place of the task.
public struct FinishedTaskRecord: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
    public var task: UUID
    public var key: String, title: String, ticket: String?
    public var project: UUID
    public var agent: AgentKind, model: String, reasoning: String?
    public var end: TaskEnd, state: OperatedState
    public var acceptedSHA: String?
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

    private enum CodingKeys: String, CodingKey {
        case task, key, title, ticket, project, agent, model, reasoning, end, state, acceptedSHA, branch, mergeRequestURL, mergedSHA
        case result, branchDeleted, at
    }

    /// A record missing its ids reads as no task's and no project's: the nil UUID, which nothing else has.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        let none = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        task = try c.decodeIfPresent(UUID.self, forKey: .task) ?? none
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        ticket = try c.decodeIfPresent(String.self, forKey: .ticket)
        project = try c.decodeIfPresent(UUID.self, forKey: .project) ?? none
        agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .claude
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        end = try c.decodeIfPresent(TaskEnd.self, forKey: .end) ?? .commit
        state = try c.decodeIfPresent(OperatedState.self, forKey: .state) ?? .accepted
        acceptedSHA = try c.decodeIfPresent(String.self, forKey: .acceptedSHA)
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        mergeRequestURL = try c.decodeIfPresent(String.self, forKey: .mergeRequestURL)
        mergedSHA = try c.decodeIfPresent(String.self, forKey: .mergedSHA)
        result = try c.decodeIfPresent(String.self, forKey: .result) ?? ""
        branchDeleted = try c.decodeIfPresent(Bool.self, forKey: .branchDeleted) ?? false
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(task, forKey: .task)
        try c.encode(key, forKey: .key)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(ticket, forKey: .ticket)
        try c.encode(project, forKey: .project)
        try c.encode(agent, forKey: .agent)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encode(end, forKey: .end)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(acceptedSHA, forKey: .acceptedSHA)
        try c.encode(branch, forKey: .branch)
        try c.encodeIfPresent(mergeRequestURL, forKey: .mergeRequestURL)
        try c.encodeIfPresent(mergedSHA, forKey: .mergedSHA)
        try c.encode(result, forKey: .result)
        try c.encode(branchDeleted, forKey: .branchDeleted)
        try c.encode(at, forKey: .at)
    }
}
