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
            let rows = sessions.map(Self.rowRelevant)
            if rows != rowSessions { rowSessions = rows }
            seedContexts(from: sessions)
            sessionsChanged(sessions)
        }
    }
    /// The tabs as the sidebar's rows read them — where each is, which row it belongs to, its
    /// agent, state and directory — with the rest cleared, and written only when that part
    /// changes. Most session events are a context fill, a model or a Codex spinner title, and
    /// each of those re-ran the whole row list when the sidebar read `sessions`.
    private(set) var rowSessions: [SessionInfo] = []
    var usage = UsageSnapshot.empty
    /// Context is displayed per provider within a sidebar row — a task or a terminal — not per tab.
    /// Keep each provider's last telemetry value while tabs switch or a polling snapshot has nothing
    /// new to say; selection only controls whether those values are shown.
    private var contextByRowId: [UUID: [AgentKind: Int]] = [:]

    /// The workspace the tabs are matched to rows in, and who hears of every change to `sessions`.
    private let workspace: @MainActor () -> AppState
    private let sessionsChanged: @MainActor ([SessionInfo]) -> Void

    init(workspace: @escaping @MainActor () -> AppState, sessionsChanged: @escaping @MainActor ([SessionInfo]) -> Void) {
        self.workspace = workspace
        self.sessionsChanged = sessionsChanged
    }

    /// The session and usage events; every other event is someone else's and is ignored.
    func handle(_ event: DaemonEvent) {
        switch event {
        case .snapshot(let snapshot):
            sessions = snapshot.sessions
            usage = snapshot.usage
        case .sessionOpened(let session), .sessionChanged(let session):
            let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId })
            rememberContext(from: session, replacing: index.map { sessions[$0] })
            if let index { sessions[index] = session }
            else { sessions.append(session) }
        case .sessionClosed(let id): sessions.removeAll { $0.sessionId == id }
        case .usageChanged(let value): usage = value
        case .itermConnected, .itermDisconnected, .itermAuthFailed, .itermCookieRequested,
             .windowActivated, .windowClosed, .unknown: break
        }
    }

    /// `session` without what no row draws: a field the rows start to read has to stay here.
    private static func rowRelevant(_ session: SessionInfo) -> SessionInfo {
        var row = session
        row.model = nil; row.reasoning = nil; row.title = ""; row.contextPercent = nil
        return row
    }

    /// The context each provider last reported in `row`; empty with nothing selected.
    func contextPercents(for row: RowSelection?) -> [AgentKind: Int] {
        row.flatMap { contextByRowId[$0.id] } ?? [:]
    }

    /// The footer's first row: what runs in the task's or terminal's active tab and its last-known
    /// `ctx`. With nothing selected there is no such row at all.
    func usageRow(for row: RowSelection?) -> UsageTaskRow? {
        let state = workspace(), contexts = contextPercents(for: row)
        switch row {
        case .task(let id):
            guard let task = state.task(id: id) else { return nil }
            return SidebarModel.usageTaskRow(taskId: id, agent: task.agent, sessions: sessions, contexts: contexts)
        case .terminal(let id):
            guard let terminal = state.terminal(id: id) else { return nil }
            return SidebarModel.usageTerminalRow(windowId: terminal.windowId, sessions: sessions, contexts: contexts)
        case .project, nil: return nil
        }
    }

    /// Drops the values of rows the workspace no longer has; run on every change to it.
    func pruneContexts() {
        let state = workspace()
        let live = Set(state.tasks.map(\.id) + state.terminals.map(\.id))
        guard contextByRowId.keys.contains(where: { !live.contains($0) }) else { return }
        contextByRowId = contextByRowId.filter { live.contains($0.key) }
    }

    /// Writes one provider's fill only when it moved: session events arrive several a second, and
    /// every write to a published property re-renders the sidebar.
    private func setContext(_ context: Int, row: UUID, provider: AgentKind) {
        guard contextByRowId[row]?[provider] != context else { return }
        contextByRowId[row, default: [:]][provider] = context
    }

    /// The sidebar row a tab is drawn under: its task, by the tag the daemon read off it, or else
    /// the terminal whose window it is in. A terminal's tabs carry no task tag, so the window is the
    /// only thing that ties an agent started in one back to its row — as it is for the row's avatars.
    private func rowId(for session: SessionInfo, in state: AppState) -> UUID? {
        if session.taskId != nil {
            return session.taskUUID.flatMap(state.task(id:))?.id
        }
        return state.terminals.first { $0.windowId != nil && $0.windowId == session.windowId }?.id
    }

    /// A snapshot has no event timestamps, so it can only initialise an unseen provider value.
    /// Prefer that provider's active tab; its fullest known tab is the fallback.
    private func seedContexts(from sessions: [SessionInfo]) {
        let state = workspace()
        let reportingByRow = Dictionary(grouping: sessions.filter { $0.contextPercent != nil },
                                        by: { rowId(for: $0, in: state) })
        for case let (rowId?, reporting) in reportingByRow {
            for provider in AgentKind.allCases where contextByRowId[rowId]?[provider] == nil {
                let own = reporting.filter { $0.agent.agentKind == provider }
                let session = own.first { $0.active == true }
                    ?? own.max { ($0.contextPercent ?? 0) < ($1.contextPercent ?? 0) }
                if let context = session?.contextPercent { setContext(context, row: rowId, provider: provider) }
            }
        }
    }

    /// Only a newly learned non-empty value advances a row's cache. Session changes caused by
    /// tab activation carry the old per-tab value too; treating those as telemetry would make the
    /// footer jump backwards while the new tab is still waiting to report.
    private func rememberContext(from session: SessionInfo, replacing old: SessionInfo?) {
        guard let context = session.contextPercent,
              old?.contextPercent != context || old?.taskId != session.taskId
                  || old?.windowId != session.windowId || old?.agent != session.agent,
              let provider = session.agent.agentKind,
              let rowId = rowId(for: session, in: workspace()) else { return }
        setContext(context, row: rowId, provider: provider)
    }
}
