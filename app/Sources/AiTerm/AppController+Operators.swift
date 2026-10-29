import Foundation
import Observation
import AiTermCore

/// What the operator views ask of the app, forwarded to the operator controller (Part D). A refusal
/// lands in the banner, as every other action's does, named after what it was for.
extension AppController {
    /// A driven task row's Take Over, Hand Back or Stop Task….
    func perform(_ item: OperatorMenuItem, on task: TaskItem) {
        let controller = operatorController
        switch item {
        case .takeOver:
            attempt("Couldn’t take over “\(task.title)”") { try await controller.takeOver(task: task.id) }
        case .handBack:
            attempt("Couldn’t hand “\(task.title)” back") { try await controller.handBack(task: task.id) }
        case .stopTask:
            Task { await confirmStop(task) }
        default:
            break
        }
    }

    /// Stop Task…: asks first, then the task ends `stopped` for its operator — its dependents wait for
    /// you; its window, branch and any agent at work stay. Says whether it was stopped.
    @discardableResult
    func confirmStop(_ task: TaskItem) async -> Bool {
        guard await prompter.ask(OperatorAlerts.stopTask(task)).confirmed else { return false }
        let controller = operatorController
        attempt("Couldn’t stop “\(task.title)”") { try controller.stop(task: task.id) }
        return true
    }

    /// Runs `work` and reports what it threw as `title`.
    func attempt(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in await attemptNow(title, work) }
    }

    /// Runs `work` here and now, reports what it threw as `title`, and says whether it went through.
    @discardableResult
    func attemptNow(_ title: String, _ work: @MainActor () async throws -> Void) async -> Bool {
        do { try await work(); return true } catch { report(OperationIssue(title: title + ".", error: error)); return false }
    }
}

extension AppController {
    /// New Broadcast… is off behind a sheet, over a locked workspace, and until the previous broadcast ends.
    var canPresentNewBroadcast: Bool { canUseFileMenu && state.activeRun == nil }

    /// The OPERATOR heading's "+" or File › New Broadcast… (⌘B), its help following Settings › Operator's slices and Oracle as
    /// they are now, the profile the broadcast freezes as it starts, and its Agents step the installed agents' models,
    /// their defaults and the last broadcast's rows (`NewBroadcastContext`), and its Task step each chosen project's code
    /// host as the Operator's tools check it, an origin git can't read as none. Started, the Operator's row is
    /// selected; its window comes forward by the operator controller's own start.
    func presentNewBroadcast() {
        guard canPresentNewBroadcast else { return }
        let controller = operatorController
        let profile = controller.ports.profile, models = controller.tools.agentModels, remembered = state.lastModelByAgent
        let codeHost = controller.ports.codeHost
        let installed = ModelChoice.pair.filter(controller.tools.installedAgents.contains)
        // UserDefaults is thread-safe, though not marked Sendable.
        nonisolated(unsafe) let preferences = controller.ports.preferences ?? .standard
        Task { [weak self] in
            let context = await BackgroundWork.run {
                NewBroadcastContext.read(profile: profile?(),
                                         installed: installed, models: models, remembered: remembered, preferences: preferences)
            }
            guard let self, self.canPresentNewBroadcast else { return }
            self.sheets.presentNewBroadcast(context: context, loadJiraProjects: { [weak self] in try await self?.loadJiraProjects() ?? [] },
                                            readiness: { [weak self] in self?.broadcastReadiness ?? .checking },
                                            checkReadiness: { [weak self] in await self?.checkBroadcastReadiness() },
                                            hasCodeHost: { (try? await codeHost.connects($0)) ?? false }) { [weak self] request in
                let id = try await controller.startBroadcast(name: request.name, jiraProjectKeys: request.jiraProjectKeys,
                                                             projectIds: request.projectIds, prompt: request.prompt,
                                                             agents: request.agents,
                                                             taskSettings: request.taskSettings, goal: request.goal)
                self?.focus.browse(.operation(id))
                return id
            }
        }
    }
}

