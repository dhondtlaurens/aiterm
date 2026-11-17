import Foundation

public extension AppState {
    /// The workspace as a snapshot of iTerm2 shows it: every row whose window the snapshot does not
    /// list is left without one, as `closeWindow` has it. Only a connected snapshot says anything: one
    /// taken while iTerm2 is out of reach lists no windows, and would clear every row's. Taking a
    /// window by its tag is `windowPlan`'s.
    func reconciled(with snapshot: DaemonSnapshot) -> AppState {
        guard snapshot.connected else { return self }
        var next = self
        let windows = Set(snapshot.sessions.map(\.windowId))
        let closed = Set((next.tasks.compactMap(\.windowId) + next.terminals.compactMap(\.windowId))
            .filter { !windows.contains($0) })
        for windowId in closed { next.closeWindow(windowId) }
        return next
    }
}
