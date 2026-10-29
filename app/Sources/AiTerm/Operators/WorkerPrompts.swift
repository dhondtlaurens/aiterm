import Foundation
import AiTermCore

/// Owns worker prompt discovery and post-delivery reads. All screen jobs share the same per-session
/// gap and lifetime; replies from a stopped generation cannot create or resolve questions.
@MainActor
final class WorkerPrompts {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let ports: OperatorPorts
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private var probing: [String: Task<Void, Never>] = [:]
    private var promptReadAt: [String: Date] = [:]
    private var promptState: [String: SessionState] = [:]
    private var messageProbes: [UUID: Task<Void, Never>] = [:]
    private var generation = 0
    private var isStopped = false
    private(set) var lastProbe: Task<Void, Never>?
    var tabsKnown: @MainActor () -> Bool = { false }
    var changed: @MainActor (UUID) -> Void = { _ in }

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.daemon = daemon
    }

    func start() { isStopped = false }

    func stop() {
        isStopped = true
        generation += 1
        for job in probing.values { job.cancel() }
        for job in messageProbes.values { job.cancel() }
        probing.removeAll()
        messageProbes.removeAll()
        promptReadAt.removeAll()
        promptState.removeAll()
        lastProbe = nil
    }

    func afterMessage(_ task: UUID, tab: String?) {
        guard !isStopped else { return }
        let id = UUID()
        messageProbes[id] = Task { [weak self] in
            guard let self else { return }
            defer { messageProbes[id] = nil }
            await probeAfterMessage(task, tab: tab)
        }
    }

    /// Why a worker screen is read: events follow input, ticks discover menus, delivery checks bypass the gap.
    enum Source { case event, reconcile, delivery }

    /// Events read tabs needing input or with open questions; ticks also discover unannounced menus.
    /// Both respect the per-tab read gap, except when entering or answering needs-input.
    func observe(_ source: Source = .event) {
        guard !isStopped else { return }
        let sessions = Set(live.sessions.map(\.sessionId))
        promptReadAt = promptReadAt.filter { sessions.contains($0.key) }
        promptState = promptState.filter { sessions.contains($0.key) }
        let workers = WorkerSessions(live.sessions)
        for task in workspace.state.tasks where task.operated != nil {
            for worker in task.workerTabs(in: workers) { probePrompt(task.id, worker, source: source) }
        }
    }

    /// Read the addressed worker after delivery and once more after it has had time to draw a dialog.
    /// Neither read delays the tool result; a replacement session is never probed for the old message.
    private func probeAfterMessage(_ id: UUID, tab key: String?) async {
        guard let worker = workspace.state.task(id: id)?.workerTab(key, in: live.sessions), let tab = worker.session else { return }
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return }
            if attempt > 0 {
                do { try await ports.promptSleep(.seconds(OperatorTiming.promptAfterMessageDelay)) } catch { return }
            }
            // A read begun before the delivery cannot say what that message opened.
            await probing[tab.sessionId]?.value
            guard !Task.isCancelled, let current = workspace.state.task(id: id)?.workerTab(key, in: live.sessions),
                  current.session?.sessionId == tab.sessionId else { return }
            probePrompt(id, current, source: .delivery)
            await probing[tab.sessionId]?.value
        }
    }

    /// Hook-announced and post-delivery prompts are questions on steerable tasks in unfinished broadcasts.
    /// Discovery on a tick is limited to working tasks in active broadcasts with no pause or stop intent.
    /// Existing questions resolve in every state. Event and tick reads have a gap, except when entering
    /// needs-input or leaving it with an open question; delivery bypasses it too.
    /// Each extra tab has its own question.
    func probePrompt(_ id: UUID, source: Source = .event) {
        guard !isStopped else { return }
        guard let task = workspace.state.task(id: id) else { return }
        for worker in task.workerTabs(in: live.sessions) { probePrompt(id, worker, source: source) }
    }

    private func probePrompt(_ id: UUID, _ worker: WorkerTab, source: Source) {
        guard let task = workspace.state.task(id: id), let operated = task.operated, let run = workspace.state.run(id: operated.runId) else { return }
        let prefix = "\(OperatorQuestion.promptPrefix)\(id.uuidString)-"
        let open = run.questions.first { $0.id.hasPrefix(prefix) && $0.tab == worker.key && $0.resolution == nil }
        let tab = worker.session
        guard let tab else {
            // No tab listed yet is not an answer; a known closed tab has no prompt left to answer.
            if let open, tabsKnown() { resolvePrompt(open, in: run.id, task: id) }
            return
        }
        let previous = promptState.updateValue(tab.state, forKey: tab.sessionId)
        if previous != tab.state, tab.state == .needsInput || (open != nil && previous == .needsInput) {
            promptReadAt[tab.sessionId] = nil
        }
        guard open != nil || mayRecordPrompt(task, in: run, tab: tab, source: source) else { return }
        if source == .event, tab.state != .needsInput, open == nil { return }
        let now = ports.now()
        if source != .delivery, let last = promptReadAt[tab.sessionId],
           now.timeIntervalSince(last) < OperatorTiming.promptProbeInterval { return }
        guard probing[tab.sessionId] == nil, let daemon = daemon() else { return }
        promptReadAt[tab.sessionId] = now
        let generation = self.generation
        lastProbe = Task { [weak self] in
            // The helper gone is not a prompt AiTerm can't read: nothing is recorded, and the next pass asks again.
            let kind: PromptKind?
            let readSucceeded: Bool
            do {
                kind = try await daemon.prompt(sessionId: tab.sessionId)
                readSucceeded = true
            } catch {
                kind = nil
                readSucceeded = false
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            // Codex's update offer is AiTerm's to decline (spec §7.1): the daemon sends Esc only when the
            // screen shows that dialog. Anything else at startup — a trust question — is yours, and so is
            // a dismissal that did not happen: only a dismissed offer is never put to you.
            let declined = kind == .startup ? (try? await daemon.dismissStartup(sessionId: tab.sessionId)) == true : false
            guard !Task.isCancelled, self.generation == generation else { return }
            probing[tab.sessionId] = nil
            guard !declined else { return }
            // A changed worker or turn makes the read stale. A new or answered prompt gets a fresh
            // read now, even if its state event arrived while this read was in flight.
            guard let task = workspace.state.task(id: id),
                  let currentWorker = task.workerTab(worker.key, in: live.sessions), let current = currentWorker.session,
                  current.sessionId == tab.sessionId else { return }
            guard current.state == tab.state else {
                if current.state == .needsInput || (open != nil && tab.state == .needsInput) {
                    promptReadAt[tab.sessionId] = nil
                    probePrompt(id, currentWorker, source: .event)
                }
                return
            }
            guard readSucceeded else { return }
            if kind == nil, tab.state != .needsInput {
                if let open { resolvePrompt(open, in: run.id, task: id) }
                return
            }
            guard open == nil, let run = workspace.state.run(id: run.id),
                  mayRecordPrompt(task, in: run, tab: current, source: source) else { return }
            let now = ports.now()
            workspace.mutate { state in
                // Numbered as it is recorded: another tab of the task may have recorded one while this was read.
                let number = (state.run(id: run.id)?.questions.filter { $0.id.hasPrefix(prefix) }.count ?? 0) + 1
                let question = OperatorQuestion(id: prefix + String(number), text: Self.promptText(kind, agent: worker.agent), task: id,
                                                askedAt: now, resolution: nil, tab: worker.key)
                state.updateRun(id: run.id) { $0.questions.append(question) }
                state.updateOperated(id) {
                    $0.flags.insert(.waitingOnYou)
                    $0.flags.remove(.possiblyStalled)
                }
            }
        }
        probing[tab.sessionId] = lastProbe
    }

    private func mayRecordPrompt(_ task: TaskItem, in run: OperatorRun, tab: SessionInfo, source: Source) -> Bool {
        guard let operated = task.operated, run.intent != .stopped else { return false }
        if source == .delivery || tab.state == .needsInput {
            return [.working, .blocked, .inReview].contains(operated.state) && ![.complete, .stopped].contains(run.state)
        }
        return operated.state == .working && run.state == .active && run.intent == nil
    }

    /// Mark the tab's question answered and clear waiting-on-you once no question remains on its task.
    /// This can also complete a broadcast whose tasks have already ended.
    private func resolvePrompt(_ question: OperatorQuestion, in run: UUID, task: UUID) {
        workspace.mutate { state in
            state.updateRun(id: run) { run in
                if let i = run.questions.firstIndex(where: { $0.id == question.id }) { run.questions[i].resolution = "Answered in its window." }
            }
            if state.run(id: run)?.questions.contains(where: { $0.task == task && $0.resolution == nil }) == false {
                state.updateOperated(task) { $0.flags.remove(.waitingOnYou) }
            }
        }
        // The last open question may be what kept the broadcast from completing.
        changed(run)
    }

    /// What a prompt asks, as the board and the row say it. The daemon names the prompt's kind,
    /// not its words, so this is what AiTerm can say of it.
    static func promptText(_ kind: PromptKind?, agent: AgentKind) -> String {
        let name = agent.harness.displayName
        switch kind {
        case .permission: return "\(name) asks for permission"
        case .menu: return "\(name) shows a menu"
        case .startup: return "\(name) shows a startup question"
        case nil: return "\(name) waits for input AiTerm can’t read"
        }
    }

}