extension AppController {
    /// What New Broadcast's Start waits for, from the Agents cards' probes and the delivery check's file
    /// as they stand: the same words the cards say.
    var broadcastReadiness: BroadcastReadiness {
        let messaging = self.messaging
        return .of(installed: agents.availableAgents, snapshots: agents.harnessSettingsModel().snapshots,
                   messaging: { messaging.readiness(of: $0) }, iterm: messaging.iterm)
    }

    /// Probes the cards of the agents the Operator may plan on, as Settings does when it opens, and reads
    /// the delivery check's file until the task is cancelled: the sheet's, for as long as it is open.
    func checkBroadcastReadiness() async {
        let planned = ModelChoice.pair.filter(agents.availableAgents.contains), harness = agents.harnessSettingsModel()
        async let probes: Void = harness.load(planned)
        async let watch: Void = messaging.watch()
        _ = await (probes, watch)
    }
}

extension AppController {
    /// OPERATOR's board button or Open Board (`openBoard`), or a notification's click: its
    /// board, over whatever sheet is up.
    func presentBoard(run id: UUID) {
        guard state.activeRun?.id == id else { return }
        sheets.present(operatorSheet: .broadcastBoard(id))
    }

    /// Open on the Shelf, for an ended broadcast: its sheet, read-only on Summary, in the Shelf's place. The live
    /// broadcast's is the sidebar's (`presentBoard`).
    func presentShelved(run id: UUID) {
        guard state.run(id: id)?.hasEnded == true else { return }
        sheets.present(operatorSheet: .shelvedBroadcast(id))
    }

    /// Remove on the Shelf, for an ended broadcast: asks first (`OperatorAlerts.removeShelved`), then forgets it
    /// and deletes its run folder; its tasks stay. Says whether it went: false when declined, and false when it
    /// failed (it is reported).
    @discardableResult
    func confirmRemoveShelved(_ id: UUID) async -> Bool {
        guard canChangeWorkspace, let run = state.run(id: id), run.hasEnded else { return false }
        guard await prompter.ask(OperatorAlerts.removeShelved(run)).confirmed else { return false }
        let controller = operatorController
        return await attemptNow("Couldn’t remove “\(run.name)”") { try await controller.forget(run: id) }
    }

    /// The board a notification's click asked for (D7 sets `OperatorController.presentBoard`),
    /// held behind an editing sheet, then presented and cleared so it opens once.
    func presentRequestedBoard() {
        guard let id = operatorController.presentBoard else { return }
        if let sheet {
            guard case .broadcastBoard = sheet else { return }
        }
        operatorController.presentBoard = nil
        presentBoard(run: id)
    }

    /// Installs Auto-close once, for the app's lifetime: the operator controller holds it. Each
    /// connected snapshot sweeps it, the first one telling it who is driving, which a restart has to wait for.
    func installTaskAutoCloser() {
        let controller = operatorController
        let closer = TaskAutoCloser(workspace: workspace, live: live, git: controller.ports.git,
                                    now: controller.ports.now) { [remover] in try await remover.removeAutomatically($0, starting: $1) }
        controller.onRunChanged = { [closer] in closer.changed($0) }
        // After `live`'s own hook, so the sweep reads the snapshot's sessions. Weak, as the
        // helper's other hooks are, so the closer goes with the controller that holds it.
        helper.onEvent { [weak closer] event in
            if case .snapshot(let snapshot) = event, snapshot.connected { closer?.sweep() }
        }
    }

