import Foundation

/// A sidebar row that owns an iTerm2 window: a task's (or a review's) or a terminal's.
public enum WindowRow: Hashable, Sendable {
    case task(UUID), terminal(UUID)

    public var id: UUID {
        switch self {
        case .task(let id), .terminal(let id): id
        }
    }
}

/// One thing `AppState.windowPlan` says to do about a row's window.
public enum WindowStep: Equatable, Sendable {
    /// The row takes this window: a tab tagged with it is open there.
    case adopt(WindowRow, windowId: String)
    /// The row's window is owed and nothing stands in the way: open it again, its conversations resumed.
    case restore(WindowRow)
    /// The person closed this task's window alone: ask Remove Task's own question.
    case ask(UUID)
    /// The person closed this terminal's window alone: the row goes with it.
    case drop(UUID)
}

public extension AppState {
    /// The rows locked to their windows: what to do about each row whose window is not where its row
    /// says. A row with no window (`windowId == nil`) is owed one, and every reason it has not come
    /// back yet is an input here, never a state the row is in.
    ///
    /// - A row takes a window its tag is in when it has none, or when its own is not among them; a row
    ///   whose own window still carries its tag keeps it. This is the only adoption rule.
    /// - An owed row closed alone and `due` is asked about (a task) or dropped (a terminal).
    /// - Any other owed row is restored once iTerm2 is `settled` — synced, quiet, a daemon there and
    ///   the workspace able to change.
    /// - A row in `waiting` (held, busy, asked about, restoring, failed, its checkout missing) is
    ///   neither asked about, dropped nor restored, though it may still adopt; a task in `lettingGo`,
    ///   whose removal let its window go, does nothing at all.
    /// - A row with no checkout yet is not planned; an operated row is only adopted.
    func windowPlan(sessions: [SessionInfo], settled: Bool, due: Set<UUID>, waiting: Set<UUID>,
                    lettingGo: Set<UUID>) -> [WindowStep] {
        var tagged: [UUID: [String]] = [:]
        for tab in sessions {
            guard let id = tab.terminalUUID ?? tab.taskUUID, tagged[id]?.contains(tab.windowId) != true else { continue }
            tagged[id, default: []].append(tab.windowId)
        }
        var steps: [WindowStep] = []
        func plan(_ row: WindowRow, window: String?, adoptOnly: Bool = false) {
            let id = row.id
            guard !lettingGo.contains(id) else { return }
            let windows = tagged[id] ?? []
            if let found = windows.first, window.map({ !windows.contains($0) }) ?? true {
                steps.append(.adopt(row, windowId: found))
                return
            }
            guard !adoptOnly, window == nil, !waiting.contains(id) else { return }
            if due.contains(id) {
                switch row {
                case .task: steps.append(.ask(id))
                case .terminal: steps.append(.drop(id))
                }
            } else if settled {
                steps.append(.restore(row))
            }
        }
        // A row with no worktree yet has no window to take or open. An operator's started task takes
        // back a window its tag is in, but is reopened only by the operator controller on your click
        // (`reopenWorker`), which resumes its worker with the Operator's worker flags rather than the
        // resume a sheet's task gets.
        for task in tasks where task.hasCheckout { plan(.task(task.id), window: task.windowId, adoptOnly: task.operated != nil) }
        for terminal in terminals { plan(.terminal(terminal.id), window: terminal.windowId) }
        return steps
    }
}
