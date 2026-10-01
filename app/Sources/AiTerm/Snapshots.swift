import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// Renders the sidebar and every step of the New Task sheet to PNGs, offscreen, so the
/// implementation can be checked against the design without a screen recorder.
/// Only runs when `AITERM_SNAPSHOT_DIR` is set; `scripts/snapshots.sh` is the front door, and it
/// runs the debug build, so a release build carries none of this.
@MainActor
enum Snapshots {
    static func runIfRequested() -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_DIR"] else { return false }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let fixture = Fixture()
        sidebar(fixture, to: out)
        creationSheets(fixture, to: out)
        settings(fixture, to: out)
        marks(to: out)
        collapsedSidebar(fixture, to: out)
        banners(to: out)
        removalRows(fixture, to: out)
        selectedHeaders(fixture, to: out)
        emptySidebar(fixture, to: out)
        readmeDesktop(to: out)

        print("snapshots written to \(out.path)")
        return true
    }

    /// The workspace the images draw. Its store is a file nothing loads, so nothing is ever saved
    /// over the developer's `state.json`, and every checkout pass reports the fixture's own
    /// checkouts rather than running git.
    @MainActor
    private struct Fixture {
        /// A domain nothing writes: the images show the default preferences, not the developer's.
        static let defaults = UserDefaults(suiteName: "AiTerm.snapshots")!
        /// A home with no agent configuration in it: the sheets' models and prompt completions are
        /// the images', not whatever the developer's `~/.claude` and `~/.codex` hold.
        nonisolated static let home: URL = {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-snapshots-home")
            try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            return home
        }()
        nonisolated static let catalogue: @Sendable (AgentKind) -> [AgentModel] = { ModelCatalog.models(for: $0, home: Fixture.home) }
        let controller: AppController
        let project: Project, personal: Project
        let working: TaskItem, other: TaskItem, piTask: TaskItem, grokTask: TaskItem
        let terminal: TerminalItem
        let rule: SidebarDivider

        init() {
            // Linked to two Jira projects, so the sidebar snapshot carries a project row's Jira
            // badges; `dotfiles` below is linked to none, which is the other half of that rule.
            let site = URL(string: "https://example.atlassian.net")!
            let project = Project(id: UUID(), name: "acme-storefront", path: FileManager.default.currentDirectoryPath,
                                  provider: .gitlab, remoteUrl: "git@gitlab.example/acme/storefront.git", addedAt: Date(), collapsed: false,
                                  jiraProjects: [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site),
                                                 JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)])
            let working = TaskItem(id: UUID(), projectId: project.id, title: "Add Apple Pay to the checkout flow",
                                   branch: "feat/pay-214-apple-pay", worktreePath: "/r/.worktrees/x", baseBranch: "main",
                                   jira: JiraRef(key: "PAY-214", summary: "Apple Pay", url: "https://example/PAY-214"),
                                   agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil, appendTicket: true,
                                   createdAt: Date(), windowId: "w1")
            let other = TaskItem(id: UUID(), projectId: project.id, title: "Cut product page load time in half",
                                 branch: "perf/shop-1088-product-page", worktreePath: "/r/.worktrees/y", baseBranch: "develop",
                                 jira: JiraRef(key: "SHOP-1088", summary: "Product page speed", url: "https://example/SHOP-1088"),
                                 agent: .codex, model: "gpt-5.6", reasoning: "medium", firstPrompt: nil, appendTicket: true,
                                 createdAt: Date(), windowId: "w2")
            let piTask = TaskItem(id: UUID(), projectId: project.id, title: "Fix rounding in cart totals",
                                  branch: "fix/cart-total-rounding", worktreePath: "/r/.worktrees/pi", baseBranch: "main",
                                  jira: nil, agent: .pi, model: "openai-codex/gpt-5.6-sol", reasoning: "high",
                                  firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w5")
            let grokTask = TaskItem(id: UUID(), projectId: project.id, title: "Write the release notes for v2.4",
                                    branch: "docs/release-notes-2-4", worktreePath: "/r/.worktrees/grok", baseBranch: "main",
                                    jira: nil, agent: .grok, model: "grok-4.7", reasoning: "high",
                                    firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w6")
            let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Dev server", windowId: "w3", createdAt: Date())
            // A second project under a divider, so the sidebar snapshot carries a `DividerRow`.
            let personal = Project(id: UUID(), name: "dotfiles", path: FileManager.default.currentDirectoryPath,
                                   provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: true)
            let rule = SidebarDivider(id: UUID(), name: "Personal")
            // What every checkout pass reports. The images are drawn before the pass the sessions
            // below start has finished, so the monitor is handed the same values directly too.
            let onDisk = WorkspaceScan(
                branchByCwd: [working.worktreePath: working.branch, piTask.worktreePath: piTask.branch, "/r": "main"],
                projectBranch: [project.id: "main"], missingCheckouts: [], removedTasks: [], remotes: [:],
                // The VS Code badge's three looks: a long diff, one side only (off `develop`, named only in
                // the tooltip), and the selected row, where the counts turn white.
                diffByTask: [working.id: DiffStat(added: 148, removed: 12), other.id: DiffStat(added: 3, removed: 0),
                             piTask.id: DiffStat(added: 7, removed: 2)])
            let store = StateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-snapshots-\(UUID().uuidString).json"))
            let controller = AppController(store: store, preferences: InterfacePreferences(defaults: Self.defaults),
                                           harnessHome: Self.home, bundledResourcesURL: Bundle.main.resourceURL,
                                           locateAgents: { nil },
                                           scan: { _, _, _, _, _, _, _ in onDisk })
            controller.state.append(project: project)
            controller.state.append(divider: rule)
            controller.state.append(project: personal)
            controller.state.tasks = [working, other, piTask, grokTask]
            controller.state.terminals = [terminal]
            controller.live.sessions = [
                // The selected task's window: two tabs in its worktree, one the user cd'd back to the
                // repo root — the "+1" case.
                // The active tab supplies the initial last-known context for this selected task.
                session("s1", "w1", working.id, "claude", "working", 0, cwd: working.worktreePath, active: true, context: 37),
                session("s2", "w1", working.id, "claude", "idle", 1, cwd: working.worktreePath, context: 91),
                session("s3", "w1", working.id, "codex", "idle", 2, cwd: "/r", context: 64),
                // The other task's agent left its worktree entirely — the drift case.
                session("s4", "w2", other.id, "codex", "needsInput", 0, cwd: "/r", active: true),
                session("s5", "w2", other.id, "shell", "idle", 1, cwd: "/r"),
                session("s7", "w5", piTask.id, "pi", "working", 0, cwd: piTask.worktreePath,
                        active: true, context: 84, model: piTask.model, reasoning: piTask.reasoning),
                session("s8", "w6", grokTask.id, "grok", "working", 0, cwd: grokTask.worktreePath,
                        active: true, context: 37, model: grokTask.model, reasoning: grokTask.reasoning),
            ].compactMap { $0 }
            controller.checkouts.seedSnapshotFixture(onDisk)
            // Resets are relative to the render so the footer shows both of its shapes: a bare `HH:mm`
            // for a window clearing today, and a weekday-prefixed one for a window clearing later.
            let soon = Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970)
            let later = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
            let fresh = Int(Date().timeIntervalSince1970)
            controller.live.usage = (try? JSONDecoder().decode(UsageSnapshot.self, from: Data("""
            {"claude":{"fiveHour":{"usedPercent":42,"resetsAt":\(soon)},"sevenDay":{"usedPercent":61,"resetsAt":\(later)},"spend":null,"plan":"Max","updatedAt":\(fresh)},
             "codex":{"fiveHour":{"usedPercent":88,"resetsAt":\(soon)},"sevenDay":null,"spend":null,"plan":"Pro","updatedAt":\(fresh)}}
            """.utf8))) ?? .empty
            controller.focus.browse(.task(piTask.id))
            controller.helper.itermConnection = .connected(version: "3.7.2")
            self.controller = controller
            self.project = project; self.personal = personal
            self.working = working; self.other = other; self.piTask = piTask; self.grokTask = grokTask
            self.terminal = terminal; self.rule = rule
        }
    }

    // `SessionInfo`'s memberwise initialiser is internal to AiTermCore, so the fixtures come in
    // the same way the daemon's do: as JSON.
    private static func session(_ id: String, _ window: String, _ task: UUID, _ agent: String, _ state: String, _ tab: Int,
                                cwd: String = "/r", active: Bool = false, context: Int? = nil,
                                model: String? = nil, reasoning: String? = nil) -> SessionInfo? {
        let json = """
        {"sessionId":"\(id)","windowId":"\(window)","tabIndex":\(tab),"taskId":"\(task.uuidString)","projectId":null,
         "agent":"\(agent)","model":\(model.map { "\"\($0)\"" } ?? "null"),
         "reasoning":\(reasoning.map { "\"\($0)\"" } ?? "null"),
         "state":"\(state)","title":"\(agent)","cwd":"\(cwd)","active":\(active),
         "contextPercent":\(context.map(String.init) ?? "null")}
        """
        return try? JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
    }

    /// The README's picture: the hosted `SidebarView` and the iTerm2 window of its selected task,
    /// side by side on a transparent ground. Its own workspace — a home folder, then aiterm
    /// under Personal and acme under Work, two tasks each, one of them a review — so the fixture
    /// the other images share stays small. Hosted only: `ImageRenderer` never materialises a `List`.
    private static func readmeDesktop(to out: URL) {
        guard ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_HOSTED"] == "1" else { return }
        let here = FileManager.default.currentDirectoryPath
        let site = URL(string: "https://example.atlassian.net")!
        let ml = JiraProjectRef(id: "10001", key: "ML", name: "Machine Learning", siteURL: site)
        let web = JiraProjectRef(id: "10002", key: "WEB", name: "Website", siteURL: site)
        func project(_ name: String, _ provider: Provider, jira: [JiraProjectRef] = []) -> Project {
            Project(id: UUID(), name: name, path: here, provider: provider, remoteUrl: nil, addedAt: Date(),
                    collapsed: false, jiraProjects: jira)
        }
        let models: [AgentKind: String] = [.claude: "opus", .codex: "gpt-5.6", .pi: "openai-codex/gpt-5.6-sol", .grok: "grok-4.7"]
        func task(_ project: Project, _ title: String, _ branch: String, _ agent: AgentKind, _ window: String,
                  jira: String? = nil, review: MergeRequestRef? = nil) -> TaskItem {
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: branch, worktreePath: "/r/.worktrees/\(window)",
                     baseBranch: "main", jira: jira.map { JiraRef(key: $0, summary: title, url: "https://example/\($0)") },
                     kind: review == nil ? .task : .review, mr: review,
                     agent: agent, model: models[agent] ?? "", reasoning: "high", firstPrompt: nil, appendTicket: jira != nil,
                     createdAt: Date(), windowId: window)
        }
        let home = project("laurensdhondt", .none)
        let aiterm = project("aiterm", .github)
        let acme = project("acme", .gitlab, jira: [ml, web])

        let refactor = task(aiterm, "Refactor the session tracker", "refactor/session-tracker", .claude, "a1")
        let orphan = task(aiterm, "Fix orphaned helper on restart", "fix/orphaned-helper", .grok, "a2")
        let quantize = task(acme, "Quantize the ranking model to int8", "feat/ml-412-int8-quantization", .pi, "m1", jira: "ML-412")
        let release = task(acme, "Release new marketing website", "release/marketing-website", .codex, "m2", jira: "WEB-221",
                           review: MergeRequestRef(iid: 87, title: "Release new marketing website", url: "https://example/!87"))
        let tasks = [refactor, orphan, quantize, release]

        let onDisk = WorkspaceScan(
            branchByCwd: Dictionary(uniqueKeysWithValues: tasks.map { ($0.worktreePath, $0.branch) } + [("/r", "main")]),
            projectBranch: Dictionary(uniqueKeysWithValues: [home, aiterm, acme].map { ($0.id, "main") }),
            missingCheckouts: [], removedTasks: [], remotes: [:],
            // The review has just been checked out, so it sits on its branch and draws no diff.
            diffByTask: [refactor.id: DiffStat(added: 212, removed: 148), orphan.id: DiffStat(added: 18, removed: 6),
                         quantize.id: DiffStat(added: 96, removed: 31)])
        let store = StateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-readme-\(UUID().uuidString).json"))
        let controller = AppController(store: store, preferences: InterfacePreferences(defaults: Fixture.defaults),
                                       harnessHome: Fixture.home, bundledResourcesURL: Bundle.main.resourceURL,
                                       locateAgents: { nil }, scan: { _, _, _, _, _, _, _ in onDisk })
        controller.state.append(project: home)
        controller.state.append(divider: SidebarDivider(id: UUID(), name: "Personal"))
        controller.state.append(project: aiterm)
        controller.state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        controller.state.append(project: acme)
        controller.state.tasks = tasks
        controller.live.sessions = [
            // The selected task: Claude Code in front, its context the footer's CONTEXT line.
            session("r1", "a1", refactor.id, "claude", "working", 0, cwd: refactor.worktreePath, active: true, context: 38),
            session("r2", "a1", refactor.id, "codex", "idle", 1, cwd: refactor.worktreePath),
            session("r3", "a2", orphan.id, "grok", "done", 0, cwd: orphan.worktreePath, active: true),
            session("r4", "m1", quantize.id, "pi", "working", 0, cwd: quantize.worktreePath, active: true),
            session("r5", "m2", release.id, "codex", "needsInput", 0, cwd: release.worktreePath, active: true),
            session("r6", "m2", release.id, "claude", "idle", 1, cwd: release.worktreePath),
        ].compactMap { $0 }
        controller.checkouts.seedSnapshotFixture(onDisk)
        let soon = Int(Date().addingTimeInterval(2 * 3600).timeIntervalSince1970)
        let later = Int(Date().addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        let fresh = Int(Date().timeIntervalSince1970)
        controller.live.usage = (try? JSONDecoder().decode(UsageSnapshot.self, from: Data("""
        {"claude":{"fiveHour":{"usedPercent":42,"resetsAt":\(soon)},"sevenDay":{"usedPercent":61,"resetsAt":\(later)},"spend":null,"plan":"Max","updatedAt":\(fresh)},
         "codex":{"fiveHour":null,"sevenDay":{"usedPercent":17,"resetsAt":\(later)},"spend":null,"plan":"Pro","updatedAt":\(fresh)}}
        """.utf8))) ?? .empty
        controller.focus.browse(.task(refactor.id))
        controller.helper.itermConnection = .connected(version: "3.7.2")
        write(ReadmeDesktop(controller: controller, tabTitle: refactor.branch, tabs: 2),
              to: out.appendingPathComponent("readme-desktop.png"))
    }

    /// The sidebar's rows at every size, and the usage footer.
    private static func sidebar(_ fixture: Fixture, to out: URL) {
        let controller = fixture.controller, project = fixture.project, rule = fixture.rule
        let working = fixture.working, piTask = fixture.piTask
        // `ImageRenderer` never materialises the sidebar's `List`, so its rows are rendered directly
        // instead of through `SidebarView`'s scrolling body.
        if ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_HOSTED"] == "1" {
            write(SidebarView(controller: controller).frame(width: 340, height: 600), to: out.appendingPathComponent("sidebar-native.png"))
        }
        let section = SidebarModel.sections(state: controller.state, sessions: controller.live.sessions,
                                            branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                            diffByTask: controller.checkouts.diffByTask)[0]
        let ruleEntry = DividerEntry(divider: rule, canMoveUp: controller.state.canMove(id: rule.id, .up),
                                     canMoveDown: controller.state.canMove(id: rule.id, .down))
        @ViewBuilder func sidebarRows() -> some View {
            SidebarHeader(controller: controller)
            ProjectHeaderRow(section: section, controller: controller)
            ForEach(section.tasks) { row in
                TaskRowView(row: row, task: controller.state.tasks.first { $0.id == row.id }, controller: controller)
            }
            ForEach(section.terminals) { row in
                TerminalRowView(row: row, terminal: controller.state.terminals.first { $0.id == row.id }, project: project,
                                controller: controller)
            }
            DividerRow(entry: ruleEntry, controller: controller)
            ProjectHeaderRow(section: SidebarModel.sections(state: controller.state, sessions: controller.live.sessions,
                                                            branchByCwd: controller.checkouts.branchByCwd,
                                                            projectBranch: controller.checkouts.projectBranch)[1],
                             controller: controller)
        }
        write(VStack(alignment: .leading, spacing: Space.hairline) {
            // A stack of its own, so the inset reaches the rows as one block and the spacing between
            // them stays the outer stack's.
            VStack(alignment: .leading, spacing: Space.hairline) { sidebarRows() }
                .padding(.horizontal, Space.inset)
            Spacer()
            UsageFooter(task: controller.live.usageRow(for: controller.focus.selection),
                        rows: SidebarModel.usageVendorRows(controller.live.usage, now: Date(), calendar: .current))
        }
        // The rows' 10 pt inset stands in for the List's. The footer is a direct child of the real
        // sidebar and gets its full width — it adds that inset back itself — so it is not padded
        // here, and the frame carries the inset on top of `sidebarWidth`.
        // The selected task adds the footer's CONTEXT group and its rule above USAGE; USAGE itself
        // grew 26 pt over the old vendor block when it gained its heading and menu-row lines.
        .frame(width: Size.sidebarWidth + 20,
               height: 352 + 26 + Size.menuRow + Size.projectRow
                   + Space.tight + Size.menuRow * 2 + Space.base + 1)
        .background(Palette.sidebar), to: out.appendingPathComponent("sidebar.png"))
        // The two larger sidebar sizes, for judging the scale by eye; ×1 is `sidebar.png` above.
        for (name, scale) in [("large", InterfaceScale.large), ("extra-large", .extraLarge)] {
            write(VStack(alignment: .leading, spacing: scale(Space.hairline)) {
                VStack(alignment: .leading, spacing: scale(Space.hairline)) { sidebarRows() }
                    .padding(.horizontal, scale(Space.inset))
                UsageFooter(task: controller.live.usageRow(for: controller.focus.selection),
                            rows: SidebarModel.usageVendorRows(controller.live.usage, now: Date(), calendar: .current))
            }
            .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset))
            .fixedSize(horizontal: false, vertical: true)
            .background(Palette.sidebar)
            .interfaceScale(scale), to: out.appendingPathComponent("sidebar-\(name).png"))
        }
        // A task stacking two providers draws only its active tab's provider.
        controller.focus.browse(.task(working.id))
        write(UsageFooter(task: controller.live.usageRow(for: controller.focus.selection),
                          rows: SidebarModel.usageVendorRows(controller.live.usage, now: Date(), calendar: .current))
            .frame(width: Size.sidebarWidth)
            .background(Palette.sidebar), to: out.appendingPathComponent("usage-footer-agents.png"))
        controller.focus.browse(.task(piTask.id))
    }

    /// Every step of the New Task and New Review sheets, and the New Terminal sheet.
    private static func creationSheets(_ fixture: Fixture, to out: URL) {
        let project = fixture.project, working = fixture.working
        let tickets = [
            JiraTicket(key: "PAY-214", summary: "Add Apple Pay to the checkout flow", description: nil, issueType: "Story", status: "In Progress", url: "u"),
            JiraTicket(key: "SHOP-1711", summary: "Migrate the storefront to a monorepo", description: nil, issueType: "Task", status: "DEV", url: "u"),
            JiraTicket(key: "SHOP-1731", summary: "Add customer reviews to the product page", description: nil, issueType: "Story", status: "DEV", url: "u"),
            JiraTicket(key: "PAY-230", summary: "Retry failed payment webhooks with backoff", description: nil, issueType: "Task", status: "In Progress", url: "u"),
            JiraTicket(key: "SHOP-1088", summary: "Cut product page load time in half", description: nil, issueType: "Task", status: "In Progress", url: "u"),
            JiraTicket(key: "SHOP-1640", summary: "Fix the storefront's Lighthouse accessibility score", description: nil, issueType: "Bug", status: "To Do", url: "u"),
        ]

        // Built rather than `TaskDraft.initial`, which asks git for the base branch of whatever
        // directory the renderer runs in.
        let preference = TaskDraft.preference(for: .claude, state: .empty, defaults: Fixture.defaults)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: preference.model, reasoning: preference.reasoning)
        write(NewTaskSheet(model: TaskCreationModel(project: project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in }), previewStep: 1, previewTickets: tickets,
                           previewTicketsOpen: false),
              to: out.appendingPathComponent("step1-closed.png"))
        write(NewTaskSheet(model: TaskCreationModel(project: project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in }), previewStep: 1, previewTickets: tickets),
              to: out.appendingPathComponent("step1-empty.png"))
        draft.apply(ticket: tickets[3])
        write(NewTaskSheet(model: TaskCreationModel(project: project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in }), previewStep: 1, previewTickets: tickets),
              to: out.appendingPathComponent("step1-picked.png"))
        write(NewTaskSheet(model: TaskCreationModel(project: project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in }), previewStep: 2, previewTickets: tickets),
              to: out.appendingPathComponent("step2-agent.png"))
        draft.promptText = "/superpowers:brainstorming\nStart with the worker's shutdown path and the queue drain."
        write(NewTaskSheet(model: TaskCreationModel(project: project, draft: draft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in }), previewStep: 3, previewTickets: tickets),
              to: out.appendingPathComponent("step3-prompt.png"))
        // The completion popup open on the prompt's third line, where it hangs past the field and
        // over the hint, the checkbox and the command preview below it. Hosted only: under
        // ImageRenderer the editor never lives long enough for the popup to be opened on it.
        if ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_HOSTED"] == "1" {
            var completingDraft = draft
            completingDraft.promptText = "Start with the worker's shutdown path.\nThen the queue drain.\n/s"
            let completing = TaskCreationModel(project: project, draft: completingDraft, home: Fixture.home, catalogue: Fixture.catalogue, searchIssues: { _ in tickets }, createTask: { _ in })
            let skills = [
                AgentCompletion(name: "superpowers:brainstorming", kind: .skill, detail: "You MUST use this before any creative work", source: .plugin("superpowers")),
                AgentCompletion(name: "superpowers:finishing-a-development-branch", kind: .skill, detail: "Use when implementation is complete", source: .plugin("superpowers")),
                AgentCompletion(name: "pdf", kind: .skill, detail: "Use this skill whenever the user wants to do anything with PDF files", source: .user),
                AgentCompletion(name: "review", kind: .command, detail: "Review a pull request", source: .builtIn),
                AgentCompletion(name: "simplify", kind: .skill, detail: "Review the changed code for reuse", source: .user),
                AgentCompletion(name: "loop", kind: .skill, detail: "Run a prompt on a recurring interval", source: .user),
                AgentCompletion(name: "security-review", kind: .skill, detail: "Review the pending changes", source: .user),
                AgentCompletion(name: "statusline", kind: .command, detail: "Set up the status line", source: .builtIn),
            ]
            let completions = completing.completions
            func open() {
                completions.visible = skills
                completions.anchor = CGPoint(x: Space.snug, y: 64)
                completions.fieldWidth = Sheet.width - 2 * Space.margin
            }
            // Opened late: the sheet's catalogue load, which runs on appear, closes the popup.
            write(NewTaskSheet(model: completing, previewStep: 3, previewTickets: tickets)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { open() } },
                  to: out.appendingPathComponent("step3-completions.png"))
        }
        let mergeRequests = [
            MergeRequest(iid: 4, title: "Add a gift-card field to checkout", sourceBranch: "feat-gift-card",
                         targetBranch: "main", author: "Sam Rivera", state: "opened", draft: false,
                         url: "https://git.example.net/acme/storefront/-/merge_requests/4"),
            MergeRequest(iid: 7, title: "Drop the unused CDN origin", sourceBranch: "chore-drop-cdn-origin",
                         targetBranch: "main", author: "Alex Kim", state: "opened", draft: true,
                         url: "https://git.example.net/acme/storefront/-/merge_requests/7"),
        ]
        let reviewDraft = ReviewDraft(mr: nil, agent: .claude, model: draft.model, reasoning: draft.reasoning)
        func reviewModel() -> ReviewCreationModel {
            ReviewCreationModel(project: project, draft: reviewDraft, home: Fixture.home, catalogue: Fixture.catalogue,
                                searchMergeRequests: { _ in mergeRequests }, createReview: { _ in })
        }
        write(NewReviewSheet(model: reviewModel(), previewStep: 1, previewMergeRequests: mergeRequests),
              to: out.appendingPathComponent("review-step1.png"))
        write(NewReviewSheet(model: reviewModel(), previewStep: 2, previewMergeRequests: mergeRequests),
              to: out.appendingPathComponent("review-step2.png"))
        // Step 3 is reached only with a branch, which its destination line names.
        let picked = reviewModel()
        picked.draft.apply(mr: mergeRequests[0])
        write(NewReviewSheet(model: picked, previewStep: 3, previewMergeRequests: mergeRequests),
              to: out.appendingPathComponent("review-step3.png"))
        // A branch that is already a task's: the sheet says the review opens there.
        let ownedModel = ReviewCreationModel(project: project, draft: reviewDraft, home: Fixture.home, catalogue: Fixture.catalogue,
                                             owningTask: { branch, _ in branch == working.branch ? working : nil },
                                             searchMergeRequests: { _ in mergeRequests }, createReview: { _ in })
        ownedModel.draft.setTitle(working.title)
        ownedModel.draft.setBranch(working.branch)
        write(NewReviewSheet(model: ownedModel, previewStep: 1, previewMergeRequests: mergeRequests, previewOpen: false),
              to: out.appendingPathComponent("review-in-task.png"))
        // What the footer makes of a refused `worktree add`: the `fatal:` line as a sentence
        // (`GitError.sentence`), not the command and git's "Preparing worktree" narration that
        // used to fill the three lines — those are the tooltip.
        let fatal = "fatal: 'feat/pay-214-apple-pay' is already used by worktree at '\(project.path)/.worktrees/pay-214-apple-pay'"
        let refused = CreationFailure(GitError(args: ["worktree", "add", "\(project.path)/.worktrees/review-pay-214-apple-pay", "feat/pay-214-apple-pay"],
                                               code: 128, stderr: "Preparing worktree (checking out 'feat/pay-214-apple-pay')\n" + fatal))
        write(CreationFooter(step: 3, error: refused, availableAgents: [.claude],
                             createLabel: "Create Review", creating: false, canAdvance: true, back: {}, advance: {}, escape: {})
                .padding(Space.margin).frame(width: Sheet.width).background(Palette.surfaceRaised),
              to: out.appendingPathComponent("sheet-git-error.png"))
        write(NewTerminalSheet(project: project, suggestedName: "shell 2", branch: "main", canCreate: true, createTerminal: { _ in }),
              to: out.appendingPathComponent("terminal.png"))
        nameSheets(fixture, to: out)
    }

    /// The other `NameSheet` flows, built as `SidebarSheet` builds them: Add divider, and the
    /// renames of a divider, a task and a terminal, each with its band's sentence.
    private static func nameSheets(_ fixture: Fixture, to out: URL) {
        write(NameSheet.newDivider(canSubmit: true, submit: { _ in }), to: out.appendingPathComponent("name-new-divider.png"))
        let divider = AppController.RenameTarget.divider(SidebarDivider(id: UUID(), name: "Clients"))
        let task = AppController.RenameTarget.task(fixture.working)
        let terminal = AppController.RenameTarget.terminal(TerminalItem(id: UUID(), projectId: fixture.project.id, name: "shell",
                                                                        windowId: "w", createdAt: Date()))
        for (target, file) in [(divider, "name-rename-divider.png"), (task, "name-rename-task.png"),
                               (terminal, "name-rename-terminal.png")] {
            write(NameSheet.rename(target, canSubmit: true, submit: { _ in }), to: out.appendingPathComponent(file))
        }
    }

    /// The Jira projects sheet and every Settings tab.
    private static func settings(_ fixture: Fixture, to out: URL) {
        let controller = fixture.controller, project = fixture.project
        let harnessSettings = HarnessSettingsModel.preview()
        // The Jira projects sheet with two linked and the picker's list down, leaving them out.
        // Seeded rather than loaded, the way the settings fixtures are: `loadProjects` is a network
        // call the renderer never waits for.
        let site = URL(string: "https://example.atlassian.net")!
        let jiraProjects = [
            // The fixture project's two, by the same ids, as Jira would list them.
            JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site),
            JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site),
            JiraProjectRef(id: "3", key: "SUP", name: "Customer support", siteURL: site),
            JiraProjectRef(id: "4", key: "MOB", name: "Mobile", siteURL: site),
            JiraProjectRef(id: "5", key: "PLT", name: "Platform engineering", siteURL: site),
            JiraProjectRef(id: "6", key: "SEC", name: "Security", siteURL: site),
        ]
        var jiraSheet = JiraProjectSheet(projectName: project.name, linked: project.jiraProjects, canSubmit: true,
                                         loadProjects: { jiraProjects }, submit: { _ in })
        jiraSheet._projects = State(initialValue: jiraProjects)
        jiraSheet._loading = State(initialValue: false)
        jiraSheet._open = State(initialValue: true)
        write(jiraSheet, to: out.appendingPathComponent("jira-project.png"))
        for tab in SettingsTab.allCases {
            // A Jira site and email typed in, no token yet.
            let jira = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "you@example.com", token: "")
            let settings = SettingsView(jiraConfig: jira, gitLabConfig: nil,
                                        harnessModel: harnessSettings,
                                        itermConnection: { .connected(version: "3.7.2") },
                                        checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                        preferences: controller.preferences, setMatchItermBackground: { _ in }, setInterfaceSize: { _ in }, initialTab: tab)
            write(settings, to: out.appendingPathComponent("settings-\(tab.rawValue.lowercased()).png"))
        }
        // The sheet clips a tab to its height, and the Interface tab runs on past it into the
        // keyboard section, so the whole tab is drawn once more at full length, on the sheet's
        // ground and inside its margins.
        let preferences = controller.preferences
        let interface = InterfaceSettingsPane(matchItermBackground: .constant(preferences.matchItermBackground),
                                              badgeDetails: .constant(preferences.badgeDetails),
                                              interfaceSize: .constant(preferences.interfaceSize))
            .padding(Space.margin).frame(width: Sheet.width).background(Palette.surface)
        write(interface, to: out.appendingPathComponent("settings-interface-full.png"))
        // The iTerm card's other shape: a broken link, and the numbered steps that mend it.
        let apiOff = ItermEnvironment(installed: true, pythonAPIEnabled: false)
        var itermOff = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: harnessSettings,
                                    itermConnection: { .waitingForIterm }, checkIterm: { apiOff },
                                    preferences: controller.preferences, setMatchItermBackground: { _ in }, setInterfaceSize: { _ in }, initialTab: .integrations)
        itermOff._itermEnvironment = State(initialValue: apiOff)
        write(itermOff, to: out.appendingPathComponent("settings-iterm-off.png"))
    }

    private static func marks(to out: URL) {
        // Every round mark side by side at every size it is drawn at, plus one large row, so their
        // optical balance can be judged against each other rather than one screen at a time.
        write(VStack(alignment: .leading, spacing: Space.base) {
            ForEach([Size.vendorMark, Size.avatar, Size.control, 96], id: \.self) { size in
                HStack(spacing: Space.base) {
                    ForEach([SessionAgent.claude, .codex, .grok, .pi, .shell], id: \.self) { VendorMark(agent: $0, size: size) }
                    IntegrationMark(service: .jira, size: size)
                    IntegrationMark(service: .gitlab, size: size)
                    IntegrationMark(service: .github, size: size)
                }
            }
        }
        .padding(Space.inset)
        .background(Palette.sidebar), to: out.appendingPathComponent("marks.png"))
    }

    private static func collapsedSidebar(_ fixture: Fixture, to out: URL) {
        let controller = fixture.controller, project = fixture.project
        let working = fixture.working, other = fixture.other
        // Last, because it rewrites the fixtures: a collapsed project, with a task in every
        // status, so the header's count chips have all four to draw.
        let idle = TaskItem(id: UUID(), projectId: project.id, title: "Rename the settings pane", branch: "chore/settings",
                            worktreePath: "/r/.worktrees/z", baseBranch: "main", jira: nil, agent: .claude, model: "opus",
                            reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
        let done = TaskItem(id: UUID(), projectId: project.id, title: "Ship the usage footer", branch: "feat/usage-footer",
                            worktreePath: "/r/.worktrees/w", baseBranch: "main", jira: nil, agent: .claude, model: "opus",
                            reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w4")
        controller.state.tasks = [working, other, idle, done]
        controller.live.sessions += [session("s6", "w4", done.id, "claude", "done", 0)].compactMap { $0 }
        controller.state.projects[0].collapsed = true
        let collapsed = SidebarModel.sections(state: controller.state, sessions: controller.live.sessions,
                                              branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                              diffByTask: controller.checkouts.diffByTask)[0]
        write(VStack(alignment: .leading, spacing: Space.hairline) {
            SidebarHeader(controller: controller)
            ProjectHeaderRow(section: collapsed, controller: controller)
            Spacer()
        }
        .padding(.horizontal, Space.inset)
        .frame(width: Size.sidebarWidth + 20, height: 76)
        .background(Palette.sidebar), to: out.appendingPathComponent("sidebar-collapsed.png"))
    }

    /// Last, so the images before it render as they did before it existed: drawing one more image
    /// first nudged a later sheet's antialiasing by a level.
    private static func banners(to out: URL) {
        // Every banner the sidebar can raise, one of each tone: their text shares one leading edge.
        write(VStack(spacing: 0) {
            SidebarBanner(text: "Couldn’t save the workspace: the disk is full.", tone: .error,
                          actions: [.init(title: "Retry Saving") {}])
            SidebarBanner(text: "Branch feat/migrate-alert kept.", detail: "It has commits that aren’t on main.", tone: .error,
                          actions: ["Keep Branch", "Delete Branch…", "Dismiss"].map { .init(title: $0) {} }, vertical: Space.base)
            SidebarBanner(text: ItermConnection.refused("not allowed").banner?.text ?? "", tone: .warning, trailing: Space.block)
            SidebarBanner(text: "Waiting for iTerm2…", tone: .info, trailing: Space.block)
        }
        .frame(width: Size.sidebarWidth + 20)
        .background(Palette.sidebar), to: out.appendingPathComponent("sidebar-banners.png"))
    }

    /// Rows on their way out, unselected and selected: removing, closing, and a removal that stopped
    /// short of the row with its note. After `banners`, so no earlier image moves; it puts back the
    /// tasks `collapsedSidebar` rewrote.
    private static func removalRows(_ fixture: Fixture, to out: URL) {
        let controller = fixture.controller
        controller.state.projects[0].collapsed = false
        controller.state.tasks = [fixture.working, fixture.other, fixture.piTask, fixture.grokTask]
        controller.seedSnapshotRemoval(.removing, of: fixture.working.id)
        controller.seedSnapshotRemoval(.removing, of: fixture.piTask.id)
        controller.seedSnapshotRemoval(.closing, of: fixture.grokTask.id)
        controller.seedSnapshotRemoval(.stopped(note: "Not removed: branch kept", worktreeRemoved: true), of: fixture.other.id)
        controller.report(.branchKept(fixture.other.branch, of: fixture.other.id, because: .notMerged(base: "develop")))
        func rows() -> some View {
            let section = SidebarModel.sections(state: controller.state, sessions: controller.live.sessions,
                                                branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                                diffByTask: controller.checkouts.diffByTask)[0]
            return VStack(alignment: .leading, spacing: Space.hairline) {
                ForEach(section.tasks) { row in
                    TaskRowView(row: row, task: controller.state.tasks.first { $0.id == row.id }, controller: controller)
                }
            }
            .padding(.horizontal, Space.inset)
            .frame(width: Size.sidebarWidth + 20)
            .background(Palette.sidebar)
        }
        write(rows(), to: out.appendingPathComponent("sidebar-removal.png"))
        // The note on the accent, where it yields its amber.
        controller.focus.browse(.task(fixture.other.id))
        write(rows(), to: out.appendingPathComponent("sidebar-removal-selected.png"))
    }

    /// A project header on the arrow path, selected: open over its terminal row, and folded with
    /// its count chips. After `removalRows`, so no earlier image moves.
    private static func selectedHeaders(_ fixture: Fixture, to out: URL) {
        let controller = fixture.controller, project = fixture.project
        controller.focus.browse(.project(project.id))
        func header() -> some View {
            let section = SidebarModel.sections(state: controller.state, sessions: controller.live.sessions,
                                                branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                                diffByTask: controller.checkouts.diffByTask)[0]
            return VStack(alignment: .leading, spacing: Space.hairline) {
                ProjectHeaderRow(section: section, controller: controller)
                if !section.collapsed {
                    ForEach(section.terminals) { row in
                        TerminalRowView(row: row, terminal: controller.state.terminals.first { $0.id == row.id }, project: project,
                                        controller: controller)
                    }
                }
            }
            .padding(.horizontal, Space.inset).padding(.vertical, Space.tight)
            .frame(width: Size.sidebarWidth + 20)
            .background(Palette.sidebar)
        }
        controller.state.projects[0].collapsed = false
        write(header(), to: out.appendingPathComponent("sidebar-header-selected.png"))
        controller.state.projects[0].collapsed = true
        write(header(), to: out.appendingPathComponent("sidebar-header-selected-collapsed.png"))
        controller.state.projects[0].collapsed = false
    }

    /// The sidebar with no project yet: the block under `PROJECTS`, at ×1 and at the largest size.
    /// Last, so no earlier image moves.
    private static func emptySidebar(_ fixture: Fixture, to out: URL) {
        for (name, scale) in [("", InterfaceScale.standard), ("-extra-large", .extraLarge)] {
            write(VStack(alignment: .leading, spacing: scale(Space.hairline)) {
                SidebarHeader(controller: fixture.controller)
                SidebarEmptyState(canAdd: true, add: {})
                Spacer()
            }
            .padding(.horizontal, scale(Space.inset))
            .frame(width: scale(Size.sidebarWidth) + 2 * scale(Space.inset), height: scale(200))
            .background(Palette.sidebar)
            .surface(.sidebar)
            .interfaceScale(scale), to: out.appendingPathComponent("sidebar-empty\(name).png"))
        }
    }

    private static func write(_ view: some View, to url: URL) {
        if ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_HOSTED"] == "1" {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            let size = host.fittingSize
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            if ProcessInfo.processInfo.environment["AITERM_SNAPSHOT_NATIVE_CAPTURE"] == "1" {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
                try? capture.run()
                capture.waitUntilExit()
                if capture.terminationStatus == 0 { window.orderOut(nil); return }
                print("WindowServer capture unavailable for \(url.lastPathComponent); using view capture")
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
            }
            window.orderOut(nil)
            return
        }
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.snapshotRendering, true))
        renderer.scale = 2
        // `colorScheme` reaches SwiftUI; an AppKit colour resolves against the drawing appearance,
        // which is the app's only while `Appearance.apply` has run. Pinned here, the images are
        // dark whatever the process or the system is set to.
        var png: Data?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return }
            png = rep.representation(using: .png, properties: [:])
        }
        guard let png else { print("could not render \(url.lastPathComponent)"); return }
        try? png.write(to: url)
    }
}

