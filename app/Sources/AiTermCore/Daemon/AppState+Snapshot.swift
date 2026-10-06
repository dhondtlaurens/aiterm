import Foundation

public extension AppState {
    /// The workspace as a snapshot of iTerm2 shows it. Only a connected snapshot says anything:
    /// one taken while iTerm2 is out of reach lists no windows, and would close every row.
    ///
    /// Each task first takes the window of a tab tagged with it — a create whose reply was lost, or
    /// a window iTerm2 renumbered, is found again by the tag — except a task in `lettingGo`: its
    /// removal has let its window go, and re-attached, the window would take the row with it when
    /// it closes. Then every task and terminal whose window the snapshot does not list goes, as
    /// `closeWindow` takes it.
    func reconciled(with snapshot: DaemonSnapshot, lettingGo: Set<UUID>) -> AppState {
        guard snapshot.connected else { return self }
        var next = self
        let tabByTask = Dictionary(snapshot.sessions.compactMap { tab in tab.taskUUID.map { ($0, tab) } },
                                   uniquingKeysWith: { first, _ in first })
        for index in next.tasks.indices where !lettingGo.contains(next.tasks[index].id) {
            if let session = tabByTask[next.tasks[index].id] { next.tasks[index].windowId = session.windowId }
        }
        let windows = Set(snapshot.sessions.map(\.windowId))
        let closed = Set((next.tasks.compactMap(\.windowId) + next.terminals.compactMap(\.windowId))
            .filter { !windows.contains($0) })
        for windowId in closed { next.closeWindow(windowId) }
        return next
    }
}
