import Foundation

/// How one stretch of the Operator's status line is drawn: at rest in the idle ring's grey; during an exchange dotted
/// in the text ink, marching down while the Operator acts on a task and up, once, when a task wakes it; and solid
/// amber, still, while a question for you is open on a task.
public enum StatusLineInk: Equatable, Sendable {
    case rest, acting, waking, asking

    /// Which ink a stretch two exchanges share takes (O7): a moving exchange shows while it lasts, over a question,
    /// which shows again after it; a wake's single march up, a second long, shows over a longer act.
    var precedence: Int {
        switch self {
        case .rest: 0
        case .asking: 1
        case .acting: 2
        case .waking: 3
        }
    }

    static func strongest(_ a: Self?, _ b: Self?) -> Self? {
        guard let a else { return b }
        guard let b else { return a }
        return b.precedence > a.precedence ? b : a
    }
}

/// One row's part of the status line, drawn in the row's trailing slot: the line coming in from the row above, going
/// on to the row below, and what it meets at the row's centre.
public struct StatusLinePiece: Equatable, Sendable {
    public enum Node: Equatable, Sendable {
        /// Nothing: the line passes straight through (a divider, an open heading, a folded one with nothing of the
        /// Operator's left).
        case none
        /// A status mark, the Operator's or a task's: the line stops short of it.
        case mark
        /// A folded project's stop, in the ink of the stretch that reaches it.
        case stop(StatusLineInk)
    }
    public var above: StatusLineInk?
    public var below: StatusLineInk?
    public var node: Node

    public init(above: StatusLineInk? = nil, below: StatusLineInk? = nil, node: Node = .none) {
        self.above = above; self.below = below; self.node = node
    }
}

/// Where the Operator's status line runs down the open Operator section (decision 7, O7 and the folded stop): from
/// under the Operator's mark to the last row that is a task it runs or a folded project holding one, or that it is
/// exchanging with now. A task row between is passed around its mark; a divider and an open heading are passed
/// through; a folded project holding a task the Operator runs (or exchanging with it) takes a stop on its heading's row.
/// Rows after the end have no piece; with no Operator row, or nothing it runs or exchanges with, there is no line.
///
/// An exchange inks every stretch from the Operator's mark to its task's mark, or to the stop of the folded project
/// holding it: `acting` while the Operator acts on the task, `waking` while the task's wake lasts, `asking` while a
/// question for you is open on it.
public enum StatusLine {
    /// A row of the open Operator section, in drawn order, by its id.
    public enum Row: Equatable, Sendable {
        case operatorRow
        case divider(UUID)
        /// A project's heading in the Operator's section, by its own row id, whether it is folded, and the tasks under it.
        case heading(UUID, folded: Bool, tasks: [UUID])
        case task(UUID)

        public var id: UUID {
            switch self {
            case .operatorRow: OperatorSession.rowID
            case .divider(let id), .heading(let id, _, _), .task(let id): id
            }
        }
    }

    /// Each row's piece, by row id; a row off the line has none.
    public static func pieces(rows: [Row], workload: Set<UUID>, acting: Set<UUID> = [], waking: Set<UUID> = [],
                              asking: Set<UUID> = []) -> [UUID: StatusLinePiece] {
        guard let start = rows.firstIndex(of: .operatorRow) else { return [:] }
        func exchange(_ task: UUID) -> StatusLineInk? {
            var ink: StatusLineInk?
            if asking.contains(task) { ink = StatusLineInk.strongest(ink, .asking) }
            if acting.contains(task) { ink = StatusLineInk.strongest(ink, .acting) }
            if waking.contains(task) { ink = StatusLineInk.strongest(ink, .waking) }
            return ink
        }
        // What each row below the Operator's is to the line: whether it ends a stretch (a node the line can end at),
        // and the ink of the exchange it ends.
        var ends: [Int: StatusLineInk?] = [:]
        for index in rows.indices where index > start {
            switch rows[index] {
            case .task(let id):
                let ink = exchange(id)
                if workload.contains(id) || ink != nil { ends[index] = ink }
            case .heading(_, true, let tasks):
                let ink = tasks.reduce(nil as StatusLineInk?) { StatusLineInk.strongest($0, exchange($1)) }
                if tasks.contains(where: workload.contains) || ink != nil { ends[index] = ink }
            case .heading, .divider, .operatorRow: break
            }
        }
        guard let end = ends.keys.max() else { return [:] }
        // The stretch between row `index` and the next, each its strongest exchange's ink below it.
        var stretches = Array(repeating: StatusLineInk.rest, count: end - start)
        for (index, ink) in ends {
            guard let ink else { continue }
            for stretch in 0..<(index - start) {
                stretches[stretch] = StatusLineInk.strongest(stretches[stretch], ink) ?? .rest
            }
        }
        var pieces: [UUID: StatusLinePiece] = [:]
        for index in start...end {
            let node: StatusLinePiece.Node
            switch rows[index] {
            case .operatorRow, .task: node = .mark
            case .heading(_, true, _) where ends.keys.contains(index): node = .stop((ends[index] ?? nil) ?? .rest)
            case .heading, .divider: node = .none
            }
            pieces[rows[index].id] = StatusLinePiece(above: index > start ? stretches[index - start - 1] : nil,
                                                     below: index < end ? stretches[index - start] : nil, node: node)
        }
        return pieces
    }
}