/// The README's picture: the two windows and nothing behind them — the real `SidebarView` at
/// `Size.sidebarMinWidth`, and a drawn iTerm2 window `Snap.taskFrame`'s 12 pt to its right — on a
/// transparent ground with room left for their shadows. Everything here but the sidebar
/// approximates what macOS and iTerm2 draw, so its numbers are this view's own, not `Metrics` tokens.
private struct ReadmeDesktop: View {
    let controller: AppController
    let tabTitle: String
    let tabs: Int

    /// The windows' size, as they were on the 1512 × 982 pt desktop the picture used to sit on.
    static let windowHeight: CGFloat = 862, windowsWidth: CGFloat = 1300, gap: CGFloat = 12
    /// The transparent margin around the windows: enough for `DesktopWindow`'s shadow, which
    /// falls 24 pt down, so the bottom gets more than the top.
    static let side: CGFloat = 72, top: CGFloat = 60, bottom: CGFloat = 108
    /// The band a window's traffic lights sit in, and iTerm2's title bar.
    static let titleBar: CGFloat = 28

    var body: some View {
        let terminalWidth = Self.windowsWidth - Size.sidebarMinWidth - Self.gap
        HStack(alignment: .top, spacing: Self.gap) {
            DesktopWindow {
                // The list's own top inset already clears the traffic lights, as the real
                // window's transparent title bar leaves it.
                SidebarView(controller: controller)
            }
            .frame(width: Size.sidebarMinWidth, height: Self.windowHeight)
            DesktopWindow { ItermWindow(title: tabTitle, tabs: tabs) }
                .frame(width: terminalWidth, height: Self.windowHeight)
        }
        .padding(.horizontal, Self.side)
        .padding(.top, Self.top).padding(.bottom, Self.bottom)
    }
}

