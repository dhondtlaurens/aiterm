import Foundation

public struct OperatorLine: Equatable, Sendable {
    public enum Look: Equatable, Sendable { case quiet, ended, acting, needsYou }
    public var text: String
    public var look: Look
    /// The whole of what the line says: the request's sentence, or the words before they were cut.
    public var tooltip: String

    public init(_ text: String, look: Look = .quiet, tooltip: String? = nil) {
        self.text = text; self.look = look; self.tooltip = tooltip ?? text
    }

    /// The most characters a line says before its detail is cut: what the sidebar's status line holds, in
    /// `Typography.chip`, at the sidebar's narrowest.
    public static let maxLength = 40

    /// The broadcast's line while every task is done and the goal is still to check (`check_goal`): the board's band
    /// adds the round it checks only under it.
    public static let checkingTheGoal = OperatorLine("checking the goal", look: .acting)
    /// The Operator row's line while its session works and AiTerm carries out no act of its own.
    public static let working = OperatorLine("working", look: .acting)
    /// The Operator row's line while its window is closed.
    public static let windowClosed = OperatorLine("window closed")
    /// A broadcast you paused: a working task's line once its workers stopped, and the Operator row's once every task's
    /// did. Both rows wear the pause sign with it.
    public static let paused = OperatorLine("paused")
    /// A broadcast you paused: a working task's line while one of its workers is still at work (`WorkerTab.isStillAtWork`).
    public static let pausing = OperatorLine("pausing", look: .acting)

    /// Whether the Operator row's line names something the Operator does: an act, or checking the goal; not
    /// `working`, which names nothing. What OPERATOR decodes into as it happens (`OperatorTitle`).
    public var isAct: Bool { look == .acting && self != .working }

    // MARK: - A driven task's line

    /// The line on a driven task's row and its card; nil for a task you made yourself, one you took over
    /// (its card says `taken over`), one the Operator let go of, and every task of an ended broadcast.
    /// `tasks` names the tasks it waits for; without them the parent is "another task". `sessions` are its tabs as
    /// iTerm2 lists them (any others are passed over): they tell a task whose workers all ended their turn, and how
    /// many worker tabs it has open. Without them it reads as watched. `turn` is how its worker's last turn ended
    /// (`OperatorActs.turns`): a working task whose worker asks is `asking the Operator`, one that committed nothing
    /// `Operator watching · no commit`; any other state keeps its own line. A working task whose worker's turn an API
    /// error ended is `blocked · usage limit, resets 13:20` (`StoppedOn`), its reset said as of `now` in `calendar`'s time zone.
}
