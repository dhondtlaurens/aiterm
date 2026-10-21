import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// The app's composition root, and the one handle the views and the tests have on it. `init` builds
/// every owner below, each handed in its initializer the owners it calls, so each is built after
/// them: the workspace, the notices, the helper, the tabs, the tiling, the checkouts, the task
/// remover, the selection, then the actions, the windows, the review threads, and Backpack Mode and
/// the Mac's readings last. What an owner tells one built after it goes out through its `on…` hooks,
/// which the later owner adds itself to as it is built; the checkout monitor and the task remover,
/// which each call the other, are the one pair joined after both exist (`CheckoutRemovals`). The
/// sidebar's rows and the Dock badge are the controller's own. Everything else here forwards to the
/// owner that does it.
@MainActor
@Observable
final class AppController {
    /// The projects, dividers, tasks and terminals, and the one way they change: `workspace.mutate`,
    /// which saves the change and tells the owners below that keep something per row.
    let workspace: WorkspaceStore
    /// `workspace`'s, forwarded: the views and the tests read them here.
    var state: AppState { workspace.state }
    var workspaceLoaded: Bool { workspace.loaded }
    var persistenceError: String? { workspace.persistenceError }
    var canChangeWorkspace: Bool { workspace.canChangeWorkspace }

    /// The sheet slot, every way into it, and the creation sheets' models.
    let sheets: SheetCoordinator
    /// `sheets`', forwarded: the sidebar presents it, and the menus grey behind it.
    var sheet: SheetKind? {
        get { sheets.sheet }
        set { sheets.sheet = newValue }
    }
    /// The projects, dividers and names: every edit that is the workspace's alone, and the pull.
    let projects: ProjectActions
    /// Tasks and reviews created, and their windows opened.
    let launcher: TaskLauncher
    /// A project's terminals: a new one, and a terminal closed.
    let terminals: TerminalActions
    /// The banner above the list and the completion toast, and which report wins the banner.
    let notices: Notices

    /// The helper process, the connection to it and how far it reaches iTerm2.
    let helper: HelperLink
    /// The rows locked to their iTerm2 windows: a window lost is taken back, asked about or restored.
    let windows: WindowReconciler
    /// The tabs, usage and context fills the helper reports.
    let live: LiveSessions
    /// The branches, missing checkouts and diffs on disk, read by a pass every two seconds.
    let checkouts: CheckoutMonitor
    /// The sidebar's rows, derived from the three above once per change to what they draw: the
    /// list, the Dock badge, Focus View and List View all read them here.
    let rows: SidebarProjection
    /// The Interface tab's preferences. `tiling.setInterfaceSize` and `helper.setMatchItermBackground`
    /// change the two that act on a window; the badge switches are plain writes.
    let preferences: InterfacePreferences
    /// The sidebar window, and where each task's and terminal's window is put beside it.
    let tiling: SidebarTiling
    /// The selected row, and bringing its window forward.
    let focus: RowFocus
    /// How many of each merge request's review threads are resolved, read every 60 s and when its
    /// row is selected; each row reads its own count (`threads(of:)`).
    let reviewThreads: ReviewThreadsWatcher
    /// The agent CLIs on this machine and AiTerm's hooks into them; probed at `start()`.
    let agents: AgentIntegrations
    /// Whether AiTerm may type into Claude Code and Codex, as the delivery check last wrote it: their
    /// cards' Messaging in Settings › Agents, and part of what New Broadcast waits for.
    let messaging: MessagingChecks
    /// Every modal question the app asks goes through here, so tests answer them from a script.
    let prompter: Prompter
    /// Backpack Mode: its state, setup and battery reading. The footer's Mac rows, its sheet, Settings ›
    /// Integrations › Mac and the View menu's item read it.
    let backpack: BackpackController
    /// The Mac's CPU, memory and battery, sampled every 5 s for the footer's readings row.
    let machine: MachineMonitor
    /// Opens a row's context menu from the keyboard (`RowMenuAnchor`). A test records the call
    /// instead: the menu tracks modally, and ending that stopped a test host's run loop.
    @ObservationIgnored var openRowMenu: @MainActor (UUID) -> Void = { RowMenuAnchor.openMenu(for: $0) }
    /// What the banner's Fix runs for a project: the live pipeline — a clone, the agent, AiTerm's
    /// landing — which a test replaces with a stub, as it does `openRowMenu`.
    @ObservationIgnored var fixPipeline: @MainActor (Project) -> FixPipeline
    let git: any GitRunning
    /// Writes the Dock tile's badge. Only the app has a Dock tile to write, so the default is none.
    private let setBadge: @MainActor (String?) -> Void
    /// Starts iTerm2, and whether it is running: what `start()` asks, so a test never reaches for the real one.
    private let launchIterm: @MainActor () -> Void
    private let itermRunning: @MainActor () -> Bool
    @ObservationIgnored private var dockBadgeLabel: String?

