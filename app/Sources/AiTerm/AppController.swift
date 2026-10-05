import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// A task on its way out, as its row says it: removed by the person — its window, its worktree,
/// maybe its branch — or closing because its worktree went outside AiTerm; or a removal that
/// stopped short of the row, and why. It is the row's own, so the banner above the list can come
/// and go — replaced by another report, or dismissed — without the row forgetting where it stands.
enum TaskRemoval: Equatable {
    case removing, closing
    /// What the row says in place of its "Window closed" or "Worktree missing". `worktreeRemoved`
    /// is a removal that got past the worktree: the row waits for the person's retry, and checkout
    /// cleanup, which would forget a row whose checkout went, leaves it be.
    case stopped(note: String, worktreeRemoved: Bool)

    /// Still running: the row's window is closing, or gone.
    var inProgress: Bool {
        if case .stopped = self { false } else { true }
    }

    /// Stopped after its worktree went, so the row is held for a retry.
    var awaitsRetry: Bool {
        if case .stopped(_, true) = self { true } else { false }
    }
}

/// The controller as the owners built in its `init` reach it: their closures capture this before
/// the controller exists, and `init`'s last line points it at the controller.
@MainActor
private final class ControllerLink {
    weak var controller: AppController?
}

/// Ids held by work in flight, each as many times as that work is running: two terminals can
/// open in one project at once, and the project is busy until both have.
private struct CountedSet {
    private var counts: [UUID: Int] = [:]
    mutating func insert(_ id: UUID) { counts[id, default: 0] += 1 }
    mutating func remove(_ id: UUID) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
    }
    func contains(_ id: UUID) -> Bool { counts[id] != nil }
}

@MainActor
@Observable
final class AppController {
    var state = AppState.empty {
        didSet {
            live.pruneContexts()
            pruneForgottenRows()
            updateDockBadge()
        }
    }
    let store: StateStore
    private(set) var workspaceLoaded = false
    private(set) var persistenceError: String?
    var canChangeWorkspace: Bool { workspaceLoaded && persistenceError == nil }

    var sheet: SheetKind?
    /// The failed operation the banner above the list shows. Set through `report`, cleared by
    /// `dismissIssue`, by an action that answers it, or once the task or project it names is gone.
    private(set) var issue: OperationIssue?
    private(set) var toastState = ToastState()

    /// The helper process, the connection to it and how far it reaches iTerm2.
    let helper: HelperLink
    /// The tabs, usage and context fills the helper reports.
    let live: LiveSessions
    /// The branches, missing checkouts and diffs on disk, read by a pass every two seconds.
    let checkouts: CheckoutMonitor
    /// The Interface tab's preferences. `tiling.setInterfaceSize` and `helper.setMatchItermBackground`
    /// change the two that act on a window; the badge switches are plain writes.
    let preferences: InterfacePreferences
    /// The sidebar window, and where each task's and terminal's window is put beside it.
    let tiling: SidebarTiling
    /// The selected row, and bringing its window forward.
    let focus: RowFocus
    /// The agent CLIs on this machine and AiTerm's hooks into them; probed at `start()`.
    let agents: AgentIntegrations
    /// Every modal question the app asks goes through here, so tests answer them from a script.
    let prompter: Prompter
    /// Backpack Mode: the menu item, Settings › Backpack and the header glyph read it.
    let backpack: BackpackController
    /// Opens a row's context menu from the keyboard (`RowMenuAnchor`). A test records the call
    /// instead: the menu tracks modally, and ending that stopped a test host's run loop.
    @ObservationIgnored var openRowMenu: @MainActor (UUID) -> Void = { RowMenuAnchor.openMenu(for: $0) }
    let git = GitRunner()
    /// The home whose agent configuration the sheets read — models, skills, commands. The
    /// person's own in the app; a test's is a bare directory of its own.
    private let harnessHome: URL
    /// Read the saved Jira, GitLab and GitHub connections. Each reads the Keychain (Jira and GitLab also
    /// UserDefaults), so they are called off the main actor.
    private let jiraSettings: @Sendable () -> JiraConfig?
    private let gitLabSettings: @Sendable () -> GitLabConfig?
    private let gitHubSettings: @Sendable () -> GitHubConfig?
    private let taskWorkflow = TaskWorkflow()
    /// Writes the Dock tile's badge. Only the app has a Dock tile to write, so the default is none.
    private let setBadge: @MainActor (String?) -> Void
    /// Brings iTerm2 forward once a new terminal's window is frontmost in it (`focus` does the same
    /// for a chosen row): the daemon raises the window inside iTerm2 but leaves the app behind
    /// AiTerm. Only the app activates anything, so the default is nothing.
    private let activateIterm: @MainActor () -> Void
    @ObservationIgnored private var dockBadgeLabel: String?

    @ObservationIgnored private var creatingProjects = Set<UUID>()
    /// Projects a new terminal's window, or a task's, is opening in: the project cannot be removed
    /// from under either.
    @ObservationIgnored private var creatingTerminals = CountedSet()
    @ObservationIgnored private var openingTaskWindows = CountedSet()
    @ObservationIgnored private var changingTasks = Set<UUID>()
    /// The tasks being removed, and how, and the removals that stopped short of the row: what
    /// their rows say. Observed, unlike `changingTasks` — the lock every task change takes —
    /// because the row draws it. An entry goes with its task.
    private(set) var removals: [UUID: TaskRemoval] = [:] {
        didSet { updateDockBadge() }
    }
    /// Tasks whose removal has dropped their window before closing it (`closeWindowBeforeRemoval`),
    /// until the removal ends.
    @ObservationIgnored private var windowsLetGo = Set<UUID>()
    /// The latest closing of a task whose checkout went outside AiTerm, while it runs.
    @ObservationIgnored private(set) var closingTask: Task<Void, Never>?
    /// Projects whose default branch is being pulled or rebased. Observed: the menu's Pull greys
    /// while either runs.
    private(set) var changingDefaultBranch = Set<UUID>()
    /// What a terminal's window is doing, one thing at a time.
    @ObservationIgnored private var changingTerminals: [UUID: TerminalChange] = [:]
    private enum TerminalChange { case reopening, closing }
    @ObservationIgnored private var agentProbe: Task<Void, Never>?
    @ObservationIgnored private var preparingSheet: Task<Void, Never>?