/// A window's frame: rounded, edged in a faint light line, its traffic lights over the content's
/// top band, and a deep shadow on whatever the picture is set on.
private struct DesktopWindow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 12, height: 12) }
                }
                .frame(height: ReadmeDesktop.titleBar)
                .padding(.leading, 12)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 35, y: 24)
    }
}

/// The iTerm2 profile the picture draws: the default profile's Monokai colours, in MesloLGS NF,
/// with Interface → "Use dark terminal background" on, so the daemon paints AiTerm's tabs the
/// `#1E1E1E` it sets in `set_aiterm_background`. The profile's tab style is Minimal, so the title
/// bar and the tabs take that background too.
private enum Monokai {
    static let background = Color(hex: 0x1E1E1E), foreground = Color(hex: 0xFDFFF1)
    static let red = Color(hex: 0xF92672), green = Color(hex: 0xA6E22E), yellow = Color(hex: 0xE6DB74)
    static let magenta = Color(hex: 0xAE81FF), cyan = Color(hex: 0x66D9EF)
    /// The profile's bold colour: iTerm2 draws bold text in the default foreground in it.
    static let bold = cyan
    /// ANSI 8, bright black.
    static let brightBlack = Color(hex: 0x6E7066)
    /// Faint text: iTerm2 draws it at half opacity, which over `background` lands here.
    static let faint = Color(hex: 0x8E8E87)
    static let cursor = Color(hex: 0xC0C1B5)
    /// The Minimal tab bar's ground behind the tabs that are not in front, and the lines between them.
    static let tabBar = Color(hex: 0x171717), tabLine = Color(hex: 0x111111)