    /// The work under way on each project, task and terminal: what one waits for before it starts,
    /// and what a project's removal waits for.
    let work: WorkInFlight
    /// Removes tasks — the person's Remove, and the closing of one whose worktree went.
    let remover: TaskRemover
    /// Archives tasks and reviews.
    let archiver: TaskArchiver
    /// The operations: their runs, their operators' tabs and tokens, and the services under them.
    let operatorController: OperatorController
    @ObservationIgnored private var agentProbe: Task<Void, Never>?

    /// Nothing here has a default: every dependency that reaches outside the process — the state
    /// file, the Keychain, a login shell, the person's home, the modal alerts — is named by whoever
    /// builds a controller. The app builds one with `live()`, the snapshots with `live` too and a few
    /// of its own, and a test with the convenience initializer in its target, whose defaults touch
    /// none of them. `peekDelay` is `RowFocus`'s; a test passes none, and awaits the peek instead.
    /// `backpackPorts` are everything Backpack Mode touches — `sudo pmset`, Wi-Fi, the battery,
    /// Location, the lid — and `backpackSecrets` where it keeps the hotspot's password;
    /// `openLocationSettings` is where its Allow… sends the person once macOS will not ask.
    /// `machineSensor` reads the Mac's load for the footer; the battery is `backpackPorts.power`.
    /// `checkoutPollInterval` is the pause between the checkout monitor's passes; `toastLifetime` is
    /// how long a completion toast stays up; `closedWindowHold` and `now` are how long, and against
    /// what clock, a closed task window is held before Remove's question (`ClosedWindowTriage`);
    /// `bringForward` brings AiTerm forward for it; `launchIterm` starts iTerm2 when AiTerm starts
    /// while `itermRunning` says it is not, and when a row is chosen while it is away.
    /// `confirmsRemoval` is the last look at a checkout the monitor found gone (`TaskRemover`).
    /// `operatorPorts` are what the operators reach: run folders, the agents' home, notifications.
    init(store: StateStore,
         preferences: InterfacePreferences,
         harnessHome: URL,
         claudeConfig: ClaudeConfig = ClaudeConfig(),
         bundledResourcesURL: URL?,
         locateAgents: @escaping @Sendable () -> Set<AgentKind>?,
         findPython: @escaping @Sendable () -> URL?,
         jiraSettings: @escaping @Sendable () -> JiraConfig?,
         gitLabSettings: @escaping @Sendable () -> GitLabConfig?,
         gitHubSettings: @escaping @Sendable () -> GitHubConfig?,
         prompter: Prompter,
         setBadge: @escaping @MainActor (String?) -> Void,
         activateIterm: @escaping @MainActor () -> Void,
         launchIterm: @escaping @MainActor () -> Void,
         itermRunning: @escaping @MainActor () -> Bool,
         bringForward: @escaping @MainActor () -> Void,
         backpackPorts: BackpackPorts,
         backpackSecrets: any SecretStore,
         openLocationSettings: @escaping @MainActor () -> Void,
         machineSensor: any MachineSensor,
         peekDelay: Duration,
         checkoutPollInterval: Duration,
         toastLifetime: Duration,
         closedWindowHold: Duration,
         now: @escaping @MainActor () -> ContinuousClock.Instant,
         git: any GitRunning,
         scan: @escaping CheckoutMonitor.Scanner,
         confirmsRemoval: @escaping TaskRemover.ConfirmsRemoval,
         operatorPorts: OperatorPorts) {
        let workspace = WorkspaceStore(file: store), work = WorkInFlight(), workflow = TaskWorkflow(git: git)
        let notices = Notices(toastLifetime: toastLifetime,
                              isStale: { [weak workspace] issue in workspace.map { issue.isStale(in: $0.state) } ?? false })
        let helper = HelperLink(bundledResourcesURL: bundledResourcesURL, preferences: preferences, findPython: findPython, claudeConfig: claudeConfig, harnessHome: harnessHome,
                                notices: notices)
        let daemon: @MainActor () -> (any DaemonCommands)? = { helper.daemon }
        let live = LiveSessions(workspace: workspace)
        let tiling = SidebarTiling(preferences: preferences, workspace: workspace, daemon: daemon)
        let checkouts = CheckoutMonitor(live: live, scan: scan, pollInterval: checkoutPollInterval, git: git, workspace: workspace,
                                        onTitles: { await helper.sendTitles($0) })
        let teardown = WorktreeTeardown(workspace: workspace, work: work, prompter: prompter, daemon: daemon)
        let remover = TaskRemover(workspace: workspace, work: work, workflow: workflow, notices: notices, prompter: prompter,
                                  teardown: teardown, checkouts: checkouts, live: live, daemon: daemon, confirmsRemoval: confirmsRemoval)
        let focus = RowFocus(peekDelay: peekDelay, workspace: workspace, daemon: daemon, taskFrame: { tiling.taskFrame() },
                             activateIterm: activateIterm, isRemoving: { remover.isRemoving($0) }, notices: notices)
        let agents = AgentIntegrations(harnessHome: harnessHome, bundledResourcesURL: bundledResourcesURL, locateAgents: locateAgents,
                                       rememberedModels: { workspace.state.lastModelByAgent },
                                       defaults: preferences.defaults, claudeConfig: claudeConfig)
        let launcher = TaskLauncher(workspace: workspace, work: work, notices: notices, checkouts: checkouts, focus: focus,
                                    tiling: tiling, workflow: workflow, git: git, daemon: daemon)
        let archiver = TaskArchiver(workspace: workspace, work: work, workflow: workflow, notices: notices, prompter: prompter,
                                    checkouts: checkouts, remover: remover, focus: focus, teardown: teardown, now: { Date() })
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.helper = helper
        self.live = live
        self.tiling = tiling
        self.checkouts = checkouts
        self.remover = remover
        self.archiver = archiver
        self.focus = focus
        self.agents = agents
        self.launcher = launcher
        self.preferences = preferences
        self.prompter = prompter
        self.git = git
        self.setBadge = setBadge
        self.launchIterm = launchIterm
        self.itermRunning = itermRunning
        rows = SidebarProjection(workspace: workspace, live: live, checkouts: checkouts)
        projects = ProjectActions(workspace: workspace, work: work, notices: notices, prompter: prompter, checkouts: checkouts,
                                  agents: agents, git: git, workflow: workflow, jiraSettings: jiraSettings)
        terminals = TerminalActions(workspace: workspace, work: work, notices: notices, checkouts: checkouts, focus: focus,
                                    tiling: tiling, daemon: daemon, activateIterm: activateIterm)
        windows = WindowReconciler(helper: helper, workspace: workspace, work: work, live: live, checkouts: checkouts, focus: focus,
                                   remover: remover, archiver: archiver, launcher: launcher, terminals: terminals,
                                   notices: notices, daemon: daemon, now: now, closeHold: closedWindowHold, bringForward: bringForward, launchIterm: launchIterm)
        // The agents a task may run and their model lists are Settings › Agents', unless the caller named its own.
        var operatorPorts = operatorPorts
        if operatorPorts.installedVersions == nil { operatorPorts.installedVersions = { AgentVersions.shared.current($0) } }
        if operatorPorts.installedAgents == nil { operatorPorts.installedAgents = { [weak agents] in agents?.availableAgents ?? [] } }
        if operatorPorts.agentModels == nil {
            let catalogue = agents.catalogue
            operatorPorts.agentModels = { (try? catalogue.models(for: $0)) ?? [] }
        }
        // A broadcast freezes Settings › Operator's profile as these preferences keep it.
        if operatorPorts.profile == nil { operatorPorts.profile = agents.operatorProfile }
        // The delivery check's file beside the helper's others, read against the versions the Operator is told of;
        // Run check's window opens through the helper, tiled as a task's, and its closing reads the file again.
        let messaging = MessagingChecks(policyURL: AiTermPaths.deliveryPolicyURL(home: harnessHome),
                                        versions: operatorPorts.installedVersions ?? { _ in [:] })
        messaging.opener = MessagingChecks.Opener(daemon: daemon, runtime: { helper.runtime }, frame: { tiling.taskFrame() },
                                                  activateIterm: activateIterm)
        helper.onEvent { [weak messaging] event in
            if case .windowClosed(let window) = event { messaging?.windowClosed(window) }
        }
        self.messaging = messaging
        // After the window lock, which hands the live sessions each event first: the operators read
        // the operator's tab from them.
        let operatorController = OperatorController(workspace: workspace, live: live, notices: notices, daemon: daemon,
                                                    taskFrame: { tiling.taskFrame() }, ports: operatorPorts)
        self.operatorController = operatorController
        helper.onEvent { [weak operatorController] in operatorController?.handle($0) }
        helper.onAttach { [weak operatorController] in operatorController?.daemonAttached() }
        sheets = SheetCoordinator(workspace: workspace, checkouts: checkouts, agents: agents, git: git, harnessHome: harnessHome,
                                  jiraSettings: jiraSettings, gitLabSettings: gitLabSettings, gitHubSettings: gitHubSettings,
                                  launcher: launcher, workflow: workflow)
        // The connections as Settings saved them, read once per pass: a test's are none, so it
        // reads nothing from either host.
        reviewThreads = ReviewThreadsWatcher(workspace: workspace, focus: focus,
                                             connect: { ReviewThreadsReader(gitLab: gitLabSettings(), gitHub: gitHubSettings()) })
        // Its settings sit with the Interface tab's, so a test's scratch preferences cover both; its
        // 5 s check stays on while any tab in the workspace is working.
        backpack = BackpackController(ports: backpackPorts,
                                      settings: BackpackSettings(defaults: preferences.defaults, secrets: backpackSecrets),
                                      agentsWorking: { live.sessions.contains { $0.state == .working } },
                                      openLocationSettings: openLocationSettings,
                                      toast: { notices.showToast($0, symbol: BackpackController.symbol) })
        machine = MachineMonitor(sensor: machineSensor, power: backpackPorts.power)
        fixPipeline = { [agents] project in
            .live(git: git, workflow: workflow, project: project,
                  model: agents.fixModel,
                  locate: { HarnessCommandRunner.live.locate($0) })
        }
        // The rows are derived again whenever something they are made of may have changed, and the
        // Dock badge recounted when they did or a removal moved.
        live.onRowSessionsChanged { [weak self] in self?.refreshRows() }
        checkouts.onRowsChanged { [weak self] in self?.refreshRows() }
        remover.onRemovalsChanged { [weak self] in self?.updateDockBadge() }
        // What a change to the workspace sets off, once per change, in this order: whatever named a
        // row that has gone goes with it — its context fills and the banner about it — then the rows
        // are derived again if they changed, with the Dock badge counting what is left, and only
        // then does a gone task's removal entry go. The entry is what keeps a task on its way out
        // from being counted, so it outlasts the task's row in the sections: the other way round,
        // the badge would count the row once more between the two. Before any of these runs the
        // hook `focus` added as it was built, which drops a selection whose row went, in the same
        // change; so do the owners' `PerRow` hooks, which drop only cells no row reads. Weak: the
        // workspace outlives none of them, and each of them holds it.
        workspace.onChange { [weak live] in live?.pruneContexts() }
        workspace.onChange { [weak notices] in notices?.dropStale() }
        workspace.onChange { [weak self] in self?.refreshRows() }
        workspace.onChange { [weak remover] in remover?.pruneRemovals() }
        // The banner's Fix needs the agents and the pull, both built after the notices.
        notices.makesFixes { [weak self] in self?.makeFix(for: $0) }
        // A notification's click: an overview opens over the sidebar, a task's window comes forward.
        operatorPorts.notifications.onOpen = { [weak self] in self?.openNote($0) }
        // The broadcast row and the driven task rows read what the Operator is acting on, which the
        // operator controller owns; a change to it derives the rows again.
        let operators = operatorController
        rows.actingSource = { [weak operators] in operators?.acting ?? .none }
        operators.onChange { [weak self] in self?.refreshRows() }
        refreshRows()
        // A chosen broadcast without a window — closed, or its Operator offline — is the operator
        // controller's to reopen.
        focus.onChoosingOperationWithoutWindow { [weak operators] id, behind in
            Task { await operators?.reopenOperator(run: id, background: behind) }
        }
        // A driven task whose window you closed: its conversation resumed by the operator controller,
        // never a second worker beside a live one (integration decision 7). The row raises the window
        // it opened once the reopen is done.
        focus.onChoosingOperatedTaskWithoutWindow { [weak operators] id in
            Task { await operators?.reopenWorker(task: id) }
        }
        // A notification's click on a waiting plan, a done or a blocked operation opens its overview:
        // D7 records the request on the operator controller; this presents it, and any made before now.
        sheets.onDismiss = { [weak self] in self?.presentRequestedOverview() }
        presentRequestedOverview()
        watchOverviewRequests()
    }