    /// `harnessHome` and `bundledResourcesURL` have no defaults: the app passes the person's home
    /// and its bundle, and anything else that builds a controller says which it means, so none
    /// reads the developer's own `~/.claude` or `~/.codex` by leaving them out. `peekDelay` is
    /// `RowFocus`'s; a test passes none, and awaits the peek instead.
    init(store: StateStore = StateStore(url: StateStore.defaultURL),
         preferences: InterfacePreferences,
         harnessHome: URL,
         bundledResourcesURL: URL?,
         locateAgents: @escaping @Sendable () -> Set<AgentKind>? = { AgentAvailability.installed() },
         findPython: @escaping @Sendable () -> URL? = { PythonLocator.find() },
         jiraSettings: @escaping @Sendable () -> JiraConfig? = { JiraSettings.load() },
         gitLabSettings: @escaping @Sendable () -> GitLabConfig? = { GitLabSettings.load() },
         gitHubSettings: @escaping @Sendable () -> GitHubConfig? = { GitHubSettings.load() },
         prompter: Prompter = ModalPrompter(),
         setBadge: @escaping @MainActor (String?) -> Void = { _ in },
         activateIterm: @escaping @MainActor () -> Void = {},
         backpackPorts: BackpackPorts = .inert,
         backpackSecrets: any SecretStore = MemorySecretStore(),
         peekDelay: Duration = .milliseconds(120),
         scan: @escaping CheckoutMonitor.Scanner = { WorkspaceScan.run(cwds: $0, projects: $1, tasks: $2, branches: $3, remotes: $4, diffs: $5, defaultBranches: $6) }) {
        let link = ControllerLink()
        self.store = store
        self.preferences = preferences
        self.harnessHome = harnessHome
        self.jiraSettings = jiraSettings
        self.gitLabSettings = gitLabSettings
        self.gitHubSettings = gitHubSettings
        let helper = HelperLink(bundledResourcesURL: bundledResourcesURL, preferences: preferences, findPython: findPython,
                                onEvent: { link.controller?.handleDaemonEvent($0) },
                                onAttach: { link.controller?.checkouts.refresh() }, // Retry checkout cleanup that waited for it.
                                reportError: { link.controller?.report($0) })
        self.helper = helper
        let tiling = SidebarTiling(preferences: preferences,
            tiledWindows: {
                guard let state = link.controller?.state else { return [] }
                return state.tasks.compactMap(\.windowId) + state.terminals.compactMap(\.windowId)
            },
            daemon: { helper.daemon },
            saveSidebarFrame: { frame in
                link.controller?.state.sidebarFrame = frame
                link.controller?.persist()
            })
        self.tiling = tiling
        focus = RowFocus(peekDelay: peekDelay, workspace: { link.controller?.state ?? .empty }, daemon: { helper.daemon },
                         taskFrame: { tiling.taskFrame() }, activateIterm: activateIterm,
                         isRemoving: { link.controller?.removals[$0]?.inProgress == true },
                         onWindowGone: { link.controller?.handleWindowClosed($0) },
                         report: { link.controller?.report($0) })
        let live = LiveSessions(workspace: { link.controller?.state ?? .empty },
                                sessionsChanged: { link.controller?.sessionsChanged($0) })
        self.live = live
        checkouts = CheckoutMonitor(live: live, scan: scan, workspace: { link.controller?.state ?? .empty },
            removalInFlight: { id in
                guard let controller = link.controller else { return false }
                return controller.changingTasks.contains(id) && controller.removals[id]?.awaitsRetry != true
            },
            onRemotes: { link.controller?.applyRemotes($0) },
            onRemovedTasks: { link.controller?.forgetRemovedCheckouts($0) },
            onTitles: { await helper.sendTitles($0, placedIn: $1) })
        self.prompter = prompter
        self.setBadge = setBadge
        self.activateIterm = activateIterm
        agents = AgentIntegrations(harnessHome: harnessHome, bundledResourcesURL: bundledResourcesURL, locateAgents: locateAgents,
                                   rememberedModels: { link.controller?.state.lastModelByAgent ?? [:] },
                                   availableAgentsChanged: { link.controller?.sheet?.creationModel?.availableAgents = $0 })
        backpack = BackpackController(ports: backpackPorts,
                                      settings: BackpackSettings(defaults: preferences.defaults, secrets: backpackSecrets),
                                      openLocationSettings: {
                                          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                                      },
                                      toast: { link.controller?.showToast($0, symbol: BackpackController.symbol) })
        link.controller = self
    }

    // -- workspace ------------------------------------------------------------------
    func loadWorkspace() throws {
        guard !workspaceLoaded else { return }
        state = try store.load()
        workspaceLoaded = true
    }

    func restoreWorkspace() throws {
        state = try store.restoreBackup()
        workspaceLoaded = true
        persistenceError = nil
    }

    @discardableResult
    func persist() -> Bool {
        guard workspaceLoaded else { return false }
        do {
            try store.save(state)
            if persistenceError != nil { persistenceError = nil }
            return true
        } catch {
            persistenceError = "Changes haven’t been saved. " + error.localizedDescription
            return false
        }
    }

    /// Launch: the checkout monitor, the agent CLI probes and the helper, each once.
    func start() {
        guard workspaceLoaded, agentProbe == nil else { return }
        let backpack = self.backpack
        Task { await backpack.launch() }
        checkouts.startMonitoring()
        if agents.shimURL.map({ BundleLocation.isTranslocated($0.path) }) == true { report(BundleLocation.translocationWarning) }
        let agents = self.agents
        // A login shell costing the better part of a second, as the helper's Python lookup is; neither waits on the other.
        agentProbe = Task { await agents.probe() }
        helper.start()
    }

    /// Stops everything `start()` started, the helper last: see `HelperLink.shutdown()`. A later
    /// `start()` starts it all again.
    func shutdown() {
        backpack.shutdown()
        agentProbe?.cancel()
        agentProbe = nil
        checkouts.stop()
        preparingSheet?.cancel()
        focus.cancel()
        helper.shutdown()
    }

