import Foundation

/// The operator surface's timings, the same values as the daemon's `aitermd/delivery.py`: the
/// app and the daemon each act on some of them, and they must agree (`OperatorTimingTests` pins
/// both the values and their names in the Python file).
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
    /// A working task with no hook, transcript or screen change for this long is possibly stalled.
    public static let stallAfter: TimeInterval = 20 * 60
    /// A second opinion that takes longer is abandoned, and the act proceeds unchallenged (§4.4).
    public static let challengeTimeout: TimeInterval = 180
    /// App only: an agent review (`review_task`) that takes longer is stopped, and its review failed.
    public static let agentReviewTimeout: TimeInterval = 900
    /// How long the daemon waits for the app's reply to a forwarded tool call.
    public static let operatorRequestTimeout: TimeInterval = 30
    /// A launch attempt older than this with no tagged session may be launched again (spec §11).
    public static let launchAdoptAfter: TimeInterval = 60
    /// M3, app only: how often `finish_task` asks the host whether a `merge` task's MR is mergeable.
    public static let mergePoll: TimeInterval = 30
    /// M3, app only: how long it waits for that before blocking the task and asking you.
    public static let mergeWait: TimeInterval = 60 * 60
    /// App only: relaunches of a failed task before AiTerm blocks it (spec §4.1's fixed caps).
    public static let retries = 2
    /// App only: minutes a task may work, not counting time waiting on you, before AiTerm blocks it.
    public static let runtimeMinutes = 90
}

/// What this build of the operator supports (spec §13). A plan asking for more — a draft MR
/// in M1 — is refused when submitted, with the reason, never quietly downgraded.
public enum OperatorMilestone: Int, Comparable, CaseIterable, Sendable {
    case m1 = 1, m2, m3

    /// The milestone this build ships: M3, every end carried out.
    public static let current: OperatorMilestone = .m3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Whether a plan may end a task with `end`: a commit from M1; a draft MR, a merge or a local
    /// merge, which `finish_task` carries out, from M3.
    public func supports(_ end: TaskEnd) -> Bool { self >= end.availableFrom }
}

public extension TaskEnd {
    /// The first milestone whose `finish_task` can carry this end out.
    var availableFrom: OperatorMilestone { self == .commit ? .m1 : .m3 }

    /// A merge through the request, or a local one: what the Merge slice governs.
    var merges: Bool { self == .merge || self == .mergeLocal }

    /// The end as the plan, the overview and a refusal say it.
    var displayName: String {
        switch self {
        case .commit: return "commit"
        case .draftMR: return "draft MR"
        case .merge: return "merge"
        case .mergeLocal: return "local merge"
        }
    }
}