    // -- workspace ------------------------------------------------------------------
    /// `workspace`'s, forwarded for the app's launch and the tests.
    func loadWorkspace() throws { try workspace.load() }
    func restoreWorkspace() throws { try workspace.restoreBackup() }

    /// Launch: Backpack Mode's crash recovery, the Mac's readings, the review threads, the checkout
    /// monitor, the agent CLI probes, the helper and the sweep of dead fixes' clones, each once.
    func start() {
        guard workspaceLoaded, agentProbe == nil else { return }
        let backpack = self.backpack
        Task { await backpack.launch() }
        machine.start()
        reviewThreads.start()
        checkouts.startMonitoring()
        if agents.shimURL.map({ BundleLocation.isTranslocated($0.path) }) == true { report(BundleLocation.translocationWarning) }
        let agents = self.agents
        // A login shell costing the better part of a second, as the helper's Python lookup is; neither waits on the other.
        agentProbe = Task { await agents.probe() }
        helper.start()
        operatorController.start()
        // A fix that crashed left its throwaway clone in the temp folder; only a dead owner's is swept.
        // Blocking disk work, so off the cooperative pool.
        DispatchQueue.global(qos: .utility).async { FixClone.sweep() }
        // The daemon launches iTerm2 only at its own start, which an AiTerm adopting the daemon a
        // previous one left running never causes: starting AiTerm is the person asking for it.
        if !itermRunning() { launchIterm() }
    }

