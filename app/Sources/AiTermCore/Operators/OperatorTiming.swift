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
    /// How long the daemon waits for the app's reply to a forwarded tool call.
    public static let operatorRequestTimeout: TimeInterval = 30
    /// A launch attempt older than this with no tagged session may be launched again (spec §11).
    public static let launchAdoptAfter: TimeInterval = 60
    /// App only: at Routine, a question that does not hold up every task waits this long, bundled
    /// with the others, before it notifies you (spec §4.1).
    public static let routineBundleAfter: TimeInterval = 30 * 60
    /// M3, app only: how often `finish_task` asks the host whether a `merge` task's MR is mergeable.
    public static let mergePoll: TimeInterval = 30
    /// M3, app only: how long it waits for that before blocking the task and asking you.
    public static let mergeWait: TimeInterval = 60 * 60
}

/// What this build of the operator supports (spec §13). A plan asking for more — a draft MR
/// in M1 — is refused when submitted, with the reason, never quietly downgraded.
public enum OperatorMilestone: Int, Comparable, CaseIterable, Sendable {
    case m1 = 1, m2, m3

    /// The milestone this build ships: M2, several agents at once (G6 raises it to `.m3`).
    public static let current: OperatorMilestone = .m2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Whether a plan may end a task with `end`: a commit from M1; a draft MR or a merge, which
    /// `finish_task` carries out, from M3.
    public func supports(_ end: TaskEnd) -> Bool { self >= end.availableFrom }

    /// Agents at once: one in M1, the cap you set in AiTerm from M2 (spec §13).
    public func maxParallel(setting: Int) -> Int { self == .m1 ? 1 : max(1, setting) }
}

public extension TaskEnd {
    /// The first milestone whose `finish_task` can carry this end out.
    var availableFrom: OperatorMilestone { self == .commit ? .m1 : .m3 }

    /// The end as the plan, the overview and a refusal say it.
    var displayName: String {
        switch self {
        case .commit: return "commit"
        case .draftMR: return "draft MR"
        case .merge: return "merge"
        }
    }
}