    static func font(_ weight: Font.Weight = .regular) -> Font {
        // Fall back to the system monospace so a machine without Meslo keeps the columns.
        NSFont(name: "MesloLGS NF", size: 12) == nil
            ? .system(size: 12, weight: weight, design: .monospaced)
            : .custom("MesloLGS NF", fixedSize: 12).weight(weight)
    }
}

/// iTerm2's window for the selected task: its title bar, one tab per session — each titled with
/// the task's branch, as `SidebarModel.sessionTitles` sets it — and Claude Code mid-turn in front.
private struct ItermWindow: View {
    let title: String
    let tabs: Int

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Monokai.foreground.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: ReadmeDesktop.titleBar)
                .background(Monokai.background)
            HStack(spacing: 0) {
                ForEach(0..<tabs, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("×").opacity(0.6)
                        Text(title).lineLimit(1).frame(maxWidth: .infinity)
                        Text("⌘\(index + 1)").font(.system(size: 11)).opacity(0.6)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Monokai.foreground.opacity(index == 0 ? 0.9 : 0.5))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(index == 0 ? Monokai.background : .clear)
                    .overlay(alignment: .trailing) { Monokai.tabLine.frame(width: 1) }
                }
            }
            .frame(height: 26)
            .background(Monokai.tabBar)
            .overlay(alignment: .bottom) { Monokai.tabLine.frame(height: 1) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ClaudeTurn.lines.enumerated()), id: \.offset) { _, line in line }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Monokai.background)
        }
    }
}