    /// Stops everything `start()` started, Backpack Mode first — closed before quit waits on
    /// anything, so no turn-on can follow it — and the helper last: see `HelperLink.shutdown()`. A
    /// later `start()` starts it all again.
    func shutdown() {
        backpack.shutdown()
        machine.stop()
        reviewThreads.stop()
        agentProbe?.cancel()
        agentProbe = nil
        checkouts.stop()
        sheets.cancelPreparation()
        // A fix's agent runs in a process group of its own, which would outlive the app.
        notices.fixSession?.stop()
        if case .newReview(let model)? = sheet { model.fixSession?.stop() }
        focus.cancel()
        windows.stop()
        operatorController.stop()
        operatorController.tools.cancelChallenges()
        operatorController.tools.cancelReviews()
        helper.shutdown()
    }

    /// The Mac's rows' click and ⌘B. Backpack mode goes off at once; desk mode opens the sheet, unless
    /// another one is up. Ignored while it switches — a connect or turn-off, or the rejoin after the
    /// mode ended itself, which runs without `busy`.
    func toggleBackpack() {
        guard !backpack.busy, backpack.transition == nil else { return }
        if backpack.isOn {
            let backpack = self.backpack
            Task { await backpack.turnOff() }
        } else {
            sheets.presentBackpack(backpack)
        }
    }

