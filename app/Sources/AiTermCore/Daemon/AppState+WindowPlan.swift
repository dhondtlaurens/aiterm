import Foundation

/// A sidebar row that owns an iTerm2 window: a task's (or a review's), a terminal's, or the Operator's chat.
public enum WindowRow: Hashable, Sendable {
    case task(UUID), terminal(UUID), operatorChat
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
    /// is planned alike, driven or not, and so is the Operator's chat, whose tabs carry its session's id, except while
    /// a handover runs: the old chat's window and the new one's carry the same tag then.
    func windowPlan(sessions: [SessionInfo]) -> [WindowAdoption] {
        var tagged: [UUID: [String]] = [:]
        for tab in sessions {
            guard let id = tab.terminalUUID ?? tab.taskUUID, tagged[id]?.contains(tab.windowId) != true else { continue }
            tagged[id, default: []].append(tab.windowId)
        }
        var adoptions: [WindowAdoption] = []
        func plan(_ row: WindowRow, tag: UUID, window: String?) {
            let windows = tagged[tag] ?? []
            if let found = windows.first, window.map({ !windows.contains($0) }) ?? true {
                adoptions.append(WindowAdoption(row, windowId: found))
            }
        }
        for task in tasks { plan(.task(task.id), tag: task.id, window: task.windowId) }
        for terminal in terminals { plan(.terminal(terminal.id), tag: terminal.id, window: terminal.windowId) }
        if let session = operatorSession, session.handover == nil {
            plan(.operatorChat, tag: session.id, window: session.window)
        }
        return adoptions
    }
}