    /// Completion feedback disappears on its own, after long enough to read a sentence — some say
    /// what was kept and why. The id means an older delayed dismissal cannot hide a newer toast.
    private func showToast(_ message: String, symbol: String = "checkmark.circle.fill") {
        let id = toastState.show(message, symbol: symbol)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.toastState.dismiss(id: id)
        }
    }

    // -- what the helper reports ----------------------------------------------------
    /// The helper's events, after `helper` has taken its own.
    private func handleDaemonEvent(_ event: DaemonEvent) {
        live.handle(event)
        switch event {
        case .snapshot(let snapshot):
            guard snapshot.connected else { return }
            // Only a successful connected snapshot establishes that a window is absent.
            // Reattach by stable task tags first, including a create whose reply was lost.
            // Worked on a copy: every write to `state` is a sidebar re-render and a dock-badge update.
            var next = state
            let tabByTask = Dictionary(snapshot.sessions.compactMap { tab in tab.taskUUID.map { ($0, tab) } },
                                       uniquingKeysWith: { first, _ in first })
            // A task whose removal has let its window go is the removal's to settle: re-attached,
            // the window would take the row with it when it closes.
            for index in next.tasks.indices where !windowsLetGo.contains(next.tasks[index].id) {
                if let session = tabByTask[next.tasks[index].id] { next.tasks[index].windowId = session.windowId }
            }
            let windows = Set(snapshot.sessions.map(\.windowId))
            let closed = Set((next.tasks.compactMap(\.windowId) + next.terminals.compactMap(\.windowId))
                .filter { !windows.contains($0) })
            for wid in closed { next.closeWindow(wid) }
            guard next != state else { return }
            commitClosedWindows(next)
        case .itermConnected, .itermDisconnected, .itermAuthFailed, .itermCookieRequested: break // last observations remain visible while uncertain
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): handleWindowClosed(wid)
        case .sessionOpened, .sessionChanged, .sessionClosed, .usageChanged, .unknown: break // `live`'s, or nobody's
        }
    }

    func handleWindowClosed(_ windowId: String?) {
        guard let windowId else { return }
        var next = state
        guard next.closeWindow(windowId) else { return }
        commitClosedWindows(next)
    }

    /// The one closed-window transition — for `window.closed`, a connected snapshot and a request
    /// that found its window gone: adopt the new workspace, drop a selection whose row went with it,
    /// rescan checkouts when a task went, and save.
    private func commitClosedWindows(_ next: AppState) {
        let tasksRemoved = next.tasks.count != state.tasks.count
        state = next
        if tasksRemoved { checkouts.refresh() }
        focus.dropStale()
        persist()
    }

    /// Whatever named a row that is gone goes with it — through `window.closed`, a removed project,
    /// a restored backup or a removal — in this one place: the banner about it, and its removal's
    /// entry. Runs on every write to `state`, so it writes only what changed.
    private func pruneForgottenRows() {
        if let issue, issue.isStale(in: state) { self.issue = nil }
        guard !removals.isEmpty else { return }
        let kept = removals.filter { state.task(id: $0.key) != nil }
        if kept.count != removals.count { removals = kept }
    }

    /// Every write to the tabs, whichever event brought it.
    private func sessionsChanged(_ sessions: [SessionInfo]) {
        checkouts.sessionsChanged(sessions)
        updateDockBadge()
    }

    /// Only a changed label is written to the dock: this runs on every write to `state`, `sessions`
    /// and `removals`, several a second, and the label almost never changes. It counts what Focus
    /// View steps through, from the same rows.
    private func updateDockBadge() {
        let label = DockBadge.label(for: liveSections, skippingTasks: leavingTasks)
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        setBadge(label)
    }

    // -- projects -------------------------------------------------------------------
    /// The folder chooser adds the project at once: its Jira projects are linked afterwards, from
    /// the project's context menu, and none linked means New Task searches every Jira project.
    @discardableResult
    func addProject() -> Task<Void, Never>? {
        guard canChangeWorkspace, let url = prompter.chooseFolder(prompt: "Add Project"), canChangeWorkspace else { return nil }
        return Task { await addProject(path: url.path) }
    }

    /// The repository a picked folder belongs to, added with its remote, then the offer to import
    /// its worktrees. A folder inside a repository adds the repository itself, and a toast says so;
    /// one already in the workspace is refused.
    func addProject(path picked: String) async {
        guard canChangeWorkspace else { return }
        let git = self.git
        let inspection = try? await BackgroundWork.run {
            let top = try Worktrees.toplevel(of: picked, git: git)
            let path = top ?? picked
            return (top, path, top == nil ? nil : Worktrees.remoteUrl(repo: path, git: git))
        }
        guard canChangeWorkspace, let (toplevel, path, remote) = inspection else { return }
        if let existing = state.projects.first(where: { $0.path == path }) {
            prompter.ask(AlertPrompt(message: "\(existing.name) is already in your projects", detail: existing.path))
            return
        }
        let provider = ProviderDetector.detect(remoteUrl: remote, repoPath: toplevel == nil ? nil : path).provider
        let project = Project(id: UUID(), name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                              provider: provider, remoteUrl: remote, addedAt: Date(), collapsed: false)
        state.append(project: project)
        guard persist() else { return }
        checkouts.refresh()
        if let toplevel, toplevel != picked { showToast("Added \(project.name), the repository around the folder you picked.") }
        await importWorktrees(for: project)
    }

    private func importWorktrees(for project: Project) async {
        guard project.provider != .none else { return }
        let git = self.git, home = harnessHome
        let agent = state.lastAgentByProject[project.id] ?? .claude
        let remembered = state.lastModelByAgent[agent]
        let imports = try? await BackgroundWork.run {
            (try Worktrees.existing(repo: project.path, git: git), Worktrees.defaultBranch(repo: project.path, git: git),
             ModelSettings.resolve(for: agent, catalog: ModelCatalog.models(for: agent, home: home), remembered: remembered))
        }
        guard canChangeWorkspace, state.project(id: project.id) != nil,
              let (found, base, preference) = imports, !found.isEmpty else { return }
        let answer = prompter.ask(AlertPrompt(message: "Import \(found.count) worktree\(found.count == 1 ? "" : "s")?",
                                              detail: "Adds existing worktrees as tasks without starting agents.",
                                              buttons: ["Import", "Skip"], escape: 1))
        // `runModal` runs whatever was queued while the alert was up; the project can have gone.
        guard answer.confirmed, canChangeWorkspace, state.project(id: project.id) != nil else { return }
        let known = Set(state.tasks.map(\.worktreePath))
        state.tasks += found.compactMap { worktree in
            guard let branch = worktree.branch, !known.contains(worktree.path) else { return nil }
            return TaskItem(id: UUID(), projectId: project.id, title: branch, branch: branch,
                     worktreePath: worktree.path, baseBranch: base, jira: nil, kind: Self.importedKind(worktree),
                     agent: agent, model: preference.model,
                     reasoning: preference.reasoning, firstPrompt: nil, appendTicket: true, createdAt: Date(), windowId: nil)
        }
        persist()
    }

    /// Which kind an imported worktree is. This is the whole reason `Worktrees.existing` reports a
    /// lock reason: removing a project leaves its worktrees on disk, so re-adding it re-imports
    /// them, and an import that guessed `.task` for a review would hand `confirmRemove(task:)` an
    /// "Also delete branch" checkbox over a merge request's branch — the one thing this app must
    /// never do.
    ///
    /// The lock reason `Worktrees.checkout` writes is the authority. The `review-` directory
    /// prefix is a weaker fallback for a worktree whose lock was dropped by hand or lost in a copy
    /// of the repository; it can mislabel a task on a branch like `feat/review-dashboard`, which
    /// costs that task its delete-branch checkbox and nothing else. The costs are not symmetric.
    private static func importedKind(_ worktree: Worktree) -> TaskKind? {
        if worktree.lockReason == Worktrees.reviewLockReason { return .review }
        return URL(fileURLWithPath: worktree.path).lastPathComponent.hasPrefix("review-") ? .review : nil
    }

    /// Adopts a remote added, changed or removed after the project itself was — `git remote add` in
    /// a terminal is not something the app can be told about, and the stored value is what the
    /// provider badge and every merge-request link are built from, so a stale one outlives the
    /// change indefinitely.
    private func applyRemotes(_ detected: [UUID: WorkspaceScan.Remote]) {
        var next = state
        for (id, found) in detected {
            next.updateProject(id: id) { project in
                guard project.provider != found.provider || project.remoteUrl != found.url else { return }
                project.provider = found.provider; project.remoteUrl = found.url
            }
        }
        guard next != state else { return }
        state = next
        persist()
    }

    /// The connection is a Keychain read, so it is made off the main actor.
    func loadJiraProjects() async throws -> [JiraProjectRef] {
        guard let config = try await BackgroundWork.run(jiraSettings) else {
            throw ActionUnavailable("Connect Jira in Settings › Integrations to choose a Jira project.")
        }
        return try await JiraClient(config: config).projects()
    }

    /// The sheet that edits the project's linked Jira projects, opened on the list as it is now.
    func presentJiraProjects(for project: Project) {
        guard canChangeWorkspace, let current = state.project(id: project.id) else { return }
        sheet = .jiraProjects(current)
    }

    /// Replaces the project's linked Jira projects with `jiraProjects`, each once, in their order.
    /// An empty list unlinks them all.
    func setJiraProjects(_ jiraProjects: [JiraProjectRef], on project: Project) {
        let linked = Self.linkedOnce(jiraProjects)
        guard canChangeWorkspace, let current = state.project(id: project.id),
              current.jiraProjects != linked else { return }
        state.updateProject(id: project.id) { $0.jiraProjects = linked }
        persist()
    }

    /// `jiraProjects` with every repeat of a project after its first dropped.
    private static func linkedOnce(_ jiraProjects: [JiraProjectRef]) -> [JiraProjectRef] {
        var seen = Set<String>()
        return jiraProjects.filter { seen.insert($0.id).inserted }
    }

    /// "Pull main": the project's default branch brought to origin's, fast-forward only. Git's
    /// own state, not the workspace's, so a locked workspace does not stop it.
    @discardableResult
    func pullDefault(project: Project) -> Task<Void, Never>? {
        changeDefaultBranch(of: project, { [taskWorkflow] in try await taskWorkflow.pullDefaultBranch(of: project).summary },
                            failure: { .pullRefused($0, in: project.id) })
    }

    /// The banner's Rebase, after "Pull main" found the branches diverged. Held like a pull, so
    /// the menu's Pull main waits for it.
    private func rebaseDefault(project: Project) -> Task<Void, Never>? {
        let rebase = changeDefaultBranch(of: project, { [taskWorkflow] in try await taskWorkflow.rebaseDefaultBranch(of: project).summary },
                                         failure: { OperationIssue(title: "Couldn’t rebase the default branch.", error: $0) })
        if rebase != nil { issue = nil }
        return rebase
    }

    /// A pull or a rebase of `project`'s default branch, one at a time: its summary is the toast,
    /// its failure the banner. Neither is shown for a project removed while git ran.
    private func changeDefaultBranch(of project: Project, _ run: @escaping () async throws -> String,
                                     failure: @escaping (Error) -> OperationIssue) -> Task<Void, Never>? {
        guard changingDefaultBranch.insert(project.id).inserted else { return nil }
        return Task {
            defer { changingDefaultBranch.remove(project.id) }
            do {
                let summary = try await run()
                guard state.project(id: project.id) != nil else { return }
                showToast(summary)
                checkouts.refresh()
            } catch {
                guard state.project(id: project.id) != nil else { return }
                report(failure(error))
            }
        }
    }

    /// A project with no task or terminal draws collapsed and stays that way (`ProjectSection.collapsed`),
    /// so it has no stored state worth flipping.
    func toggleCollapsed(_ project: Project) {
        guard canChangeWorkspace, state.project(id: project.id) != nil, hasRows(project) else { return }
        state.updateProject(id: project.id) { $0.collapsed.toggle() }
        persist()
    }

    /// Whether the project has a task, review or terminal row — anything to fold.
    func hasRows(_ project: Project) -> Bool {
        state.tasks.contains(where: { $0.projectId == project.id })
            || state.terminals.contains(where: { $0.projectId == project.id })
    }

    /// Whether Focus View would do anything. Off behind a sheet, whose search fields are where ⌘F
    /// would otherwise land, and with no project that has rows (`SidebarModel.focusView`).
    var canShowFocusView: Bool { canApplyView(SidebarModel.focusView(liveSections)) }
    /// Whether List View would do anything: off behind a sheet, as Focus View, and with no project
    /// that has rows to open.
    var canShowListView: Bool { canApplyView(SidebarModel.listView(liveSections)) }

    /// ⌘F: opens every project with a done or needs-input row and folds the rest — all of them when
    /// nothing is waiting — in one save, then peeks at the first row waiting on you: selected and its
    /// window shown, the keyboard left in the sidebar and a task still unseen. With nothing waiting
    /// the selection stays. The peek is returned, when there is one.
    @discardableResult
    func showFocusView() -> Task<Void, Never>? {
        let sections = liveSections
        guard applyView(SidebarModel.focusView(sections)) else { return nil }
        // A peek, as the arrows would: the keyboard stays here to arrow through what is waiting.
        // Forced: a waiting row already selected can have its window buried under others.
        guard let first = SidebarModel.firstNeedingAttention(sections, skippingTasks: leavingTasks) else { return nil }
        return focus.peek(first.isTerminal ? .terminal(first.id) : .task(first.id), force: true)
    }
    /// ⌘L: opens every project with rows, in one save.
    func showListView() { applyView(SidebarModel.listView(liveSections)) }

    private func canApplyView(_ layout: [UUID: Bool]) -> Bool {
        canChangeWorkspace && sheet == nil && !layout.isEmpty
    }

    /// Stores `layout`'s collapsed states in one write to `state`, and saves only if one changed.
    @discardableResult
    private func applyView(_ layout: [UUID: Bool]) -> Bool {
        guard canApplyView(layout) else { return false }
        var next = state
        for (id, collapsed) in layout {
            next.updateProject(id: id) { if $0.collapsed != collapsed { $0.collapsed = collapsed } }
        }
        if next != state {
            state = next
            persist()
        }
        return true
    }

    /// The tasks on their way out, which Focus View and the Dock badge pass over: their windows are
    /// closing.
    private var leavingTasks: Set<UUID> { Set(removals.filter(\.value.inProgress).keys) }

    /// The same live rows the sidebar draws, so Focus View opens what shows blue or orange.
    /// Statuses come from the tabs alone; branches play no part.
    private var liveSections: [ProjectSection] {
        SidebarModel.sections(state: state, sessions: live.rowSessions, branchByCwd: [:], projectBranch: [:])
    }

    /// Whether `move` would do anything: the first row has no "up", the last no "down", and a
    /// locked workspace has neither. The menus grey their items on this.
    func canMove(itemId: UUID, _ step: MoveStep) -> Bool {
        canChangeWorkspace && state.canMove(id: itemId, step)
    }

    /// Moves a project or a divider one slot along the sidebar. Only the item order changes: tasks
    /// and terminals stay attached by project id, so an expanded project's rows move with it and
    /// its collapsed state is left untouched.
    @discardableResult
    func move(itemId: UUID, _ step: MoveStep) -> Bool {
        guard canChangeWorkspace, state.move(id: itemId, step) else { return false }
        return persist()
    }

    /// Plan self-review (spec 4.6): removing a project only forgets it. Worktrees created for its
    /// tasks stay on disk — the alert lists them so nothing disappears silently — and no git
    /// command runs.
    func confirmRemove(project: Project) {
        guard canChangeWorkspace, !refusesRemoval(of: project) else { return }
        let tasks = state.tasks.filter { $0.projectId == project.id }
        let paths = tasks.map(\.worktreePath)
        let answer = prompter.ask(AlertPrompt(
            message: "Remove project “\(project.name)”?",
            detail: paths.isEmpty
                ? "Removes the project from AiTerm. Files are kept and terminal windows stay open."
                : "Removes the project, tasks, and terminals from AiTerm. Files and windows are kept, including these worktrees:\n\n" + paths.joined(separator: "\n"),
            buttons: ["Remove", "Cancel"]))
        // The alert's modal loop runs whatever was queued meanwhile, a create among them.
        guard answer.confirmed, canChangeWorkspace, !refusesRemoval(of: project) else { return }
        var next = state
        next.tasks.removeAll { $0.projectId == project.id }
        next.terminals.removeAll { $0.projectId == project.id }
        next.removeItem(id: project.id)
        state = next
        focus.dropStale()
        persist()
    }

    /// Says why `project` cannot be removed yet, if it cannot: work still in flight would land in a
    /// project that is gone, and a row whose project is gone fails every save.
    private func refusesRemoval(of project: Project) -> Bool {
        let busy: String
        if creatingProjects.contains(project.id) { busy = "A task is still being created in it." }
        else if creatingTerminals.contains(project.id) { busy = "A terminal is still opening in it." }
        else if openingTaskWindows.contains(project.id) { busy = "A window is still opening for one of its tasks." }
        else if state.terminals.contains(where: { $0.projectId == project.id && changingTerminals[$0.id] != nil }) {
            busy = "One of its terminals is still opening or closing its window."
        }
        else if !changingTasks.isEmpty { busy = "A task is still being changed." }
        else { return false }
        prompter.ask(AlertPrompt(message: "“\(project.name)” can’t be removed yet", detail: busy + " Try again in a moment."))
        return true
    }

    // -- dividers and renames -------------------------------------------------------
    func presentNewDivider() {
        guard canChangeWorkspace else { return }
        sheet = .newDivider
    }

    /// A divider is pure workspace state: no daemon call, no window, nothing to undo but the label.
    func addDivider(name: String) {
        guard canChangeWorkspace else { return }
        state.append(divider: SidebarDivider(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        persist()
    }

    func removeDivider(_ divider: SidebarDivider) {
        guard canChangeWorkspace else { return }
        state.removeItem(id: divider.id)
        persist()
    }

    func presentRename(divider: SidebarDivider) {
        guard canChangeWorkspace else { return }
        sheet = .rename(.divider(divider))
    }

    func presentRename(task: TaskItem) {
        guard canChangeWorkspace else { return }
        sheet = .rename(.task(task))
    }

    /// An empty name is a real choice for a divider — the row draws a plain rule.
    func rename(divider: SidebarDivider, to name: String) {
        guard canChangeWorkspace else { return }
        state.renameDivider(id: divider.id, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
        persist()
    }

    /// The title only. The branch, worktree, base branch and Jira link are untouched, and the
    /// iTerm2 window keeps its own title — it carries the branch, not the task's name.
    func rename(task: TaskItem, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = state.tasks.firstIndex(where: { $0.id == task.id }),
              state.tasks[i].title != trimmed else { return }
        state.tasks[i].title = trimmed
        persist()
    }

    func presentRename(terminal: TerminalItem) {
        guard canChangeWorkspace, let current = state.terminal(id: terminal.id) else { return }
        sheet = .rename(.terminal(current))
    }

    /// The row's name, and the one its window is opened with on Reopen. Nothing in iTerm2 changes:
    /// its tabs are titled with their branch (`SidebarModel.sessionTitles`), not with this name,
    /// and the window's profile name is set once, as it opens. An empty name keeps the old one.
    func rename(terminal: TerminalItem, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = state.terminals.firstIndex(where: { $0.id == terminal.id }),
              state.terminals[i].name != trimmed else { return }
        state.terminals[i].name = trimmed
        persist()
    }

    // -- sheets ---------------------------------------------------------------------
    /// Settings opens on the saved connections, read off the main actor: two Keychain items and
    /// UserDefaults, which can take a moment, and a Keychain that asks for access longer still.
    /// Off behind another sheet, as the zoom and view items are: Settings would replace it, and a
    /// New Task draft with it.
    var canPresentSettings: Bool { sheet == nil }

    func presentSettings(tab: SettingsTab? = nil) {
        guard canPresentSettings else { return }
        preparingSheet?.cancel()
        let jira = jiraSettings, gitLab = gitLabSettings, gitHub = gitHubSettings
        preparingSheet = Task {
            let saved = try? await BackgroundWork.run { (jira: jira(), gitLab: gitLab(), gitHub: gitHub()) }
            guard !Task.isCancelled, let saved, canPresentSettings else { return }
            sheet = .settings(jira: saved.jira, gitLab: saved.gitLab, gitHub: saved.gitHub, tab: tab)
        }
    }

    /// Builds the draft once, here, and hands it to the sheet (see `SheetKind`): SwiftUI re-creates
    /// a sheet's root view on every state change of the presenting view, and a draft costs a git
    /// call and a read of the agent's model catalogue.
    func presentNewTask(project: Project) {
        let git = self.git
        prepareSheet(for: project, draft: { TaskDraft.initial(project: project, state: $0, git: git, agent: $1, catalog: $2) },
                     search: jiraSettings) { [unowned self] in
            .newTask(makeCreationModel(project: project, draft: $0, catalogue: $1, jira: $2))
        }
    }

    func presentNewReview(project: Project) {
        let gitLab = gitLabSettings, gitHub = gitHubSettings
        prepareSheet(for: project, draft: { ReviewDraft.initial(state: $0, agent: $1, catalog: $2) },
                     search: { (gitLab: gitLab(), gitHub: gitHub(),
                                remote: ProviderDetector.detect(remoteUrl: project.remoteUrl, repoPath: project.path)) }) { [unowned self] in
            .newReview(makeReviewModel(project: project, draft: $0, catalogue: $1, gitLab: $2.gitLab, gitHub: $2.gitHub, remote: $2.remote))
        }
    }

    /// The remembered agent may be one that is no longer installed, so the draft falls back to an
    /// available one — the sheet's picker disables the missing ones and says why. The agent's
    /// catalogue is read once, for the draft, and handed to the sheet's model with it: for PI it
    /// is a launch of the CLI. `search` is read here too — what the sheet's search needs from the
    /// Keychain and the checkout — so no keystroke has to.
    private func prepareSheet<Draft, Search>(for project: Project,
                                             draft build: @escaping @Sendable (AppState, AgentKind, [AgentModel]) -> Draft,
                                             search resolve: @escaping @Sendable () -> Search,
                                             sheet makeSheet: @escaping (Draft, [AgentModel], Search) -> SheetKind)
        where Draft: AgentDraft & Sendable, Search: Sendable {
        guard canChangeWorkspace else { return }
        preparingSheet?.cancel()
        let state = self.state, available = agents.availableAgents, home = harnessHome
        let agent = AgentAvailability.agent(preferring: state.lastAgentByProject[project.id] ?? .claude, available: available)
        preparingSheet = Task {
            let prepared = try? await BackgroundWork.run {
                let catalog = ModelCatalog.models(for: agent, home: home)
                return (draft: build(state, agent, catalog), catalog: catalog, search: resolve())
            }
            guard !Task.isCancelled, canChangeWorkspace, let prepared,
                  self.state.project(id: project.id) != nil else { return }
            sheet = makeSheet(prepared.draft, prepared.catalog, prepared.search)
        }
    }

    /// `catalogue` is the one `draft` was built from, if the caller read it; `jira` is the
    /// connection read when the sheet was prepared.
    func makeCreationModel(project: Project, draft: TaskDraft, catalogue: [AgentModel]? = nil, jira: JiraConfig?) -> TaskCreationModel {
        let home = harnessHome
        return TaskCreationModel(project: project, draft: draft, home: home, availableAgents: agents.availableAgents,
                          rememberedModels: state.lastModelByAgent,
                          catalogue: { ModelCatalog.models(for: $0, home: home) }, initialCatalogue: catalogue,
                          canChangeWorkspace: { [weak self] in self?.canChangeWorkspace == true },
                          searchIssues: TaskCreationModel.jiraSearcher(for: project, jira: jira),
                          createTask: { [weak self] draft in
                              guard let self else { throw CancellationError() }
                              try await self.createTask(draft: draft, project: project)
                          })
    }

    private func makeReviewModel(project: Project, draft: ReviewDraft, catalogue: [AgentModel]? = nil,
                                 gitLab: GitLabConfig?, gitHub: GitHubConfig?, remote: RemoteInfo) -> ReviewCreationModel {
        let home = harnessHome
        return ReviewCreationModel(project: project, draft: draft, home: home, availableAgents: agents.availableAgents,
                            rememberedModels: state.lastModelByAgent,
                            catalogue: { ModelCatalog.models(for: $0, home: home) }, initialCatalogue: catalogue,
                            canChangeWorkspace: { [weak self] in self?.canChangeWorkspace == true },
                            owningTask: { [weak self] branch, checkouts in
                                self?.state.task(checkingOut: branch, in: project.id, worktrees: checkouts)
                            },
                            codeHost: remote.provider == .github ? .gitHub : .gitLab,
                            searchMergeRequests: ReviewCreationModel.searcher(gitLab: gitLab, gitHub: gitHub, remote: remote),
                            createReview: { [weak self] draft in
                                guard let self else { throw CancellationError() }
                                try await self.createReview(draft: draft, project: project)
                            })
    }

    // -- tasks ----------------------------------------------------------------------
    func createTask(draft: TaskDraft, project: Project) async throws {
        try await create(draft, kind: .task, in: project) { try await self.taskWorkflow.create(draft: draft, project: project) }
    }

    /// A branch already checked out in a task's worktree — or an earlier review's — is reviewed
    /// there; any other gets a worktree of its own, on the branch (see `Worktrees.checkout`). Which
    /// is asked of git now, not of the saved rows: a task's worktree can have moved to another branch.
    func createReview(draft: ReviewDraft, project: Project) async throws {
        if let owner = try await checkoutOwner(of: draft.branch, in: project) {
            return try await openReview(draft, in: owner, project: project)
        }
        try await create(draft, kind: .review, in: project) { try await self.taskWorkflow.createReview(draft: draft, project: project) }
    }

    /// The review as a tab in `owner`'s window, running the reviewer in the task's worktree — or
    /// the window itself, reopened with the reviewer, when the task has none. Nothing is written
    /// to disk and no row is added, so closing the tab ends the review and there is nothing whose
    /// removal could reach the task's worktree or branch. For the same reason every failure is the
    /// sheet's: the draft is still there to retry.
    private func openReview(_ draft: ReviewDraft, in owner: TaskItem, project: Project) async throws {
        guard canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before opening a review.") }
        guard FileManager.default.fileExists(atPath: owner.worktreePath) else {
            throw ActionUnavailable("“\(owner.title)” has this branch, but its worktree is missing at \(owner.worktreePath). Restore it or remove the task.")
        }
        guard let daemon = helper.daemon else { throw ActionUnavailable("Disconnected. Try again once AiTerm reconnects.") }
        guard changingTasks.insert(owner.id).inserted else { throw ActionUnavailable("“\(owner.title)” is busy. Try again in a moment.") }
        defer { changingTasks.remove(owner.id) }
        openingTaskWindows.insert(owner.projectId)
        defer { openingTaskWindows.remove(owner.projectId) }
        let command = try await taskWorkflow.reviewCommand(draft: draft, in: owner)
        guard let current = state.task(id: owner.id) else { throw ActionUnavailable("“\(owner.title)” was removed.") }
        // Checked again last thing: a checkout in the task's own tab can have moved it meanwhile.
        // Its worktree is never switched back — the review would take over someone's checkout.
        guard try await checkoutOwner(of: draft.branch, in: project)?.id == owner.id else {
            throw ActionUnavailable("“\(owner.title)” no longer has \(draft.branch) checked out. Try again to review it where it is now.")
        }
        var opened = false
        if let wid = current.windowId {
            do {
                _ = try await daemon.createTab(windowId: wid, cwd: current.worktreePath, agentCommand: command)
                opened = true
                try? await daemon.activate(windowId: wid)
            }
            // Closed since the last poll: reopened below, as a task with no window is.
            catch let error as DaemonError where error.isNotFound {}
        }
        if !opened { try await openWindow(for: current, command: command, with: daemon) }
        var next = state
        if let mr = draft.mr, let i = next.tasks.firstIndex(where: { $0.id == owner.id }) {
            next.tasks[i].mr = MergeRequestRef(iid: mr.iid, title: mr.title, url: mr.url)
        }
        next.rememberChoice(draft, projectId: owner.projectId)
        state = next
        focus.browse(.task(owner.id))
        persist()
    }

    /// The row whose worktree has `branch` checked out, by git's own worktree listing.
    private func checkoutOwner(of branch: String, in project: Project) async throws -> TaskItem? {
        guard !branch.isEmpty else { return nil }
        let git = self.git, repo = project.path
        let worktrees = try await BackgroundWork.run { try Worktrees.listed(repo: repo, git: git) }
        return state.task(checkingOut: branch, in: project.id, worktrees: worktrees)
    }

    /// Commits the new row's identity before any terminal effect. A created task is never a failed
    /// form submission: the sheet closes, and any recovery is offered on the existing row.
    ///
    /// The new row is selected and its window opens beside the sidebar, but iTerm2 is not brought
    /// forward: the agent is already working on the prompt, so the keyboard stays in the sidebar,
    /// as after a peek, and Return commits. A new terminal, which has nothing running, does come
    /// forward (see `newTerminal(project:name:)`).
    private func create(_ draft: some AgentDraft, kind: TaskKind, in project: Project,
                        checkout: () async throws -> TaskWorkflow.Created) async throws {
        let noun = kind == .review ? "Review" : "Task"
        guard canChangeWorkspace else {
            throw ActionUnavailable("Save or recover the workspace before creating a \(noun.lowercased()).")
        }
        guard creatingProjects.insert(project.id).inserted else {
            throw ActionUnavailable("A task or review is already being created in \(project.name). Try again once it is.")
        }
        defer { creatingProjects.remove(project.id) }
        let result = try await checkout()
        let task = result.task
        var next = state
        next.tasks.append(task)
        next.rememberChoice(draft, projectId: project.id)
        state = next
        checkouts.refresh()
        focus.browse(.task(task.id))
        guard persist() else { return }
        if let warning = result.launchWarning {
            report(OperationIssue(title: "\(noun) created, but the agent couldn’t start. Choose Reopen Window, then start the agent manually.",
                                  reason: warning))
            return
        }
        guard let daemon = helper.daemon else {
            report("\(noun) created. Once AiTerm reconnects, choose Reopen Window and start the agent manually.")
            return
        }
        do { try await openWindow(for: task, command: result.command, with: daemon) }
        catch {
            report(OperationIssue(title: "\(noun) created. Couldn’t confirm its window opened. Wait for reconnection or choose Reopen Window.",
                                  error: error))
        }
    }

    /// A task's window, in its worktree, adopted by the row. `command` launches its agent; a reopened
    /// window gets none — the first prompt is never replayed. A row that went while the window opened
    /// cannot adopt it, so the window is closed rather than left behind with nothing to show it.
    private func openWindow(for task: TaskItem, command: String?, with daemon: any DaemonCommands) async throws {
        openingTaskWindows.insert(task.projectId)
        defer { openingTaskWindows.remove(task.projectId) }
        let wid = try await daemon.createTaskWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.branch,
                                                    agentCommand: command, frame: tiling.taskFrame())
        guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else {
            try? await closeWindow(wid, with: daemon)
            return
        }
        state.tasks[i].windowId = wid
        persist()
    }

    /// Closes a window, treating one that is already gone as closed.
    private func closeWindow(_ windowId: String, with daemon: any DaemonCommands) async throws {
        do { try await daemon.close(windowId: windowId) }
        catch let error as DaemonError where error.isNotFound { }
    }

    /// Ruling T13-1: a task that still has a window has nothing to reopen — the menu item is hidden
    /// in that case, and a stale click is ignored rather than leaking a second window.
    @discardableResult
    func reopen(task: TaskItem) -> Task<Void, Never>? {
        guard canChangeWorkspace else { return nil }
        guard let daemon = helper.daemon, let current = state.task(id: task.id),
              current.windowId == nil, changingTasks.insert(task.id).inserted else { return nil }
        guard FileManager.default.fileExists(atPath: current.worktreePath) else {
            changingTasks.remove(task.id)
            report("Worktree missing at \(current.worktreePath). Restore it or use Remove \(current.kindName).")
            return nil
        }
        return Task {
            defer { changingTasks.remove(task.id) }
            guard canChangeWorkspace else { return }
            do { try await openWindow(for: current, command: nil, with: daemon) }
            catch { report(OperationIssue(title: "Couldn’t reopen the window.", error: error)) }
        }
    }

    // -- the banner ------------------------------------------------------------------
    /// Shows `issue` above the list, in place of whatever was there — unless it is about a task or
    /// project that has gone while the work it reports was running.
    func report(_ issue: OperationIssue) {
        guard !issue.isStale(in: state) else { return }
        self.issue = issue
    }
    /// A failure with nothing to offer but Dismiss.
    func report(_ message: String) { report(OperationIssue(title: message)) }

    /// Dismissed, a removal that stopped with nothing deleted is just a task again. One that got
    /// past its worktree still waits on a retry, and its row keeps saying so.
    func dismissIssue() {
        if let id = issue?.subject, case .stopped(_, worktreeRemoved: false)? = removals[id] { removals[id] = nil }
        issue = nil
    }

    /// Answers the banner. Keeping loses nothing and just finishes the removal; deleting drops
    /// commits no other branch has, so it asks first. Rebasing rewrites only local commits and
    /// aborts on a conflict, so it does not. Nil when nothing started: the question was declined,
    /// or the task or project is gone or busy.
    @discardableResult
    func perform(_ action: OperationIssue.Action) -> Task<Void, Never>? {
        switch action {
        case .keepBranch(let id):
            guard let (task, project) = heldForRetry(id) else { return nil }
            issue = nil
            return remove(task, from: project, deleteBranch: false)
        case .deleteBranch(let id):
            guard let shown = state.task(id: id) else { return nil }
            let base = shown.baseBranch.isEmpty ? "its base" : shown.baseBranch
            let answer = prompter.ask(AlertPrompt(
                message: "Delete branch \(shown.branch)?",
                detail: "It has commits that aren’t on \(base). Deleting the branch deletes them too.",
                buttons: ["Delete Branch", "Cancel"], defaultDeletes: true))
            // The alert is a reentrancy point: act on the task as it is once it is answered.
            guard answer.confirmed, let (task, project) = heldForRetry(id) else { return nil }
            issue = nil
            return remove(task, from: project, deleteBranch: true) { [taskWorkflow] in
                try await taskWorkflow.deleteUnmergedBranch(of: task, in: project)
            }
        case .rebaseDefault(let id):
            guard let project = state.project(id: id) else { return nil }
            return rebaseDefault(project: project)
        }
    }

    /// The task and its project, now held in `changingTasks` for a removal's retry — only while
    /// its removal is still waiting on one.
    private func heldForRetry(_ id: UUID) -> (TaskItem, Project)? {
        guard canChangeWorkspace, removals[id]?.awaitsRetry == true, let task = state.task(id: id),
              let project = state.project(id: task.projectId), changingTasks.insert(id).inserted else { return nil }
        return (task, project)
    }

    // -- removing a task ------------------------------------------------------------
    #if DEBUG
    /// The snapshot renderer's rows mid-removal, drawn without running one.
    func seedSnapshotRemoval(_ removal: TaskRemoval?, of id: UUID) { removals[id] = removal }
    #endif

    /// Whether the remove alert offers an "Also delete branch" checkbox. A review's branch is the
    /// merge request's — GitLab deletes it on merge — so it never does.
    ///
    /// This is the courtesy, not the guarantee: `TaskWorkflow.remove` refuses a review's branch
    /// deletion outright (Task 6), so a caller that asks anyway still gets nothing. Hiding the
    /// checkbox here only keeps the alert from offering something that would be ignored.
    static func offersBranchDeletion(for task: TaskItem) -> Bool { task.kind != .review }

    /// Each alert here is a reentrancy point: `runModal` drains the main queue, so a snapshot, a
    /// window closing or another Remove can run while it is up. What happens after an answer is
    /// decided on the task as it is then — `task` is the row's copy, as old as the click.
    @discardableResult
    func confirmRemove(task: TaskItem) -> Task<Void, Never>? {
        guard canChangeWorkspace, !changingTasks.contains(task.id), let shown = state.task(id: task.id),
              state.project(id: shown.projectId) != nil else { return nil }
        let answer = prompter.ask(AlertPrompt(
            message: "Remove \(shown.kind == .review ? "review" : "task") “\(shown.title)”?",
            detail: shown.kind == .review
                ? "Deletes the worktree and closes its iTerm2 window. Its local branch goes too, unless it has commits origin lacks:\n\n\(shown.worktreePath)"
                : "Deletes the worktree and closes its iTerm2 window:\n\n\(shown.worktreePath)",
            buttons: ["Remove", "Cancel"],
            checkbox: Self.offersBranchDeletion(for: shown) ? "Also delete branch \(shown.branch)" : nil,
            defaultDeletes: true))
        // A Remove started during the alert owns the removal now; this answer then does nothing.
        guard answer.confirmed, canChangeWorkspace, let current = state.task(id: task.id),
              let project = state.project(id: current.projectId), changingTasks.insert(task.id).inserted else { return nil }
        return remove(current, from: project, deleteBranch: answer.checked)
    }

    /// The removal itself, for a task already held in `changingTasks`: its window, its worktree, its
    /// branch when asked for, then its row. `before` runs first; if it throws, nothing else does. A
    /// removal that stops says why on the row, which keeps it until the task goes or is removed again.
    private func remove(_ task: TaskItem, from project: Project, deleteBranch: Bool,
                        before: (() async throws -> Void)? = nil) -> Task<Void, Never> {
        removals[task.id] = .removing
        return Task {
            defer {
                changingTasks.remove(task.id)
                windowsLetGo.remove(task.id)
                if removals[task.id] == .removing { removals[task.id] = nil }
            }
            do {
                try await before?()
                // A canceled confirmation leaves the task as it was.
                guard let result = try await removeWorktree(task: task, project: project, deleteBranch: deleteBranch) else { return }
                await finishRemoval(of: task, after: result)
            } catch RemovalStop.keptWithoutWindow {
                removals[task.id] = .stopped(note: "Kept; choose Reopen Window", worktreeRemoved: false)
                report(OperationIssue(title: "\(task.kindName) kept. Its window had already closed.", subject: task.id))
            } catch RemovalStop.windowStayedOpen(let why) {
                removals[task.id] = .stopped(note: "Not removed: its window did not close", worktreeRemoved: false)
                report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: why, subject: task.id))
            } catch {
                removals[task.id] = .stopped(note: "Not removed", worktreeRemoved: false)
                report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: error, subject: task.id))
            }
        }
    }

    /// The task's window, then its worktree and its branch when asked for, through `TaskWorkflow`. A
    /// worktree with uncommitted changes asks first, while the window is still open; nil means it
    /// was kept. Unsaved work written after that check is only found once the window has closed:
    /// kept then, the task has lost its window, and `RemovalStop.keptWithoutWindow` says so.
    private func removeWorktree(task: TaskItem, project: Project, deleteBranch: Bool) async throws -> TaskWorkflow.Removed? {
        var task = task, force = false
        if try await taskWorkflow.hasUnsavedWork(task: task, project: project) {
            guard let still = confirmDeletingUnsavedWork(of: task) else { return nil }
            task = still
            force = true
        }
        let closed = try await closeWindowBeforeRemoval(of: task)
        do { return try await taskWorkflow.remove(task: task, project: project, deleteBranch: deleteBranch, force: force) }
        catch let error as GitError where error.refusedForUnsavedWork {
            // Written after the check, before the window closed.
            guard let still = confirmDeletingUnsavedWork(of: task) else {
                if closed { throw RemovalStop.keptWithoutWindow }
                return nil
            }
            return try await taskWorkflow.remove(task: still, project: project, deleteBranch: deleteBranch, force: true)
        }
    }

    /// The task as it is once deleting its unsaved work is agreed to; nil when it is kept. The task
    /// is still held, so no other removal started, but its row can have gone.
    ///
    /// Keeping is the default, on ↩ and ⎋ both; deleting is the plain grey button beside it, never
    /// marked red — the red default is for a button ↩ can press.
    private func confirmDeletingUnsavedWork(of task: TaskItem) -> TaskItem? {
        let force = prompter.ask(AlertPrompt(
            message: "The worktree has uncommitted changes",
            detail: "Removing this worktree permanently deletes its uncommitted changes and untracked files.",
            buttons: [task.kind == .review ? "Keep Review" : "Keep Task", "Delete Changes and Remove"], escape: 0))
        guard force.button == 1, canChangeWorkspace else { return nil }
        return state.task(id: task.id)
    }

    /// Closes the window the task has now, before git deletes its worktree: a process still running
    /// there — a dev server's watcher — writes files back into a checkout being deleted, and git then
    /// gives up halfway. The row drops the window first, so the window's own `window.closed` does
    /// not take the row with it: the row stays until the removal is done, or for a retry if it fails.
    /// A window that will not close is given back, and nothing is deleted. Without a daemon it is
    /// left open, and `finishRemoval` asks for it to be closed by hand. True once a window closed.
    private func closeWindowBeforeRemoval(of task: TaskItem) async throws -> Bool {
        guard let daemon = helper.daemon, let i = state.tasks.firstIndex(where: { $0.id == task.id }),
              let wid = state.tasks[i].windowId else { return false }
        windowsLetGo.insert(task.id)
        state.tasks[i].windowId = nil
        // Saved windowless too, so a removal that fails from here leaves a row to retry after a
        // relaunch, rather than one the next snapshot drops for its missing window.
        persist()
        do { try await closeWindow(wid, with: daemon) }
        catch {
            windowsLetGo.remove(task.id)
            if let j = state.tasks.firstIndex(where: { $0.id == task.id }), state.tasks[j].windowId == nil {
                state.tasks[j].windowId = wid
                persist()
            }
            throw RemovalStop.windowStayedOpen(ActionUnavailable("Its iTerm2 window did not close (\(error)), so nothing was deleted."))
        }
        return true
    }

    /// Why a removal stopped before git deleted anything, told apart from git's refusals so the row
    /// can say which it was.
    private enum RemovalStop: Error {
        /// `closeWindowBeforeRemoval`'s window would not close, so nothing was deleted.
        case windowStayedOpen(ActionUnavailable)
        /// Unsaved work turned up once the window had closed, and the person kept the task.
        case keptWithoutWindow
    }

    /// With the worktree gone: a branch left behind, or a window that would not close, leaves the
    /// row for a retry and says why; otherwise the row goes.
    private func finishRemoval(of task: TaskItem, after result: TaskWorkflow.Removed) async {
        if let refusal = result.branchRefusal {
            removals[task.id] = .stopped(note: "Not removed: branch kept", worktreeRemoved: true)
            report(.branchKept(task.branch, of: task.id, because: refusal))
            persist()
            return
        }
        // The window the task has now: the one it had at the click can have closed, or come back.
        if let wid = state.task(id: task.id)?.windowId {
            guard let daemon = helper.daemon else {
                removals[task.id] = .stopped(note: "Worktree removed; close its window, then retry", worktreeRemoved: true)
                checkouts.dropDiff(for: task.id)
                report(OperationIssue(title: "Worktree removed. Close its iTerm2 window, then retry Remove \(task.kindName).", subject: task.id))
                return
            }
            do { try await closeWindow(wid, with: daemon) }
            catch {
                removals[task.id] = .stopped(note: "Worktree removed; its window did not close", worktreeRemoved: true)
                checkouts.dropDiff(for: task.id)
                report(OperationIssue(title: "Worktree removed. Couldn’t close its window. Retry Remove \(task.kindName).", error: error, subject: task.id))
                return
            }
        }
        forget(task: task)
        if persistenceError == nil { showToast("\(task.kindName) removed." + (result.keptBranch.map { " " + $0 } ?? "")) }
    }

    /// The row goes, and with it — `pruneForgottenRows` — the banner about it and its removal's entry.
    private func forget(task: TaskItem) {
        state.tasks.removeAll { $0.id == task.id }
        checkouts.forget(task: task.id)
        checkouts.refresh()
        focus.dropStale()
        persist()
    }

    /// The tasks a checkout pass found gone, as they are now: one being changed, or waiting on a
    /// removal's retry, is its workflow's to finish, and one whose checkout or project came back
    /// while the pass ran stays. One whose agent is still mid-turn — it removed its own worktree
    /// and is finishing up — waits: closing the window would kill it. The daemon settles such a
    /// turn even when the agent's last hook cannot arrive (spec §10b), and the next pass closes it.
    private func forgetRemovedCheckouts(_ removed: [TaskItem]) {
        // A task still closing whose checkout came back is not closing any more.
        let gone = Set(removed.map(\.id))
        for (id, removal) in removals where removal == .closing && !gone.contains(id) && !changingTasks.contains(id) {
            removals[id] = nil
        }
        for task in removed where state.tasks.contains(task) && !changingTasks.contains(task.id)
                                  && removals[task.id]?.awaitsRetry != true && !turnInFlight(task.id) {
            guard WorkspaceScan.checkoutRemovalIsConfirmed(task,
                projectPath: state.project(id: task.projectId)?.path) else { continue }
            automaticallyForgetRemovedTask(task.id)
        }
    }

    private func turnInFlight(_ taskId: UUID) -> Bool {
        live.sessions.contains { $0.taskUUID == taskId && ($0.state == .working || $0.state == .needsInput) }
    }

    /// Keep the window identity until closure succeeds; a missing daemon or failed
    /// request is retried on the next poll/reconnect instead of orphaning the window. The row says
    /// "Closing…" from the first try until the window closes or the checkout comes back — not
    /// flickering back to "Worktree missing" between tries while iTerm2 is away.
    private func automaticallyForgetRemovedTask(_ id: UUID) {
        guard let task = state.task(id: id), !changingTasks.contains(id) else { return }
        guard let windowId = task.windowId else {
            forget(task: task)
            showToast("\(task.kindName) closed because its worktree was removed.")
            return
        }
        guard let daemon = helper.daemon else { return }
        changingTasks.insert(id)
        removals[id] = .closing
        closingTask = Task {
            defer { changingTasks.remove(id) }
            // On failure the saved task remains visible, still closing, and the next poll retries.
            guard (try? await closeWindow(windowId, with: daemon)) != nil else {
                checkouts.dropDiff(for: id)
                return
            }
            // A newer window association must not be forgotten by an old response.
            guard state.task(id: id)?.windowId == windowId else {
                if removals[id] == .closing { removals[id] = nil }
                return
            }
            forget(task: task)
            showToast("\(task.kindName) closed because its worktree was removed.")
        }
    }

    // -- terminals ------------------------------------------------------------------
    /// The New Terminal sheet, prefilled with the next free name. It asks for nothing else: the
    /// terminal opens in the project folder and starts no agent. The branch is read here rather
    /// than in the sheet, for the same reason `TaskDraft` is (see `SheetKind`): SwiftUI re-creates
    /// a sheet's root view on every state change of the presenting view, and this is a git call.
    func presentNewTerminal(project: Project) {
        guard canChangeWorkspace else { return }
        preparingSheet?.cancel()
        let git = self.git
        preparingSheet = Task {
            let branch = try? await BackgroundWork.run { try git.run(["symbolic-ref", "--short", "HEAD"], in: project.path) }
            guard !Task.isCancelled, canChangeWorkspace, state.project(id: project.id) != nil else { return }
            sheet = .newTerminal(project, name: TerminalItem.suggestedName(existing: state.terminals.filter { $0.projectId == project.id }), branch: branch ?? "")
        }
    }

    @discardableResult
    func newTerminal(project: Project, name: String) -> Task<Void, Never>? {
        guard canChangeWorkspace else { return nil }
        guard let daemon = helper.daemon else { report("Disconnected. Try creating the terminal once AiTerm reconnects."); return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? TerminalItem.suggestedName(existing: state.terminals.filter { $0.projectId == project.id }) : trimmed
        creatingTerminals.insert(project.id)
        // Selected like a new task, and — unlike one — brought forward: an empty shell is only
        // useful once typed into. Neither if another row was chosen meanwhile.
        let generation = focus.generation
        return Task {
            defer { creatingTerminals.remove(project.id) }
            guard canChangeWorkspace else { return }
            do {
                let wid = try await daemon.createTerminalWindow(projectId: project.id.uuidString, cwd: project.path, title: name, frame: tiling.taskFrame())
                // Removal waits for this, but a restored backup replaces the whole workspace. A row
                // whose project is gone would fail every save, so the window is closed, not adopted.
                guard state.project(id: project.id) != nil else {
                    try? await closeWindow(wid, with: daemon)
                    return
                }
                let item = TerminalItem(id: UUID(), projectId: project.id, name: name, windowId: wid, createdAt: Date())
                state.terminals.append(item)
                checkouts.refresh()
                persist()
                guard generation == focus.generation else { return }
                focus.browse(.terminal(item.id))
                activateIterm()
            } catch { report(OperationIssue(title: "Couldn’t open the terminal.", error: error)) }
        }
    }

    /// The terminal twin of `reopen(task:)`: a new window in the project's own directory, adopted by
    /// the row that lost its window.
    @discardableResult
    func reopen(terminal: TerminalItem, project: Project) -> Task<Void, Never>? {
        guard canChangeWorkspace else { return nil }
        guard let daemon = helper.daemon, let current = state.terminal(id: terminal.id), current.windowId == nil,
              changingTerminals[terminal.id] == nil else { return nil }
        changingTerminals[terminal.id] = .reopening
        return Task {
            defer { changingTerminals[terminal.id] = nil }
            guard canChangeWorkspace else { return }
            do {
                let wid = try await daemon.createTerminalWindow(projectId: project.id.uuidString, cwd: project.path, title: current.name, frame: tiling.taskFrame())
                // As for a task's window: a row that went meanwhile cannot adopt it.
                guard let i = state.terminals.firstIndex(where: { $0.id == terminal.id }) else {
                    try? await closeWindow(wid, with: daemon)
                    return
                }
                state.terminals[i].windowId = wid
                persist()
            } catch { report(OperationIssue(title: "Couldn’t reopen the window.", error: error)) }
        }
    }

    /// Closing a terminal touches nothing on disk — there is no worktree behind it — so it needs no
    /// confirmation, unlike removing a task. The row's copy is as old as the click, so the window
    /// closed is the one the terminal has when the close runs: a reopen can have given it one since.
    /// A close while the window is still reopening says so rather than racing it.
    @discardableResult
    func close(terminal: TerminalItem) -> Task<Void, Never>? {
        guard canChangeWorkspace, let current = state.terminal(id: terminal.id) else { return nil }
        switch changingTerminals[terminal.id] {
        case .closing: return nil // the Remove already in flight
        case .reopening:
            report("“\(current.name)” is still reopening its window. Try Remove Terminal again once it has.")
            return nil
        case nil: changingTerminals[terminal.id] = .closing
        }
        return Task {
            defer { changingTerminals[terminal.id] = nil }
            guard canChangeWorkspace else { return }
            if let wid = state.terminal(id: terminal.id)?.windowId {
                guard let daemon = helper.daemon else { report("Disconnected. Try Remove Terminal again once AiTerm reconnects."); return }
                do { try await closeWindow(wid, with: daemon) }
                catch { report(OperationIssue(title: "Couldn’t close the terminal.", error: error)); return }
            }
            state.terminals.removeAll { $0.id == terminal.id }
            focus.dropStale()
            persist()
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
        case nil: nil
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
    /// ↩ on the list: a header folds or opens its project; any other row goes to its window. An
    /// empty project has nothing to fold, so its header opens its context menu — its first items
    /// are the ones that give it a row.
    @discardableResult
    func activateSelection() -> Task<Void, Never>? {
        if let project = focus.selectedProjectId.flatMap(state.project(id:)) {
            if hasRows(project) {
                toggleCollapsed(project)
            } else {
                // Next turn, as ⌘⌫'s alert: the menu runs modally, and not inside SwiftUI's key
                // handler.
                RunLoop.main.perform { MainActor.assumeIsolated { self.openRowMenu(project.id) } }
            }
            return nil
        }
        return focus.activateSelection()
    }

    /// ⌘⌫ on the list: the selected row's own Remove, as its context menu has it — a task or a
    /// review asks first, a terminal just closes.
    @discardableResult
    func removeSelection() -> Task<Void, Never>? {
        if let task = focus.selectedTaskId.flatMap(state.task(id:)) { return confirmRemove(task: task) }
        if let terminal = focus.selectedTerminalId.flatMap(state.terminal(id:)) { return close(terminal: terminal) }
        return nil
    }
}