/// Claude Code's transcript in the front tab, one 16 pt line at a time in the profile's 12 pt mono.
/// Claude Code runs its `dark-ansi` theme, so every colour is an ANSI slot of `Monokai`: Claude's
/// own accent is bright red, success bright green, the text bright white, the dim text faint,
/// the auto-accept mode bright magenta, and the user's prompt sits on bright black. Bold text takes
/// the profile's bold colour. A diff has no line washes: its gutter carries the red and green, the
/// removed code is faint, and the rest is highlighted in the profile's colours.
private enum ClaudeTurn {
    enum Ink { case text, dim, green, red, accent, bold, mode, keyword, type, function, link, boldLink }
    typealias Run = (String, Ink)

    static let lineHeight: CGFloat = 16

    static var lines: [AnyView] {
        [
            line(("✻", .accent), (" ", .text), ("Welcome to Claude Code", .bold), ("  · opus · ~/aiterm/.worktrees/session-tracker", .dim)),
            blank,
            prompt("> Refactor the session tracker into one owner: LiveSessions and CheckoutMonitor"),
            prompt("  each keep their own copy of the open tabs. Fold that into a SessionTracker."),
            blank,
            line(("⏺", .green), (" Both copies are rebuilt from the same workspace snapshot, so one owner can", .text)),
            line(("  feed the sidebar and the tab titles alike. Reading both first.", .text)),
            blank,
            tool("Read", "app/Sources/AiTerm/LiveSessions.swift"), result(("Read ", .text), ("214", .bold), (" lines", .text)), blank,
            tool("Read", "app/Sources/AiTerm/CheckoutMonitor.swift"), result(("Read ", .text), ("171", .bold), (" lines", .text)), blank,
            tool("Write", "app/Sources/AiTerm/SessionTracker.swift"),
            result(("Wrote ", .text), ("96", .bold), (" lines to ", .text), ("app/Sources/AiTerm/SessionTracker.swift", .boldLink)), blank,
            tool("Update", "app/Sources/AiTerm/CheckoutMonitor.swift"),
            result(("Added ", .text), ("1", .bold), (" line, removed ", .text), ("2", .bold), (" lines", .text)),
            diff(162, nil, "    /// The titles read the tabs as they are after the pass."),
            diff(163, nil, "    private func syncTitles(_ scan: WorkspaceScan) async {"),
            diff(164, "-", "        let sessions = live.sessions"),
            diff(165, "-", "        let titles = SidebarModel.sessionTitles(state: workspace(),"),
            diff(164, "+", "        let titles = tracker.titles(after: scan)"),
            diff(165, nil, "            await onTitles(titles, tracker.sessions)"),
            blank,
            tool("Bash", "scripts/test.sh", link: false),
            result(("Executed 412 tests, with 0 failures", .text)), blank,
            line(("✶ Moving tab titles onto the tracker…", .accent), (" (4m 02s · ↓ 6.2k tokens · esc to interrupt)", .dim)),
            blank,
            rule,
            AnyView(HStack(spacing: 0) {
                text([("> ", .dim)])
                Rectangle().fill(Monokai.cursor).frame(width: 7, height: 15)
            }.frame(height: lineHeight)),
            rule,
            line(("  ⏵⏵ accept edits on", .mode), (" (shift+tab to cycle)", .dim)),
        ]
    }

