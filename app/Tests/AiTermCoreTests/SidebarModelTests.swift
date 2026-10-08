import Testing
import Foundation
import Synchronization
@testable import AiTermCore

@Suite struct SidebarModelTests {
    func session(_ id: String, task: String?, agent: SessionAgent, state: SessionState, tab: Int, window: String = "w1", project: String? = nil,
                 cwd: String = "", agentCwd: String? = nil, active: Bool = false, context: Int? = nil) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: window, tabIndex: tab, taskId: task, projectId: project, agent: agent, model: nil, state: state,
                    title: "", cwd: cwd, agentCwd: agentCwd, active: active, contextPercent: context)
    }

    @Test func testAggregateWorstWins() {
        #expect(SidebarModel.aggregate([.idle, .done, .working]) == .working)
        #expect(SidebarModel.aggregate([.working, .needsInput]) == .needsInput)
        #expect(SidebarModel.aggregate([.idle, .done]) == .done)
        #expect(SidebarModel.aggregate([]) == .idle)
    }

    func taskRow(_ status: TaskStatus) -> TaskRow {
        TaskRow(id: UUID(), title: "t", jiraKey: nil, jiraUrl: nil, mr: nil, branch: .none, avatars: AvatarGroup(marks: [], overflow: 0), status: status)
    }

    func terminalRow(_ status: TaskStatus) -> TerminalRow {
        TerminalRow(id: UUID(), name: "Terminal", branch: .none, avatars: AvatarGroup(marks: [], overflow: 0), status: status)
    }

    @Test func testStatusCountsOrderTheLifecycleAndDropEmptyOnes() {
        let rows = [taskRow(.done), taskRow(.needsInput), taskRow(.idle), taskRow(.needsInput), taskRow(.idle), taskRow(.idle)]
        #expect(SidebarModel.statusCounts(tasks: rows) == [StatusCount(status: .idle, count: 3),
                                                    StatusCount(status: .needsInput, count: 2),
                                                    StatusCount(status: .done, count: 1)])
        #expect(SidebarModel.statusCounts(tasks: [taskRow(.working)]) == [StatusCount(status: .working, count: 1)])
        #expect(SidebarModel.statusCounts(tasks: []) == [])
    }

    @Test func testCollapsedStatusCountsIncludeTasksAndTerminals() {
        let counts = SidebarModel.statusCounts(tasks: [taskRow(.done), taskRow(.idle)],
                                               terminals: [terminalRow(.working), terminalRow(.needsInput), terminalRow(.idle)])
        #expect(counts == [StatusCount(status: .idle, count: 2),
                           StatusCount(status: .working, count: 1),
                           StatusCount(status: .needsInput, count: 1),
                           StatusCount(status: .done, count: 1)])
    }

    /// A project with nothing under it has nothing to disclose: it draws collapsed whatever it
    /// stored, and goes back to its stored state as soon as a task or a terminal lands in it.
    @Test func testAProjectWithNoRowsIsCollapsedWhateverItStored() {
        var project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let empty = ProjectSection(project: project, tasks: [], terminals: [])
        #expect(empty.isEmpty)
        #expect(empty.collapsed)
        #expect(!ProjectSection(project: project, tasks: [taskRow(.idle)], terminals: []).collapsed)
        #expect(!ProjectSection(project: project, tasks: [], terminals: [terminalRow(.idle)]).collapsed)
        project.collapsed = true
        #expect(ProjectSection(project: project, tasks: [taskRow(.idle)], terminals: []).collapsed)
    }

    /// Focus View (⌘F): a project with a done or a needs-input row opens, every other one with rows folds, and a
    /// project with no rows is left out — it draws collapsed whatever it stored.
    @Test func focusViewOpensOnlyTheProjectsWaitingOnYou() {
        func section(tasks: [TaskRow] = [], terminals: [TerminalRow] = [], collapsed: Bool) -> ProjectSection {
            ProjectSection(project: Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                                            addedAt: Date(), collapsed: collapsed), tasks: tasks, terminals: terminals)
        }
        let done = section(tasks: [taskRow(.idle), taskRow(.done)], collapsed: true)
        let asking = section(terminals: [terminalRow(.needsInput)], collapsed: true)
        let busy = section(tasks: [taskRow(.working), taskRow(.idle)], terminals: [terminalRow(.idle)], collapsed: false)
        let empty = section(collapsed: false)
        #expect(SidebarModel.focusView([done, asking, busy, empty])
                == [done.id: false, asking.id: false, busy.id: true])
    }

    /// With nothing waiting — only working or idle rows — every project with rows folds to its header.
    @Test func focusViewFoldsEverythingWhenNothingNeedsAttention() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        #expect(SidebarModel.focusView([ProjectSection(project: project, tasks: [taskRow(.working)], terminals: [terminalRow(.idle)])])
                == [project.id: true])
        #expect(SidebarModel.focusView([]) == [:])
    }

    /// The row Focus View goes to, in drawing order: projects top to bottom, terminals above tasks,
    /// a skipped task passed over, and none when nothing waits.
    @Test func firstNeedingAttentionFollowsTheDrawingOrder() {
        func section(tasks: [TaskRow] = [], terminals: [TerminalRow] = []) -> ProjectSection {
            ProjectSection(project: Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                                            addedAt: Date(), collapsed: false), tasks: tasks, terminals: terminals)
        }
        let busy = section(tasks: [taskRow(.working)])
        let done = taskRow(.done), asking = terminalRow(.needsInput), later = taskRow(.needsInput)
        let waiting = section(tasks: [done, later], terminals: [asking])
        #expect(SidebarModel.firstNeedingAttention([busy, waiting]) == .terminal(asking.id))
        let tasksOnly = section(tasks: [done, later])
        #expect(SidebarModel.firstNeedingAttention([busy, tasksOnly]) == .task(done.id))
        #expect(SidebarModel.firstNeedingAttention([tasksOnly], skippingTasks: [done.id]) == .task(later.id))
        #expect(SidebarModel.firstNeedingAttention([busy]) == nil)
        // The whole list Focus View steps through, in the same order; the Dock badge counts it.
        #expect(SidebarModel.needingAttention([busy, waiting]) == [.terminal(asking.id), .task(done.id), .task(later.id)])
        #expect(SidebarModel.needingAttention([waiting], skippingTasks: [done.id]) == [.terminal(asking.id), .task(later.id)])
        #expect(SidebarModel.needingAttention([busy]).isEmpty)
    }

    /// List View (⌘L): every project with rows opens, whatever its rows say; empty ones are left out.
    @Test func listViewOpensEveryProjectWithRows() {
        func section(tasks: [TaskRow] = [], terminals: [TerminalRow] = [], collapsed: Bool) -> ProjectSection {
            ProjectSection(project: Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                                            addedAt: Date(), collapsed: collapsed), tasks: tasks, terminals: terminals)
        }
        let folded = section(tasks: [taskRow(.working)], collapsed: true)
        let shell = section(terminals: [terminalRow(.idle)], collapsed: true)
        let open = section(tasks: [taskRow(.done)], collapsed: false)
        let empty = section(collapsed: true)
        #expect(SidebarModel.listView([folded, shell, open, empty]) == [folded.id: false, shell.id: false, open.id: false])
        #expect(SidebarModel.listView([empty]) == [:])
    }

    @Test func testStatusCountsLabelNamesEveryStatus() {
        let counts = SidebarModel.statusCounts(tasks: [taskRow(.idle), taskRow(.working), taskRow(.needsInput), taskRow(.needsInput), taskRow(.done)])
        #expect(SidebarModel.statusCountsLabel(counts) == "1 idle, 1 working, 2 need input, 1 done")
        #expect(SidebarModel.statusCountsLabel([StatusCount(status: .needsInput, count: 1)]) == "1 needs input")
        #expect(SidebarModel.statusCountsLabel([]) == "")
    }

    @Test func testAvatarsMaxTwoWithOverflow() {
        let s = (0..<5).map { session("s\($0)", task: "t", agent: $0 % 2 == 0 ? .claude : .codex, state: .idle, tab: $0) }
        #expect(SidebarModel.avatars(for: Array(s.prefix(2))) == AvatarGroup(marks: [.claude, .codex], overflow: 0))
        #expect(SidebarModel.avatars(for: Array(s.prefix(3))) == AvatarGroup(marks: [.claude], overflow: 2))
        #expect(SidebarModel.avatars(for: s) == AvatarGroup(marks: [.claude], overflow: 4))
        #expect(SidebarModel.avatars(for: []) == AvatarGroup(marks: [], overflow: 0))
    }

    @Test func claudeCodexAndPiAvatarsFollowTabOrder() {
        let sessions = [
            session("pi", task: "t", agent: .pi, state: .working, tab: 2),
            session("claude", task: "t", agent: .claude, state: .idle, tab: 0),
            session("codex", task: "t", agent: .codex, state: .needsInput, tab: 1),
        ]
        #expect(SidebarModel.avatars(for: sessions, max: 3)
            == AvatarGroup(marks: [.claude, .codex, .pi], overflow: 0))
    }

    @Test func testSectionsMatchSessionsToTasksAndTerminals() {
        var state = AppState.empty
        let p = Project(id: UUID(), name: "acme-web", path: "/r", provider: .gitlab, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let t = TaskItem(id: UUID(), projectId: p.id, title: "SIGTERM", branch: "feat/web-5447-sigterm", worktreePath: "/r/.worktrees/x", baseBranch: "main", jira: JiraRef(key: "WEB-5447", summary: "SIGTERM", url: "u"), agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: true, createdAt: Date(), windowId: "w1")
        let term = TerminalItem(id: UUID(), projectId: p.id, name: "Terminal", windowId: "w9", createdAt: Date())
        state.items = [.project(p)]; state.tasks = [t]; state.terminals = [term]
        let sessions = [session("a", task: t.id.uuidString, agent: .claude, state: .working, tab: 0, cwd: "/r/.worktrees/x"),
                        session("b", task: t.id.uuidString, agent: .codex, state: .needsInput, tab: 1, cwd: "/r/.worktrees/x"),
                        session("c", task: nil, agent: .shell, state: .idle, tab: 0, window: "w9", project: p.id.uuidString, cwd: "/r")]
        let sections = SidebarModel.sections(state: state, sessions: sessions,
                                             branchByCwd: ["/r/.worktrees/x": "feat/web-5447-sigterm", "/r": "main"], projectBranch: [p.id: "main"])
        #expect(sections.count == 1)
        #expect(sections[0].tasks == [TaskRow(id: t.id, title: "SIGTERM", jiraKey: "WEB-5447", jiraUrl: "u", mr: nil,
                                              branch: BranchLabel(name: "feat/web-5447-sigterm", extra: 0, drifted: false, detail: ""),
                                              avatars: AvatarGroup(marks: [.claude, .codex], overflow: 0), status: .needsInput)])
        #expect(sections[0].terminals == [TerminalRow(id: term.id, name: "Terminal", branch: BranchLabel(name: "main", extra: 0, drifted: false, detail: ""),
                                                      avatars: AvatarGroup(marks: [.shell], overflow: 0), status: .idle)])
    }

    /// A tag read back from iTerm2 is a string; it names its task as a UUID, whatever its case —
    /// the same comparison the snapshot's window reattachment makes.
    @Test func aTabFindsItsTaskByTheIdItsTagNames() {
        var state = AppState.empty
        let p = Project(id: UUID(), name: "r", path: "/r", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let t = TaskItem(id: UUID(), projectId: p.id, title: "T", branch: "feat/t", worktreePath: "/r/.worktrees/t", baseBranch: "main",
                         jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false,
                         createdAt: Date(), windowId: "w1")
        state.items = [.project(p)]; state.tasks = [t]
        let sessions = [session("a", task: t.id.uuidString.lowercased(), agent: .codex, state: .working, tab: 0),
                        session("b", task: "not-a-uuid", agent: .claude, state: .needsInput, tab: 1)]
        let row = SidebarModel.sections(state: state, sessions: sessions, branchByCwd: [:], projectBranch: [:])[0].tasks[0]
        #expect(row.avatars == AvatarGroup(marks: [.codex], overflow: 0))
        #expect(row.status == .working)
        // The footer and the tab title follow the same rule as the row.
        #expect(SidebarModel.usageTaskRow(taskId: t.id, agent: .claude, sessions: sessions, contexts: [.codex: 40])
                == UsageTaskRow(agent: .codex, context: UsageLine(window: .context, percent: 40, reset: nil, warning: false)))
        #expect(SidebarModel.sessionTitles(state: state, sessions: sessions, branchByCwd: [:], projectBranch: [:])
                == [SessionTitle(sessionId: "a", title: "feat/t")])
        let asking = [session("a", task: t.id.uuidString.lowercased(), agent: .codex, state: .needsInput, tab: 0)]
        #expect(DockBadge.label(for: SidebarModel.sections(state: state, sessions: asking, branchByCwd: [:], projectBranch: [:])) == "1")
    }

    @Test func testSectionsPutTasksBeforeReviewsWithoutReorderingEitherLane() {
        var state = AppState.empty
        let project = Project(id: UUID(), name: "p", path: "/p", provider: .git, remoteUrl: nil,
                              addedAt: Date(), collapsed: false)
        state.items = [.project(project)]
        func item(_ title: String, kind: TaskKind = .task) -> TaskItem {
            TaskItem(id: UUID(), projectId: project.id, title: title, branch: title,
                     worktreePath: "/p/.worktrees/\(title)", baseBranch: "main", jira: nil, kind: kind,
                     agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false,
                     createdAt: Date(), windowId: nil)
        }
        let task1 = item("Task 1") // Saved without a `kind`, as tasks are.
        let review1 = item("MR 1", kind: .review)
        let task2 = item("Task 2", kind: .task)
        let review2 = item("MR 2", kind: .review)
        state.tasks = [task1, review1, task2, review2]

        let rows = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])[0].tasks

        #expect(rows.map(\.id) == [task1.id, task2.id, review1.id, review2.id])
    }

    /// The reported bug: a terminal row was drawn with a hardcoded shell mark and an idle dot, so
    /// starting Claude in it never changed the icon. A terminal's sessions are the ones in its own
    /// window — `projectId` cannot tell two terminals of the same project apart.
    @Test func testTerminalRowFollowsTheAgentsRunningInItsWindow() {
        var state = AppState.empty
        let p = Project(id: UUID(), name: "acme-web", path: "/r", provider: .gitlab, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let first = TerminalItem(id: UUID(), projectId: p.id, name: "Terminal", windowId: "w1", createdAt: Date())
        let second = TerminalItem(id: UUID(), projectId: p.id, name: "Logs", windowId: "w2", createdAt: Date())
        state.items = [.project(p)]; state.terminals = [first, second]
        func rows(_ sessions: [SessionInfo]) -> [TerminalRow] {
            SidebarModel.sections(state: state, sessions: sessions, branchByCwd: ["/r": "main"], projectBranch: [p.id: "main"])[0].terminals
        }

        // `claude` took over the window's only session; the second terminal still has a plain shell.
        let running = rows([session("a", task: nil, agent: .claude, state: .working, tab: 0, window: "w1", project: p.id.uuidString),
                            session("b", task: nil, agent: .shell, state: .idle, tab: 0, window: "w2", project: p.id.uuidString)])
        #expect(running[0].avatars == AvatarGroup(marks: [.claude], overflow: 0))
        #expect(running[0].status == .working)
        #expect(running[1] == TerminalRow(id: second.id, name: "Logs", branch: BranchLabel(name: "main", extra: 0, drifted: false, detail: ""),
                                          avatars: AvatarGroup(marks: [.shell], overflow: 0), status: .idle))

        // A Codex tab opened next to it adds a mark; the row stays the same row.
        let both = rows([session("a", task: nil, agent: .claude, state: .idle, tab: 0, window: "w1", project: p.id.uuidString),
                         session("c", task: nil, agent: .codex, state: .needsInput, tab: 1, window: "w1", project: p.id.uuidString)])
        #expect(both[0].id == first.id)
        #expect(both[0].avatars == AvatarGroup(marks: [.claude, .codex], overflow: 0))
        #expect(both[0].status == .needsInput)
    }

    /// A terminal whose window was closed (`windowId == nil`) has no sessions to read, and neither
    /// has one whose window the daemon has not reported yet: draw a shell mark rather than nothing.
    @Test func testTerminalRowWithoutSessionsFallsBackToAShellMark() {
        var state = AppState.empty
        let p = Project(id: UUID(), name: "r", path: "/r", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let closed = TerminalItem(id: UUID(), projectId: p.id, name: "Terminal", windowId: nil, createdAt: Date())
        state.items = [.project(p)]; state.terminals = [closed]
        let stranger = [session("a", task: nil, agent: .claude, state: .working, tab: 0, window: "w1", cwd: "/elsewhere")]
        let row = SidebarModel.sections(state: state, sessions: stranger, branchByCwd: ["/elsewhere": "other"], projectBranch: [:])[0].terminals[0]
        #expect(row.avatars == AvatarGroup(marks: [.shell], overflow: 0))
        #expect(row.status == .idle)
        #expect(row.branch == BranchLabel.none)
        // With the project's own checkout known, a closed terminal shows that rather than nothing.
        let withFallback = SidebarModel.sections(state: state, sessions: stranger, branchByCwd: [:], projectBranch: [p.id: "main"])[0].terminals[0]
        #expect(withFallback.branch == BranchLabel(name: "main", extra: 0, drifted: false, detail: ""))
    }

    // MARK: - branch line (design canvas, "Branch awareness · 17 Sep")

    /// The row follows the agent, not the shell it was launched from, and says how many other
    /// branches the same window has open.
    @Test func testBranchLabelTakesTheActiveTabAndCountsTheRest() {
        let claude = session("s1", task: nil, agent: .claude, state: .working, tab: 0, cwd: "/repo", agentCwd: "/repo/.worktrees/feat", active: true)
        let shell = session("s2", task: nil, agent: .shell, state: .idle, tab: 1, cwd: "/repo")
        let label = SidebarModel.branchLabel(sessions: [claude, shell],
                                             branchByCwd: ["/repo/.worktrees/feat": "feat/x", "/repo": "main"], own: nil, fallback: nil)
        #expect(label.name == "feat/x")
        #expect(label.extra == 1)
        #expect(label.drifted == false)
        #expect(label.detail == "tab 1 · claude · feat/x\ntab 2 · shell · main")
    }

    /// Without an active flag (an older daemon), the first tab wins rather than nothing.
    @Test func testBranchLabelFallsBackToTheFirstTabWhenNoneIsActive() {
        let first = session("s1", task: nil, agent: .claude, state: .idle, tab: 0, cwd: "/repo")
        let second = session("s2", task: nil, agent: .shell, state: .idle, tab: 1, cwd: "/repo/.worktrees/feat")
        let label = SidebarModel.branchLabel(sessions: [second, first],
                                             branchByCwd: ["/repo": "main", "/repo/.worktrees/feat": "feat/x"], own: nil, fallback: nil)
        #expect(label.name == "main")
        #expect(label.extra == 1)
    }

    @Test func testBranchLabelIsDriftedWhenTheAgentLeftTheTasksWorktree() {
        let claude = session("s1", task: "t1", agent: .claude, state: .working, tab: 0, cwd: "/repo/.worktrees/fe", agentCwd: "/repo", active: true)
        let label = SidebarModel.branchLabel(sessions: [claude], branchByCwd: ["/repo": "main"], own: "feat/shop-4952", fallback: nil)
        #expect(label.name == "main")
        #expect(label.extra == 0)
        #expect(label.drifted == true)
        #expect(label.detail == "task · feat/shop-4952")
    }

    @Test func testBranchLabelFallsBackWhenNothingIsOpen() {
        #expect(SidebarModel.branchLabel(sessions: [], branchByCwd: [:], own: "feat/x", fallback: nil)
                == BranchLabel(name: "feat/x", extra: 0, drifted: false, detail: ""))
        #expect(SidebarModel.branchLabel(sessions: [], branchByCwd: [:], own: nil, fallback: "main").name == "main")
        #expect(SidebarModel.branchLabel(sessions: [], branchByCwd: [:], own: nil, fallback: nil) == BranchLabel.none)
    }

    /// A tab sitting somewhere that is not a checkout at all — the Cmd+T tab in `$HOME` the probe
    /// found — must not count as a second branch.
    @Test func testBranchLabelIgnoresTabsWithNoBranch() {
        let claude = session("s1", task: nil, agent: .claude, state: .idle, tab: 0, cwd: "/repo", active: true)
        let stray = session("s2", task: nil, agent: .shell, state: .idle, tab: 1, cwd: "/Users/me")
        let label = SidebarModel.branchLabel(sessions: [claude, stray], branchByCwd: ["/repo": "main"], own: nil, fallback: nil)
        #expect(label.name == "main")
        #expect(label.extra == 0)
        #expect(label.detail == "")
    }

    @Test func testSessionTitlesUseTheSameLiveBranchesAndFallbacksAsTheSidebar() {
        var state = AppState.empty
        let project = Project(id: UUID(), name: "repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Task", branch: "feat/original", worktreePath: "/repo/.worktrees/original", baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: "w1")
        state.items = [.project(project)]; state.tasks = [task]
        let live = session("s1", task: task.id.uuidString, agent: .claude, state: .working, tab: 0,
                           cwd: task.worktreePath, agentCwd: "/repo/.worktrees/current")
        let unresolved = session("s2", task: task.id.uuidString, agent: .shell, state: .idle, tab: 1, cwd: "/Users/me")
        let terminal = session("s3", task: nil, agent: .shell, state: .idle, tab: 0, window: "w2",
                               project: project.id.uuidString, cwd: "/repo")
        let unmanaged = session("s4", task: nil, agent: .shell, state: .idle, tab: 0, window: "w3", cwd: "/elsewhere")

        let titles = SidebarModel.sessionTitles(
            state: state, sessions: [live, unresolved, terminal, unmanaged],
            branchByCwd: ["/repo/.worktrees/current": "feat/current", "/repo": "main", "/elsewhere": "other"],
            projectBranch: [project.id: "main"])

        #expect(titles == [SessionTitle(sessionId: "s1", title: "feat/current"),
                           SessionTitle(sessionId: "s2", title: "feat/original"),
                           SessionTitle(sessionId: "s3", title: "main")])
    }

    /// Renders on several threads share the kept formatters; each still gets its own answer. On
    /// today's Foundation a shared `DateFormatter` rarely misbehaves, so this cannot catch the
    /// formatter leaving its lock — Swift 6's `sending` check does — but it holds the cache to
    /// answering correctly under concurrent use, whatever replaces it.
    @Test func resetTimesFormatCorrectlyFromManyThreadsAtOnce() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 9, minute: 55))!
        let calendar = cal
        let cases = (0..<48).map { hour -> (Int, String) in
            let date = cal.date(byAdding: .hour, value: hour, to: now)!
            let day = (9 + hour) / 24, time = String(format: "%02d:55", (9 + hour) % 24)
            let expected = day == 0 ? time : ["Fri", "Sat"][day - 1] + " " + time
            return (Int(date.timeIntervalSince1970), expected)
        }
        let wrong = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let (resetsAt, expected) = cases[i % cases.count]
            if SidebarModel.fmtReset(resetsAt, now: now, calendar: calendar) != expected { wrong.withLock { $0 += 1 } }
        }
        #expect(wrong.withLock { $0 } == 0)
    }

    @Test func testUsageVendorRowsPutFiveHourFirstWhenAvailable() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 9, minute: 55))!
        let today1640 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 16, minute: 40))!.timeIntervalSince1970)
        let monday2100 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 21, minute: 0))!.timeIntervalSince1970)
        let wednesday1628 = Int(cal.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 16, minute: 28))!.timeIntervalSince1970)
        let snap = UsageSnapshot(
            claude: Usage(fiveHour: UsageWindow(usedPercent: 23, resetsAt: today1640), sevenDay: UsageWindow(usedPercent: 84, resetsAt: monday2100), spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970)),
            codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 23, resetsAt: wednesday1628), spend: nil, plan: "self_serve_business_prolite", updatedAt: Int(now.timeIntervalSince1970)))
        let rows = SidebarModel.usageVendorRows(snap, now: now, calendar: cal)
        #expect(rows == [
            UsageVendorRow(vendor: .claude, lines: [UsageLine(window: .weekly, percent: 84, reset: "Mon 21:00", warning: true, resetInFull: "Monday 21:00"),
                                                    UsageLine(window: .fiveHour, percent: 23, reset: "16:40", warning: false, resetInFull: "16:40")], note: nil),
            UsageVendorRow(vendor: .codex, lines: [UsageLine(window: .weekly, percent: 23, reset: "Wed 16:28", warning: false, resetInFull: "Wednesday 16:28")], note: nil),
        ])
        // Each segment's tooltip and VoiceOver label say it in words.
        #expect(rows[0].lines.map(\.help) == ["Weekly limit, 84 % used, resets Monday 21:00", "5-hour limit, 23 % used, resets 16:40"])
        let none = SidebarModel.usageVendorRows(UsageSnapshot(claude: nil, codex: Usage(fiveHour: nil, sevenDay: nil, spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970))), now: now, calendar: cal)
        #expect(none[0] == UsageVendorRow(vendor: .claude, lines: [], note: "No usage data yet"))
        #expect(none[1] == UsageVendorRow(vendor: .codex, lines: [], note: "No usage data reported"))
        let noReset = SidebarModel.usageVendorRows(UsageSnapshot(claude: Usage(fiveHour: UsageWindow(usedPercent: 5, resetsAt: nil), sevenDay: nil, spend: nil, plan: nil, updatedAt: Int(now.timeIntervalSince1970)), codex: nil), now: now, calendar: cal)
        #expect(noReset[0].lines == [UsageLine(window: .fiveHour, percent: 5, reset: nil, warning: false)])
        #expect(noReset[0].lines[0].help == "5-hour limit, 5 % used")
    }

    /// "No usage data yet" is the honest answer while the first status line tick is awaited, but it is a
    /// lie once AiTerm's shim is no longer Claude Code's status line: no tick is coming, ever. The
    /// footer has to tell those two apart, or a broken feed looks like a slow one forever.
    @Test func testTheClaudeRowSaysWhenTheStatusLineIsNotInstalled() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cal = Calendar(identifier: .gregorian)
        let empty = UsageSnapshot(claude: nil, codex: nil)
        let claude = { (rows: [UsageVendorRow]) in rows.first { $0.vendor == .claude }! }
        #expect(claude(SidebarModel.usageVendorRows(empty, now: now, calendar: cal)).note == "No usage data yet")
        #expect(claude(SidebarModel.usageVendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false)).note == "Usage disconnected")
        let codex = SidebarModel.usageVendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false).first { $0.vendor == .codex }!
        #expect(codex.note == "No usage data yet", "Codex's rate limits come from its own rollout file; the status line is not its feed")
        // Only the broken feed is a warning; the footer reads the flag, not the wording.
        #expect(claude(SidebarModel.usageVendorRows(empty, now: now, calendar: cal, claudeStatusLineInstalled: false)).warning)
        #expect(!claude(SidebarModel.usageVendorRows(empty, now: now, calendar: cal)).warning)
        #expect(!codex.warning)
    }

    /// A window whose reset time has passed has cleared: whatever it last reported, that limit is at
    /// zero now. Drawing the old percentage next to a reset time in the past would be a stale
    /// number wearing a live one's clothes, so the window is dropped instead.
    @Test func testAWindowPastItsResetIsDroppedNotRedrawn() {
        let now = Date(timeIntervalSince1970: 1_700_000_000), cal = Calendar(identifier: .gregorian)
        let epoch = Int(now.timeIntervalSince1970)
        let snap = UsageSnapshot(
            claude: Usage(fiveHour: UsageWindow(usedPercent: 91, resetsAt: epoch - 1),
                          sevenDay: UsageWindow(usedPercent: 40, resetsAt: epoch + 3600), spend: nil, plan: nil, updatedAt: epoch),
            codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 28, resetsAt: epoch - 86_400), spend: nil, plan: nil, updatedAt: epoch))
        let rows = SidebarModel.usageVendorRows(snap, now: now, calendar: cal)
        #expect(rows[0].lines.map(\.window) == [.weekly])
        #expect(rows[1] == UsageVendorRow(vendor: .codex, lines: [], note: "No usage data reported"))
        // A window with no reset time at all never expires.
        let open = UsageSnapshot(claude: Usage(fiveHour: UsageWindow(usedPercent: 5, resetsAt: nil), sevenDay: nil, spend: nil, plan: nil, updatedAt: epoch), codex: nil)
        #expect(SidebarModel.usageVendorRows(open, now: now, calendar: cal)[0].lines.map(\.window) == [.fiveHour])
    }

    /// Both feeds only move while their agent runs, so a quiet vendor is idle, not broken. Its last
    /// numbers are still its numbers: a day-old report yields the same lines as a fresh one.
    @Test func testASilentVendorsWindowsAreDrawnLikeFreshOnes() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let epoch = Int(now.timeIntervalSince1970)
        let usage = { (age: Int) in
            UsageSnapshot(claude: nil, codex: Usage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: 28, resetsAt: epoch + 86_400),
                                                     spend: nil, plan: nil, updatedAt: epoch - age))
        }
        let rows = { (age: Int) in SidebarModel.usageVendorRows(usage(age), now: now, calendar: cal)[1].lines }
        #expect(rows(86_400) == rows(0))
        #expect(rows(0) == [UsageLine(window: .weekly, percent: 28, reset: "Wed 23:13", warning: false, resetInFull: "Wednesday 23:13")])
    }

    // MARK: - context

    /// The counts are the active tab's own, never another tab's: two Claude tabs are two conversations.
    @Test func theCountsAreTheActiveTabsOwn() {
        let id = UUID()
        let sessions = [tab(id, .claude, 0), tab(id, .claude, 1, active: true)]
        let counts = ["s0": TokenTally(input: 9, cached: 0, output: 9), "s1": TokenTally(input: 936_018, cached: 935_988, output: 5_625)]
        let row = SidebarModel.usageTaskRow(taskId: id, agent: .claude, sessions: sessions, contexts: [.claude: 42], tokens: counts)
        #expect(row.tokens == counts["s1"])
    }

    /// A shell tab, or a task whose window is closed, has no conversation and no counts.
    @Test func aShellTabHasNoCounts() {
        let id = UUID()
        let counts = ["s0": TokenTally(input: 9, cached: 0, output: 9), "s1": TokenTally(input: 1, cached: 0, output: 1)]
        #expect(SidebarModel.usageTaskRow(taskId: id, agent: .claude, sessions: [tab(id, .claude, 0), tab(id, .shell, 1, active: true)],
                                          contexts: [:], tokens: counts).tokens == nil)
        #expect(SidebarModel.usageTaskRow(taskId: UUID(), agent: .claude, sessions: [], contexts: [:], tokens: counts).tokens == nil)
    }

    /// A tally of nothing in and nothing out — PI reports one from a session's start — is no counts
    /// at all, never `in 0 · out 0`; a tally with either side spent still shows.
    @Test func aTallyOfNothingInAndNothingOutHasNoCounts() {
        let id = UUID()
        let row = { (tally: TokenTally) in
            SidebarModel.usageTaskRow(taskId: id, agent: .pi, sessions: [self.tab(id, .pi, 0, active: true)],
                                      contexts: [:], tokens: ["s0": tally]).tokens
        }
        #expect(row(TokenTally(input: 0, cached: 0, output: 0)) == nil)
        #expect(row(TokenTally(input: 0, cached: nil, output: 0)) == nil)
        #expect(row(TokenTally(input: 0, cached: 0, output: 3)) == TokenTally(input: 0, cached: 0, output: 3))
        #expect(row(TokenTally(input: 12, cached: nil, output: 0)) == TokenTally(input: 12, cached: nil, output: 0))
    }

    /// The footer's first row is the selected task's active tab: that tab's agent mark and its
    /// provider's context fill. Other providers' fills in the same task are not drawn.
    @Test func testTheTaskRowFollowsTheActiveTab() {
        let id = UUID()
        let sessions = [tab(id, .claude, 0), tab(id, .codex, 1, active: true), tab(UUID(), .pi, 0, active: true)]
        let task = SidebarModel.usageTaskRow(taskId: id, agent: .claude, sessions: sessions,
                                             contexts: [.claude: 42, .codex: 18, .pi: 7])
        #expect(task == UsageTaskRow(agent: .codex,
                                     context: UsageLine(window: .context, percent: 18, reset: nil, warning: false)))
    }

    /// The row is the active tab, whatever runs in it: a shell tab shows the shell with no fill,
    /// even while another tab of the task has reported one.
    @Test func testAnActiveShellTabShowsTheShellWithoutContext() {
        let id = UUID()
        let task = SidebarModel.usageTaskRow(taskId: id, agent: .claude,
                                             sessions: [tab(id, .claude, 0), tab(id, .shell, 1, active: true)],
                                             contexts: [.claude: 42])
        #expect(task == UsageTaskRow(agent: .shell, context: nil))
    }

    /// A task whose window is closed has no tab to follow; it shows its own agent's last fill.
    @Test func testATaskWithoutTabsShowsItsOwnAgent() {
        let task = SidebarModel.usageTaskRow(taskId: UUID(), agent: .pi, sessions: [tab(UUID(), .codex, 0, active: true)],
                                             contexts: [.pi: 12, .codex: 30])
        #expect(task == UsageTaskRow(agent: .pi, context: UsageLine(window: .context, percent: 12, reset: nil, warning: false)))
    }

    /// A provider that has not reported yet keeps its mark and draws no fill.
    @Test func testAnAgentWithoutContextHasNoFill() {
        let id = UUID()
        let task = SidebarModel.usageTaskRow(taskId: id, agent: .claude, sessions: [tab(id, .codex, 0, active: true)],
                                             contexts: [.claude: 42])
        #expect(task == UsageTaskRow(agent: .codex, context: nil))
    }

    /// A selected terminal is a row like a task, its tabs matched by window since they carry no
    /// task tag. A shell shows the shell mark with no fill; starting Claude in that tab turns the
    /// same row into Claude's mark and its fill.
    @Test func testATerminalRowFollowsItsActiveTab() {
        let shell = [session("s0", task: nil, agent: .shell, state: .idle, tab: 0, window: "w2", active: true),
                     session("s1", task: nil, agent: .codex, state: .idle, tab: 0, window: "w3", active: true)]
        #expect(SidebarModel.usageTerminalRow(windowId: "w2", sessions: shell, contexts: [.codex: 18])
                == UsageTaskRow(agent: .shell, context: nil))
        var claude = shell
        claude[0].agent = .claude
        #expect(SidebarModel.usageTerminalRow(windowId: "w2", sessions: claude, contexts: [.claude: 42, .codex: 18])
                == UsageTaskRow(agent: .claude, context: UsageLine(window: .context, percent: 42, reset: nil, warning: false)))
    }

    /// A terminal whose window is closed has no tab and no agent of its own: it is a shell.
    @Test func testATerminalWithoutTabsIsAShell() {
        #expect(SidebarModel.usageTerminalRow(windowId: nil, sessions: [], contexts: [.claude: 42])
                == UsageTaskRow(agent: .shell, context: nil))
    }

    /// The daemon may not have said which tab is current yet; the first tab stands in for it.
    @Test func testWithoutAnActiveTabTheFirstTabLeads() {
        let tabs = [session("s0", task: nil, agent: .codex, state: .idle, tab: 1, window: "w2"),
                    session("s1", task: nil, agent: .claude, state: .idle, tab: 0, window: "w2")]
        #expect(SidebarModel.usageTerminalRow(windowId: "w2", sessions: tabs, contexts: [:])
                == UsageTaskRow(agent: .claude, context: nil))
    }

    /// Context crosses the same 80% line as a rate-limit window, so it turns amber with them.
    @Test func testContextWarnsAtTheSameThresholdAsAWindow() {
        let line = { (pct: Int) in SidebarModel.usageTaskRow(taskId: UUID(), agent: .claude, sessions: [], contexts: [.claude: pct]).context }
        #expect(line(79) == UsageLine(window: .context, percent: 79, reset: nil, warning: false))
        #expect(line(80) == UsageLine(window: .context, percent: 80, reset: nil, warning: true))
        #expect(line(84)?.help == "Context 84 % full")
    }

    /// PI has no account-quota source, so it never gets a vendor row: its context lives on the task.
    @Test func testVendorRowsAreClaudeAndCodexOnly() {
        let now = Date(timeIntervalSince1970: 1_700_000_000), cal = Calendar(identifier: .gregorian)
        #expect(SidebarModel.usageVendorRows(.empty, now: now, calendar: cal).map(\.vendor) == [.claude, .codex])
    }

    /// Grok Build has no account-quota source either, so it follows PI: no vendor row, only ctx.
    @Test func grokGetsAContextRowAndNoVendorRow() {
        let rows = SidebarModel.usageVendorRows(.empty, now: Date(), calendar: .current)
        #expect(rows.map(\.vendor) == [.claude, .codex])
        let task = UUID()
        let tab = session("g", task: task.uuidString, agent: .grok, state: .working, tab: 0, active: true)
        let row = SidebarModel.usageTaskRow(taskId: task, agent: .grok, sessions: [tab], contexts: [.grok: 37])
        #expect(row.agent == .grok && row.context?.percent == 37)
    }

    private func tab(_ task: UUID, _ agent: SessionAgent, _ index: Int, active: Bool = false) -> SessionInfo {
        session("s\(index)", task: task.uuidString, agent: agent, state: .idle, tab: index, active: active)
    }

    @Test func testAReviewRowCarriesItsMergeRequest() {
        var state = AppState.empty
        let project = Project(id: UUID(), name: "p", path: "/tmp/p", provider: .gitlab, remoteUrl: nil, addedAt: Date(), collapsed: false)
        state.items = [.project(project)]
        let mr = MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4")
        state.tasks = [TaskItem(id: UUID(), projectId: project.id, title: "Review gift card", branch: "feat-gift",
                                worktreePath: "/tmp/wt", baseBranch: "main", jira: nil, kind: .review, mr: mr,
                                agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                                createdAt: Date(), windowId: nil)]
        let row = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])[0].tasks[0]
        #expect(row.mr == mr)
        #expect(row.jiraKey == nil)
    }

    @Test func testEntriesInterleaveDividersAmongProjectSections() {
        var state = AppState.empty
        func project(_ name: String) -> Project {
            Project(id: UUID(), name: name, path: "/" + name, provider: .git, remoteUrl: nil,
                    addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        }
        let (a, b) = (project("a"), project("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        state.append(project: a); state.append(divider: rule); state.append(project: b)
        let entries = SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(entries.map(\.id) == [a.id, rule.id, b.id])
        guard case .divider(let drawn) = entries[1] else { Issue.record("expected a divider"); return }
        #expect(drawn.divider.name == "Work")
        // `sections` is the project-only view of the same list and is unchanged by the divider.
        let sections = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(sections.map(\.id) == [a.id, b.id])
    }

    /// Each top-level row carries which way it can move, so its menu need not ask the workspace:
    /// the first has no "up", the last no "down", and a divider is a row like any other.
    @Test func testEntriesSayWhichWayEachRowCanMove() {
        var state = AppState.empty
        func project(_ name: String) -> Project {
            Project(id: UUID(), name: name, path: "/" + name, provider: .git, remoteUrl: nil,
                    addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        }
        state.append(project: project("a")); state.append(divider: SidebarDivider(id: UUID(), name: "")); state.append(project: project("b"))
        let moves = SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:]).map { entry in
            switch entry {
            case .project(let s): return [s.canMove(.up), s.canMove(.down)]
            case .divider(let d): return [d.canMove(.up), d.canMove(.down)]
            }
        }
        #expect(moves == [[false, true], [true, true], [true, false]])
        let ids = state.items.map(\.id)
        #expect(moves == ids.map { [state.canMove(id: $0, .up), state.canMove(id: $0, .down)] },
                "the same answer `AppState.canMove` gives")
    }

    private func stateWithOneTask(base: String) -> (AppState, TaskItem) {
        var state = AppState.empty
        let project = Project(id: UUID(), name: "p", path: "/p", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "t", branch: "feat/t", worktreePath: "/p/.worktrees/t",
                            baseBranch: base, jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)
        state.items = [.project(project)]; state.tasks = [task]
        return (state, task)
    }

    @Test func aTaskRowCarriesItsDiffAgainstTheBase() {
        let (state, task) = stateWithOneTask(base: "main")
        let row = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:],
                                        diffByTask: [task.id: DiffStat(added: 12, removed: 3)])[0].tasks[0]
        #expect(row.diff == BaseDiff(base: "main", stat: DiffStat(added: 12, removed: 3)))
    }

    @Test func noDiffMeansThePlainBadge() {
        // An empty diff, a task the scan has not measured yet, and a task with no base all draw the
        // VS Code badge as its plain mark.
        let (state, task) = stateWithOneTask(base: "main")
        #expect(SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:],
                                      diffByTask: [task.id: DiffStat(added: 0, removed: 0)])[0].tasks[0].diff == nil)
        #expect(SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])[0].tasks[0].diff == nil)
        let (unbased, other) = stateWithOneTask(base: "")
        #expect(SidebarModel.sections(state: unbased, sessions: [], branchByCwd: [:], projectBranch: [:],
                                      diffByTask: [other.id: DiffStat(added: 1, removed: 0)])[0].tasks[0].diff == nil)
    }

    @Test func theHelpNamesTheWholeBaseAndBothCounts() {
        #expect(BaseDiff(base: "develop", stat: DiffStat(added: 12, removed: 3)).help
            == "Open in VS Code \u{2014} 12 added, 3 removed against develop")
        #expect(BaseDiff(base: "main", stat: DiffStat(added: 5, removed: 0)).help
            == "Open in VS Code \u{2014} 5 added against main")
        #expect(BaseDiff(base: "main", stat: DiffStat(added: 0, removed: 2)).help
            == "Open in VS Code \u{2014} 2 removed against main")
    }
}
