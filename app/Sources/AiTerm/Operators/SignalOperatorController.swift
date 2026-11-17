import Foundation
import Observation
import AiTermCore

/// The Operator, composed for AppController: it builds the Signal owners and the one Operator chat,
/// wires them, routes daemon events and Operator requests to them, and runs one ordered reconcile: the
/// Operator's tick, each minute and on the events that call it, whose steps each run when they are due.
@Observable @MainActor final class SignalOperatorController {
    let workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts
    let daemon: @MainActor () -> (any DaemonCommands)?
    let frame: @MainActor () -> Frame
    let automatic: Bool
    let activity: OperatorActivityTracker
    /// The activity log and the Operator's issues.
    let log: ActivityWriter
    let native: SignalWorkerIO, host: SignalHostIO, journal: SignalJournal, poller: SignalPoller
    /// The tasks an Operator effect runs on, one effect per task, shared by every owner that acts on a task.
    let effects: OperatorInFlight
    var tabsKnown = false
    private(set) var profile = OperatorProfile(model: "", reasoning: nil)
    /// What the Operator row shows as "needs you": an issue that needs the person, then the session's own.
    var statusIssue: String? {
        guard !isStopped else { return nil }
        return log.issues.attention?.sentence ?? chat.sessionIssue
    }
    @ObservationIgnored private(set) var isStopped = true
    @ObservationIgnored var readConnections: @Sendable () -> SignalConnections = { SignalConnections() }
    @ObservationIgnored var sourceRegistrations: (@MainActor ([Signal]) async -> [SignalPoller.Registration])?
    @ObservationIgnored var archive: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> Void = { _, _ in throw ActionUnavailable("Archive is unavailable.") }
    @ObservationIgnored var remove: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> Void = { _, _ in throw ActionUnavailable("Remove is unavailable.") }
    /// An archived task's worktree recreated and its row back in the sidebar: the app's restore.
    @ObservationIgnored var restore: @MainActor (UUID) async throws -> TaskItem = { _ in throw ActionUnavailable("Restore is unavailable.") }
    /// A task's worker checkout, saved on the task, refused once the second argument says no: the app's.
    @ObservationIgnored var checkout: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> TaskItem = { _, _ in throw ActionUnavailable("Checkout is unavailable.") }
    @ObservationIgnored private var loop: PollLoop?
    @ObservationIgnored private var configuration = UUID()
    @ObservationIgnored private var lastSignals: [Signal] = []
    @ObservationIgnored private var registrationKeys: [String] = []
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var hostDue = Date.distantPast
    /// The host watch's pass still running; the next starts only once it ended.
    @ObservationIgnored private var hostPass: Task<Void, Never>?
    @ObservationIgnored private var settingsDue = Date.distantPast
    @ObservationIgnored private var activeTools = 0
    @ObservationIgnored private var hooks: [() -> Void] = []
    @ObservationIgnored private var savedObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastNote: OperatorNote?
    @ObservationIgnored lazy var oracle: OracleConsult = makeOracle()
    private func makeOracle() -> OracleConsult {
        OracleConsult(workspace: workspace, folder: OperatorLaunch.folder(home: ports.home), activity: activity, now: ports.now, ports: .init(
            settings: { [weak self] in
                self?.oracleSettings ?? .init(oracle: OracleSetting(isOn: false, agent: .codex, model: "", reasoning: nil), instructions: "", revision: 0)
            }, ask: { [weak self] setting, prompt in
                guard let self else { return .unanswered("The Operator stopped.") }
                return await self.ports.oracle.ask(setting, prompt: prompt, folder: OperatorLaunch.folder(home: self.ports.home),
                                                   projects: self.workspace.state.projects.map(\.path))
            }, running: { [weak self] in self?.isStopped == false }))
    }
    @ObservationIgnored lazy var chat: OperatorChat = OperatorChat(workspace: workspace, live: live, ports: ports, daemon: daemon, frame: frame,
        activity: activity, log: log, context: .init(running: { [weak self] in self?.isStopped == false },
            tabsKnown: { [weak self] in self?.tabsKnown == true },
            profile: { [weak self] in self?.profile ?? OperatorProfile(model: "", reasoning: nil) },
            instructions: { [weak self] in self?.currentInstructions }, oracleOn: { [weak self] in self?.oracle.isOn == true },
            wakeToType: { [weak self] in self?.waker.unread == true }))
    @ObservationIgnored lazy var waker: OperatorWaker = OperatorWaker(workspace: workspace, daemon: daemon, activity: activity, log: log,
        tab: { [weak self] in self?.chat.operatorTab() }, running: { [weak self] in self?.isStopped == false })
    @ObservationIgnored lazy var pause = SignalPauseSignaller(workspace: workspace, live: live, native: native,
        enabled: { [weak self] in self?.isStopped == false }, now: ports.now)
    @ObservationIgnored lazy var router = ItemRouter(workspace: workspace, now: ports.now,
        workerIsWorking: { [native, effects] id in native.busy(id) || effects.holds(id) })
    @ObservationIgnored lazy var stages = StageRunner(workspace: workspace, journal: journal, now: ports.now,
        ports: .init(workerIsWorking: native.busy, prepare: { [weak self] task, signal in
            guard let self else { throw ActionUnavailable("The Operator stopped.") }
            return try await self.activity.during("preparing " + OperatorActivityTracker.name(task) + "’s worker") {
                let allowed: @MainActor () -> Bool = { [weak self] in self?.native.allows(task) == true }
                guard allowed() else { throw ActionUnavailable("The task changed hands or the Operator is paused.") }
                return try await self.checkout(task, allowed)
            }
        }, launch: { [weak self] task, prompt in
            guard let self else { throw ActionUnavailable("The Operator stopped.") }
            return try await self.activity.during("starting " + OperatorActivityTracker.name(task) + "’s worker") { try await self.native.launch(task, prompt: prompt) }
        }, restore: { [weak self] task in
            guard let self else { throw ActionUnavailable("The Operator stopped.") }
            return try await self.activity.during("restoring " + OperatorActivityTracker.name(task) + "’s checkout") {
                guard self.native.allows(task) else { throw ActionUnavailable("The task changed hands or the Operator is paused.") }
                return try await self.restore(task.id)
            }
        }), effects: effects)
    @ObservationIgnored lazy var then = ThenRunner(workspace: workspace, journal: journal, stages: stages, now: ports.now,
        ports: .init(workerIsWorking: native.busy, archive: { [weak self] task, allowed in
            guard let self else { return }
            try await self.activity.during("archiving " + OperatorActivityTracker.name(task)) { try await self.archive(task, allowed) }
        }, remove: { [weak self] task, allowed in
            guard let self else { return }
            try await self.activity.during("removing " + OperatorActivityTracker.name(task)) {
                try await self.remove(task, allowed); await self.host.deleteMergedBranch(of: task)
            }
        }), effects: effects)
    @ObservationIgnored lazy var watch = RequestWatch(workspace: workspace, stages: stages, then: then,
        ports: .init(workerIsWorking: native.busy, read: { [weak self] task in
            guard let self else { throw ActionUnavailable("The Operator stopped.") }
            return try await self.activity.during("checking " + OperatorActivityTracker.name(task) + "’s completion") { try await self.host.read(task) }
        }, oracleMerge: { [weak self] task, snapshot in
            guard let self else { return false }
            let status = OperatorDigest(state: self.workspace.state, at: self.ports.now(), oracleOn: true, task: task.id)
            if case .agreed = await self.oracle.consult(.mergeVeto(head: snapshot.head, status: status), binding: .init(claim: SignalClaim(task))) { return true }
            return false
        }, merge: { [weak self] task, snapshot in
            guard let self else { throw ActionUnavailable("The Operator stopped.") }
            try await self.activity.during("merging " + OperatorActivityTracker.name(task)) { try await self.host.merge(task, snapshot: snapshot) }
        }), effects: effects)
    @ObservationIgnored lazy var questions = QuestionRounds(workspace: workspace, journal: journal, now: ports.now, oracle: oracle,
        ports: .init(question: native.question, deliver: { [weak self] task, question, text in
                guard let self, let claim = SignalClaim(task) else { throw ActionUnavailable("The Operator stopped.") }
                try await self.native.message(task, text: text, tab: question.tab, allowed: {
                    !self.isStopped && claim.holds(in: self.workspace.state)
                })
            }), effects: effects)
    @ObservationIgnored lazy var choices = AgentChoiceRounds(workspace: workspace, now: ports.now, oracle: oracle, ports: .init(
        weeklyUsage: { [weak self] in self.map { SidebarModel.weeklyUsage($0.live.usage, now: $0.ports.now()) } ?? [:] },
        installedAgents: { [weak self] in self?.ports.installedAgents() ?? [] }), effects: effects)
    @ObservationIgnored lazy var tools: SignalOperatorToolHandler = makeTools()
    private func makeTools() -> SignalOperatorToolHandler {
        return SignalOperatorToolHandler(workspace: workspace, stages: stages, questions: questions, choices: choices,
        journal: journal, now: ports.now, ports: .init(oracleEnabled: { [weak self] in self?.oracle.isOn == true },
            workerQuestion: { [weak self] id, tab in self?.native.question(id, tab: tab) != nil },
            read: { [weak self] task in
                guard let self else { throw ActionUnavailable("The Operator stopped.") }
                let workers = try await self.native.read(task)
                let source: JSONValue
                do { source = try await self.host.details(task) }
                catch { source = ["sourceError": .string(OperationIssue.reason(of: error))] }
                return ["workers": workers, "source": source]
            }, message: { [weak self] task, text, tab, allowed in
                guard let self else { throw ActionUnavailable("The Operator stopped.") }
                try await self.native.message(task, text: text, tab: tab, allowed: allowed)
            }, openTab: { [weak self] task, key, choice, prompt, why, allowed in
                guard let self else { throw ActionUnavailable("The Operator stopped.") }
                return try await self.native.openTab(task, key: key, choice: choice, prompt: prompt, why: why, allowed: allowed)
            }, jiraSearch: { [weak self] query in
                guard let self else { throw ActionUnavailable("The Operator stopped.") }
                let links = await self.connections()
                let read = try await links.reader(for: .jira(JiraConditions(jql: query))).poll(since: nil, full: true)
                guard read.complete else { throw IncompleteRead("Jira search") }
                return .array(read.items.map { ["title": .string($0.title), "description": $0.description.map(JSONValue.string) ?? .null,
                                               "item": (try? JSONValue(encoding: $0.item)) ?? .null] })
            }, consult: { [weak self] task, question in
                guard let self else { return .unavailable(.off) }
                return await self.oracle.consult(question, binding: .init(claim: task.flatMap(SignalClaim.init)))
            }, actionsAllowed: { [weak self] in self?.isStopped == false },
            sessions: { [weak self] in self?.live.sessions ?? [] }, instructions: { [weak self] in self?.currentInstructions }, usage: { [weak self] in self?.live.usage ?? .empty },
            installedAgents: { [weak self] in self?.ports.installedAgents() ?? [] },
            issues: { [weak self] in self?.log.issues.current ?? [] }), effects: effects)
    }
    @ObservationIgnored lazy var gate = SignalShellGate(workspace: workspace, folder: OperatorLaunch.folder(home: ports.home),
        now: ports.now, validate: { [weak self] request in
            guard let self, !self.isStopped else { throw ActionUnavailable("The Operator stopped.") }
            try self.tools.requireSession(request, mutating: true)
        }, consult: { [weak self] question in
            guard let self else { return .unavailable(.off) }
            return await self.oracle.consult(question, binding: .none)
        })
    init(workspace: WorkspaceStore, live: LiveSessions, work: WorkInFlight, ports: OperatorPorts,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, frame: @escaping @MainActor () -> Frame, automatic: Bool = true) {
        self.workspace = workspace; self.live = live; self.ports = ports; self.daemon = daemon; self.frame = frame; self.automatic = automatic
        let activity = OperatorActivityTracker(); self.activity = activity
        let effects = OperatorInFlight(); self.effects = effects
        log = ActivityWriter(folder: OperatorLaunch.folder(home: ports.home), work: ports.work, now: ports.now, activity: activity)
        native = SignalWorkerIO(workspace: workspace, live: live, work: work, ports: ports, daemon: daemon, frame: frame, effects: effects)
        host = SignalHostIO(workspace: workspace, git: ports.git, connections: { SignalConnections() })
        journal = SignalJournal(workspace: workspace, folder: OperatorLaunch.folder(home: ports.home).appendingPathComponent("journals"), now: ports.now)
        poller = SignalPoller(work: ports.work, now: ports.now)
        poller.canPoll = { [weak self] in
            self.map { !$0.isStopped && $0.workspace.canChangeWorkspace && $0.workspace.state.operatorSession?.paused != true } ?? false
        }
        native.enabled = { [weak self] in self?.isStopped == false }
        native.additionalContext = { [weak self] task in try await self?.host.additionalContext(task) ?? "" }
        host.connections = { [weak self] in await self?.connections() ?? SignalConnections() }
        host.now = ports.now
        host.enabled = { [weak self] in self?.isStopped == false }
        native.onBlocked = { [weak self] id in self?.waker.wake(.taskBlocked, id: id) }
        native.onTurn = { [weak self] id in self?.waker.wake(.workerEnded, id: id) }
        activity.changed = { [weak self] in self?.reconcileIfIdle(); self?.changed() }
        log.enabled = { [weak self] in self?.isStopped == false }
        log.changed = { [weak self] in self?.changed() }
        chat.finished = { [weak self] in
            guard let self else { return }
            self.waker.reset()
            // These failures belonged to the retired chat. Other sources still clear only on
            // their own next success.
            self.log.succeed(.wake); self.log.succeed(.reply)
            self.activity.pulse()
        }
        native.recordSwitch = { [weak self] id, row in try await self?.journal.append(.ours(AgentChoiceRecord.switchLine(row)), task: id) }
        router.changed = { [weak self] id, event in
            guard let self else { return }
            self.log.record(tool: "signal_match", task: self.workspace.state.signalItem(id: id)?.id,
                            arguments: ["owner": .string(id.uuidString)], outcome: .ok, result: event, line: event)
            self.waker.wakeIfWaiting(id)
        }
        stages.changed = { [weak self] id, _ in
            guard let self else { return }
            self.waker.wakeIfWaiting(id)
            self.changed()
        }
        watch.changed = { [weak self] _, _ in self?.activity.pulse() }
        questions.changed = { [weak self] in
            guard let self else { return }; self.waker.wake(.questionWaiting, id: self.workspace.state.operatorSession?.id ?? UUID()); self.changed()
        }
        gate.changed = questions.changed
        tools.changed = { [weak self] in self?.changed() }
        tools.recorded = { [weak self] request, answer in
            guard let self else { return }
            let task = request.arguments["task"]?.stringValue.flatMap(UUID.init(uuidString:))
            let result = answer.value.flatMap { try? $0.canonicalJSON() } ?? answer.message ?? ""
            self.log.record(tool: request.tool, task: task, arguments: request.arguments,
                            outcome: answer.message == nil ? .ok : .failed, result: result,
                            line: request.tool + (task.map { " " + $0.uuidString } ?? ""))
        }
        poller.onPass = { [weak self] observations in
            guard let self, !self.isStopped, self.workspace.state.operatorSession?.paused != true else { return }
            for observation in observations { for id in observation.signals {
                if self.workspace.state.operatorSession?.sourceFailures?[id.uuidString] != nil {
                    self.workspace.mutate { $0.operatorSession?.sourceFailures?[id.uuidString] = nil }
                }
            } }
            let ids = self.router.apply(observations: observations)
            for id in ids { self.schedule { await self.stages.run(id) } }
            if !ids.isEmpty { self.schedule { await self.reconcile() } }
        }
        poller.onFailure = { [weak self] ids, reason in
            guard let self, !self.isStopped else { return }
            for id in ids where self.workspace.state.operatorSession?.sourceFailures?[id.uuidString] != reason {
                self.workspace.mutate { state in
                    if state.operatorSession == nil { state.operatorSession = OperatorSession(createdAt: self.ports.now()) }
                    if state.operatorSession?.sourceFailures == nil { state.operatorSession?.sourceFailures = [:] }
                    state.operatorSession?.sourceFailures?[id.uuidString] = reason
                }
                self.log.record(tool: "signal_read", task: nil, arguments: ["signal": .string(id.uuidString)], outcome: .failed,
                    result: reason, line: "A signal source could not be read.")
                self.waker.wake(.signalFailed, id: id)
            }
        }
        workspace.onChange { [weak self] in
            guard let self, !self.isStopped else { return }
            if self.normalized(self.workspace.state.signals) != self.lastSignals { self.schedule { await self.configure(); self.poller.tick() } }
            self.reconcileIfIdle()
            self.changed()
        }
    }
    func onChange(_ hook: @escaping () -> Void) { hooks.append(hook) }
    private func changed() {
        if !isStopped {
            let note = SignalQuestionNotification.make(state: workspace.state)
            if note != lastNote {
                if let note { ports.notifications.requestAuthorization(); ports.notifications.post(note) }
                else { ports.notifications.withdraw(ids: [SignalQuestionNotification.id]) }
                lastNote = note
            }
        }
        for hook in hooks { hook() }
    }
    func connections() async -> SignalConnections { let read = readConnections; return await BackgroundWork.run(read) }
    private func normalized(_ signals: [Signal]) -> [Signal] { signals.map { var value = $0; value.collapsed = false; return value } }
    func start() {
        guard isStopped else { return }; isStopped = false; stages.start()
        savedObserver = NotificationCenter.default.addObserver(forName: OperatorProfileStore.didSave, object: nil, queue: .main) { [weak self] notification in
            let owner = (notification.object as? UserDefaults).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, owner == ObjectIdentifier(self.ports.preferences) else { return }
                if let id = self.workspace.state.operatorSession?.id { self.waker.wake(.settingsChanged, id: id) }
                self.schedule { [weak self] in await self?.loadProfile() }
            }
        }
        if automatic { loop = PollLoop(interval: ports.reconcileInterval) { [weak self] in
            guard let self, !self.isStopped else { return nil }; await self.reconcile(); return self.ports.reconcileInterval
        } }
        waker.restore()
        schedule {
            let delivered = await self.ports.notifications.readDelivered()
            if delivered.contains(SignalQuestionNotification.id) {
                self.lastNote = SignalQuestionNotification.make(state: self.workspace.state)
                if self.lastNote == nil { self.ports.notifications.withdraw(ids: [SignalQuestionNotification.id]) }
            }
            await self.loadProfile(); await self.configure(); await self.reconcile(); self.changed()
        }
    }
    func stop() {
        isStopped = true; configuration = UUID(); loop?.cancel(); loop = nil; poller.stop(); stages.stop(); chat.stop(); hostPass?.cancel()
        for job in jobs.values { job.cancel() }; jobs.removeAll()
        if let savedObserver { NotificationCenter.default.removeObserver(savedObserver); self.savedObserver = nil }
    }
    private func schedule(_ body: @escaping @MainActor () async -> Void) {
        guard !isStopped else { return }; let id = UUID()
        jobs[id] = ports.work.start { [weak self] in await body(); self?.jobs[id] = nil }
    }
    func loadProfile() async {
        let read = ports.profile, value = await BackgroundWork.run(read)
        guard !isStopped else { return }; profile = value
    }
    func configure(refresh requested: Set<UUID> = []) async {
        guard !isStopped, workspace.canChangeWorkspace else { return }
        let key = UUID(), expected = normalized(workspace.state.signals); configuration = key
        let registrations: [SignalPoller.Registration]
        if let sourceRegistrations { registrations = await sourceRegistrations(expected) }
        else { let links = await connections(); registrations = links.registrations(for: expected) }
        guard !isStopped, configuration == key, normalized(workspace.state.signals) == expected else { return }
        let edited = Set(expected.filter { value in lastSignals.first(where: { $0.id == value.id }) != value }.map(\.id)).union(requested)
        let keys = registrations.map { $0.id.uuidString + ":" + $0.sourceHost + ":" + $0.readKey }.sorted()
        if keys != registrationKeys || !edited.isEmpty { poller.replace(registrations, refresh: edited); registrationKeys = keys }
        lastSignals = expected
    }
    func save(_ signal: Signal) async throws {
        guard workspace.canChangeWorkspace, signal.source.isSupported, signal.finish.isValid(for: signal.source) else { throw ActionUnavailable("This signal cannot be saved.") }
        workspace.mutate { state in
            if let index = state.signals.firstIndex(where: { $0.id == signal.id }) { state.signals[index] = signal }
            else { state.signals.append(signal) }
        }
        guard workspace.flush() else { throw ActionUnavailable("The signal could not be saved.") }
        // The edited signal reads now, even while a tick runs and would drop this call's reconcile.
        await pause.reconcile(); await configure(refresh: [signal.id]); poller.tick(); await reconcile()
    }
    func daemonAttached() { tabsKnown = false; settingsDue = .distantPast }
    func handle(_ event: DaemonEvent) {
        guard !isStopped else { return }
        switch event {
        case .snapshot(let snapshot): tabsKnown = snapshot.connected; if snapshot.connected { schedule { await self.reconcile() } }
        case .itermDisconnected: tabsKnown = false
        case .windowClosed(let window): chat.windowClosed(window)
        case .operatorRequest(let request): schedule { await self.respond(request) }
        default: break
        }
    }
    private func respond(_ request: OperatorRequest) async {
        guard let daemon = daemon() else { return }
        activeTools += 1
        let task = request.arguments["task"]?.stringValue.flatMap(UUID.init(uuidString:)).flatMap { workspace.state.signalItem(id: $0) }
        await activity.during(OperatorActivityTracker.words(for: request, task: task)) {
            await answer(request, using: daemon)
        }
        activeTools -= 1
        await reconcile()
    }
    private func answer(_ request: OperatorRequest, using daemon: any DaemonCommands) async {
        do {
            if request.tool == "gate_command" {
                let result = await gate.respond(request)
                log.record(tool: "shell", task: nil, arguments: request.arguments,
                    outcome: result["decision"]?.stringValue == "allow" ? .ok : .refused,
                    result: (try? result.canonicalJSON()) ?? "", line: "Checked an Operator shell command.")
                try await daemon.replyToOperator(requestId: request.requestId, result: result, error: nil)
            }
            else {
                let answer: ToolAnswer
                if request.tool == "run_status", request.arguments["task"]?.stringValue != nil, waker.unread {
                    // Refuse before producing/logging a partial digest. Only a global read can
                    // acknowledge a wake that may coalesce several tasks.
                    do {
                        try tools.requireSession(request, mutating: false)
                        answer = .error("A wake may include updates for other tasks. Call run_status without task first.")
                    } catch let refusal as ToolRefusal { answer = .error(refusal.message) }
                    catch { answer = .error(OperationIssue.reason(of: error)) }
                    tools.recorded(request, answer)
                } else { answer = await tools.respond(request) }
                if request.tool == "run_status", request.arguments["task"]?.stringValue == nil, case .result = answer { waker.acknowledge() }
                switch answer {
                case .result(let value): try await daemon.replyToOperator(requestId: request.requestId, result: value, error: nil)
                case .error(let reason): try await daemon.replyToOperator(requestId: request.requestId, result: nil, error: reason)
                }
            }
            if !isStopped, workspace.state.operatorSession?.id.uuidString == request.operatorId,
               workspace.state.operatorSession?.generation == request.generation { log.succeed(.reply) }
        } catch {
            // Not resent: the Operator retries its timed-out call, and a keyed call replays its ledger result.
            if !isStopped, workspace.state.operatorSession?.id.uuidString == request.operatorId,
               workspace.state.operatorSession?.generation == request.generation {
                log.fail(.reply, "An answer could not be sent back to the Operator: " + OperationIssue.reason(of: error))
            }
        }
    }
    func reconcile() async {
        guard !isStopped, !reconciling, workspace.canChangeWorkspace else { return }
        reconciling = true; defer { reconciling = false; changed() }
        let now = ports.now()
        if now >= settingsDue {
            settingsDue = now.addingTimeInterval(OperatorTiming.reconcileInterval)
            workspace.mutate { $0.pruneOperator(at: ports.now()) }
            await loadProfile(); await configure()
        }
        // Polling needs no iTerm2. The poller skips it while paused or stopped.
        poller.tick()
        guard !isStopped, tabsKnown else { return }
        if workspace.mutate({ $0.withdrawObsoleteQuestions(at: ports.now()) }) { workspace.flush() }
        // A durable retirement must complete before a new generation can serve a later match.
        if workspace.state.operatorSession?.finishing == true
            || (!workspace.state.operatorHasWork && workspace.state.operatorSession?.startingFresh == true) {
            await chat.finishIfIdle(idle: activeTools == 0 && oracle.isIdle, wakeWaiting: waker.waking)
        }
        if workspace.state.operatorHasWork { await chat.ensure() }
        guard !isStopped else { return }
        chat.remember()
        native.recoverLaunches()
        await native.refreshTurns()
        await pause.reconcile()
        guard !isStopped else { return }
        if workspace.state.operatorSession?.paused == true {
            await finishChatWhenNoWork()
            return
        }
        for task in workspace.state.allSignalTasks {
            if task.signalTask?.phase == .launching { schedule { await self.stages.run(task.id) } }
            else if let record = task.signalTask, record.phase.canContinue, !record.pendingStages.isEmpty {
                schedule { try? await self.stages.finish(task.id, action: .advancePending) }
            }
        }
        for task in workspace.state.tasks where task.signalTask?.canRunThen == true && task.signalTask?.thenApplied != true {
            schedule { await self.activity.during("finishing " + OperatorActivityTracker.name(task)) { await self.then.apply(task.id) } }
        }
        if now >= hostDue, hostPass == nil, !isStopped {
            hostDue = now.addingTimeInterval(OperatorTiming.reconcileInterval)
            hostPass = ports.work.start { [weak self] in await self?.watch.pass(); self?.hostPass = nil }
        }
        waker.dropWhenNoWork()
        await waker.deliver()
        await finishChatWhenNoWork()
        if workspace.state.operatorHasWork {
            await chat.freshIfDue(idle: oracle.isIdle && activeTools == 0, wakeWaiting: waker.unread || waker.waking)
        }
    }
    /// Completion, removal and Take Over can finish between minute ticks. Both state writes
    /// and the end of tracked I/O recheck this, so the last closeout retires promptly.
    private func reconcileIfIdle() {
        guard !isStopped, !reconciling, activeTools == 0, !activity.isRunning,
              !workspace.state.operatorHasWork, workspace.state.operatorSession?.window != nil else { return }
        schedule { await self.reconcile() }
    }
    /// With no work left, the chat retires once no tool call, Oracle check or tracked activity runs
    /// and no wake waits to be typed or read.
    private func finishChatWhenNoWork() async {
        await chat.finishWhenNoWork(idle: activeTools == 0 && oracle.isIdle && !activity.isRunning, wakeWaiting: waker.waking || waker.unread)
    }
    private var currentInstructions: String { OperatorProfileStore.saved(ports.preferences)?.instructions ?? profile.instructions }
    private var currentOracle: OracleSetting { OperatorProfileStore.saved(ports.preferences)?.oracle ?? profile.oracle }
    /// The Oracle's setting, the standing instructions and the settings revision, as each check reads them.
    private var oracleSettings: OracleConsult.Settings {
        .init(oracle: currentOracle, instructions: currentInstructions, revision: OperatorProfileStore.oracleRevision(ports.preferences))
    }
    func setPaused(_ paused: Bool) async {
        guard !isStopped, workspace.canChangeWorkspace else { return }
        workspace.mutate { state in
            if state.operatorSession == nil { state.operatorSession = OperatorSession(createdAt: ports.now()) }
            state.operatorSession?.paused = paused
        }
        guard workspace.flush() else { return }
        await pause.reconcile()
        if !paused { await configure(refresh: Set(workspace.state.signals.filter(\.enabled).map(\.id))); poller.tick(); await reconcile() }
    }
}
