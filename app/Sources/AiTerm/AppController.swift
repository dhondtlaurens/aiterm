import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// The app's composition root, and the one handle the views and the tests have on it. `init` builds
/// every owner below, each handed in its initializer the owners it calls, so each is built after
/// them: the workspace, the notices, the helper, the tabs, the tiling, the checkouts, the task
/// teardown, the selection, then the actions, the operators, the windows, the review threads, and
/// Backpack Mode and the Mac's readings last. What an owner tells one built after it goes out
/// through its `on…` hooks, which the later owner adds itself to as it is built; the checkout
/// monitor and the task teardown, which each call the other, are the one pair joined after both
/// exist (`CheckoutRemovals`). The sidebar's rows and the Dock badge are the controller's own. Views
/// and tests reach each owner directly through this handle; the actions here coordinate owners or
/// decide between them.
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
    /// Every row's iTerm2 window: a window gone leaves its row without one, a tagged window is taken,
    /// and a chosen row's window is opened.
    let windows: RowWindows
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
    /// cards' Messaging in Settings › Agents, and part of what New Signal waits for.
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
    /// Takes tasks down: Archive, Remove, removing an archived row, and the closing of one whose worktree went.
    let teardown: TaskTeardown
    /// The operations: their runs, their operators' tabs and tokens, and the services under them.
    let signalController: SignalOperatorController
    @ObservationIgnored private var agentProbe: Task<Void, Never>?

    /// Nothing here has a default: every dependency that reaches outside the process is one of `ports`, named by whoever
    /// builds a controller (`AppPorts`), and every wait one of `timings` (`AppTimings`). The app builds one with `live()`,
    /// the snapshots with `live` too and a few of their own, and a test with the scratch ports in its target, which touch
    /// none of them.
    init(preferences: InterfacePreferences, ports: AppPorts, timings: AppTimings) {
        let store = ports.store, harnessHome = ports.harnessHome, claudeConfig = ports.claudeConfig
        let bundledResourcesURL = ports.bundledResourcesURL, locateAgents = ports.locateAgents, findPython = ports.findPython
        let jiraSettings = ports.jiraSettings, gitLabSettings = ports.gitLabSettings, gitHubSettings = ports.gitHubSettings
        let prompter = ports.prompter, setBadge = ports.setBadge, activateIterm = ports.activateIterm
        let launchIterm = ports.launchIterm, itermRunning = ports.itermRunning
        let backpackPorts = ports.backpackPorts, backpackSecrets = ports.backpackSecrets
        let openLocationSettings = ports.openLocationSettings, machineSensor = ports.machineSensor, git = ports.git
        let scan = ports.scan
        let peekDelay = timings.peekDelay, checkoutPollInterval = timings.checkoutPollInterval
        let toastLifetime = timings.toastLifetime
        let workspace = WorkspaceStore(file: store), work = WorkInFlight(), workflow = TaskWorkflow(git: git)
        let notices = Notices(toastLifetime: toastLifetime,
                              isStale: { [weak workspace] issue in workspace.map { issue.isStale(in: $0.state) } ?? false })
        let helper = HelperLink(bundledResourcesURL: bundledResourcesURL, preferences: preferences, findPython: findPython, claudeConfig: claudeConfig, harnessHome: harnessHome,
                                notices: notices, connectionGrace: timings.connectionGrace)
        let daemon: @MainActor () -> (any DaemonCommands)? = { helper.daemon }
        let live = LiveSessions(workspace: workspace)
        let tiling = SidebarTiling(preferences: preferences, workspace: workspace, daemon: daemon)
        let checkouts = CheckoutMonitor(live: live, scan: scan, pollInterval: checkoutPollInterval, git: git, workspace: workspace,
                                        onTitles: { await helper.sendTitles($0) })
        let teardown = TaskTeardown(workspace: workspace, work: work, workflow: workflow, notices: notices, prompter: prompter,
                                    checkouts: checkouts, live: live, daemon: daemon, now: { Date() })
        let focus = RowFocus(peekDelay: peekDelay, workspace: workspace, daemon: daemon, taskFrame: { tiling.taskFrame() },
                             activateIterm: activateIterm, isRemoving: { teardown.isLeaving($0) }, notices: notices)
        let agents = AgentIntegrations(harnessHome: harnessHome, bundledResourcesURL: bundledResourcesURL, locateAgents: locateAgents,
                                       rememberedModels: { workspace.state.lastModelByAgent },
                                       defaults: preferences.defaults, claudeConfig: claudeConfig)
        // The agents, model lists and Operator profile come from Settings › Agents unless the caller supplied ports.
        let operatorPorts = ports.operatorPorts ?? .live(home: harnessHome, git: git, jiraSettings: jiraSettings, claudeConfig: claudeConfig,
                                                    agents: agents, preferences: preferences.defaults)
        let launcher = TaskLauncher(workspace: workspace, work: work, notices: notices, checkouts: checkouts, focus: focus,
                                    tiling: tiling, workflow: workflow, git: git, home: operatorPorts.home,
                                    workerGuardExecutable: operatorPorts.workerGuardExecutable, daemon: daemon)
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.helper = helper
        self.live = live
        self.tiling = tiling
        self.checkouts = checkouts
        self.teardown = teardown
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
        // The live sessions hear each helper event first: every other hook reads the tabs as that event left them.
        helper.onEvent { [weak live] in live?.handle($0) }
        // A window iTerm2 brought forward, by a click there or a notification, selects its row.
        helper.onEvent { [weak focus] event in
            if case .windowActivated(let window) = event { focus?.windowActivated(window) }
        }
        // The delivery check's file beside the helper's others, read against the versions the Operator is told of;
        // Run check's window opens through the helper, tiled as a task's, and its closing reads the file again.
        let messaging = MessagingChecks(policyURL: AiTermPaths.deliveryPolicyURL(home: harnessHome),
                                        versions: operatorPorts.installedVersions)
        messaging.opener = MessagingChecks.Opener(daemon: daemon, runtime: { helper.runtime }, frame: { tiling.taskFrame() },
                                                  activateIterm: activateIterm)
        self.messaging = messaging
        let signalController = SignalOperatorController(workspace: workspace, live: live, work: work, ports: operatorPorts,
                                                        daemon: daemon, frame: { tiling.taskFrame() })
        self.signalController = signalController
        signalController.readConnections = { SignalConnections(jira: jiraSettings(), gitLab: gitLabSettings(), gitHub: gitHubSettings()) }
        signalController.archive = { [teardown] task, allowed in try await teardown.archive(task, consent: .refuse(stillAllowed: allowed)) }
        signalController.remove = { [teardown] task, allowed in try await teardown.remove(task, consent: .refuse(stillAllowed: allowed)) }
        signalController.restore = { [launcher] id in
            guard let restored = try await launcher.restore(id) else { throw ActionUnavailable("The task is busy.") }
            return restored
        }
        signalController.checkout = { [launcher] task, allowed in try await launcher.checkOutWorker(task, stillAllowed: allowed).task }
        launcher.connections = { [weak signalController] in await signalController?.connections() ?? SignalConnections() }
        // After the operators, whose openers it calls; its event hook right after the live sessions' own.
        windows = RowWindows(helper: helper, workspace: workspace, work: work, live: live, checkouts: checkouts, focus: focus,
                             launcher: launcher, terminals: terminals, signalController: signalController, notices: notices,
                             daemon: daemon, launchIterm: launchIterm)
        helper.onEvent { [weak messaging] event in
            if case .windowClosed(let window) = event { messaging?.windowClosed(window) }
        }
        // After the live sessions and the rows' windows: the operators read the Operator's tab from the sessions.
        helper.onEvent { [weak signalController] in signalController?.handle($0) }
        helper.onAttach { [weak signalController] in signalController?.daemonAttached() }
        sheets = SheetCoordinator(projects: projects, workspace: workspace, checkouts: checkouts, agents: agents, git: git, harnessHome: harnessHome,
                                  jiraSettings: jiraSettings, gitLabSettings: gitLabSettings, gitHubSettings: gitHubSettings,
                                  launcher: launcher, defaults: preferences.defaults)
        projects.presentAdd = { [weak sheets] path in
            guard let sheets else { return }
            sheets.presentAddProject(path: path)
            await sheets.preparingSheet?.value
        }
        // The connections as Settings saved them, read once per pass: a test's are none, so it
        // reads nothing from either host.
        reviewThreads = ReviewThreadsWatcher(workspace: workspace, focus: focus,
                                             connect: { ReviewThreadsReader(gitLab: gitLabSettings(), gitHub: gitHubSettings()) })
        // Its settings sit with the Interface tab's, so a test's scratch preferences cover both; its
        // 5 s check stays on while any tab in the workspace is working.
        backpack = BackpackController(ports: backpackPorts,
                                      settings: BackpackSettings(defaults: preferences.defaults, secrets: backpackSecrets),
                                      agentsWorking: { live.sessions.contains { $0.state == .working } },
                                      operatorCanStartWork: { workspace.state.operatorMayStartWork },
                                      openLocationSettings: openLocationSettings,
                                      toast: { notices.showToast($0, symbol: BackpackController.symbol) })
        machine = MachineMonitor(sensor: machineSensor, power: backpackPorts.power)
        // The rows are derived again whenever something they are made of may have changed, the
        // tasks on their way out among them, and the Dock badge recounted when they did.
        live.onRowSessionsChanged { [weak self] in self?.refreshRows() }
        checkouts.onRowsChanged { [weak self] in self?.refreshRows() }
        teardown.onChanged { [weak self] in self?.refreshRows() }
        // What a change to the workspace sets off, once per change, in this order: whatever named a
        // row that has gone goes with it — its context fills and the banner about it — then the rows
        // are derived again if they changed, with the Dock badge counting what is left, then what a
        // teardown left on a gone task goes. Before any of these runs the hook `focus` added as it
        // was built, which drops a selection whose row went, in the same change; so do the owners'
        // `PerRow` hooks, which drop only cells no row reads. Weak: the workspace outlives none of
        // them, and each of them holds it.
        workspace.onChange { [weak live] in live?.pruneContexts() }
        workspace.onChange { [weak notices] in notices?.dropStale() }
        workspace.onChange { [weak self] in self?.refreshRows() }
        workspace.onChange { [weak teardown] in teardown?.pruneStates() }
        // A notification's click chooses the Operator's row or a task's, as a click on the row does.
        operatorPorts.notifications.onOpen = { [weak self] target in
            guard let self else { return }
            switch target {
            case .operatorWindow: self.choose(.operatorChat)
            case .task(let id): self.choose(.task(id))
            }
        }
        // A row chosen while iTerm2 was away is chosen again once it is synced, if it is still selected.
        windows.onPendingOpen { [weak self] row in
            guard let self else { return }
            let selection = RowSelection(row)
            if self.focus.selection == selection { self.choose(selection) }
        }
        // Rows read the Operator's current activity and issues from its controller; a change derives the rows again.
        rows.operatorIssue = { [weak self] in self?.signalController.statusIssue }
        rows.leaving = { [weak teardown] in teardown?.leaving ?? [] }
        rows.operatorActivity = { [weak self] in self?.signalController.activity.event }
        rows.operatorActs = { [weak self] in
            guard let activity = self?.signalController.activity else { return ([:], nil) }
            return (activity.actsByTask, activity.latestAct)
        }
        signalController.onChange { [weak self] in self?.refreshRows() }
        refreshRows()
    }

    // -- lifecycle ------------------------------------------------------------------
    /// Starts iTerm2 through the same launch port used at startup, without bringing it forward.
    func openIterm() { launchIterm() }

    /// Launch: Backpack Mode's crash recovery, the Mac's readings, the review threads, the checkout
    /// monitor, the agent CLI probes, the helper and the sweep of dead fixes' clones, each once.
    func start() {
        guard workspaceLoaded, agentProbe == nil else { return }
        let backpack = self.backpack
        Task { await backpack.launch() }
        machine.start()
        reviewThreads.start()
        checkouts.startMonitoring()
        if agents.shimURL.map({ BundleLocation.isTranslocated($0.path) }) == true { notices.report(BundleLocation.translocationWarning) }
        let agents = self.agents
        // A login shell costing the better part of a second, as the helper's Python lookup is; neither waits on the other.
        agentProbe = Task { await agents.probe() }
        helper.start()
        signalController.start()
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
        focus.cancel()
        windows.stop()
        signalController.stop()
        helper.shutdown()
    }

    /// The Mac's rows' click and ⌘B. Backpack Mode goes off at once; desk mode opens the sheet, unless
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

    // -- the rows and the Dock badge ------------------------------------------------
    /// Something the rows are made of may have changed: they are derived again if it did, and the
    /// badge recounted if a section changed.
    private func refreshRows() {
        if rows.refresh() { updateDockBadge() }
    }

    /// Only a changed label is written to the dock: this runs whenever a row's status may have
    /// moved — a section changed, a task started or stopped leaving — and the label almost never
    /// changes. It counts what Focus View steps through, from the same rows.
    private func updateDockBadge() {
        let count = rows.projectsNeedingAttention.count
        let label = count == 0 ? nil : String(count)
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        setBadge(label)
    }

    // Whether Focus View would change any project's collapsed state. A sheet keeps ⌘F for its search fields.
    var canShowFocusView: Bool { canApplyView(signalLayout(focus: true)) }
    /// Whether List View would open any project with rows. A sheet keeps the command disabled.
    var canShowListView: Bool { canApplyView(signalLayout(focus: false)) }

    /// ⌘F: opens projects and signals with a row needing attention, folds the rest in one save, then peeks
    /// at the first row waiting on you: selected and its window shown, the keyboard left in the sidebar
    /// and a task still unseen. With nothing waiting the selection stays. The peek is returned, when there
    /// is one.
    @discardableResult
    func showFocusView() -> Task<Void, Never>? {
        guard applyView(signalLayout(focus: true)) else { return nil }
        // A peek, as the arrows would: the keyboard stays here to arrow through what is waiting.
        // Forced: a waiting row already selected can have its window buried under others.
        guard let first = rows.projectsNeedingAttention.first else { return nil }
        return focus.peek(RowSelection(first), force: true)
    }
    /// ⌘L: opens every project with rows in one save.
    func showListView() { applyView(signalLayout(focus: false)) }

    private func signalLayout(focus: Bool) -> [UUID: Bool] {
        var layout = focus ? SidebarModel.focusView(rows.sections) : SidebarModel.listView(rows.sections)
        for section in rows.signalSections where !section.tasks.isEmpty {
            layout[section.id] = focus && !section.tasks.contains { $0.status == .needsInput }
        }
        return layout
    }

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
    /// `sheets`', forwarded: the menus grey behind an open sheet.
    var canPresentSettings: Bool { sheets.canPresentSettings }
    var canPresentArchive: Bool { sheets.canPresentArchive }

    /// The Archive, reading the current archived tasks and reviews whenever it draws.
    func presentArchive() {
        sheets.presentArchive(ArchiveSheetModel(
            entries: { [weak self] in self?.state.archiveEntries ?? [] },
            restore: { [weak self] id in Task { await self?.restoreFromArchive(id) } },
            // A turn later, never inside the key handler that asked (`Prompter`).
            remove: { [weak self] id in Task { await self?.removeFromArchive(id) } }))
    }

    /// A person's restore of an archived task or review (`TaskLauncher.restore`): git's refusal is said
    /// in an alert and the row stays archived; a row back has its project opened, is toasted, and is
    /// chosen as a click chooses it, which opens its window with its conversations resumed. Returns
    /// once that window has opened or the choosing gave up, or at once when nothing started.
    func restoreFromArchive(_ id: UUID) async {
        guard let archived = state.archived(id: id)?.task else { return }
        let restored: TaskItem?
        do { restored = try await launcher.restore(id) }
        catch {
            await prompter.ask(AlertPrompt(message: "“\(archived.title)” can’t be restored", detail: OperationIssue.reason(of: error)))
            return
        }
        guard let restored else { return }
        workspace.mutate { $0.updateProject(id: restored.projectId) { $0.collapsed = false } }
        if workspace.persistenceError == nil { notices.showToast("\(restored.kindName) restored.", symbol: "tray.and.arrow.up") }
        await choose(.task(id))?.value
    }

    /// Asks before removing an archived task or review, and returns once it is removed or not.
    func removeFromArchive(_ id: UUID) async {
        await teardown.removeArchived(id)
    }

    // -- the banner ------------------------------------------------------------------
    /// `notices`', forwarded: the views and the tests read the banner and the toast here.
    var issue: OperationIssue? { notices.issue }
    var toastState: ToastState { notices.toastState }

    /// Answers the banner. Rebasing rewrites only local commits and aborts on a conflict, so it
    /// does not ask. Returns once the action has ended, or at once when nothing started: the
    /// project is gone or busy.
    func perform(_ action: OperationIssue.Action) async {
        switch action {
        case .rebaseDefault(let id):
            guard let project = state.project(id: id) else { return }
            await projects.rebaseDefault(project: project)?.value
        }
    }

    // -- the File menu -----------------------------------------------------------------
    /// The project File › New Task, New Review and New Terminal act on: the selected project header,
    /// or the project of the selected task, review or terminal row. `nil` with nothing selected, and
    /// the three items are off.
    var targetProject: Project? {
        switch focus.selection {
        case .project(let id): state.project(id: id)
        case .task(let id): state.task(id: id).flatMap { state.project(id: $0.projectId) }
        case .terminal(let id): state.terminal(id: id).flatMap { state.project(id: $0.projectId) }
        case .operatorChat, .signal, nil: nil
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
    /// Return folds a populated project or signal; an empty project's header opens its menu.
    /// Other rows open their window through the managed focus path.
    @discardableResult
    func activateSelection() -> Task<Void, Never>? {
        if case .signal(let id) = focus.selection, let section = rows.signalSections.first(where: { $0.id == id }) {
            if !section.tasks.isEmpty { toggleCollapsed(section.signal) }
            return nil
        }
        if let project = focus.selectedProjectId.flatMap(state.project(id:)) {
            if projects.hasRows(project) {
                projects.toggleCollapsed(project)
            } else {
                // Next turn, as an alert comes up (`Prompter`): the menu runs modally, and not
                // inside SwiftUI's key handler.
                RunLoop.main.perform { MainActor.assumeIsolated { self.openRowMenu(project.id) } }
            }
            return nil
        }
        // Any other row as its click chooses it, while it is still a row.
        guard let selection = focus.selection else { return nil }
        switch selection {
        case .task(let id) where state.task(id: id) != nil: return choose(selection)
        case .operatorChat: return choose(selection)
        default: return focus.row(id: selection.id) != nil ? choose(selection) : nil
        }
    }

    /// A row's click or ↩, and every other way a row is chosen: a heading is only selected; a task,
    /// a terminal or the Operator's row has its window opened when it has none (`RowWindows.open`), and
    /// is selected and raised once that open ends (`RowFocus.select`).
    @discardableResult
    func choose(_ row: RowSelection) -> Task<Void, Never>? {
        switch row {
        case .project, .signal:
            focus.browse(row)
            return nil
        case .task(let id):
            return choose(task: id)
        case .terminal(let id):
            return openAndRaise(row, .terminal(id))
        case .operatorChat:
            return openAndRaise(row, .operatorChat)
        }
    }

    /// A task's choosing: a signal's task with a tab that asks, or its last foreground tab, brings that
    /// tab forward; a task on its way out is only selected; any other is opened if it has no window,
    /// then raised.
    @discardableResult
    func choose(task id: UUID) -> Task<Void, Never>? {
        if windows.itermSynced, let task = state.task(id: id), task.signalTask != nil, !teardown.isLeaving(id),
           let tab = task.tabToBring(sessions: live.sessions) { return bringTab(task: id, sessionId: tab.sessionId) }
        if teardown.isLeaving(id) { return focus.select(.task(id)) }
        return openAndRaise(.task(id), .task(id))
    }

    /// Opens `row`'s window if it has none, then selects and raises it. While iTerm2 is not synced the
    /// window the row last had may have gone with it: the row is only selected, iTerm2 is started and
    /// the row is chosen again once iTerm2 is synced (`RowWindows.onPendingOpen`).
    private func openAndRaise(_ row: RowSelection, _ window: WindowRow) -> Task<Void, Never>? {
        guard windows.itermSynced else {
            windows.open(window)
            focus.browse(row)
            return nil
        }
        return focus.select(row, after: windows.open(window))
    }

    /// ⌘⌫ on the list: the selected row's own Remove, as its context menu has it — a task or a
    /// review asks first, a terminal just closes. Returns once that has ended.
    func removeSelection() async {
        if let task = focus.selectedTaskId.flatMap(state.task(id:)) { try? await teardown.remove(task, consent: .ask) }
        else if let terminal = focus.selectedTerminalId.flatMap(state.terminal(id:)) { await terminals.close(terminal: terminal)?.value }
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
                         WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5)
                     }) -> AppController {
        // git with the login shell's PATH, so the hooks it runs (a lefthook pre-push) find Homebrew's node.
        let git = GitRunner(searchPath: { LoginShellLocator.shared.knownPath })
        let ports = AppPorts(store: store, harnessHome: harnessHome, claudeConfig: claudeConfig, bundledResourcesURL: bundledResourcesURL,
                             locateAgents: locateAgents, findPython: { PythonLocator.find() },
                             jiraSettings: { JiraSettings.load() }, gitLabSettings: { GitLabSettings.load() },
                             gitHubSettings: { GitHubSettings.load() }, prompter: ModalPrompter(), setBadge: setBadge,
                             activateIterm: activateIterm, launchIterm: launchIterm, itermRunning: itermRunning,
                             backpackPorts: backpackPorts, backpackSecrets: Keychain.shared,
                             openLocationSettings: {
                                 NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                             },
                             machineSensor: machineSensor, git: git, scan: scan,
                             operatorPorts: nil)
        return AppController(preferences: preferences, ports: ports, timings: .live)
    }
}
