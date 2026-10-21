import Foundation

/// One of a task's worker tabs: its first worker, or a tab the Operator added (`open_tab`, `ExtraTab`), with the tab
/// iTerm2 lists for it. A task counts every one: it waits for acceptance once all ended their turn, its runtime runs
/// while any one is at work, and a prompt or a stall in any one is the task's.
public struct WorkerTab: Equatable, Sendable {
    /// The name `run_status` gives the first worker among its task's tabs; no extra tab takes it.
    public static let firstKey = "main"

    /// The extra tab's key; nil for the first worker.
    public var key: String?
    public var agent: AgentKind, model: String
    /// Its tab as iTerm2 lists it; nil while none is.
    public var session: SessionInfo?
    /// An extra tab asked for whose agent has not shown yet: never listed since its request, or listed as the shell its
    /// command is typed into. It counts as at work.
    public var isOpening: Bool
    /// The conversation its agent named: its tab's now, else the one last recorded for it (the first worker's
    /// `TaskItem.firstWorkerConversation`, an extra tab's `ExtraTab.conversation`).
    public var conversation: String?

    public init(key: String?, agent: AgentKind, model: String, session: SessionInfo?, isOpening: Bool = false, conversation: String? = nil) {
        self.key = key; self.agent = agent; self.model = model; self.session = session; self.isOpening = isOpening
        self.conversation = conversation
    }

    /// What it counts as: at work while opening, else its tab's status; nil with no tab listed (a first worker whose
    /// window is gone, an extra tab that was closed).
    public var status: SessionState? { isOpening ? .working : session?.state }

    /// An extra tab that opened and is listed no more: closed, and never opened again. A first worker is never closed
    /// here; its window comes back on your click.
    public var isClosed: Bool { key != nil && session == nil && !isOpening }
}

public extension TaskItem {
    /// Its first worker as `sessions` list it: the first tab tagged with the task that runs an agent and is none of the
    /// Operator's extra tabs.
    func firstWorker(in sessions: [SessionInfo]) -> SessionInfo? {
        sessions.filter { $0.taskUUID == id && $0.agent.agentKind != nil && $0.tabKey == nil }.min { $0.tabIndex < $1.tabIndex }
    }

    /// The conversation its first worker last named, as its window last showed it (`conversations`): the first of its own
    /// agent's that none of its extra tabs named (`ExtraTab.conversation`), wherever that tab stood in the window.
    var firstWorkerConversation: TaskConversation? {
        let extra = Set((operated?.extraTabs ?? []).compactMap(\.conversation))
        return conversations.first { $0.agent == agent && !extra.contains($0.id) }
    }

    /// The worker tab `key` names: the first worker for nil or `WorkerTab.firstKey`, else the extra tab of that key; nil
    /// when the task has none of that key.
    func workerTab(_ key: String?, in sessions: [SessionInfo]) -> WorkerTab? {
        let tabs = workerTabs(in: sessions)
        guard let key, key != WorkerTab.firstKey else { return tabs[0] }
        return tabs.first { $0.key == key }
    }

    /// Whether its result waits for the Operator to accept it, its workers as `sessions` list them: working, and
    /// every worker ended its turn (`RunStatus.isReadyForAcceptance`).
    func isReadyForAcceptance(in sessions: [SessionInfo]) -> Bool {
        guard let operated else { return false }
        let workers = workerTabs(in: sessions).map(\.status)
        return RunStatus.isReadyForAcceptance(operated, live: workers[0], extraTabs: Array(workers.dropFirst()))
    }

    /// Its worker tabs: its first worker, then each extra tab in the order asked for, all but one the daemon refused.
    /// An extra tab is the tab tagged with the task and its key, whatever runs in it.
    func workerTabs(in sessions: [SessionInfo]) -> [WorkerTab] {
        let worker = firstWorker(in: sessions)
        let first = WorkerTab(key: nil, agent: agent, model: model, session: worker,
                              conversation: worker?.conversationId ?? firstWorkerConversation?.id)
        return [first] + (operated?.extraTabs ?? []).filter { $0.failure == nil }.map { tab in
            let session = sessions.first { $0.taskUUID == id && $0.tabKey == tab.key }
            let opening = session.map { $0.agent.agentKind == nil } ?? (tab.sessionId == nil && tab.launch.openedAt == nil)
            return WorkerTab(key: tab.key, agent: tab.agent, model: tab.model, session: session, isOpening: opening,
                             conversation: session?.conversationId ?? tab.conversation)
        }
    }
}
