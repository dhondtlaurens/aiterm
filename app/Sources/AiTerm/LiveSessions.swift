import Foundation
import AiTermCore

/// What the helper reports is running now: every iTerm2 tab it can see, each agent's usage, and
/// the context fill each sidebar row last reported. Nothing here is saved; the workspace it is
/// matched against is.
@MainActor
@Observable
final class LiveSessions {
    /// Every tab, as the helper last described it.
    var sessions: [SessionInfo] = [] {
        didSet {
            let rows = sessions.map(\.rowRelevant)
            if rows != rowSessions {
                rowSessions = rows
                for hook in rowSessionsHooks { hook() }
            }
            let state = workspace.state
            updateContexts { $0.seed(from: sessions, in: state) }
            let counts = Dictionary(sessions.compactMap { s in s.tokens.map { (s.sessionId, $0) } }, uniquingKeysWith: { _, last in last })
            if counts != tokens { tokens = counts }
            for hook in sessionsHooks { hook(sessions) }
        }
    }
    /// The tabs as the sidebar's rows read them — where each is, which row it belongs to, its
    /// agent, state and directory — with the rest cleared, and written only when that part
    /// changes. Most session events are a context fill, a model or a Codex spinner title, and
    /// each of those re-ran the whole row list when the sidebar read `sessions`.
    private(set) var rowSessions: [SessionInfo] = []
    var usage = UsageSnapshot.empty
    /// The context fill each row last reported, per provider. Written only when a value moves:
    /// session events arrive several a second, and every write re-renders the sidebar.
    private var contexts = SessionContexts()
    /// What each tab's conversation has spent, by session: its own, never promoted across a row as a
    /// context fill is. Written only when a count moves, so a model or a title leaves the footer be.
    private(set) var tokens: [String: TokenTally] = [:]

    /// The workspace the tabs are matched to rows in.
    private let workspace: WorkspaceStore
    @ObservationIgnored private var sessionsHooks: [@MainActor ([SessionInfo]) -> Void] = []
    @ObservationIgnored private var rowSessionsHooks: [@MainActor () -> Void] = []

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
    }

    /// Adds `hook` to what hears of every change to `sessions`.
    func onSessionsChanged(_ hook: @escaping @MainActor ([SessionInfo]) -> Void) {
        sessionsHooks.append(hook)
    }

    /// Adds `hook` to what hears only of the changes to `rowSessions` — the sidebar's rows and the
    /// Dock badge, which a context fill or a spinner title leaves as they were.
    func onRowSessionsChanged(_ hook: @escaping @MainActor () -> Void) {
        rowSessionsHooks.append(hook)
    }

    /// The session and usage events; every other event is someone else's and is ignored.
    func handle(_ event: DaemonEvent) {
        switch event {
        case .snapshot(let snapshot):
            sessions = snapshot.sessions
            usage = snapshot.usage
        case .sessionOpened(let session), .sessionChanged(let session):
            let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId })
            let old = index.map { sessions[$0] }, state = workspace.state
            updateContexts { $0.remember(session, replacing: old, in: state) }
            if let index { sessions[index] = session }
            else { sessions.append(session) }
        case .sessionClosed(let id): sessions.removeAll { $0.sessionId == id }
        // A closed window's tabs went with it. One that only moved to another window is still listed
        // here under the old one until its `session.changed`, which the daemon sends after the close:
        // it comes back with that.
        case .windowClosed(let wid): sessions.removeAll { $0.windowId == wid }
        case .usageChanged(let value): usage = value
        case .itermConnected, .itermDisconnected, .itermAuthFailed, .itermCookieRequested,
             .windowActivated, .unknown: break
        }
    }

    /// The window of an open tab tagged with `task`, if there is one: a task's tab lives on in another
    /// window once it is dragged there, or the windows are merged, though its own window closed.
    func window(ofTask task: UUID) -> String? {
        sessions.first { $0.taskUUID == task }?.windowId
    }

    /// The context each provider last reported in `row`; empty with nothing selected.
    func contextPercents(for row: RowSelection?) -> [AgentKind: Int] {
        row.map { contexts.percents(forRow: $0.id) } ?? [:]
    }

    /// Drops the values of rows the workspace no longer has; run on every change to it.
    func pruneContexts() {
        let state = workspace.state
        updateContexts { $0.prune(keeping: state) }
    }

    /// Applies `change` to the context fills, and writes them back only if it moved one.
    private func updateContexts(_ change: (inout SessionContexts) -> Void) {
        var next = contexts
        change(&next)
        if next != contexts { contexts = next }
    }
}
