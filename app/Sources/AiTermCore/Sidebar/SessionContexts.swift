import Foundation

/// The context fill each sidebar row last reported, per provider. Context is shown per row — a task
/// or a terminal — not per tab: each provider's last value is kept while tabs switch, or while a
/// snapshot has nothing new to say. Nothing here is saved.
public struct SessionContexts: Equatable, Sendable {
    private var byRow: [UUID: [AgentKind: Int]] = [:]

    public init() {}

    /// The context each provider last reported in the row; empty for a row none has reported in.
    public func percents(forRow id: UUID) -> [AgentKind: Int] { byRow[id] ?? [:] }

    /// Drops the values of rows `state` no longer has.
    public mutating func prune(keeping state: AppState) {
        let live = Set(state.tasks.map(\.id) + state.terminals.map(\.id))
        guard byRow.keys.contains(where: { !live.contains($0) }) else { return }
        byRow = byRow.filter { live.contains($0.key) }
    }

    /// A snapshot has no event timestamps, so it can only initialise a provider's value a row does
    /// not have yet. That provider's active tab is preferred; its fullest known tab is the fallback.
    public mutating func seed(from sessions: [SessionInfo], in state: AppState) {
        let reportingByRow = Dictionary(grouping: sessions.filter { $0.contextPercent != nil },
                                        by: { Self.row(for: $0, in: state) })
        for case let (rowId?, reporting) in reportingByRow {
            for provider in AgentKind.allCases where byRow[rowId]?[provider] == nil {
                let own = reporting.filter { $0.agent.agentKind == provider }
                let session = own.first { $0.active == true }
                    ?? own.max { ($0.contextPercent ?? 0) < ($1.contextPercent ?? 0) }
                if let context = session?.contextPercent { set(context, row: rowId, provider: provider) }
            }
        }
    }

    /// Only a newly learned non-empty value advances a row's value. Session changes caused by tab
    /// activation carry the old per-tab value too; treating those as telemetry would make the
    /// footer jump backwards while the new tab is still waiting to report.
    public mutating func remember(_ session: SessionInfo, replacing old: SessionInfo?, in state: AppState) {
        guard let context = session.contextPercent,
              old?.contextPercent != context || old?.taskId != session.taskId
                  || old?.windowId != session.windowId || old?.agent != session.agent,
              let provider = session.agent.agentKind,
              let rowId = Self.row(for: session, in: state) else { return }
        set(context, row: rowId, provider: provider)
    }

    /// Writes one provider's fill only when it moved, so a caller can tell a change by comparing.
    private mutating func set(_ context: Int, row: UUID, provider: AgentKind) {
        guard byRow[row]?[provider] != context else { return }
        byRow[row, default: [:]][provider] = context
    }

    /// The sidebar row a tab is drawn under: its task, by the tag the daemon read off it, or else
    /// the terminal whose window it is in. A terminal's tabs carry no task tag, so the window is the
    /// only thing that ties an agent started in one back to its row — as it is for the row's avatars.
    static func row(for session: SessionInfo, in state: AppState) -> UUID? {
        if session.taskId != nil {
            return session.taskUUID.flatMap(state.task(id:))?.id
        }
        return state.terminals.first { $0.windowId != nil && $0.windowId == session.windowId }?.id
    }
}