    /// Watches `OperatorController.presentBoard` for as long as the app runs: each request is
    /// presented on the main actor's next turn — Observation reports a change before it is stored —
    /// and the watch re-armed.
    func watchBoardRequests() {
        withObservationTracking {
            _ = operatorController.presentBoard
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                presentRequestedBoard()
                watchBoardRequests()
            }
        }
    }

    /// The broadcast's menu (OPERATOR's and its lead row's) and its VoiceOver actions, on the broadcast as it is now.
    func perform(_ item: OperatorMenuItem, onBroadcast id: UUID) {
        guard let run = state.activeRun, run.id == id else { return }
        perform(item, on: run)
    }

    /// The broadcast's menu.
    func perform(_ item: OperatorMenuItem, on run: OperatorRun) {
        switch item {
        case .openBoard: openBoard(run.id)
        case .rename: presentRename(run: run)
        case .pause: pause(run)
        case .resume: resume(run)
        case .endBroadcast: Task { await confirmEnd(run) }
        default: break
        }
    }

    /// OPERATOR's board button, or Open Board in its menu (decided 21 Oct 2026): its board
    /// opens over the sidebar, and nothing else moves. The header's click and ↩ fold its group; the
    /// Operator's window is its own row's.
    func openBoard(_ id: UUID) {
        presentBoard(run: id)
    }

    /// The folded OPERATOR heading's amber chip: the Operator's section opens, folding the projects, and its first
    /// row that needs you is selected, its window shown as the arrows show one.
    @discardableResult
    func openAttention(of id: UUID) -> Task<Void, Never>? {
        guard let section = rows.broadcast, section.id == id, let first = section.firstNeedingAttention else { return nil }
        reveal(RowSelection(first))
        return focus.peek(RowSelection(first), force: true)
    }

    /// The folded PROJECTS heading's amber chip: the projects open, folding the Operator's section, and their first
    /// row that needs you is selected, its window shown as the arrows show one.
    @discardableResult
    func openProjectsAttention() -> Task<Void, Never>? {
        guard let first = rows.projectsNeedingAttention.first else { return nil }
        reveal(RowSelection(first))
        return focus.peek(RowSelection(first), force: true)
    }

    /// While a broadcast runs, the Operator's section and the projects fold into each other: a row selected from away
    /// from the list — a notification, Focus View, an amber chip — in the folded one opens it, folding the other.
    func reveal(_ row: RowSelection) {
        guard let run = state.activeRun else { return }
        let folded = state.foldedRuns.contains(run.id)
        let inBroadcast = switch row {
        case .operation(let id): id == run.id
        case .task(let id): state.task(id: id)?.operated?.runId == run.id
        case .project, .terminal: false
        }
        if inBroadcast == folded { toggleFolded(run: run.id) }
    }

    /// Rename…: the `NameSheet`, on the broadcast's name.
    func presentRename(run: OperatorRun) { sheets.presentRename(run: run) }

    /// The name sheet's answer. An emptied field keeps the name, as a renamed task's does.
    func rename(run: OperatorRun, to name: String) {
        guard !name.isEmpty, name != run.name else { return }
        let controller = operatorController
        attempt("Couldn’t rename “\(run.name)”") { try controller.rename(run: run.id, to: name) }
    }

    /// End Broadcast…: asks first, saying what happens to its tasks (`OperatorController.endPrompt`), then
    /// ends it. Says whether it ended: false when it was declined, and false when the end failed (it is
    /// reported, and the broadcast is as it was).
    @discardableResult
    func confirmEnd(_ run: OperatorRun) async -> Bool {
        guard await prompter.ask(operatorController.endPrompt(run: run)).confirmed else { return false }
        return await endNow(run)
    }

    func pause(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t pause “\(run.name)”") { try controller.pause(run: run.id) }
    }

    func changeEnd(of task: UUID, to end: TaskEnd) {
        let controller = operatorController
        attempt("Couldn’t change the task’s end") { try controller.changeEnd(of: task, to: end) }
    }

    func answerFixRounds(of task: UUID, _ answer: BroadcastBoard.FixRoundsAnswer) {
        let controller = operatorController
        attempt("Couldn’t answer the task’s fix rounds") { try controller.answerFixRounds(of: task, answer) }
    }

    func resume(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t resume “\(run.name)”") { try await controller.resume(run: run.id) }
    }

    /// The end, awaited: whether it went through, which is when a board may close.
    @discardableResult
    func endNow(_ run: OperatorRun) async -> Bool {
        let controller = operatorController
        return await attemptNow("Couldn’t end “\(run.name)”") {
            try await controller.end(run: run.id)
            // End Broadcast does not pass through runChanged, so it triggers cleanup here.
            controller.onRunChanged(run.id)
        }
    }

    /// The broadcast's chat — its Operator's window — brought forward as its row's click brings it: raised
    /// when it is open, reopened when it is closed (`OperatorController.reopenOperator`, which reports a refusal).
    func openOperatorWindow(_ run: OperatorRun) {
        focus.select(.operation(run.id))
    }

    /// The wake Notice's Open the Operator: the broadcast's Operator window brought forward, while it has one.
    func openOperatorWindow(of id: UUID) {
        if let run = state.run(id: id) { openOperatorWindow(run) }
    }

    /// Fix in Settings, from a Notice about an agent AiTerm can't type into: Settings at that agent's card.
    func presentAgentSettings(for agent: AgentKind) {
        presentSettings(tab: .agents, agent: agent)
    }

    /// The board's buttons, each on the broadcast as it is when pressed, and nothing once it is no longer
    /// the active one. End Broadcast… asks first and closes the board once it ended, and only then: a failed end keeps it up. A complete
    /// broadcast's End Broadcast asks nothing. Start Fresh keeps the board up, its footer back to the moment's. A card's
    /// end menu and its fix-rounds links act on its task, what is refused said in the banner.
    func boardActions(for id: UUID, dismiss: @escaping @MainActor () -> Void) -> BoardActions {
        BoardActions(
            open: { [weak self] opens in self?.open(opens, run: id) },
            pause: { [weak self] in self?.onActiveRun(id) { self?.pause($0) } },
            resume: { [weak self] in self?.onActiveRun(id) { self?.resume($0) } },
            end: { [weak self] confirming in
                self?.onActiveRun(id) { run in
                    guard let self else { return }
                    Task { if await (confirming ? self.confirmEnd(run) : self.endNow(run)) { dismiss() } }
                }
            },
            startFresh: { [weak self] in self?.onActiveRun(id) { self?.startFresh($0) } },
            changeEnd: { [weak self] task, end in self?.onActiveRun(id) { _ in self?.changeEnd(of: task, to: end) } },
            answerFixRounds: { [weak self] task, answer in self?.onActiveRun(id) { _ in self?.answerFixRounds(of: task, answer) } })
    }

    /// `work` on the broadcast with this id, as it is now, while it is the active one.
    private func onActiveRun(_ id: UUID, _ work: (OperatorRun) -> Void) {
        guard let run = state.activeRun, run.id == id else { return }
        work(run)
    }

    /// What a card's click opens, the board already closed (spec §4, §13): the task's window, or the
    /// Operator's — raised when it is open, reopened in front when it is closed. A problem AiTerm hit is the
    /// sidebar banner's, which already shows it with its recovery: nothing else comes forward. Nothing at all
    /// once the broadcast is no longer the active one: a card never acts on an ended broadcast.
    func open(_ opens: BroadcastBoard.Opens, run id: UUID) {
        guard let run = state.activeRun, run.id == id else { return }
        switch opens {
        case .taskWindow(let task): focus.select(.task(task))
        case .tab(let task, let session): bringTab(task: task, sessionId: session)
        case .operatorWindow: openOperatorWindow(run)
        case .sidebarBanner, .nothing: break
        }
    }

    /// One of a task's worker tabs in front (P5 A): its row selected and its window raised as a row's click raises
    /// it, then that tab selected in the window and the window brought forward with it (`session.activate`), so the
    /// tab stands in front whatever the window showed last. A board card's tab line brings its tab; a driven row's
    /// click brings `TaskItem.tabToBring(sessions:requests:)`'s. A tab gone meanwhile leaves the window as raised.
    @discardableResult
    func bringTab(task id: UUID, sessionId: String) -> Task<Void, Never> {
        let raising = focus.select(.task(id))
        return Task { @MainActor [helper] in
            await raising?.value
            try? await helper.daemon?.activate(sessionId: sessionId)
        }
    }

    /// Start Fresh, from the board's footer when the Operator's conversation can't be resumed.
    func startFresh(_ run: OperatorRun) {
        let controller = operatorController
        attempt("Couldn’t start a fresh Operator for “\(run.name)”") { try await controller.startFresh(run: run.id) }
    }
}
