import Foundation

/// The operator surface's timings. Those the daemon acts on too are spelled again in its
/// `aitermd/delivery.py`, and the two must agree (`OperatorTimingTests` pins both the values and
/// their names in the Python file).
public enum OperatorTiming {
    /// Sessions and branches are reconciled this often, and on every reconnect (spec §7.3).
    public static let reconcileInterval: TimeInterval = 60
    /// An Oracle that takes longer is abandoned, and the act proceeds unchallenged (§4.4).
    public static let challengeTimeout: TimeInterval = 180
    /// The Oracle's answer on a shell command takes longer than this and the command runs, unchallenged (spec §A.3).
    public static let gateTimeout: TimeInterval = 200
    /// How long the daemon waits for the app's reply to a forwarded tool call.
    public static let operatorRequestTimeout: TimeInterval = 30
    /// App only: seconds `jira_search` waits for Jira before it answers that Jira didn't, inside `operatorRequestTimeout`. The
    /// app's Jira client ends each request by then too (`JiraClient.resourceDeadline`).
    public static let jiraSearchBudget: TimeInterval = 20
    /// App only: seconds after its window was seen, else asked for, that a first worker which has named no conversation yet
    /// still counts as opening (`TaskItem.workerTabs(in:now:)`): Codex reads idle until its first hook, half a minute in.
    public static let firstWorkerOpening: TimeInterval = 180
    /// App only: seconds `run_status` and `read_task` wait for a code host to say what it thinks of a task's request before
    /// they answer without it, and how long that reading is kept per request.
    public static let hostReadTimeout: TimeInterval = 8
    public static let hostReadCache: TimeInterval = 30
}
