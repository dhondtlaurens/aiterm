import Foundation

/// The operator surface's timings. Those the daemon acts on too are spelled again in its
/// `aitermd/delivery.py`, and the two must agree (`OperatorTimingTests` pins both the values and
/// their names in the Python file).
public enum OperatorTiming {
    /// Between a bracketed paste and the `\r` that submits it (spec §2.2: sent together, the CLI
    /// takes the Enter as part of the paste).
    public static let submitDelay: TimeInterval = 0.4
    /// No wake line is typed within this of your last key in the operator's session (spec §7.4).
    public static let typingQuiet: TimeInterval = 10
    /// A message longer than this goes through `.aiterm/messages/<n>.md` (spec §7.1).
    public static let messageFileThreshold = 2000
    /// Wake lines within this of each other are merged into one.
    public static let wakeCoalesce: TimeInterval = 3
    /// Sessions and branches are reconciled this often, and on every reconnect (spec §7.3).
    public static let reconcileInterval: TimeInterval = 60
    /// App only: minimum gap between reconcile and event reads, except when a prompt leaves needs-input.
    public static let promptProbeInterval: TimeInterval = 10
    /// App only: let a delivered command draw its dialog before the second screen read.
    public static let promptAfterMessageDelay: TimeInterval = 1.5
    /// A working task with no hook, transcript or screen change for this long is possibly stalled.
    public static let stallAfter: TimeInterval = 20 * 60
    /// An Oracle that takes longer is abandoned, and the act proceeds unchallenged (§4.4).
    public static let challengeTimeout: TimeInterval = 180
    /// The Oracle's answer on a shell command takes longer than this and the command runs, unchallenged (spec §A.3).
    public static let gateTimeout: TimeInterval = 200
    /// App only: an agent review (`review_task`) that takes longer is stopped, and its review failed.
    public static let agentReviewTimeout: TimeInterval = 900
    /// How long the daemon waits for the app's reply to a forwarded tool call.
    public static let operatorRequestTimeout: TimeInterval = 30
    /// App only: seconds `jira_search` waits for Jira before it answers that Jira didn't, inside `operatorRequestTimeout`. The
    /// app's Jira client ends each request by then too (`JiraClient.resourceDeadline`).
    public static let jiraSearchBudget: TimeInterval = 20
    /// A launch attempt older than this with no tagged session may be launched again (spec §11).
    public static let launchAdoptAfter: TimeInterval = 60
    /// App only: how often `finish_task` asks the host whether a `merge` task's MR is mergeable.
    public static let mergePoll: TimeInterval = 30
    /// App only: how long it waits for that before blocking the task and asking you.
    public static let mergeWait: TimeInterval = 60 * 60
    /// App only: how long after the plan is done AiTerm waits for the Operator's summary before giving up on it.
    public static let summaryWait: TimeInterval = 300
    /// App only: relaunches of a failed task before AiTerm blocks it (spec §4.1's fixed caps).
    public static let retries = 2
    /// App only: working minutes without a new commit on the task branch before AiTerm blocks it.
    public static let runtimeMinutes = 90
    /// App only: total working hours since starting or the Operator last resumed the task before AiTerm blocks it.
    public static let totalRuntimeHours = 4
    /// App only: minutes a worker whose session says working may go with no growth in its transcript before AiTerm reads it
    /// `working?` and lists it as uncertain (spec §H), on a task in any state: the daemon's state may have stuck.
    public static let liveQuietMinutes = 2
    /// Minutes a task may sit in review with nothing waiting (no open thread, no worker's question or change) before
    /// `run_status` lists it under `reviewQuiet` and wakes the Operator, who decides against the Done whether it is over (spec §K).
    public static let reviewQuietMinutes = 5
    /// App only: seconds `run_status` and `read_task` wait for a code host to say what it thinks of a task's request before
    /// they answer without it, and how long that reading is kept per request.
    public static let hostReadTimeout: TimeInterval = 8
    public static let hostReadCache: TimeInterval = 30
    /// App only: seconds `read_task diff` and `review_task` let the fetch of a task's base from origin take, well inside
    /// `operatorRequestTimeout` with the local reads after it; and how long after a fetch of the same base, or a try at
    /// one, they read origin's copy as it is without fetching again.
    public static let diffBaseFetchTimeout: TimeInterval = 10
    public static let diffBaseFetchInterval: TimeInterval = 60
}

public extension TaskEnd {
    /// A merge through the request, or a local one: what the Merge slice governs.
    var merges: Bool { self == .merge || self == .mergeLocal }

    /// The end as the plan, the board and a refusal say it.
    var displayName: String {
        switch self {
        case .commit: return "commit"
        case .draftMR: return "draft MR"
        case .merge: return "merge"
        case .mergeLocal: return "local merge"
        }
    }
}