    /// `windows`', forwarded for the tests: a window gone, as a request that found it gone reports it
    /// (it asks nothing; `window.closed` itself arrives through `helper.handle`).
    func handleWindowClosed(_ windowId: String?) { windows.handleWindowClosed(windowId) }

    // -- the rows and the Dock badge ------------------------------------------------
    /// Something the rows are made of may have changed: they are derived again if it did, and the
    /// badge recounted if a section changed.
    private func refreshRows() {
        if rows.refresh() { updateDockBadge() }
    }

    /// Only a changed label is written to the dock: this runs whenever a row's status may have
    /// moved — a section changed, a removal started or ended — and the label almost never changes.
    /// It counts what Focus View steps through, from the same rows.
    private func updateDockBadge() {
        let label = DockBadge.label(for: rows.sections, skippingTasks: remover.leavingTasks)
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        setBadge(label)
    }

    // -- projects -------------------------------------------------------------------
    /// `projects`', forwarded: the menus, the rows and the tests reach a project's edits here.
    func addProject() async { await projects.addProject() }
    func addProject(path: String) async { await projects.addProject(path: path) }
    func loadJiraProjects() async throws -> [JiraProjectRef] { try await projects.loadJiraProjects() }
    func setJiraProjects(_ jiraProjects: [JiraProjectRef], on project: Project) { projects.setJiraProjects(jiraProjects, on: project) }
    func isChangingDefaultBranch(_ projectId: UUID) -> Bool { projects.isChangingDefaultBranch(projectId) }
    @discardableResult
    func pullDefault(project: Project) -> Task<Void, Never>? { projects.pullDefault(project: project) }
    func toggleCollapsed(_ project: Project) { projects.toggleCollapsed(project) }
    func canMove(itemId: UUID, _ step: MoveStep) -> Bool { projects.canMove(itemId: itemId, step) }
    @discardableResult
    func move(itemId: UUID, _ step: MoveStep) -> Bool { projects.move(itemId: itemId, step) }
    func confirmRemove(project: Project) async { await projects.confirmRemove(project: project) }
    func addDivider(name: String) { projects.addDivider(name: name) }
    func removeDivider(_ divider: SidebarDivider) { projects.removeDivider(divider) }
    func rename(divider: SidebarDivider, to name: String) { projects.rename(divider: divider, to: name) }
    func rename(task: TaskItem, to name: String) { projects.rename(task: task, to: name) }
    func rename(terminal: TerminalItem, to name: String) { projects.rename(terminal: terminal, to: name) }

    // -- Focus View and List View -----------------------------------------------------
    /// Whether Focus View would do anything. Off behind a sheet, whose search fields are where ⌘F
    /// would otherwise land, and with no project that has rows (`SidebarModel.focusView`).
    var canShowFocusView: Bool { canApplyView(SidebarModel.focusView(rows.sections)) }
    /// Whether List View would do anything: off behind a sheet, as Focus View, and with no project
    /// that has rows to open.
    var canShowListView: Bool { canApplyView(SidebarModel.listView(rows.sections)) }

