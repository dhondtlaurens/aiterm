import Foundation
import AiTermCore

/// Native worker effects. Every await is followed by the saved stage's authority check; a
/// daemon delivery independently checks the live process, prompt and ownership.
@MainActor final class SignalWorkerIO {
    let workspace: WorkspaceStore, live: LiveSessions, work: WorkInFlight, ports: OperatorPorts
    let daemon: @MainActor () -> (any DaemonCommands)?
    let frame: @MainActor () -> Frame
    let transcripts: TranscriptLocator
    /// The tasks an Operator effect runs on. `launch`, `message` and `openTab` run under their caller's claim.
    let effects: OperatorInFlight
    private(set) var replies: [UUID: [String: WorkerTranscript.Reply]] = [:]
    /// The tasks the last `refreshTurns` saw with live work; one that has none at the next gets a `worker_ended` wake.
    private var awaitingLiveWork: Set<UUID> = []
    var enabled: @MainActor () -> Bool = { true }
    var additionalContext: @MainActor (TaskItem) async throws -> String = { _ in "" }
    var onBlocked: @MainActor (UUID) -> Void = { _ in }
    var onTurn: (UUID) -> Void = { _ in }
    /// Runs a launch's wait for your pause (`PauseGate`) under `words`, so the Operator's row says it is waiting.
    var whilePausing: @MainActor (_ words: String, _ wait: @MainActor () async -> Void) async -> Void = { _, wait in await wait() }
    init(workspace: WorkspaceStore, live: LiveSessions, work: WorkInFlight, ports: OperatorPorts,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, frame: @escaping @MainActor () -> Frame,
         effects: OperatorInFlight = OperatorInFlight()) {
        self.workspace = workspace; self.live = live; self.work = work; self.ports = ports; self.daemon = daemon; self.frame = frame
        self.effects = effects
        transcripts = TranscriptLocator(home: ports.home, claudeConfig: ports.claudeConfig)
    }
    /// Whether `id`'s workers are at work, asking, paused, stopped or owe a reply. It changes nothing.
    func busy(_ id: UUID) -> Bool {
        guard let task = workspace.state.signalItem(id: id) else { return false }
        // StageRunner saves its intent before prepare/launch. Only a sent launch can be
        // waiting for its first hook; treating the intent as live work would prevent that RPC.
        let launchNotSent = task.signalTask.map {
            $0.phase == .launching && $0.launch?.openedAt == nil && $0.pendingReplies?["main"] == nil
        } ?? false
        let tabs = task.workerTabs(in: live.sessions, now: ports.now()).map {
            launchNotSent && $0.key == nil ? $0.asListed : $0
        }
        // A person's additional tab need not have an Operator tab key. It still owns live work
        // in this task, and must finish before a signal starts, merges or cleans up a stage.
        let anyLiveWork = live.sessions.contains { session in
            session.taskUUID == id && isLiveWork(session)
        }
        return anyLiveWork || workspace.state.operatorSession?.questions.contains { $0.task == id && $0.resolvedAt == nil } == true
            || workspace.state.operatorSession?.pausedWorkers?.contains { $0.task == id } == true
            || (task.signalTask?.phase.isActive == true && !(task.signalTask?.pendingReplies?.isEmpty ?? true))
            || tabs.contains { (task.signalTask?.phase.isActive == true || $0.session?.agent.agentKind != nil) && ($0.isStillAtWork || $0.status == .needsInput) }
            || (task.signalTask?.phase == .working && tabs.contains { $0.session?.stoppedOn != nil })
            || (task.signalTask?.phase == .working && tabs.contains { tab in
                tab.status?.turnEnded == true && replies[id]?[tab.reference.name].map {
                    WorkerTurn.endsWithQuestion($0.text)
                } == true
            })
    }
    private func isLiveWork(_ session: SessionInfo) -> Bool {
        guard !session.isHelper else { return false }
        return session.state == .working || session.state == .needsInput
            || session.work.contains(where: \.holdsTurn) || session.testActivity?.isActive == true
    }
    /// Whether the task's main worker is listed: a live agent in its first tab, not only the placeholder
    /// `workerTab` always gives.
    func hasMainWorker(_ task: TaskItem) -> Bool { task.firstWorker(in: live.sessions) != nil }
    func question(_ id: UUID, tab: String) -> QuestionRounds.Question? {
        guard workspace.state.task(id: id)?.signalTask?.pendingReplies?[tab] == nil, let task = workspace.state.task(id: id), task.signalTask?.phase == .working,
              let worker = task.workerTab(tab, in: live.sessions), worker.status?.turnEnded == true,
              let session = worker.session, session.stoppedOn == nil, let reply = replies[id]?[tab], WorkerTurn.endsWithQuestion(reply.text) else { return nil }
        return .init(session: session.sessionId, tab: tab, text: WorkerTurn.question(reply.text), message: reply.text, conversation: worker.conversation, fingerprint: reply.fingerprint)
    }
    /// A saved intent may already have opened its worker before a reply was lost. A tagged tab
    /// running the planned agent is adopted without repeating its prompt.
    func recoverLaunches() {
        guard enabled(), workspace.canChangeWorkspace else { return }
        for task in workspace.state.tasks {
            guard !effects.holds(task.id), SignalClaim(task) != nil,
                  let record = task.signalTask, let launch = record.launch, launch.workerPending == true,
                  launch.openedAt == nil, record.phase == .launching || record.phase == .blocked,
                  live.sessions.contains(where: { $0.taskUUID == task.id && !$0.isHelper }) else { continue }
            if let worker = task.firstWorker(in: live.sessions), worker.agent.agentKind == task.agent {
                guard let adopted = try? SignalTransitions.apply(.adopted, to: record, at: ports.now()) else { continue }
                workspace.mutate { $0.updateSignalItem(task.id) { value in
                    value.windowId = worker.windowId
                    value.signalTask = adopted
                    if let conversation = worker.conversationId {
                        let saved = TaskConversation(agent: task.agent, id: conversation)
                        if !value.conversations.contains(saved) { value.conversations.insert(saved, at: 0) }
                    }
                } }
            } else if let blocked = try? SignalTransitions.apply(
                .launchFailed("A terminal is already open from an interrupted launch. Inspect it before resuming this stage."), to: record, at: ports.now()) {
                workspace.mutate { $0.updateSignalTask(task.id) { $0 = blocked } }
                onBlocked(task.id)
            }
            workspace.flush()
        }
    }
    /// The tick's worker reads. Unkeyed companion tabs have no transcript the Operator owns, but a task whose live work
    /// the last tick saw and this one does not is woken, so a stage that waited on that work moves on.
    func refreshTurns() async {
        let tasks = workspace.state.tasks.filter { $0.signalTask?.needsWorkerReads == true }
        let ids = Set(tasks.map(\.id))
        let liveWork = Set(live.sessions.filter(isLiveWork).compactMap(\.taskUUID)).intersection(ids)
        let ended = awaitingLiveWork.intersection(ids).subtracting(liveWork)
        awaitingLiveWork = liveWork
        for id in ended { onTurn(id) }
        for task in tasks {
            guard let claim = SignalClaim(task) else { continue }
            let workers = task.workerTabs(in: live.sessions)
            let failedOpening = task.signalTask?.pendingReplies?.contains { key, pending in
                guard ports.now().timeIntervalSince(pending.at) >= OperatorTiming.openingGrace else { return false }
                let worker = workers.first { $0.reference.name == key }
                // A live CLI may legitimately work longer than the opening grace period.
                return worker?.session?.agent.agentKind == nil || worker?.conversation == nil
            } == true
            if failedOpening {
                workspace.mutate { $0.updateSignalTask(task.id) { record in
                    if let next = try? SignalTransitions.apply(.block("Its worker did not start after its saved launch. Inspect its window before resuming."),
                                                               to: record, at: ports.now()) {
                        record = next
                    }
                } }
                replies[task.id] = nil; workspace.flush(); onBlocked(task.id); continue
            }
            for worker in workers {
                guard let session = worker.session, worker.status?.turnEnded == true else { continue }
                if let stopped = session.stoppedOn {
                    workspace.mutate { state in
                        state.updateSignalTask(task.id) { record in
                            if let next = try? SignalTransitions.apply(.block("Its worker " + stopped.reason(now: ports.now()) + "."), to: record, at: ports.now()) {
                                record = next
                            }
                        }
                    }
                    replies[task.id] = nil; workspace.flush(); onBlocked(task.id); break
                }
                guard let conversation = worker.conversation else { continue }
                let locator = transcripts, agent = worker.agent, key = worker.reference.name
                let reply = await BackgroundWork.run { locator.lastReply(agent: agent, conversation: conversation) }
                guard claim.holds(in: workspace.state), workspace.state.task(id: task.id)?.workerTab(key, in: live.sessions)?.conversation == conversation else { continue }
                let pending = workspace.state.task(id: task.id)?.signalTask?.pendingReplies?[key]
                if let pending {
                    if let reply, reply.fingerprint != pending.fingerprint {
                        workspace.mutate { $0.updateSignalTask(task.id) { $0.pendingReplies?[key] = nil } }
                    } else if ports.now().timeIntervalSince(pending.at) >= OperatorTiming.openingGrace {
                        workspace.mutate { $0.updateSignalTask(task.id) { record in
                            if let next = try? SignalTransitions.apply(.block("Its worker has not replied to the saved message. Inspect its window before resuming."),
                                                                       to: record, at: ports.now()) { record = next }
                        } }
                    } else { continue }
                }
                if let reply, replies[task.id]?[key]?.fingerprint != reply.fingerprint {
                    replies[task.id, default: [:]][key] = reply
                    onTurn(task.id)
                }
                if let conversation = session.conversationId {
                    workspace.mutate { $0.updateSignalItem(task.id) { value in
                        if key == "main" { let saved = TaskConversation(agent: worker.agent, id: conversation)
                            if !value.conversations.contains(saved) { value.conversations.insert(saved, at: 0) } }
                        else if let index = value.signalTask?.extraTabs.firstIndex(where: { $0.key == key }) {
                            value.signalTask?.extraTabs[index].conversation = conversation
                        }
                    } }
                }
            }
        }
        replies = replies.filter { ids.contains($0.key) }
    }
    /// Whether the Operator may still act on `task` as it read it: running, and its claim on the task allowed.
    func allows(_ task: TaskItem) -> Bool {
        enabled() && SignalClaim(task)?.allows(in: workspace) == true
    }
    private func require(_ task: TaskItem) throws -> SignalClaim {
        guard allows(task), let claim = SignalClaim(task) else {
            throw ActionUnavailable("The task changed hands or the Operator is paused.")
        }
        return claim
    }
    /// `saving` changes the stage in the same saved change that marks the launch's reply pending.
    func launch(_ task: TaskItem, prompt: String, saving: @escaping (inout SignalTask) -> Void = { _ in }) async throws -> String {
        _ = try require(task)
        guard let daemon = daemon(), task.hasCheckout,
              let token = work.begin(.opening, onTask: task.id) else { throw ActionUnavailable("Its worker cannot open now.") }
        defer { work.end(token) }
        try await checkDelivery(for: task, agent: task.agent)
        let fullPrompt = prompt + (try await additionalContext(task))
        _ = try require(task)
        let previous = task.firstWorker(in: live.sessions)
        // A new window waits for your pause before the worker it replaces closes, so the task is not left without
        // one for as long as you type.
        var waited = opensWindow(task, replacing: previous) ? try await waitForPause(task) : false
        var conversation = task.firstWorkerConversation?.id
        if let previous {
            guard previous.state.turnEnded, let old = previous.conversationId else { throw ActionUnavailable("Wait for this worker to end its turn before continuing it.") }
            conversation = previous.agent.agentKind == task.agent ? old : nil
            try await daemon.setOwnership(sessionId: previous.sessionId, ownership: task.signalTask?.ownership ?? 0)
            _ = try require(task)
            let closed = try await daemon.closeIdle(sessionId: previous.sessionId, ownership: task.signalTask?.ownership ?? 0, conversation: old)
            guard closed.result == .delivered else { throw ActionUnavailable(closed.reason ?? "The worker could not close safely.") }
            _ = try require(task)
        }
        let command = try await command(for: task, prompt: fullPrompt, slot: "main", conversation: conversation)
        _ = try require(task)
        let window = opensWindow(task, replacing: previous) ? nil : task.windowId
        let baseline = await replyBaseline(task, conversation: conversation)
        _ = try require(task)
        if let window {
            try savePending(task, tab: "main", baseline: baseline, saving: saving)
            _ = try require(task)
            let opening = try await daemon.createTab(windowId: window, cwd: task.worktreePath, agentCommand: command, tabKey: nil, background: true, worker: true)
            guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
            return window
        }
        // Again after the daemon's calls, the command and the transcript read, and once more inside the Operator's one
        // window turn (`WindowTurn`), with no await between that look and the window: typing resumed meanwhile, or while
        // another window had the turn, holds this one until your next pause. The pending reply is saved there, after the
        // waits, because one older than the opening grace blocks the task, which then counts from the open.
        let pause = ports.pause
        if try await waitForPause(task) { waited = true }
        while true {
            let restamp = waited
            let opened: String? = try await pause.turn.take {
                guard pause.isQuiet else { return nil }
                // Its turn may come after a pause of the Operator or a Take Over: nothing is saved for a launch it lost.
                _ = try require(task)
                let at = ports.now()
                try savePending(task, tab: "main", baseline: baseline, saving: { record in
                    if restamp { record.launch?.requestedAt = at; record.launch?.workerPending = true }
                    saving(&record)
                })
                let opening = try await daemon.createTaskWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.title,
                                                                agentCommand: command, frame: frame(), background: true, worker: true)
                guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
                return opening.id
            }
            if let opened { return opened }
            if try await waitForPause(task) { waited = true }
        }
    }
    /// Whether launching `task`'s worker opens a window: no live session besides the worker it replaces holds its window
    /// open for a tab. iTerm2 keeps a background tab in an open window unselected and behind; a new window it makes key.
    private func opensWindow(_ task: TaskItem, replacing previous: SessionInfo?) -> Bool {
        guard let window = task.windowId else { return true }
        return !live.sessions.contains { $0.windowId == window && $0.sessionId != previous?.sessionId }
    }
    /// Waits until you have paused (`PauseGate`), then requires the task again; whether it had to wait.
    ///
    /// The stage saved its worker as pending before the launch, for recovery to adopt a worker whose reply was lost.
    /// While it waits no worker is opening, and the one it replaces may still be open: recovery after a quit, a pause
    /// or a Take Over meanwhile would take that one for the new stage's and never send its prompt. So the wait is saved
    /// as not pending first, and the save just before the window opens marks it pending again.
    private func waitForPause(_ task: TaskItem) async throws -> Bool {
        guard !ports.pause.isQuiet else { return false }
        workspace.mutate { $0.updateSignalTask(task.id) { if $0.launch?.openedAt == nil { $0.launch?.workerPending = false } } }
        guard workspace.flush() else { throw ActionUnavailable("The launch couldn’t be saved as waiting for your pause.") }
        let pause = ports.pause
        // A task taken over, or an Operator paused, stops waiting at once: the launch holds the task until it ends.
        await whilePausing("waiting for your pause to open " + OperatorActivityTracker.name(task) + "’s worker") {
            await pause.quiet(while: { [weak self] in self?.allows(task) == true })
        }
        _ = try require(task)
        return true
    }
    private func command(for task: TaskItem, prompt: String, slot: String, conversation: String? = nil) async throws -> String {
        guard task.signalTask?.current.configuration.agents.contains(AgentChoice(agent: task.agent, model: task.model, reasoning: task.reasoning)) == true else {
            throw ActionUnavailable("This agent and model are not permitted by the task's signal.")
        }
        let git = ports.git, home = ports.home, executable = ports.workerGuardExecutable
        let remote = workspace.state.project(id: task.projectId)?.remoteUrl
        return try await BackgroundWork.run {
            try WorkerGuardLaunch.workerCommand(task: task, prompt: prompt, resuming: conversation, slot: slot, remote: remote,
                                                home: home, executable: executable, git: git)
        }
    }
    private func checkDelivery(for task: TaskItem, agent: AgentKind) async throws {
        guard ports.installedAgents().contains(agent), let daemon = daemon() else { throw ActionUnavailable("This worker's CLI is unavailable.") }
        let verdict = try await daemon.deliveryPolicy()[agent], versions = ports.installedVersions
        let installed = await BackgroundWork.run { versions([agent])[agent] }
        _ = try require(task)
        guard verdict?.policy == .auto, DeliveryCheck.covers(checked: verdict?.version, installed: installed) else {
            throw ActionUnavailable("\(agent.displayName) has not passed Messaging for its installed version. Run its check in Settings › Agents.")
        }
    }
    private func markPending(_ task: TaskItem, tab: String, conversation: String?, workRequested: Bool = false,
                             saving: (inout SignalTask) -> Void = { _ in }) async throws {
        let baseline = await replyBaseline(task, conversation: conversation)
        _ = try require(task)
        try savePending(task, tab: tab, baseline: baseline, workRequested: workRequested, saving: saving)
    }
    /// The fingerprint of the conversation's last reply, which the pending reply waits to see change.
    private func replyBaseline(_ task: TaskItem, conversation: String?) async -> String? {
        let locator = transcripts, agent = task.agent
        return await BackgroundWork.run { conversation.flatMap { locator.lastReply(agent: agent, conversation: $0)?.fingerprint } }
    }
    /// Saves the reply as pending, with no await: a launch saves it straight after its last wait for your pause.
    private func savePending(_ task: TaskItem, tab: String, baseline: String?, workRequested: Bool = false,
                             saving: (inout SignalTask) -> Void = { _ in }) throws {
        guard let current = workspace.state.task(id: task.id)?.signalTask else { throw ActionUnavailable("This task has no open worker.") }
        let next = workRequested ? try SignalTransitions.apply(.workRequested, to: current, at: ports.now()) : current
        workspace.mutate { $0.updateSignalTask(task.id) { record in
            record = next
            if record.pendingReplies == nil { record.pendingReplies = [:] }
            record.pendingReplies?[tab] = SignalWorkerReply(at: ports.now(), fingerprint: baseline)
            saving(&record)
        } }
        guard workspace.flush() else { throw ActionUnavailable("The worker message intent could not be saved.") }
    }
    /// `saving` changes the stage in the same saved change that marks the message's reply pending, before it is typed.
    func message(_ task: TaskItem, text: String, tab: String, allowed: @escaping @MainActor () -> Bool,
                 saving: @escaping (inout SignalTask) -> Void = { _ in }) async throws {
        _ = try require(task)
        guard allowed(), !(task.signalTask?.pendingReplies?.keys.contains(tab) ?? false),
              let worker = task.workerTab(tab, in: live.sessions), worker.status?.turnEnded == true,
              let session = worker.session, let daemon = daemon() else { throw ActionUnavailable("This worker is not idle and ready for a message.") }
        try await daemon.setOwnership(sessionId: session.sessionId, ownership: task.signalTask?.ownership ?? 0)
        guard allowed() else { throw ActionUnavailable("The task changed before delivery.") }
        try await markPending(task, tab: tab, conversation: worker.conversation, workRequested: true, saving: saving)
        guard allowed() else { throw ActionUnavailable("The task changed before delivery.") }
        let sent = try await daemon.deliver(sessionId: session.sessionId, text: text, ownership: task.signalTask?.ownership ?? 0, wake: false, worktree: task.worktreePath)
        guard sent.result == .delivered else { throw ActionUnavailable(sent.reason ?? "The message was not delivered.") }
        replies[task.id]?[tab] = nil
    }
    func control(_ task: TaskItem, tab: String, text: String, resuming: Bool) async throws {
        guard enabled(), let claim = SignalClaim(task), claim.holds(in: workspace.state),
              let worker = task.workerTab(tab, in: live.sessions), worker.status != .needsInput,
              let session = worker.session, let daemon = daemon() else { throw ActionUnavailable("This worker cannot receive a note.") }
        try await daemon.setOwnership(sessionId: session.sessionId, ownership: claim.ownership)
        guard enabled(), claim.holds(in: workspace.state) else { throw ActionUnavailable("The task changed.") }
        if resuming { try await markPending(task, tab: tab, conversation: worker.conversation) }
        let sent = try await daemon.deliver(sessionId: session.sessionId, text: text, ownership: claim.ownership, wake: false, worktree: task.worktreePath)
        guard sent.result == .delivered else { throw ActionUnavailable(sent.reason ?? "The note was not delivered.") }
        if resuming { replies[task.id]?[tab] = nil }
    }
    func read(_ task: TaskItem) async throws -> JSONValue {
        let locator = transcripts, tabs = task.workerTabs(in: live.sessions), snapshot = task
        return await BackgroundWork.run {
            var workers: [JSONValue] = []
            for tab in tabs {
                let text = tab.conversation.flatMap { locator.lastMessage(agent: tab.agent, conversation: $0) }
                workers.append(["tab": .string(tab.reference.name), "session": tab.session.map { .string($0.sessionId) } ?? .null,
                                "state": tab.status.map { .string($0.rawValue) } ?? .null, "lastMessage": text.map(JSONValue.string) ?? .null])
            }
            return ["workers": .array(workers), "savedPrompt": snapshot.signalTask?.current.prompt.map(JSONValue.string) ?? .null]
        }
    }
    func openTab(_ task: TaskItem, key: String, choice: AgentChoice, prompt: String, why: String,
                 allowed: @escaping @MainActor () -> Bool) async throws -> JSONValue {
        _ = try require(task)
        guard allowed(), !key.isEmpty, key != "main", let window = task.windowId, task.hasCheckout,
              let daemon = daemon() else { throw ActionUnavailable("This task has no open window for a work tab.") }
        if let old = workspace.state.task(id: task.id)?.signalTask?.extraTabs.first(where: { $0.key == key }) {
            guard old.agent == choice.agent, old.model == choice.model, old.reasoning == choice.reasoning,
                  old.brief == prompt, old.modelReason == why else { throw ActionUnavailable("That tab key names another launch.") }
            if let session = old.sessionId { return ["status": "opened", "session": .string(session), "tab": .string(key)] }
        }
        guard let token = work.begin(.reviewing, onTask: task.id) else { throw ActionUnavailable("This task is busy.") }
        defer { work.end(token) }
        if workspace.state.task(id: task.id)?.signalTask?.extraTabs.contains(where: { $0.key == key }) != true {
            let extra = ExtraTab(key: key, agent: choice.agent, model: choice.model, reasoning: choice.reasoning,
                modelReason: why, brief: prompt, launch: LaunchAttempt(number: 1, requestedAt: ports.now()))
            workspace.mutate { $0.updateSignalTask(task.id) { $0.extraTabs.append(extra) } }
            guard workspace.flush() else { throw ActionUnavailable("The work-tab intent could not be saved.") }
        }
        try await checkDelivery(for: task, agent: choice.agent)
        var launched = task; launched.agent = choice.agent; launched.model = choice.model; launched.reasoning = choice.reasoning
        let command = try await command(for: launched, prompt: WorkerPrompt.worktreeLine(branch: task.branch) + "\n\n" + prompt, slot: key)
        _ = try require(task)
        guard allowed() else { throw ActionUnavailable("The task changed before its work tab opened.") }
        try await markPending(launched, tab: key, conversation: nil, workRequested: true)
        guard allowed() else { throw ActionUnavailable("The task changed before its work tab opened.") }
        let opening = try await daemon.createTab(windowId: window, cwd: task.worktreePath, agentCommand: command, tabKey: key, background: true, worker: true)
        guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
        let session = opening.id
        _ = try require(task)
        workspace.mutate { $0.updateSignalTask(task.id) { record in
            if let index = record.extraTabs.firstIndex(where: { $0.key == key }) {
                record.extraTabs[index].sessionId = session; record.extraTabs[index].launch.openedAt = ports.now()
            }
        } }
        guard workspace.flush() else { throw ActionUnavailable("The work tab opened but its result could not be saved. Inspect its window.") }
        return ["status": "opened", "session": .string(session), "tab": .string(key)]
    }
}
