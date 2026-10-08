import Foundation
import AiTermUI
import AiTermCore

#if DEBUG
/// The workspace the images draw: two projects under a divider, four tasks and a terminal. A value,
/// made fresh for every image, so what one image changes — a collapsed project, a removal, the
/// selection — no other image sees.
///
/// Its controller's store is a file nothing loads, so nothing is ever saved over the developer's
/// `state.json`, and every checkout pass reports the fixture's own checkouts rather than running git.
@MainActor
struct Fixture {
    /// A domain nothing writes: the images show the default preferences, not the developer's.
    static let defaults = UserDefaults(suiteName: "AiTerm.snapshots")!
    /// A home with no agent configuration in it: the sheets' models and prompt completions are
    /// the images', not whatever the developer's `~/.claude` and `~/.codex` hold.
    nonisolated static let home: URL = {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-snapshots-home")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }()
    /// The bare home's models, with no CLI to launch: PI offers none.
    nonisolated static let catalogue: @Sendable (AgentKind) -> [AgentModel] = { models.read($0).models }
    nonisolated private static let models = ModelCatalogue(home: home, runner: .nothingInstalled)
    /// Asked for branches and checkouts of a project that is not on disk: it answers none.
    nonisolated static let git = GitRunner()
    /// The preferences every image draws with: the defaults, read from `defaults`.
    static var preferences: InterfacePreferences { InterfacePreferences(defaults: defaults) }

    /// Usage resets relative to the render, so the footer shows both of its shapes: a bare `HH:mm`
    /// for a window clearing today, and a weekday-prefixed one for a window clearing later.
    static let soon = Int(Snapshots.clock.now.addingTimeInterval(2 * 3600).timeIntervalSince1970)
    static let later = Int(Snapshots.clock.now.addingTimeInterval(3 * 86_400).timeIntervalSince1970)
    static let fresh = Int(Snapshots.clock.now.timeIntervalSince1970)

    let project: Project, personal: Project
    let working: TaskItem, other: TaskItem, piTask: TaskItem, grokTask: TaskItem
    let terminal: TerminalItem
    let rule: SidebarDivider
    /// What every checkout pass reports.
    let onDisk: WorkspaceScan

    init() {
        // Linked to two Jira projects, so the sidebar snapshot carries a project row's Jira count
        // badge; `dotfiles` below is linked to none, which is the other half of that rule.
        let site = URL(string: "https://example.atlassian.net")!
        project = Project(id: UUID(), name: "acme-storefront", path: FileManager.default.currentDirectoryPath,
                          provider: .gitlab, remoteUrl: "git@gitlab.example/acme/storefront.git", addedAt: Snapshots.clock.now, collapsed: false,
                          jiraProjects: [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site),
                                         JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)])
        working = TaskItem(id: UUID(), projectId: project.id, title: "Add Apple Pay to the checkout flow",
                           branch: "feat/pay-214-apple-pay", worktreePath: "/r/.worktrees/x", baseBranch: "main",
                           jira: JiraRef(key: "PAY-214", summary: "Apple Pay", url: "https://example/PAY-214"),
                           agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil, appendTicket: true,
                           createdAt: Snapshots.clock.now, windowId: "w1")
        other = TaskItem(id: UUID(), projectId: project.id, title: "Cut product page load time in half",
                         branch: "perf/shop-1088-product-page", worktreePath: "/r/.worktrees/y", baseBranch: "develop",
                         jira: JiraRef(key: "SHOP-1088", summary: "Product page speed", url: "https://example/SHOP-1088"),
                         agent: .codex, model: "gpt-5.6", reasoning: "medium", firstPrompt: nil, appendTicket: true,
                         createdAt: Snapshots.clock.now, windowId: "w2")
        piTask = TaskItem(id: UUID(), projectId: project.id, title: "Fix rounding in cart totals",
                          branch: "fix/cart-total-rounding", worktreePath: "/r/.worktrees/pi", baseBranch: "main",
                          jira: nil, agent: .pi, model: "openai-codex/gpt-5.6-sol", reasoning: "high",
                          firstPrompt: nil, appendTicket: false, createdAt: Snapshots.clock.now, windowId: "w5")
        grokTask = TaskItem(id: UUID(), projectId: project.id, title: "Write the release notes for v2.4",
                            branch: "docs/release-notes-2-4", worktreePath: "/r/.worktrees/grok", baseBranch: "main",
                            jira: nil, agent: .grok, model: "grok-4.7", reasoning: "high",
                            firstPrompt: nil, appendTicket: false, createdAt: Snapshots.clock.now, windowId: "w6")
        terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Dev server", windowId: "w3", createdAt: Snapshots.clock.now)
        // A second project under a divider, so the sidebar snapshot carries a `DividerRow`.
        personal = Project(id: UUID(), name: "dotfiles", path: FileManager.default.currentDirectoryPath,
                           provider: .git, remoteUrl: nil, addedAt: Snapshots.clock.now, collapsed: true)
        rule = SidebarDivider(id: UUID(), name: "Personal")
        onDisk = WorkspaceScan(
            branchByCwd: [working.worktreePath: working.branch, piTask.worktreePath: piTask.branch, "/r": "main"],
            projectBranch: [project.id: "main"], missingCheckouts: [], removedTasks: [], remotes: [:],
            // The VS Code badge's three looks: a long diff, one side only (off `develop`, named only in
            // the tooltip), and the selected row, where the counts turn white.
            diffByTask: [working.id: DiffStat(added: 148, removed: 12), other.id: DiffStat(added: 3, removed: 0),
                         piTask.id: DiffStat(added: 7, removed: 2)])
    }

    /// The fixture's workspace in a controller, its tabs and usage reported, the PI task selected
    /// and iTerm2 connected.
    func controller() -> AppController {
        let controller = Self.emptyController(scan: onDisk)
        controller.workspace.mutate { state in
            state.append(project: project)
            state.append(divider: rule)
            state.append(project: personal)
            state.tasks = [working, other, piTask, grokTask]
            state.terminals = [terminal]
        }
        controller.live.sessions = [
            // The selected task's window: two tabs in its worktree, one the user cd'd back to the
            // repo root — the "+1" case.
            // The active tab supplies the initial last-known context for this selected task.
            Self.session("s1", "w1", working.id, "claude", "working", 0, cwd: working.worktreePath, active: true, context: 37,
                         tokens: TokenTally(input: 936_018, cached: 935_988, output: 5_625)),
            Self.session("s2", "w1", working.id, "claude", "idle", 1, cwd: working.worktreePath, context: 91),
            Self.session("s3", "w1", working.id, "codex", "idle", 2, cwd: "/r", context: 64),
            // The other task's agent left its worktree entirely — the drift case.
            Self.session("s4", "w2", other.id, "codex", "needsInput", 0, cwd: "/r", active: true),
            Self.session("s5", "w2", other.id, "shell", "idle", 1, cwd: "/r"),
            Self.session("s7", "w5", piTask.id, "pi", "working", 0, cwd: piTask.worktreePath,
                         active: true, context: 84, tokens: TokenTally(input: 3_283_279, cached: 3_093_248, output: 18_391),
                         model: piTask.model, reasoning: piTask.reasoning),
            Self.session("s8", "w6", grokTask.id, "grok", "working", 0, cwd: grokTask.worktreePath,
                         active: true, context: 37, model: grokTask.model, reasoning: grokTask.reasoning),
        ].compactMap { $0 }
        // The monitor is handed what the pass the sessions start would report, and the pass is
        // called off: hosted, it would land while an image is drawn, and its empty list of removed
        // checkouts would end the closing a removal image draws.
        controller.checkouts.seedSnapshotFixture(onDisk)
        controller.checkouts.refreshTask?.cancel()
        controller.live.usage = Self.usage("""
            {"claude":{"fiveHour":{"usedPercent":42,"resetsAt":\(Self.soon)},"sevenDay":{"usedPercent":61,"resetsAt":\(Self.later)},"spend":null,"plan":"Max","updatedAt":\(Self.fresh)},
             "codex":{"fiveHour":{"usedPercent":88,"resetsAt":\(Self.soon)},"sevenDay":null,"spend":null,"plan":"Pro","updatedAt":\(Self.fresh)}}
            """)
        controller.focus.browse(.task(piTask.id))
        controller.helper.itermConnection = .connected(version: "3.7.2")
        return controller
    }

    /// A controller with nothing in it yet, over a store nothing loads — so, like every fixture
    /// controller, its workspace reads as not yet loaded — whose checkout passes report `scan`, and
    /// whose Backpack Mode runs over the inert ports: at its desk, touching no Wi-Fi or Location —
    /// and which reads no load off this Mac.
    static func emptyController(scan: WorkspaceScan = WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [],
                                                                    removedTasks: [], remotes: [:])) -> AppController {
        let store = StateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-snapshots-\(UUID().uuidString).json"))
        return AppController.live(store: store, preferences: preferences, harnessHome: home, locateAgents: { nil },
                                  setBadge: { _ in }, activateIterm: {}, backpackPorts: .inert,
                                  machineSensor: InertMachineSensor(), scan: { _, _, _, _, _, _, _ in scan })
    }

    /// `SessionInfo`'s memberwise initialiser is internal to AiTermCore, so the fixtures come in
    /// the same way the daemon's do: as JSON.
    static func session(_ id: String, _ window: String, _ task: UUID, _ agent: String, _ state: String, _ tab: Int,
                        cwd: String = "/r", active: Bool = false, context: Int? = nil, tokens: TokenTally? = nil,
                        model: String? = nil, reasoning: String? = nil) -> SessionInfo? {
        let counts = tokens.map { #"{"input":\#($0.input),"cached":\#($0.cached.map(String.init) ?? "null"),"output":\#($0.output)}"# } ?? "null"
        let json = """
        {"sessionId":"\(id)","windowId":"\(window)","tabIndex":\(tab),"taskId":"\(task.uuidString)","projectId":null,
         "agent":"\(agent)","model":\(model.map { "\"\($0)\"" } ?? "null"),
         "reasoning":\(reasoning.map { "\"\($0)\"" } ?? "null"),
         "state":"\(state)","title":"\(agent)","cwd":"\(cwd)","active":\(active),
         "contextPercent":\(context.map(String.init) ?? "null"),"tokens":\(counts)}
        """
        return try? JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
    }

    /// A usage report, as the daemon sends it.
    static func usage(_ json: String) -> UsageSnapshot {
        (try? JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))) ?? .empty
    }
}
#endif