    /// ⌘F: opens every project with a done or needs-input row and folds the rest — all of them when
    /// nothing is waiting — in one save, then peeks at the first row waiting on you: selected and its
    /// window shown, the keyboard left in the sidebar and a task still unseen. With nothing waiting
    /// the selection stays. The peek is returned, when there is one.
    @discardableResult
    func showFocusView() -> Task<Void, Never>? {
        let sections = rows.sections
        guard applyView(SidebarModel.focusView(sections)) else { return nil }
        // A peek, as the arrows would: the keyboard stays here to arrow through what is waiting.
        // Forced: a waiting row already selected can have its window buried under others.
        guard let first = SidebarModel.firstNeedingAttention(sections, skippingTasks: remover.leavingTasks) else { return nil }
        return focus.peek(RowSelection(first), force: true)
    }
    /// ⌘L: opens every project with rows, in one save.
    func showListView() { applyView(SidebarModel.listView(rows.sections)) }

    private func canApplyView(_ layout: [UUID: Bool]) -> Bool {
        canChangeWorkspace && sheet == nil && !layout.isEmpty
    }

    /// Whether the layout was stored. A locked workspace is `projects.setCollapsed`'s to refuse, as
    /// every edit of its own is; `canApplyView` asks it too, but only to grey the menus.
    @discardableResult
    private func applyView(_ layout: [UUID: Bool]) -> Bool {
        guard sheet == nil, !layout.isEmpty else { return false }
        return projects.setCollapsed(layout)
    }

    // -- sheets ---------------------------------------------------------------------
    /// `sheets`', forwarded: the menus, the rows and the tests open a sheet here.
    var canPresentSettings: Bool { sheets.canPresentSettings }
    /// `agent` opens Agents at that agent's card: the sidebar's "Fix in Settings" for one that can't be messaged.
    func presentSettings(tab: SettingsTab? = nil, agent: AgentKind? = nil) { sheets.presentSettings(tab: tab, agent: agent) }
    var canPresentArchive: Bool { sheets.canPresentArchive }

    /// The Archive sheet, reading the archive as it is whenever it draws.
    func presentArchive() {
        sheets.presentArchive(ArchiveSheetModel(
            entries: { [weak self] in self?.state.archiveEntries ?? [] },
            restore: { [weak self] in self?.restoreArchived($0) },
            // A turn later, never inside the key handler that asked (`Prompter`).
            remove: { [weak self] id in Task { await self?.confirmRemove(archived: id) } }))
    }

    func presentJiraProjects(for project: Project) { sheets.presentJiraProjects(for: project) }
    func presentNewDivider() { sheets.presentNewDivider() }
    func presentRename(divider: SidebarDivider) { sheets.presentRename(divider: divider) }
    func presentRename(task: TaskItem) { sheets.presentRename(task: task) }
    func presentRename(terminal: TerminalItem) { sheets.presentRename(terminal: terminal) }
    func presentNewTask(project: Project) { sheets.presentNewTask(project: project) }
    func presentNewReview(project: Project) { sheets.presentNewReview(project: project) }
    func presentNewTerminal(project: Project) { sheets.presentNewTerminal(project: project) }

    // -- tasks ----------------------------------------------------------------------
    /// `launcher`'s, forwarded: the tests start a task here.
    func createTask(draft: TaskDraft, project: Project) async throws { try await launcher.createTask(draft: draft, project: project) }
    func createReview(draft: ReviewDraft, project: Project) async throws { try await launcher.createReview(draft: draft, project: project) }

    // -- the banner ------------------------------------------------------------------
    /// `notices`', forwarded: the views and the tests reach the banner and the toast here. The
    /// owners above report to `notices` itself.
    var issue: OperationIssue? { notices.issue }
    var toastState: ToastState { notices.toastState }
    func report(_ issue: OperationIssue) { notices.report(issue) }
    func report(_ message: String) { notices.report(message) }
    func dismissIssue() { notices.dismissIssue() }
    func showToast(_ message: String, symbol: String = "checkmark.circle.fill") { notices.showToast(message, symbol: symbol) }

    /// Answers the banner. Keeping or deleting a branch a removal kept is `remover`'s (see
    /// `TaskRemover.keepBranch(of:)`). Rebasing rewrites only local commits and aborts on a
    /// conflict, so it does not ask. Nil when nothing started: the question was declined, or the
    /// task or project is gone or busy.
    @discardableResult
    func perform(_ action: OperationIssue.Action) async -> Task<Void, Never>? {
        switch action {
        case .keepBranch(let id): return remover.keepBranch(of: id)
        case .deleteBranch(let id): return await remover.deleteBranch(of: id)
        case .rebaseDefault(let id):
            guard let project = state.project(id: id) else { return nil }
            return projects.rebaseDefault(project: project)
        }
    }

