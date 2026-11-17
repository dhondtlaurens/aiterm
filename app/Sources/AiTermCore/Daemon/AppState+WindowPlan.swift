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

/// A row taking a window `AppState.windowPlan` found its tag in.
public struct WindowAdoption: Equatable, Sendable {
    public var row: WindowRow
    public var windowId: String

    public init(_ row: WindowRow, windowId: String) {
        self.row = row
        self.windowId = windowId
    }
}

public extension AppState {
    /// The windows rows take by their tag: a row takes a window a tab tagged with its id is in when it has none, or
    /// when its own is not among them; a row whose own window still carries its tag keeps it. Every task and terminal
    /// is planned alike, driven or not.
    func windowPlan(sessions: [SessionInfo]) -> [WindowAdoption] {
        var tagged: [UUID: [String]] = [:]
        for tab in sessions {
            guard let id = tab.terminalUUID ?? tab.taskUUID, tagged[id]?.contains(tab.windowId) != true else { continue }
            tagged[id, default: []].append(tab.windowId)
        }
        var adoptions: [WindowAdoption] = []
        func plan(_ row: WindowRow, window: String?) {
            let windows = tagged[row.id] ?? []
            if let found = windows.first, window.map({ !windows.contains($0) }) ?? true {
                adoptions.append(WindowAdoption(row, windowId: found))
            }
        }
        for task in tasks { plan(.task(task.id), window: task.windowId) }
        for terminal in terminals { plan(.terminal(terminal.id), window: terminal.windowId) }
        return adoptions
    }
}
