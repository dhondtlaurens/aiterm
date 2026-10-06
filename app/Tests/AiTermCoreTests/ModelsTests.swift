import Testing
import Foundation
@testable import AiTermCore

@Suite struct ModelsTests {
    @Test func agentsAreOrderedClaudeCodexGrokPi() {
        #expect(AgentKind.allCases == [.claude, .codex, .grok, .pi])
        #expect(AgentKind.grok.displayName == "Grok Build")
        #expect(AgentKind.grok.session == .grok && SessionAgent.grok.agentKind == .grok)
    }

    /// A provider a newer build saved decodes as a plain repository instead of failing the load.
    @Test func anUnknownProviderDecodesAsGit() throws {
        #expect(try JSONDecoder().decode(Provider.self, from: Data(#""bitbucket""#.utf8)) == .git)
        #expect(try JSONDecoder().decode(Provider.self, from: Data(#""github""#.utf8)) == .github)
        #expect(String(decoding: try JSONEncoder().encode(Provider.github), as: UTF8.self) == #""github""#)
    }

    @Test func anUnknownTaskKindReadsAsATaskAndIsWrittenBackAsSaved() throws {
        var task = TaskItem(id: UUID(), projectId: UUID(), title: "t", branch: "b", worktreePath: "/w", baseBranch: "main",
                            jira: nil, kind: .review, agent: .codex, model: "m", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        func decoded(agent: String, kind: String?) throws -> TaskItem {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])
            json["agent"] = agent; json["kind"] = kind
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: json))
        }
        func raw(_ task: TaskItem, _ key: String) throws -> String? {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return (try JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])?[key] as? String
        }
        var future = try decoded(agent: "gemini", kind: "spike")
        #expect(future.kind == .task && future.kindName == "Task" && future.agent == .claude)
        #expect(try raw(future, "kind") == "spike" && raw(future, "agent") == "gemini")
        // Choosing a value of this build's own replaces the saved one.
        future.agent = .grok; future.kind = .review
        #expect(try raw(future, "kind") == "review" && raw(future, "agent") == "grok")
        // Known values, and a missing kind, are untouched.
        #expect(try decoded(agent: "pi", kind: "review").kind == .review)
        let plain = try decoded(agent: "pi", kind: nil)
        #expect(plain.kind == nil && plain.agent == .pi && plain.unrecognizedAgent == nil)
        task.kind = nil
        #expect(try raw(task, "kind") == nil)
    }

    @Test func anUnknownSidebarItemKeepsItsPlaceAndIsNeverDrawnOrCounted() throws {
        let a = Project(id: UUID(), name: "A", path: "/a", provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        let b = Project(id: UUID(), name: "B", path: "/b", provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        var state = AppState.empty
        state.append(project: a)
        state.items.append(try JSONDecoder().decode(SidebarItem.self, from: Data(#"{"kind":"folder","folder":{"n":1}}"#.utf8)))
        state.append(project: b)
        let hidden = state.items[1].id

        #expect(state.projects == [a, b])
        #expect(state.canMove(id: a.id, .down) && !state.canMove(id: a.id, .up))
        #expect(!state.canMove(id: b.id, .down) && state.canMove(id: b.id, .up))
        let moved = state.move(id: b.id, .up)
        #expect(moved)
        #expect(state.items.map(\.id) == [b.id, a.id, hidden])
        let back = state.move(id: b.id, .down)
        #expect(back)
        #expect(state.items.map(\.id) == [a.id, b.id, hidden], "a move steps over drawn rows only")

        let entries = SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(entries.map(\.id) == [a.id, b.id])
        guard case .project(let first) = entries[0], case .project(let last) = entries[1] else { Issue.record("expected projects"); return }
        #expect(!first.canMoveUp && first.canMoveDown && last.canMoveUp && !last.canMoveDown)

        let again = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
        #expect(!again.items[2].isDrawn)
    }

    @Test func testAppStateRoundTripsThroughJSON() throws {
        let p = Project(id: UUID(), name: "acme-web", path: "/Users/me/Sites/acme-web", provider: .gitlab, remoteUrl: "git@git.example.net:web/acme-web.git", addedAt: Date(timeIntervalSince1970: 1), collapsed: false,
                        jiraProjects: [JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: URL(string: "https://example.atlassian.net")!),
                                       JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: URL(string: "https://example.atlassian.net")!)])
        let t = TaskItem(id: UUID(), projectId: p.id, title: "Add graceful SIGTERM", branch: "feat/web-5447-graceful-sigterm", worktreePath: p.path + "/.worktrees/web-5447-graceful-sigterm", baseBranch: "main", jira: JiraRef(key: "WEB-5447", summary: "Add graceful SIGTERM", url: "https://x.atlassian.net/browse/WEB-5447"), agent: .claude, model: "opus", reasoning: "high", firstPrompt: nil, appendTicket: true, createdAt: Date(timeIntervalSince1970: 2), windowId: nil)
        let term = TerminalItem(id: UUID(), projectId: p.id, name: "Logs", windowId: "w7", createdAt: Date(timeIntervalSince1970: 3))
        var state = AppState.empty
        state.items = [.project(p)]; state.tasks = [t]; state.terminals = [term]
        state.lastAgentByProject[p.id] = .codex
        state.lastModelByAgent[.codex] = "gpt-5.6"
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(AppState.self, from: data)
        #expect(back == state)
    }

    /// The remembered agent and model choices are only preferences: an entry for an agent this
    /// build has never heard of, written by a newer one, is dropped rather than failing the load.
    @Test func testRememberedChoicesForAnUnknownAgentAreDropped() throws {
        let kept = UUID()
        var state = AppState.empty
        state.lastAgentByProject = [UUID(): .pi, kept: .codex]
        state.lastModelByAgent = [.pi: "pi-model", .codex: "gpt-5.6"]
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            .replacingOccurrences(of: "\"pi\"", with: "\"someday\"")
        let back = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(back.lastAgentByProject == [kept: .codex])
        #expect(back.lastModelByAgent == [.codex: "gpt-5.6"])
    }

    /// A task's agent from a newer build no longer fails the load: the task reads as a Claude task
    /// and keeps the saved name for the next save (see `anUnknownTaskKindReadsAsATask…`).
    @Test func testATaskForAnUnknownAgentLoadsAndKeepsItsSavedName() throws {
        var state = AppState.empty
        state.tasks = [TaskItem(id: UUID(), projectId: UUID(), title: "t", branch: "b", worktreePath: "/w", baseBranch: "main", jira: nil,
                                agent: .pi, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                                createdAt: Date(timeIntervalSince1970: 1), windowId: nil)]
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            .replacingOccurrences(of: "\"pi\"", with: "\"someday\"")
        let back = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        #expect(back.tasks.first?.agent == .claude && back.tasks.first?.unrecognizedAgent == "someday")
    }

    @Test func testProjectFromAnOlderStateFileDecodesWithoutAJiraProject() throws {
        let json = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"Repo","path":"/repo",\
        "provider":"git","addedAt":"1970-01-01T00:00:01Z","collapsed":false}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.jiraProjects.isEmpty)
    }

    /// A project linked before it could have several Jira projects stored the one under
    /// `jiraProject`; it loads as a list of one and is written back as the list, and as the one.
    @Test func testProjectWithTheSingleJiraProjectOfAnOlderStateFileDecodesAsAListOfOne() throws {
        let json = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"Repo","path":"/repo",\
        "provider":"git","addedAt":"1970-01-01T00:00:01Z","collapsed":false,\
        "jiraProject":{"id":"10001","key":"SHOP","name":"Storefront","siteURL":"https://example.atlassian.net"}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(json.utf8))
        #expect(project.jiraProjects.map(\.key) == ["SHOP"])

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        #expect((written?["jiraProject"] as? [String: Any])?["key"] as? String == "SHOP")
        #expect((written?["jiraProjects"] as? [Any])?.count == 1)
    }

    /// A build from before projects could link several reads only `jiraProject`, and saves the
    /// project without it. So the first link is written there too, and the list still wins on reading.
    @Test func testProjectAlsoWritesItsFirstJiraProjectForOlderBuilds() throws {
        let site = URL(string: "https://example.atlassian.net")!
        var project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 1),
                              collapsed: false, jiraProjects: ["SHOP", "PAY"].map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: site) })
        var written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        #expect((written?["jiraProject"] as? [String: Any])?["key"] as? String == "SHOP")
        #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)).jiraProjects.map(\.key) == ["SHOP", "PAY"])

        project.jiraProjects = []
        written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any]
        #expect(written?["jiraProject"] == nil)
    }

    @Test func testLinkedJiraProjectsReadAsTheirKeysInOrder() {
        let site = URL(string: "https://example.atlassian.net")!
        let refs = ["SHOP", "PAY", "WEB"].map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: site) }
        #expect(Array(refs.prefix(1)).keyList == "SHOP")
        #expect(Array(refs.prefix(2)).keyList == "SHOP and PAY")
        #expect(refs.keyList == "SHOP, PAY and WEB")
    }

    /// Older workspaces remain readable without an explicit migration.
    @Test func testTerminalFromAnOlderStateFileDecodesWithTheDefaultName() throws {
        let json = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","projectId":"1EB4C0DE-0000-0000-0000-000000000002",\
        "windowId":"w1","createdAt":"1970-01-01T00:00:01Z"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let term = try decoder.decode(TerminalItem.self, from: Data(json.utf8))
        #expect(term.name == "Terminal")
        #expect(term.windowId == "w1")
    }

    /// `lastSelectedAt` was written on every click and never read, and is gone; a workspace saved
    /// while it existed still loads, and loses the key on its next save.
    @Test func aTaskSavedWithLastSelectedAtStillDecodes() throws {
        let json = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","projectId":"1EB4C0DE-0000-0000-0000-000000000002",\
        "title":"Work","branch":"feat/work","worktreePath":"/repo/.worktrees/work","baseBranch":"main",\
        "agent":"claude","model":"opus","appendTicket":true,"createdAt":"1970-01-01T00:00:01Z",\
        "windowId":"w1","lastSelectedAt":"1970-01-01T00:00:02Z"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.title == "Work" && task.windowId == "w1")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        #expect(!String(decoding: try encoder.encode(task), as: UTF8.self).contains("lastSelectedAt"))
    }

    @Test func rowsAreFoundByTheirId() {
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                              addedAt: Date(), collapsed: false)
        let divider = SidebarDivider(id: UUID(), name: "Work")
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: "/repo/.worktrees/work", baseBranch: "main", jira: nil, agent: .claude,
                            model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(),
                            windowId: nil)
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: nil, createdAt: Date())
        var state = AppState.empty
        state.append(divider: divider); state.append(project: project)
        state.tasks = [task]; state.terminals = [terminal]
        #expect(state.project(id: project.id) == project)
        #expect(state.project(id: divider.id) == nil, "a divider is not a project")
        #expect(state.task(id: task.id) == task && state.task(id: project.id) == nil)
        #expect(state.terminal(id: terminal.id) == terminal && state.terminal(id: task.id) == nil)
    }

    @Test func testSuggestedTerminalNameSkipsTheNamesAlreadyInUse() {
        let project = UUID()
        func term(_ name: String) -> TerminalItem { TerminalItem(id: UUID(), projectId: project, name: name, windowId: nil, createdAt: Date()) }
        #expect(TerminalItem.suggestedName(existing: []) == "Terminal")
        #expect(TerminalItem.suggestedName(existing: [term("Terminal")]) == "Terminal 2")
        #expect(TerminalItem.suggestedName(existing: [term("Terminal"), term("Terminal 2")]) == "Terminal 3")
        // A gap is filled rather than skipped, and unrelated names never push the counter up.
        #expect(TerminalItem.suggestedName(existing: [term("Terminal"), term("Terminal 3")]) == "Terminal 2")
        #expect(TerminalItem.suggestedName(existing: [term("Logs")]) == "Terminal")
    }

    @Test func testEnumsDecodeFromDaemonStrings() throws {
        #expect(try JSONDecoder().decode(SessionState.self, from: Data("\"needsInput\"".utf8)) == .needsInput)
        #expect(try JSONDecoder().decode(SessionAgent.self, from: Data("\"shell\"".utf8)) == .shell)
    }

    @Test func closedWindowRemovesMatchingItemsAndIgnoresStaleEvents() throws {
        let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: "/tmp/repo/.worktrees/work", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: "Do the work",
                            appendTicket: false, createdAt: Date(timeIntervalSince1970: 0),
                            windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w2",
                                    createdAt: Date(timeIntervalSince1970: 0))
        var state = AppState.empty
        state.items = [.project(project)]; state.tasks = [task]; state.terminals = [terminal]
        let closedTask = state.closeWindow("w1")
        #expect(closedTask)
        #expect(state.tasks.isEmpty)
        #expect(state.terminals.count == 1)
        let duplicateClose = state.closeWindow("w1")
        #expect(!duplicateClose)
        var replacement = task
        replacement.windowId = "w3"
        state.tasks = [replacement]
        let staleClose = state.closeWindow("w1")
        #expect(!staleClose)
        #expect(state.tasks[0].windowId == "w3")
        let closedTerminal = state.closeWindow("w2")
        #expect(closedTerminal)
        #expect(state.terminals.isEmpty)
        let closedReplacement = state.closeWindow("w3")
        #expect(closedReplacement)
        let rows = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(rows.first?.tasks.isEmpty == true)
        #expect(state.tasks.isEmpty)
    }

    /// The regression guard for the whole saved workspace. Both new properties must stay `Optional`:
    /// Swift's synthesized decoder uses `decodeIfPresent` for an Optional, but a non-optional with a
    /// default value (`var isReview = false`) throws `keyNotFound` instead of falling back — which
    /// would make every workspace saved before today unreadable.
    @Test func testTaskItemDecodesWithoutKindOrMergeRequest() throws {
        let json = """
        {"id":"9F1C5B4E-3A2D-4C7F-8E10-2B6D9A0C1E33","projectId":"0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9",
         "title":"Add gift card","branch":"feat/gift","worktreePath":"/tmp/wt","baseBranch":"main",
         "agent":"claude","model":"sonnet","appendTicket":true,"createdAt":0}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.kind == nil)
        #expect(task.mr == nil)
        #expect(task.title == "Add gift card")
    }

    @Test func testTaskItemRoundTripsAReview() throws {
        let mr = MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4")
        let task = TaskItem(id: UUID(), projectId: UUID(), title: "Review gift card", branch: "feat-gift",
                            worktreePath: "/tmp/wt", baseBranch: "main", jira: nil, kind: .review, mr: mr,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        #expect(decoded.kind == .review)
        #expect(decoded.mr == mr)
    }

    private func project(_ name: String, id: UUID = UUID()) -> Project {
        Project(id: id, name: name, path: "/" + name, provider: .git, remoteUrl: nil,
                addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
    }

    @Test func testProjectsViewReadsThroughTheOrderedItems() {
        var state = AppState.empty
        let (a, b) = (project("a"), project("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        state.append(project: a); state.append(divider: rule); state.append(project: b)
        #expect(state.projects.map(\.name) == ["a", "b"])
        #expect(state.items.map(\.id) == [a.id, rule.id, b.id])
    }

    /// The empty sidebar's question: a divider alone is not a project.
    @Test func hasProjectsCountsOnlyProjects() {
        var state = AppState.empty
        #expect(!state.hasProjects)
        state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        #expect(!state.hasProjects)
        state.append(project: project("a"))
        #expect(state.hasProjects)
    }

    @Test func testMutatorsAddRenameAndRemoveWithoutDisturbingNeighbours() {
        var state = AppState.empty
        let (a, b) = (project("a"), project("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        state.append(project: a); state.append(divider: rule); state.append(project: b)
        state.renameDivider(id: rule.id, to: "Personal")
        #expect(state.items[1].divider?.name == "Personal")
        state.updateProject(id: a.id) { $0.collapsed = true }
        #expect(state.items[0].project?.collapsed == true)
        state.removeItem(id: a.id)
        #expect(state.items.map(\.id) == [rule.id, b.id])
        state.removeItem(id: rule.id)
        #expect(state.items.map(\.id) == [b.id])
    }

    /// One slot at a time in the combined list: a project directly below a divider moves above it
    /// on one press, without reordering the projects around it.
    @Test func testMoveStepsOneSlotThroughTheCombinedList() {
        var state = AppState.empty
        let (a, b) = (project("a"), project("b"))
        let rule = SidebarDivider(id: UUID(), name: "Work")
        state.append(project: a); state.append(divider: rule); state.append(project: b)
        // `move` is mutating, so it is called outside `#expect` — the macro captures immutably.
        let moved = state.move(id: b.id, .up)
        #expect(moved)
        #expect(state.items.map(\.id) == [a.id, b.id, rule.id])
        #expect(state.projects.map(\.name) == ["a", "b"])
        #expect(!state.canMove(id: a.id, .up))
        let blocked = state.move(id: a.id, .up)
        #expect(!blocked)
        #expect(!state.canMove(id: rule.id, .down))
        #expect(state.canMove(id: rule.id, .up))
        #expect(!state.canMove(id: UUID(), .up))
    }

    @Test func testStateWithDividersRoundTripsThroughJSON() throws {
        var state = AppState.empty
        state.append(project: project("a"))
        state.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        state.append(project: project("b"))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(AppState.self, from: encoder.encode(state))
        #expect(back == state)
    }

    /// Workspaces written before dividers existed carry a flat `projects` array and no `items`.
    @Test func testLegacyWorkspaceWithoutItemsDecodesItsProjectsInOrder() throws {
        let json = """
        {"projects":[
          {"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"one","path":"/one","provider":"git",
           "addedAt":"1970-01-01T00:00:01Z","collapsed":false},
          {"id":"1EB4C0DE-0000-0000-0000-000000000002","name":"two","path":"/two","provider":"none",
           "addedAt":"1970-01-01T00:00:02Z","collapsed":true}],
         "tasks":[],"terminals":[]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(AppState.self, from: Data(json.utf8))
        #expect(state.projects.map(\.name) == ["one", "two"])
        #expect(state.projects.allSatisfy { $0.jiraProjects.isEmpty })
        #expect(state.items.count == 2)
        #expect(state.items.allSatisfy { $0.divider == nil })
    }

    /// A review of a branch opens in the row whose worktree git reports it checked out in — a
    /// task's or an earlier review's — decided by that checkout, not by the branch the row was
    /// created on. The same path in another project is another repository's row.
    @Test func testTheRowCheckingOutABranchIsFoundByItsWorktree() {
        let project = UUID(), other = UUID()
        func item(_ title: String, bound branch: String, in projectId: UUID, kind: TaskKind? = nil) -> TaskItem {
            TaskItem(id: UUID(), projectId: projectId, title: title, branch: branch, worktreePath: "/wt/" + title, baseBranch: "main",
                     jira: nil, kind: kind, agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: true,
                     createdAt: Date(), windowId: nil)
        }
        let task = item("mine", bound: "feat/x", in: project), review = item("reviewing", bound: "feat/z", in: project, kind: .review)
        var state = AppState.empty
        state.tasks = [item("mine", bound: "feat/x", in: other), task, review]
        let listing = [Worktree(path: "/repo", branch: "main", lockReason: nil),
                       Worktree(path: "/wt/mine", branch: "feat/x", lockReason: "aiterm task"),
                       Worktree(path: "/wt/reviewing", branch: "feat/z", lockReason: "aiterm review")]
        #expect(state.task(checkingOut: "feat/x", in: project, worktrees: listing) == task)
        #expect(state.task(checkingOut: "feat/z", in: project, worktrees: listing) == review)
        // The project's own checkout, a branch nobody has, and no branch at all belong to no row.
        #expect(state.task(checkingOut: "main", in: project, worktrees: listing) == nil)
        #expect(state.task(checkingOut: "feat/none", in: project, worktrees: listing) == nil)
        #expect(state.task(checkingOut: "", in: project, worktrees: listing) == nil)
    }

    /// A task's worktree can drift off the branch it was created on. Its saved branch then names
    /// nothing it has checked out, and the branch it did move to is its.
    @Test func testADriftedWorktreeOwnsTheBranchItIsOnNotTheOneItWasCreatedOn() {
        let project = UUID()
        let task = TaskItem(id: UUID(), projectId: project, title: "A", branch: "feat/A", worktreePath: "/wt/a", baseBranch: "main",
                            jira: nil, agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: true,
                            createdAt: Date(), windowId: nil)
        var state = AppState.empty
        state.tasks = [task]
        let drifted = [Worktree(path: "/repo", branch: "main", lockReason: nil), Worktree(path: "/wt/a", branch: "feat/B", lockReason: nil)]
        #expect(state.task(checkingOut: "feat/A", in: project, worktrees: drifted) == nil)
        #expect(state.task(checkingOut: "feat/B", in: project, worktrees: drifted) == task)
    }
}
