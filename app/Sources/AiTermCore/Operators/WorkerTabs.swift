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
    /// command is typed into; or a first worker whose launch is under way and that has named no conversation yet
    /// (`TaskItem.workerTabs(in:now:)`). It counts as at work.
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

    /// What it left running in the background when its turn ended (`SessionInfo.background`), which wakes it again.
    /// While it works, only the subagents among it: the daemon holds a turn that ended on a subagent at working and
    /// lists each subagent until it ends, while the rest that Stop listed may have ended since.
    public var background: [String] {
        let jobs = session?.background ?? []
        var result = (status?.turnEnded == true ? jobs : jobs.filter { $0.kind == .subagent }).map(\.text)
        if let activity = session?.testActivity, activity.isActive { result.append(activity.line) }
        return result
    }

    /// At work, or its ended turn left work running that wakes it again: not stopped. What a pause tells to stop, and
    /// what keeps its task `pausing`.
    public var isStillAtWork: Bool { status == .working || !background.isEmpty }

    /// An extra tab that opened and is listed no more: closed, and never opened again. A first worker is never closed
    /// here; its window comes back on your click.
    public var isClosed: Bool { key != nil && session == nil && !isOpening }

    /// This tab as its tab alone says it, a first worker's launch not counted: what `TaskItem.workerTabs(in:)` gives with
    /// no time. A pass matches its tabs once, as of its time; what readiness and a pause leave aside reads them so.
    public var asListed: WorkerTab {
        guard key == nil, isOpening else { return self }
        var tab = self
        tab.isOpening = false
        return tab
    }
}

/// Which of a task's worker tabs a field names: its first worker, or an extra tab by its key. Each field keeps its own
/// encoding, nil or `main` (`WorkerTab.firstKey`) for the first worker, and is read through this.
public enum TabReference: Hashable, Sendable {
    case first, extra(String)

    /// From a key or a name: nil and `main` are the first worker, a key no extra tab may take (`open_tab`).
    public init(_ key: String?) {
        guard let key, key != WorkerTab.firstKey else { self = .first; return }
        self = .extra(key)
    }

    /// The name `run_status` and the Operator's tools give it: `main` for the first worker.
    public var name: String { if case .extra(let key) = self { key } else { WorkerTab.firstKey } }

    /// Its key, nil for the first worker: as `WorkerTab.key`, an extra tab's question and a worker's reading keep it.
    public var key: String? { if case .extra(let key) = self { key } else { nil } }
}

public extension WorkerTab {
    /// Which tab it is (`TabReference`).
    var reference: TabReference { TabReference(key) }
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
        let extra = Set((signalTask?.extraTabs ?? []).compactMap(\.conversation))
        return conversations.first { $0.agent == agent && !extra.contains($0.id) }
    }

    /// The worker tab `key` names: the first worker for nil or `WorkerTab.firstKey`, else the extra tab of that key; nil
    /// when the task has none of that key.
    func workerTab(_ key: String?, in sessions: [SessionInfo]) -> WorkerTab? {
        let tabs = workerTabs(in: sessions)
        switch TabReference(key) {
        case .first: return tabs[0]
        case .extra(let key): return tabs.first { $0.key == key }
        }
    }

    /// The tab a row's click brings forward: the first worker tab that needs input, then the task's
    /// active tab, otherwise its first worker. Nil while no tab is listed; the row's click restores its window.
    func tabToBring(sessions: [SessionInfo]) -> SessionInfo? {
        let tabs = workerTabs(in: sessions)
        return tabs.compactMap(\.session).first { $0.state == .needsInput }
            ?? sessions.first { $0.taskUUID == id && $0.active } ?? tabs.first?.session
    }

    /// Its worker tabs: its first worker, then each extra tab in the order asked for, all but one the daemon refused.
    /// An extra tab is the tab tagged with the task and its key, whatever runs in it. Given `now`, a first worker that has
    /// named no conversation yet, while its launch is under way (`isLaunching`), is opening: Codex reads idle until its
    /// first hook, half a minute in, and that is no ended turn. Without `now` it is taken as its tab says.
    func workerTabs(in sessions: [SessionInfo], now: Date? = nil) -> [WorkerTab] {
        let worker = firstWorker(in: sessions), conversation = worker?.conversationId ?? firstWorkerConversation?.id
        let first = WorkerTab(key: nil, agent: worker?.agent.agentKind ?? agent, model: model, session: worker,
                              isOpening: conversation == nil && isLaunching(worker, now: now), conversation: conversation)
        return [first] + (signalTask?.extraTabs ?? []).filter { $0.failure == nil }.map { tab in
            let session = sessions.first { $0.taskUUID == id && $0.tabKey == tab.key }
            let opening = session.map { $0.agent.agentKind == nil } ?? (tab.sessionId == nil && tab.launch.openedAt == nil)
            return WorkerTab(key: tab.key, agent: tab.agent, model: tab.model, session: session, isOpening: opening,
                             conversation: session?.conversationId ?? tab.conversation)
        }
    }

    /// Whether its first worker's launch is under way at `now`: a working task whose window was seen, else asked for, less
    /// than `OperatorTiming.openingGrace` ago, its worker not listed yet or not at work or asking. Bounded so a launch
    /// that failed is not starting forever; one that never starts is still caught as possibly stalled.
    private func isLaunching(_ worker: SessionInfo?, now: Date?) -> Bool {
        guard let now, worker.map({ $0.state.turnEnded }) ?? true else { return false }
        let launch: LaunchAttempt?
        if let signalTask {
            guard signalTask.phase.isActive else { return false }
            launch = signalTask.launch
        } else { return false }
        guard let launch else { return false }
        return now.timeIntervalSince(launch.openedAt ?? launch.requestedAt) < OperatorTiming.openingGrace
    }
}
