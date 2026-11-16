import Foundation
import AiTermCore

/// Native worker effects. Every await is followed by the saved stage's authority check; a
/// daemon delivery independently checks the live process, prompt and ownership.
@MainActor final class SignalWorkerIO {
    let workspace: WorkspaceStore, live: LiveSessions, work: WorkInFlight, ports: OperatorPorts
    let daemon: @MainActor () -> (any DaemonCommands)?
    let frame: @MainActor () -> Frame
    let transcripts: TranscriptLocator
    private(set) var inFlight: Set<UUID> = []
    private(set) var replies: [UUID: [String: WorkerTranscript.Reply]] = [:]
    private var reading = false
    private var awaitingLiveWork: Set<UUID> = []
    var enabled: @MainActor () -> Bool = { true }
    var additionalContext: @MainActor (TaskItem) async throws -> String = { _ in "" }
    var recoveryAllowed: @MainActor (UUID) -> Bool = { _ in true }
    var onBlocked: @MainActor (UUID) -> Void = { _ in }
    var onTurn: (UUID) -> Void = { _ in }
    /// Journals a fallback row's launch-time agent switch for `run_status` and the person.
    var recordSwitch: @MainActor (UUID, AgentChoice) async throws -> Void = { _, _ in }
    var connections: @MainActor () async -> SignalConnections = { SignalConnections() }
    init(workspace: WorkspaceStore, live: LiveSessions, work: WorkInFlight, ports: OperatorPorts,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, frame: @escaping @MainActor () -> Frame) {
        self.workspace = workspace; self.live = live; self.work = work; self.ports = ports; self.daemon = daemon; self.frame = frame
        transcripts = TranscriptLocator(home: ports.home, claudeConfig: ports.claudeConfig)
    }
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
        if anyLiveWork { awaitingLiveWork.insert(id) }
        return anyLiveWork || workspace.state.operatorSession?.questions.contains { $0.task == id && $0.resolvedAt == nil } == true
            || workspace.state.operatorSession?.pausedWorkers?.contains { $0.task == id } == true
            || inFlight.contains(id) || (task.signalTask?.phase.isActive == true && !(task.signalTask?.pendingReplies?.isEmpty ?? true))
            || tabs.contains { (task.signalTask?.phase.isActive == true || $0.session?.agent.agentKind != nil) && ($0.isStillAtWork || $0.status == .needsInput) }
            || (task.signalTask?.phase == .working && tabs.contains { $0.session?.stoppedOn != nil })
            || (task.signalTask?.phase == .working && tabs.contains { tab in
                tab.status?.turnEnded == true && replies[id]?[tab.reference.name].map {
                    WorkerTurn.ending(lastMessage: $0.text, commitsAhead: nil) == .asks
                } == true
            })
    }
    private func isLiveWork(_ session: SessionInfo) -> Bool {
        session.state == .working || session.state == .needsInput
            || !session.background.isEmpty || session.testActivity?.isActive == true
    }
    func question(_ id: UUID, tab: String) -> QuestionRounds.Question? {
        guard !inFlight.contains(id), workspace.state.task(id: id)?.signalTask?.pendingReplies?[tab] == nil, let task = workspace.state.task(id: id), task.signalTask?.phase == .working,
              let worker = task.workerTab(tab, in: live.sessions), worker.status?.turnEnded == true,
              let session = worker.session, session.stoppedOn == nil, let reply = replies[id]?[tab], WorkerTurn.ending(lastMessage: reply.text, commitsAhead: nil) == .asks else { return nil }
        return .init(session: session.sessionId, tab: tab, text: WorkerTurn.question(reply.text), message: reply.text, conversation: worker.conversation, fingerprint: reply.fingerprint)
    }
    /// A saved intent may already have opened its worker before a reply was lost. Its private
    /// launch scope binds the observed process to this stage; observing it never repeats work.
    func recoverLaunches() async {
        guard enabled(), workspace.canChangeWorkspace else { return }
        for task in workspace.state.tasks {
            guard recoveryAllowed(task.id), !inFlight.contains(task.id), let claim = SignalClaim(task),
                  let record = task.signalTask, let launch = record.launch, launch.workerPending == true,
                  launch.openedAt == nil, record.phase == .launching || record.phase == .blocked,
                  live.sessions.contains(where: { $0.taskUUID == task.id }) else { continue }
            let home = ports.home, id = task.id
            let scope = await BackgroundWork.run { WorkerGuardLaunch.recordedScope(task: id, home: home) }
            guard enabled(), recoveryAllowed(task.id), claim.holds(in: workspace.state), !Task.isCancelled else { continue }
            if let worker = task.firstWorker(in: live.sessions), worker.agent.agentKind == task.agent,
               scope?.task == task.id, scope?.ownership == record.ownership, scope?.stage == record.stage,
               scope?.worktree == task.worktreePath, scope?.branch == task.branch {
                workspace.mutate { $0.updateSignalItem(task.id) { value in
                    value.windowId = worker.windowId
                    value.signalTask?.edges.append(SignalEdge(from: record.phase, to: .working, stage: record.stage, at: ports.now()))
                    value.signalTask?.phase = .working; value.signalTask?.launch?.openedAt = ports.now()
                    value.signalTask?.launch?.workerPending = false; value.signalTask?.currentAct = nil; value.signalTask?.blockedReason = nil
                    if let conversation = worker.conversationId {
                        let saved = TaskConversation(agent: task.agent, id: conversation)
                        if !value.conversations.contains(saved) { value.conversations.insert(saved, at: 0) }
                    }
                } }
            } else if record.phase != .blocked {
                workspace.mutate { $0.updateSignalTask(task.id) {
                    $0.phase = .blocked; $0.currentAct = nil
                    $0.blockedReason = "A terminal is already open from an interrupted launch. Inspect it before resuming this stage."
                } }
                onBlocked(task.id)
            }
            workspace.flush()
        }
    }
    func refreshTurns() async {
        guard !reading else { return }; reading = true; defer { reading = false }
        let tasks = workspace.state.tasks.filter { $0.signalTask?.needsWorkerReads == true }
        let ids = Set(tasks.map(\.id))
        let liveWork = Set(live.sessions.filter(isLiveWork).compactMap(\.taskUUID))
        // Include work observed by a refused action between ticks. Unkeyed companion tabs do
        // not have transcripts owned by the Operator, but ending their work must release its wait.
        let ended = awaitingLiveWork.intersection(ids).subtracting(liveWork)
        awaitingLiveWork = awaitingLiveWork.union(liveWork).intersection(ids).subtracting(ended)
        for id in ended { onTurn(id) }
        for task in tasks {
            guard let claim = SignalClaim(task) else { continue }
            let workers = task.workerTabs(in: live.sessions)
            let failedOpening = task.signalTask?.pendingReplies?.contains { key, pending in
                guard ports.now().timeIntervalSince(pending.at) >= 180 else { return false }
                let worker = workers.first { $0.reference.name == key }
                // A live CLI may legitimately work longer than the opening grace period.
                return worker?.session?.agent.agentKind == nil || worker?.conversation == nil
            } == true
            if failedOpening {
                workspace.mutate { $0.updateSignalTask(task.id) {
                    $0.phase = .blocked; $0.currentAct = nil
                    $0.blockedReason = "Its worker did not start after its saved launch. Inspect its window before resuming."
                } }
                replies[task.id] = nil; workspace.flush(); onBlocked(task.id); continue
            }
            for worker in workers {
                guard let session = worker.session, worker.status?.turnEnded == true else { continue }
                if let stopped = session.stoppedOn {
                    workspace.mutate { state in
                        state.updateSignalTask(task.id) { record in
                            if let next = try? SignalTransitions.apply(.block("Its worker " + stopped.reason(now: ports.now()) + "."), to: record, at: ports.now()) {
                                record = next; record.currentAct = nil
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
                    } else if ports.now().timeIntervalSince(pending.at) >= 180 {
                        workspace.mutate { $0.updateSignalTask(task.id) {
                            $0.phase = .blocked; $0.blockedReason = "Its worker has not replied to the saved message. Inspect its window before resuming."
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
    private func require(_ task: TaskItem) throws -> SignalClaim {
        guard enabled(), workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true,
              let claim = SignalClaim(task), claim.canAct(in: workspace.state), !Task.isCancelled else {
            throw ActionUnavailable("The task changed hands or the Operator is paused.")
        }
        return claim
    }
    func prepare(_ task: TaskItem, signal: Signal) async throws -> TaskItem {
        let claim = try require(task)
        guard let project = workspace.state.project(id: task.projectId), let token = work.begin(.opening, onTask: task.id),
              let projectToken = work.begin(.openingTaskWindow, onProject: project.id) else { throw ActionUnavailable("This task's project is busy.") }
        defer { work.end(token); work.end(projectToken) }
        let result: TaskItem
        if task.mr != nil {
            let links = await connections(); _ = try require(task)
            let host = try MergeRequestSearch.signalSource(for: ProviderDetector.detect(remoteUrl: project.remoteUrl), gitLab: links.gitLab, gitHub: links.gitHub, session: links.session)
            guard let request = try await host.existingRequest(from: task.branch), request.forkHead == nil else {
                throw ActionUnavailable("The request's source branch is unavailable in this repository. Open it yourself to choose its checkout.")
            }
            _ = try require(task)
            let git = ports.git, reserved = workspace.state.reservedWorktreeSlugs(projectId: project.id)
            result = try await BackgroundWork.run(on: GitLanes.shared.lane(for: project.path)) {
                var draft = ReviewDraft(mr: nil, agent: task.agent, model: task.model, reasoning: task.reasoning)
                draft.apply(mr: request); draft.setTitle(task.title)
                let made = try TaskCreator.createReview(draft: draft, project: project, reserved: reserved, git: git)
                var value = task; value.worktreePath = made.task.worktreePath; return value
            }
        } else {
            let git = ports.git
            let start = await BackgroundWork.run { Repository(project.path, git: git).defaultBranch() }
            _ = try require(task)
            result = try await TaskWorkflow(git: git).checkOutWorker(task, project: project, start: start,
                                                                  reserved: workspace.state.reservedWorktreeSlugs(projectId: project.id)).made.task
        }
        // A checkout made before Take Over remains a resource of the same task, even when the
        // late completion has no authority to launch a CLI in it.
        if (!enabled() || !claim.canAct(in: workspace.state)), let current = workspace.state.task(id: task.id), current.projectId == task.projectId,
           current.branch == task.branch, !current.hasCheckout {
            workspace.mutate { $0.updateSignalItem(task.id) { $0.worktreePath = result.worktreePath; $0.baseBranch = result.baseBranch } }
            workspace.flush()
        }
        _ = try require(task); return result
    }
    func restore(_ task: TaskItem) async throws -> TaskItem {
        _ = try require(task)
        guard let project = workspace.state.project(id: task.projectId), let token = work.begin(.restoring, onTask: task.id) else { throw ActionUnavailable("The task is busy.") }
        defer { work.end(token) }
        let value = try await TaskWorkflow(git: ports.git).restore(task, project: project).task
        _ = try require(task); return value
    }
    func launch(_ initial: TaskItem, prompt: String) async throws -> String {
        _ = try require(initial)
        var task = initial
        // A row the Operator chose (with weekly usage in hand) launches as chosen. Only the row a
        // three-round disagreement fell back to still moves off an agent at its weekly limit.
        if task.firstWorkerConversation == nil, (task.signalTask?.launch?.number ?? 1) == 1,
           task.signalTask?.choice?.decided == .disagreed, let configuration = task.signalTask?.configuration {
            let planned = AgentChoice(agent: task.agent, model: task.model, reasoning: task.reasoning)
            let choice = ModelChoice.launchChoice(planned: planned, pinned: false,
                weekly: SidebarModel.weeklyUsage(live.usage, now: ports.now()), installed: ports.installedAgents(), rows: configuration.agents)
            if choice != planned {
                workspace.mutate { $0.updateSignalItem(task.id) {
                    $0.agent = choice.agent; $0.model = choice.model; $0.reasoning = choice.reasoning
                    $0.signalTask?.choice?.launchSwitch = choice
                } }
                guard workspace.flush() else { throw ActionUnavailable("The worker choice could not be saved.") }
                // Journaled as it is made, so a launch that fails or is recovered later cannot lose it.
                try await recordSwitch(task.id, choice)
                guard let current = workspace.state.task(id: task.id) else { throw ActionUnavailable("The task changed while its switch was journaled.") }
                _ = try require(current); task = current
            }
        }
        guard !inFlight.contains(task.id), let daemon = daemon(), task.hasCheckout,
              let token = work.begin(.opening, onTask: task.id) else { throw ActionUnavailable("Its worker cannot open now.") }
        inFlight.insert(task.id); defer { inFlight.remove(task.id); work.end(token) }
        try await checkDelivery(for: task, agent: task.agent)
        let fullPrompt = prompt + (try await additionalContext(task))
        _ = try require(task)
        let previous = task.firstWorker(in: live.sessions)
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
        try await markPending(task, tab: "main", conversation: conversation)
        _ = try require(task)
        let opening: WorkerOpening
        if let window = task.windowId, live.sessions.contains(where: { $0.windowId == window && $0.sessionId != previous?.sessionId }) {
            opening = try await daemon.openWorkerTab(windowId: window, cwd: task.worktreePath, agentCommand: command)
            guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
            return window
        }
        opening = try await daemon.openWorkerWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.title, agentCommand: command, frame: frame())
        guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
        return opening.id
    }
    private func command(for task: TaskItem, prompt: String, slot: String, conversation: String? = nil) async throws -> String {
        guard let record = task.signalTask, let configuration = record.configuration ?? workspace.state.signal(id: record.signal),
              (record.takenOver || configuration.agents.contains(AgentChoice(agent: task.agent, model: task.model, reasoning: task.reasoning))) else {
            throw ActionUnavailable("This agent and model are not permitted by the task's signal.")
        }
        let git = ports.git, home = ports.home, executable = ports.workerGuardExecutable
        let remote = workspace.state.project(id: task.projectId)?.remoteUrl
        return try await BackgroundWork.run {
            let command = try AgentCommand.build(agent: task.agent, model: task.model, reasoning: task.reasoning, prompt: prompt,
                worktreePath: task.worktreePath, git: git, operated: !record.takenOver, promptFile: "signal-" + UUID().uuidString + ".md",
                publishing: true, resuming: conversation)
            return try WorkerGuardLaunch.command(command, task: task, remote: remote, home: home,
                executable: executable, git: git, slot: slot, publishes: task.kind != .review)
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
    private func markPending(_ task: TaskItem, tab: String, conversation: String?, workRequested: Bool = false) async throws {
        let locator = transcripts, agent = task.agent
        let baseline = await BackgroundWork.run { conversation.flatMap { locator.lastReply(agent: agent, conversation: $0)?.fingerprint } }
        _ = try require(task)
        guard let current = workspace.state.task(id: task.id)?.signalTask else { throw ActionUnavailable("This task has no open worker.") }
        let next = workRequested ? try SignalTransitions.apply(.workRequested, to: current, at: ports.now()) : current
        workspace.mutate { $0.updateSignalTask(task.id) { record in
            record = next
            if record.pendingReplies == nil { record.pendingReplies = [:] }
            record.pendingReplies?[tab] = SignalWorkerReply(at: ports.now(), fingerprint: baseline)
        } }
        guard workspace.flush() else { throw ActionUnavailable("The worker message intent could not be saved.") }
    }
    func message(_ task: TaskItem, text: String, tab: String, allowed: @escaping @MainActor () -> Bool) async throws {
        _ = try require(task)
        guard allowed(), !inFlight.contains(task.id), !(task.signalTask?.pendingReplies?.keys.contains(tab) ?? false),
              let worker = task.workerTab(tab, in: live.sessions), worker.status?.turnEnded == true,
              let session = worker.session, let daemon = daemon() else { throw ActionUnavailable("This worker is not idle and ready for a message.") }
        inFlight.insert(task.id); defer { inFlight.remove(task.id) }
        try await daemon.setOwnership(sessionId: session.sessionId, ownership: task.signalTask?.ownership ?? 0)
        guard allowed() else { throw ActionUnavailable("The task changed before delivery.") }
        try await markPending(task, tab: tab, conversation: worker.conversation, workRequested: true)
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
            return ["workers": .array(workers), "savedPrompt": snapshot.signalTask?.prompt.map(JSONValue.string) ?? .null]
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
        guard !inFlight.contains(task.id), let token = work.begin(.reviewing, onTask: task.id) else { throw ActionUnavailable("This task is busy.") }
        inFlight.insert(task.id); defer { inFlight.remove(task.id); work.end(token) }
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
        let session = try await daemon.createTab(windowId: window, cwd: task.worktreePath, agentCommand: command, tabKey: key, background: true)
        _ = try require(task)
        workspace.mutate { $0.updateSignalTask(task.id) { record in
            if let index = record.extraTabs.firstIndex(where: { $0.key == key }) {
                record.extraTabs[index].sessionId = session; record.extraTabs[index].launch.openedAt = ports.now()
            }
        } }
        guard workspace.flush() else { throw ActionUnavailable("The work tab opened but its result could not be saved. Inspect its window.") }
        return ["status": "opened", "session": .string(session), "tab": .string(key)]
    }
    /// A person's click resumes the conversation without sending a new work instruction.
    func reopen(_ task: TaskItem) async throws {
        func valid() -> Bool {
            enabled() && workspace.canChangeWorkspace && !Task.isCancelled && workspace.state.task(id: task.id)?.signalTask?.ownership == task.signalTask?.ownership
                && workspace.state.task(id: task.id)?.worktreePath == task.worktreePath
        }
        guard valid() else { throw ActionUnavailable("This task changed.") }
        guard let daemon = daemon(), task.hasCheckout, let conversation = task.firstWorkerConversation?.id,
              let token = work.begin(.reopening, onTask: task.id) else { throw ActionUnavailable("Its worker has no saved conversation to reopen.") }
        defer { work.end(token) }
        if let existing = task.firstWorker(in: live.sessions) {
            try await daemon.activate(sessionId: existing.sessionId); return
        }
        let command = try await command(for: task, prompt: "", slot: "main", conversation: conversation)
        guard valid() else { throw ActionUnavailable("This task changed.") }
        let opening = try await daemon.openWorkerWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.title,
                                                       agentCommand: command, frame: frame())
        guard valid() else { throw ActionUnavailable("This task changed.") }
        guard opening.commandError == nil else { throw ActionUnavailable(opening.commandError!) }
        workspace.mutate { $0.updateSignalItem(task.id) { $0.windowId = opening.id } }; workspace.flush()
    }
}
