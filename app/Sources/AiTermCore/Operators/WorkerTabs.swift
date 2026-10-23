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

    /// What it left running in the background when its turn ended (`SessionInfo.background`), which wakes it again;
    /// nothing while its turn is under way.
    public var background: [String] { status?.turnEnded == true ? session?.background.map(\.text) ?? [] : [] }

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
    /// every worker ended its turn with nothing left running in the background (`RunStatus.isReadyForAcceptance`).
    /// A question it waits on you for (`waitingOnYou`) holds it too, as `run_status` says.
    func isReadyForAcceptance(in sessions: [SessionInfo]) -> Bool {
        return isReadyForAcceptance(tabs: workerTabs(in: sessions))
    }

    /// `isReadyForAcceptance(in:)` from its worker tabs (`workerTabs(in:)`), for a caller that has them already.
    func isReadyForAcceptance(tabs: [WorkerTab]) -> Bool {
        guard let operated, !operated.flags.contains(.waitingOnYou) else { return false }
        let workers = tabs.map(\.status)
        return RunStatus.isReadyForAcceptance(operated, live: workers[0], extraTabs: Array(workers.dropFirst()),
                                              background: tabs.flatMap(\.background))
    }

    /// The tab a click on its row brings forward (P5 A, 21 Oct 2026), its tabs as `sessions` list them: the worker tab
    /// that asks, a request of `requests` naming it (`BroadcastRequest.tab`) or its tab at a prompt not recorded yet;
    /// of several, the most urgent (`BroadcastRequest.Kind.rank`), then by tab order (`main`, then the extra tabs as they
    /// opened). With none asking, the tab of the task last in front in its window, else its first worker. Nil while
    /// none is listed: its window comes back as a row's click brings it.
    func tabToBring(sessions: [SessionInfo], requests: [BroadcastRequest]) -> SessionInfo? {
        let tabs = workerTabs(in: sessions)
        var asking: [(rank: Int, place: Int, session: SessionInfo)] = []
        for (place, tab) in tabs.enumerated() {
            guard let session = tab.session else { continue }
            let key = tab.key ?? WorkerTab.firstKey
            var ranks = requests.filter { $0.taskId == id && $0.tab == key }.map(\.kind.rank)
            if session.state == .needsInput { ranks.append(BroadcastRequest.Kind.permission.rank) }
            if let rank = ranks.min() { asking.append((rank, place, session)) }
        }
        if let first = asking.min(by: { ($0.rank, $0.place) < ($1.rank, $1.place) }) { return first.session }
        return sessions.first { $0.taskUUID == id && $0.active } ?? tabs[0].session ?? tabs.lazy.compactMap(\.session).first
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