    /// The banner's Find a Fix for a refused Pull main or its rebase, as Help with problems allows: once
    /// the fix has landed, the banner goes, what waited behind it comes up, and the pull runs
    /// again — saying where the branch as it was is kept, however it ends, or in a toast when the
    /// project's default branch is no longer the one fixed. None for a problem
    /// another surface retries, or for a project that has gone.
    private func makeFix(for request: FixRequest) -> FixSession? {
        guard case .pullDefault(let id) = request.retry, let project = state.project(id: id) else { return nil }
        let resolution = agents.fixer
        let agent: FixerAgent? = if case .ready(let agent) = resolution { agent } else { nil }
        return FixSession(request: request, fixer: resolution, pipeline: fixPipeline(project)) { [weak self] landing in
            guard let self else { return }
            // Only this fix's banner: nothing replaces it while it lands, and the landed session is the shown one.
            if case .done? = notices.fixSession?.state { notices.clearIssue() }
            guard let project = state.project(id: id) else { return }
            // A default branch that is no longer the one fixed is not the pull this fix was for.
            let git = self.git
            let current = await BackgroundWork.run { Repository(project.path, git: git).defaultBranch() }
            guard current == landing.branch else { return notices.showToast(landing.keptSentence) }
            projects.pullDefault(project: project, after: (landing, agent))
        }
    }

    // -- removing a task ------------------------------------------------------------
    /// `remover`'s, forwarded: the views and the tests reach a task's removal here.
    var removals: [UUID: TaskRemoval] { remover.removals }
    func removal(of id: UUID) -> TaskRemoval? { remover.removal(of: id) }
    /// Whether the row's window could not be restored: its caption says so, and choosing it tries again.
    func hasFailedRestore(_ id: UUID) -> Bool { windows.hasFailed(id) }
    @discardableResult
    func confirmRemove(task: TaskItem) async -> Task<Void, Never>? { await remover.confirmRemove(task: task) }

    #if DEBUG
    /// The snapshot renderer's rows mid-removal, drawn without running one.
    func seedSnapshotRemoval(_ removal: TaskRemoval?, of id: UUID) { remover.seedSnapshotRemoval(removal, of: id) }
    #endif

    // -- archiving ------------------------------------------------------------------
    /// `archiver`'s, forwarded: the row's menu, the window-close question, the archive sheet and the tests
    /// archive and restore here.
    @discardableResult
    func archive(task: TaskItem) async -> Task<Void, Never>? { await archiver.archive(task: task) }
    @discardableResult
    func restoreArchived(_ id: UUID) -> Task<Void, Never>? { archiver.restore(id) }
    @discardableResult
    func confirmRemove(archived id: UUID) async -> Task<Void, Never>? { await archiver.confirmRemove(archived: id) }

    // -- terminals ------------------------------------------------------------------
    /// `terminals`', forwarded: the rows' menus, ⌘⌫ and the tests reach a terminal here.
    @discardableResult
    func newTerminal(project: Project, name: String) -> Task<Void, Never>? { terminals.newTerminal(project: project, name: name) }
    @discardableResult
    func close(terminal: TerminalItem) -> Task<Void, Never>? { terminals.close(terminal: terminal) }

    // -- the File menu -----------------------------------------------------------------
    /// The project File › New Task, New Review and New Terminal act on: the selected project header,
    /// or the project of the selected task, review or terminal row. `nil` with nothing selected, and
    /// the three items are off.
    var targetProject: Project? {
        switch focus.selection {
        case .project(let id): state.project(id: id)
        case .task(let id): state.task(id: id).flatMap { state.project(id: $0.projectId) }
        case .terminal(let id): state.terminal(id: id).flatMap { state.project(id: $0.projectId) }
        case .operation, nil: nil
        }
    }

    /// Whether the File menu's items can run at all: off behind a sheet, as the View items are, and
    /// while the workspace can't change.
    var canUseFileMenu: Bool { canChangeWorkspace && sheet == nil }
    /// New Terminal… needs a target project.
    var canCreateTerminal: Bool { canUseFileMenu && targetProject != nil }
    /// New Task… and New Review… need a target project with a provider, as the "+" menu has them.
    var canCreateTask: Bool { canUseFileMenu && targetProject.map { $0.provider != .none } == true }

    // -- the selected row -------------------------------------------------------------
    /// What a notification's click opens (spec §10.3): an operation's overview — the sidebar presents
    /// what `presentOverview` names — or the window of the task whose prompt waits on you.
    func openNote(_ target: OperatorNote.Target) {
        switch target {
        case .overview(let id): operatorController.presentOverview = id
        case .task(let id): focus.select(.task(id))
        }
    }