    static var blank: AnyView { AnyView(Color.clear.frame(height: lineHeight)) }
    static var rule: AnyView {
        AnyView(Monokai.brightBlack.frame(height: 1).frame(maxWidth: .infinity).frame(height: lineHeight))
    }
    /// A line of the user's prompt, on the theme's message background across the whole row.
    static func prompt(_ text: String) -> AnyView {
        AnyView(self.text([(text, .text)])
            .frame(maxWidth: .infinity, minHeight: lineHeight, maxHeight: lineHeight, alignment: .leading)
            .background(Monokai.brightBlack))
    }
    /// A tool call; a file argument is a link, which iTerm2 underlines dashed.
    static func tool(_ name: String, _ argument: String, link: Bool = true) -> AnyView {
        line(("⏺", .green), (" ", .text), (name, .bold), ("(", .text), (argument, link ? .link : .text), (")", .text))
    }
    static func result(_ runs: Run...) -> AnyView { line([("  ⎿  ", .text)] + runs) }
    /// A diff line: its number, then `-` or `+` for a removed or added line, then the code.
    static func diff(_ number: Int, _ sign: String?, _ code: String) -> AnyView {
        let mark: Ink = sign == "-" ? .red : sign == "+" ? .green : .dim
        return line([("    \(number) \(sign == "-" ? "−" : sign ?? " ")  ", mark)]
                    + (sign == "-" ? [(code, .dim)] : highlighted(code)))
    }
    /// Swift as the profile highlights it: keywords magenta, types cyan, a declared function yellow,
    /// comments faint, everything else the foreground.
    static func highlighted(_ code: String) -> [Run] {
        if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return [(code, .dim)] }
        let keywords: Set = ["private", "func", "let", "var", "await", "async", "return"]
        var runs: [Run] = [], word = "", previous = ""
        func flush() {
            guard !word.isEmpty else { return }
            let ink: Ink = keywords.contains(word) ? .keyword
                : previous == "func" ? .function
                : word.first!.isUppercase ? .type : .text
            runs.append((word, ink)); previous = word; word = ""
        }
        for character in code {
            if character.isLetter || character.isNumber || character == "_" && !word.isEmpty { word.append(character) }
            else { flush(); runs.append((String(character), .text)) }
        }
        flush()
        return runs
    }
    static func line(_ runs: Run...) -> AnyView { line(runs) }
    static func line(_ runs: [Run]) -> AnyView {
        AnyView(text(runs).frame(height: lineHeight, alignment: .leading))
    }

    static func text(_ runs: [Run]) -> Text {
        var string = AttributedString()
        for (chunk, ink) in runs {
            var run = AttributedString(chunk)
            switch ink {
            case .text: run.foregroundColor = Monokai.foreground
            case .dim: run.foregroundColor = Monokai.faint
            case .green: run.foregroundColor = Monokai.green
            case .red, .accent: run.foregroundColor = Monokai.red
            case .mode, .keyword: run.foregroundColor = Monokai.magenta
            case .type: run.foregroundColor = Monokai.cyan
            case .function: run.foregroundColor = Monokai.yellow
            case .link:
                run.foregroundColor = Monokai.foreground
                run.underlineStyle = Text.LineStyle(pattern: .dash)
            case .bold, .boldLink:
                run.foregroundColor = Monokai.bold
                run.font = Monokai.font(.bold)
                if ink == .boldLink { run.underlineStyle = Text.LineStyle(pattern: .dash) }
            }
            string += run
        }
        return Text(string).font(Monokai.font())
    }
}

private extension Color {
    init(hex: Int, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
#endif