    /// ↩ on the list: a header folds or opens its project; the broadcast row opens its overview; any
    /// other row goes to its window. An empty project has nothing to fold, so its header opens its
    /// context menu — its first items are the ones that give it a row.
    @discardableResult
    func activateSelection() -> Task<Void, Never>? {
        if let project = focus.selectedProjectId.flatMap(state.project(id:)) {
            if projects.hasRows(project) {
                toggleCollapsed(project)
            } else {
                // Next turn, as an alert comes up (`Prompter`): the menu runs modally, and not
                // inside SwiftUI's key handler.
                RunLoop.main.perform { MainActor.assumeIsolated { self.openRowMenu(project.id) } }
            }
            return nil
        }
        // The broadcast row's ↩ is its click: the overview.
        if let id = focus.selectedOperationId { return openBroadcast(id) }
        return focus.activateSelection()
    }

    /// ⌘⌫ on the list: the selected row's own Remove, as its context menu has it — a task or a
    /// review asks first, a terminal just closes.
    @discardableResult
    func removeSelection() async -> Task<Void, Never>? {
        if let task = focus.selectedTaskId.flatMap(state.task(id:)) { return await confirmRemove(task: task) }
        if let terminal = focus.selectedTerminalId.flatMap(state.terminal(id:)) { return close(terminal: terminal) }
        return nil
    }
}

extension AppController {
    /// The real wiring: the person's `state.json`, Claude's folder and `~/.codex`, the app's bundle, the
    /// Keychain and a login shell for what they hold, modal alerts for questions, the Dock badge,
    /// Backpack Mode's live ports — `sudo pmset`, CoreWLAN, IOKit, CoreLocation — the Mac's load from Mach, and iTerm2 handed focus — AiTerm is frontmost when a row is chosen, so macOS lets it hand
    /// activation over. A caller that renders rather than runs (the snapshots) names what it
    /// replaces; everything else is what the app does.
    static func live(store: StateStore = StateStore(url: StateStore.defaultURL),
                     preferences: InterfacePreferences = InterfacePreferences(defaults: .standard),
                     harnessHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                     claudeConfig: ClaudeConfig = .loginShell,
                     bundledResourcesURL: URL? = Bundle.main.resourceURL,
                     locateAgents: @escaping @Sendable () -> Set<AgentKind>? = { AgentAvailability.installed() },
                     setBadge: @escaping @MainActor (String?) -> Void = { NSApplication.shared.dockTile.badgeLabel = $0 },
                     activateIterm: @escaping @MainActor () -> Void = {
                         NSRunningApplication.runningApplications(withBundleIdentifier: ItermPreferences.bundleIdentifier)
                             .first?.activate()
                     },
                     launchIterm: @escaping @MainActor () -> Void = {
                         guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ItermPreferences.bundleIdentifier)
                         else { return }
                         let configuration = NSWorkspace.OpenConfiguration()
                         configuration.activates = false
                         NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                     },
                     itermRunning: @escaping @MainActor () -> Bool = {
                         !NSRunningApplication.runningApplications(withBundleIdentifier: ItermPreferences.bundleIdentifier).isEmpty
                     },
                     backpackPorts: BackpackPorts = .live(),
                     machineSensor: any MachineSensor = LiveMachineSensor(),
                     scan: @escaping CheckoutMonitor.Scanner = {
                         WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5, defaultBranches: $6)
                     }) -> AppController {
        AppController(store: store, preferences: preferences, harnessHome: harnessHome, claudeConfig: claudeConfig, bundledResourcesURL: bundledResourcesURL,
                      locateAgents: locateAgents, findPython: { PythonLocator.find() },
                      jiraSettings: { JiraSettings.load() }, gitLabSettings: { GitLabSettings.load() },
                      gitHubSettings: { GitHubSettings.load() }, prompter: ModalPrompter(), setBadge: setBadge,
                      activateIterm: activateIterm, launchIterm: launchIterm, itermRunning: itermRunning,
                      bringForward: { AppController.bringAiTermForward() },
                      backpackPorts: backpackPorts, backpackSecrets: Keychain.shared,
                      openLocationSettings: {
                          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                      },
                      machineSensor: machineSensor,
                      peekDelay: .milliseconds(120), checkoutPollInterval: .seconds(2),
                      toastLifetime: .seconds(10), closedWindowHold: ClosedWindowTriage.hold, now: { .now },
                      git: GitRunner(), scan: scan, confirmsRemoval: TaskRemover.diskConfirmsRemoval,
                      operatorPorts: .live(home: harnessHome, git: GitRunner(), jiraSettings: { JiraSettings.load() }, claudeConfig: claudeConfig))
    }

    /// AiTerm brought forward for Remove's question about a window the person closed in iTerm2. macOS's
    /// cooperative activation may refuse an app that asks while another is frontmost, which would leave
    /// the alert behind iTerm2; if AiTerm is still not active a moment later, its Dock icon bounces
    /// until the person comes. A bounce stops by itself once AiTerm is active.
    @MainActor static func bringAiTermForward() {
        NSApplication.shared.activate()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !NSApplication.shared.isActive else { return }
            NSApplication.shared.requestUserAttention(.criticalRequest)
        }
    }
}
