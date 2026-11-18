import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct ModelsTests {
    @Test func preservedWorkspaceValuesSaveBackByteIdentically() throws {
        let bytes = Data(#"{"future":{"array":[null,true,9007199254740993,1.25,"text"]},"items":[],"lastAgentByProject":[],"lastModelByAgent":[],"tasks":[],"terminals":[]}"#.utf8)
        let state = try JSONDecoder().decode(AppState.self, from: bytes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(state) == bytes)
    }

    @Test func agentsAreOrderedClaudeCodexPi() {
        #expect(AgentKind.allCases == [.claude, .codex, .pi])
        #expect(AgentKind.pi.displayName == "PI")
        #expect(AgentKind.pi.session == .pi && SessionAgent.pi.agentKind == .pi)
        // Each agent is a tab's agent of the same name, and back: the two enums are kept in step
        // by their raw values alone.
        #expect(AgentKind.allCases.allSatisfy { $0.session.agentKind == $0 })
        #expect(SessionAgent.shell.agentKind == nil)
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
        future.agent = .pi; future.kind = .review
        #expect(try raw(future, "kind") == "review" && raw(future, "agent") == "pi")
        // Known values, and a missing kind, are untouched: a task saved without one reads as a task
        // and is saved without one, as a task made here is; one that says "task" keeps saying it.
        #expect(try decoded(agent: "pi", kind: "review").kind == .review)
        let plain = try decoded(agent: "pi", kind: nil)
        #expect(plain.kind == .task && plain.agent == .pi && plain.unrecognizedAgent == nil)
        #expect(try raw(plain, "kind") == nil)
        #expect(try raw(decoded(agent: "pi", kind: "task"), "kind") == "task")
        task = TaskItem(id: UUID(), projectId: UUID(), title: "t", branch: "b", worktreePath: "/w", baseBranch: "main",
                        jira: nil, agent: .codex, model: "m", reasoning: nil, firstPrompt: nil,
                        appendTicket: false, createdAt: Date(timeIntervalSince1970: 0), windowId: nil)
        #expect(try raw(task, "kind") == nil && task.kind == .task)
        task.kind = .task
        #expect(try raw(task, "kind") == "task")
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

    /// A workspace saved while AiTerm drove Grok Build, which it no longer does: its task, conversation
    /// and preferences, as that build wrote them.
    private static let savedGrokWorkspace = """
    {"items":[],"terminals":[],"tasks":[{"id":"1EB4C0DE-0000-0000-0000-000000000001",\
    "projectId":"1EB4C0DE-0000-0000-0000-000000000002","title":"Work","branch":"feat/work",\
    "worktreePath":"/repo/.worktrees/work","baseBranch":"main","agent":"grok","model":"grok-4.7",\
    "appendTicket":false,"createdAt":0,"conversations":[{"agent":"grok","id":"g1"},{"agent":"claude","id":"c1"}]}],\
    "lastAgentByProject":["1EB4C0DE-0000-0000-0000-000000000002","grok"],\
    "lastModelByAgent":["grok","grok-4.7","codex","gpt-5.6"]}
    """

    /// A Grok task still loads, as any task for an agent this build does not know: as a Claude task
    /// that writes its saved agent back. Its Grok conversation cannot be resumed and is dropped, and so
    /// are the preferences that name Grok.
    @Test func savedGrokTaskLoadsAsClaudeAndKeepsItsAgent() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(Self.savedGrokWorkspace.utf8))
        let task = try #require(state.tasks.first)
        #expect(task.agent == .claude && task.unrecognizedAgent == "grok")
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        #expect(written["agent"] as? String == "grok")
        #expect(task.conversations == [TaskConversation(agent: .claude, id: "c1")])
        #expect(state.lastAgentByProject.isEmpty)
        #expect(state.lastModelByAgent == [.codex: "gpt-5.6"])
    }

    /// A former Grok task's Claude conversation was opened by hand, so it resumes on Claude's defaults,
    /// never with the Grok model the task was launched with.
    @Test func formerGrokTaskResumesClaudeOnItsDefaults() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(Self.savedGrokWorkspace.utf8))
        let task = try #require(state.tasks.first)
        #expect(task.resumeCommands == [AgentCommand.resume(agent: .claude, conversation: "c1", model: nil, reasoning: nil)])
    }

    /// Saves carry the linked Jira projects as a list.
    @Test(arguments: [[], ["SHOP", "PAY"]]) func testProjectWritesOnlyItsJiraProjectList(keys: [String]) throws {
        let site = URL(string: "https://example.atlassian.net")!
        let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 1),
                              collapsed: false, jiraProjects: keys.map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: site) })
        let data = try JSONEncoder().encode(project)
        let written = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(try #require(written).keys) == ["id", "name", "path", "provider", "addedAt", "collapsed", "jiraProjects"])
        #expect(try JSONDecoder().decode(Project.self, from: data).jiraProjects.map(\.key) == keys)
    }

    @Test func aListReadsAsASentenceSaysIt() {
        #expect([String]().sentenceList == "")
        #expect(["SHOP"].sentenceList == "SHOP")
        #expect(["SHOP", "PAY"].sentenceList == "SHOP and PAY")
        #expect(["SHOP", "PAY", "WEB"].sentenceList == "SHOP, PAY and WEB")
    }

    /// A project linked twice is linked once, where it first came.
    @Test func aJiraProjectIsLinkedOnceInItsFirstPlace() {
        let site = URL(string: "https://example.atlassian.net")!
        let refs = ["SHOP", "PAY", "SHOP", "WEB", "PAY"].map { JiraProjectRef(id: $0, key: $0, name: $0, siteURL: site) }
        #expect(refs.linkedOnce.map(\.key) == ["SHOP", "PAY", "WEB"])
    }

    /// A remote read on disk replaces a stale stored one, provider and URL together; a project the
    /// pass did not report on keeps its own.
    @Test func aChangedRemoteIsAdoptedAndAnUnreportedOneKept() {
        let added = project("added"), unchanged = project("unchanged"), unreported = project("unreported")
        var state = AppState.empty
        for p in [added, unchanged, unreported] { state.append(project: p) }
        let before = state
        state.adoptRemotes([unchanged.id: WorkspaceScan.Remote(provider: .git, url: nil)])
        #expect(state == before, "nothing changed, so nothing is written")
        state.adoptRemotes([added.id: WorkspaceScan.Remote(provider: .github, url: "git@github.com:me/added.git"),
                            unchanged.id: WorkspaceScan.Remote(provider: .git, url: nil)])
        #expect(state.project(id: added.id)?.provider == .github)
        #expect(state.project(id: added.id)?.remoteUrl == "git@github.com:me/added.git")
        #expect(state.project(id: unchanged.id) == unchanged && state.project(id: unreported.id) == unreported)
        state.adoptRemotes([added.id: WorkspaceScan.Remote(provider: .git, url: nil)])
        #expect(state.project(id: added.id)?.provider == .git && state.project(id: added.id)?.remoteUrl == nil, "a removed remote is adopted too")
    }

    /// An imported worktree is a review when its lock says so, or failing that its folder; anything
    /// else is a task.
    @Test func anImportedWorktreeIsAReviewByItsLockOrElseItsFolder() {
        #expect(Worktree(path: "/r/.worktrees/x", branch: "x", lockReason: Worktree.reviewLockReason).importedKind == .review)
        #expect(Worktree(path: "/r/.worktrees/review-x", branch: "x", lockReason: nil).importedKind == .review)
        #expect(Worktree(path: "/r/.worktrees/review-x", branch: "x", lockReason: Worktree.taskLockReason).importedKind == .review)
        #expect(Worktree(path: "/r/.worktrees/x", branch: "x", lockReason: Worktree.taskLockReason).importedKind == .task)
        #expect(Worktree(path: "/r/.worktrees/x-review-y", branch: "x", lockReason: "").importedKind == .task)
    }

    /// A field this build does not know survives decoding and saving alongside the task.
    @Test func aKeyThisBuildDoesNotKnowOnATaskSurvivesASave() throws {
        let json = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","projectId":"1EB4C0DE-0000-0000-0000-000000000002",\
        "title":"Work","branch":"feat/work","worktreePath":"/repo/.worktrees/work","baseBranch":"main",\
        "agent":"claude","model":"opus","appendTicket":true,"createdAt":"1970-01-01T00:00:01Z",\
        "windowId":"w1","fromANewerBuild":"kept"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.title == "Work" && task.windowId == "w1")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try #require(JSONSerialization.jsonObject(with: encoder.encode(task)) as? [String: Any])
        #expect(encoded["fromANewerBuild"] as? String == "kept")
    }

    @Test func aKeyThisBuildDoesNotKnowOnAWorkspaceSurvivesASave() throws {
        let state = try JSONDecoder().decode(AppState.self, from: Data(#"{"items":[],"foldedRuns":["kept"]}"#.utf8))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        #expect(encoded["foldedRuns"] as? [String] == ["kept"])
    }

    @Test func rowsAreFoundByTheirId() {
        let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
        let divider = SidebarDivider(id: UUID(), name: "Work")
        let task = TaskItem.make(project: project.id, worktreePath: "/repo/.worktrees/work", model: "opus", createdAt: Date())
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

    /// A window iTerm2 no longer has leaves its row without one — a task's and a terminal's alike; a
    /// stale report leaves a newer window be.
    @Test func aClosedWindowLeavesItsRowOwedIt() throws {
        let project = Project.make(name: "Repo", path: "/tmp/repo")
        let task = TaskItem.make(project: project.id, worktreePath: "/tmp/repo/.worktrees/work", model: "sonnet",
            firstPrompt: "Do the work", windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "w2",
                                    createdAt: Date(timeIntervalSince1970: 0))
        var state = AppState.empty
        state.items = [.project(project)]; state.tasks = [task]; state.terminals = [terminal]
        state.tasks[0].conversations = [TaskConversation(agent: .claude, id: "c1")]
        let closed1 = state.closeWindow("w1")
        #expect(closed1)
        #expect(state.tasks[0].conversations == [TaskConversation(agent: .claude, id: "c1")], "what a reopen resumes stays")
        #expect(state.tasks.map(\.id) == [task.id] && state.tasks.map(\.windowId) == [nil], "the task stays, windowless")
        #expect(state.terminals.count == 1)
        let closed2 = state.closeWindow("w1")
        #expect(!closed2, "a second report changes nothing")
        var replacement = task
        replacement.windowId = "w3"
        state.tasks = [replacement]
        let closed3 = state.closeWindow("w1")
        #expect(!closed3, "a stale report leaves the newer window be")
        #expect(state.tasks[0].windowId == "w3")
        let closed4 = state.closeWindow("w2")
        #expect(closed4)
        #expect(state.terminals.map(\.windowId) == [nil], "the terminal stays, owed")
        let closed5 = state.closeWindow("w3")
        #expect(closed5)
        #expect(state.tasks.map(\.windowId) == [nil])
        let rows = SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
        #expect(rows.first?.tasks.map(\.id) == [task.id])
    }

    /// The Operator's chat window closing leaves the chat without one, except while its lifecycle changes:
    /// the keeper writes it then. The chat stays open, without a window.
    @Test func aClosedWindowClearsTheOperatorsChatOnlyWhileItsLifecycleIsSettled() {
        var state = AppState.empty
        state.operatorSession = .open(createdAt: Date(timeIntervalSince1970: 0), window: "chat")
        state.operatorSession?.lifecycle = .closing(then: .renew)
        let whileClosing = state.closeWindow("chat")
        #expect(!whileClosing && state.operatorSession?.window == "chat")
        state.operatorSession?.lifecycle = .open(since: Date(timeIntervalSince1970: 0), wake: nil)
        let other = state.closeWindow("other")
        #expect(!other)
        let closed = state.closeWindow("chat")
        #expect(closed && state.operatorSession?.window == nil && state.operatorSession?.lifecycle.isOpen == true)
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
        #expect(task.kind == .task)
        #expect(task.mr == nil)
        #expect(task.title == "Add gift card")
    }

    @Test func testTaskItemRoundTripsAReview() throws {
        let mr = MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4")
        var task = TaskItem(id: UUID(), projectId: UUID(), title: "Review gift card", branch: "feat-gift",
                            worktreePath: "/tmp/wt", baseBranch: "main", jira: nil, kind: .review, mr: mr,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        #expect(decoded.kind == .review)
        #expect(decoded.mr == mr)
    }

    /// What a reopen resumes is saved with the task: written only when there is some, so a workspace
    /// without any reads and writes as before, and read leniently, so an agent this build does not know
    /// costs its own entry, and a list it cannot read costs only the list, never the workspace.
    @Test func aTasksConversationsAreSavedOnlyWhenItHasSomeAndReadLeniently() throws {
        let base = """
        {"id":"1EB4C0DE-0000-0000-0000-000000000001","projectId":"1EB4C0DE-0000-0000-0000-000000000002",\
        "title":"Work","branch":"feat/work","worktreePath":"/repo/.worktrees/work","baseBranch":"main",\
        "agent":"claude","model":"opus","appendTicket":true,"createdAt":0
        """
        let none = try JSONDecoder().decode(TaskItem.self, from: Data((base + "}").utf8))
        #expect(none.conversations.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("conversations"))
        let mixed = try JSONDecoder().decode(TaskItem.self, from: Data((base + #","conversations":[{"agent":"gremlin","id":"x"},{"agent":"claude","id":"c-1"},{"agent":"codex","id":""}]}"#).utf8))
        #expect(mixed.conversations == [TaskConversation(agent: .claude, id: "c-1")])
        let flag = try JSONDecoder().decode(TaskItem.self, from: Data((base + #","conversations":[{"agent":"claude","id":"--model"},{"agent":"codex","id":"t-1"}]}"#).utf8))
        #expect(flag.conversations == [TaskConversation(agent: .codex, id: "t-1")], "an id the CLI would read as a flag is dropped")
        let unreadable = try JSONDecoder().decode(TaskItem.self, from: Data((base + #","conversations":"many"}"#).utf8))
        #expect(unreadable.conversations.isEmpty)
    }

    /// `TaskItem`'s `Codable` is written by hand, so nothing but this keeps a field from being left
    /// out of one half: every field set, each is written under its own key and read back as it was.
    @Test func aTaskWithEveryFieldSetRoundTripsWhole() throws {
        var task = TaskItem(id: UUID(), projectId: UUID(), title: "Review gift card", branch: "feat-gift",
                            worktreePath: "/tmp/wt", baseBranch: "develop",
                            jira: JiraRef(key: "SHOP-1", summary: "Gift card", url: "https://x.atlassian.net/browse/SHOP-1"),
                            kind: .review, mr: MergeRequestRef(iid: 4, title: "Add gift card", url: "https://git.example.net/g/p/-/merge_requests/4"),
                            agent: .codex, model: "gpt-5.6", reasoning: "high", firstPrompt: "Look at it", appendTicket: true,
                            createdAt: Date(timeIntervalSince1970: 1_700_000_000), windowId: "w9",
                            conversations: [TaskConversation(agent: .codex, id: "t-1"), TaskConversation(agent: .claude, id: "c-2")])
        task.signalTask = SignalTask.make(item: .ticket(site: "https://x.atlassian.net", key: "SHOP-1"), startedAt: Date())
        let data = try JSONEncoder().encode(task)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["id", "projectId", "title", "branch", "worktreePath", "baseBranch", "jira", "kind", "mr", "agent",
                              "model", "reasoning", "firstPrompt", "appendTicket", "createdAt", "windowId", "conversations",
                              "signalTask"])
        #expect(try JSONDecoder().decode(TaskItem.self, from: data) == task)
    }

    /// A row with no `kind`, or one that is not a string, is a row this build cannot read, as one
    /// of a kind it does not know is: it is kept as it came rather than failing the whole workspace.
    @Test(arguments: [#"{"project":{"n":1}}"#, #"{"kind":7,"project":{"n":1}}"#, #"{"kind":null}"#])
    func aSidebarItemWithoutAReadableKindIsKeptAsItCame(_ json: String) throws {
        let item = try JSONDecoder().decode(SidebarItem.self, from: Data(json.utf8))
        #expect(!item.isDrawn)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? NSDictionary
        #expect(written == (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary))
    }

    private func project(_ name: String, id: UUID = UUID()) -> Project {
        Project.make(id: id, name: name, path: "/" + name)
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

    @Test func tasksMoveOnlyPastTheirVisibleProjectAndKindNeighbours() throws {
        var world = SignalWorld()
        let held = world.workingTask(signal: world.signal())
        let driven = try #require(world.state.task(id: held))
        let other = Project.make()
        world.state.append(project: other)
        let first = TaskItem.make(project: world.project.id)
        let second = TaskItem.make(project: world.project.id, kind: .task)
        let review = TaskItem.make(project: world.project.id, kind: .review)
        let nextReview = TaskItem.make(project: world.project.id, kind: .review)
        let foreign = TaskItem.make(project: other.id)
        world.state.tasks = [first, review, driven, foreign, second, nextReview]
        let original = world.state

        #expect(!world.state.canMove(taskId: first.id, .up))
        #expect(world.state.canMove(taskId: first.id, .down))
        #expect(!world.state.canMove(taskId: second.id, .down))
        let moved = world.state.move(taskId: second.id, .up)
        #expect(moved)
        #expect(world.state.tasks == [second, review, driven, foreign, first, nextReview])
        let restored = world.state.move(taskId: second.id, .down)
        #expect(restored && world.state == original)
        let reviewMoved = world.state.move(taskId: review.id, .down)
        #expect(reviewMoved)
        #expect(world.state.tasks == [first, nextReview, driven, foreign, second, review])
        #expect(world.state.items == original.items && world.state.terminals == original.terminals)
    }

    @Test func taskMovementRejectsMissingParentsOperatorTasksAndGroupEdges() throws {
        var world = SignalWorld()
        let held = world.workingTask(signal: world.signal())
        let alone = TaskItem.make(project: world.project.id)
        let review = TaskItem.make(project: world.project.id, kind: .review)
        let orphan = TaskItem.make(project: UUID())
        world.state.tasks += [alone, review, orphan]
        let original = world.state
        for id in [alone.id, review.id, orphan.id, held, UUID()] {
            for step in [MoveStep.up, .down] {
                #expect(!world.state.canMove(taskId: id, step))
                let moved = world.state.move(taskId: id, step)
                #expect(!moved)
                #expect(world.state == original)
            }
        }
    }

    /// A signal swaps with the live signal beside it. A removed signal is no longer in `signals`, so its
    /// leftover heading is never a neighbour, and nothing but the signal order changes.
    @Test func signalsMoveOnePlaceAndStopAtTheirEdges() throws {
        var world = SignalWorld()
        let first = world.signal(name: "First"), second = world.signal(name: "Second"), third = world.signal(name: "Third")
        let gone = world.signal(name: "Gone")
        world.workingTask(signal: gone)
        world.state.signals.removeAll { $0.id == gone }
        world.state.signals[1].enabled = false
        let original = world.state

        #expect(!world.state.canMove(signalId: first, .up) && world.state.canMove(signalId: first, .down))
        #expect(world.state.canMove(signalId: second, .up) && world.state.canMove(signalId: second, .down))
        #expect(world.state.canMove(signalId: third, .up) && !world.state.canMove(signalId: third, .down))
        for id in [gone, UUID()] {
            for step in [MoveStep.up, .down] {
                #expect(!world.state.canMove(signalId: id, step))
                let moved = world.state.move(signalId: id, step)
                #expect(!moved && world.state == original)
            }
        }
        let blockedUp = world.state.move(signalId: first, .up), blockedDown = world.state.move(signalId: third, .down)
        #expect(!blockedUp && !blockedDown && world.state == original)

        let down = world.state.move(signalId: first, .down)
        #expect(down)
        #expect(world.state.signals.map(\.id) == [second, first, third])
        let up = world.state.move(signalId: third, .up)
        #expect(up)
        #expect(world.state.signals.map(\.id) == [second, third, first])
        #expect(world.state.signals.map(\.enabled) == [false, true, true])
        #expect(world.state.tasks == original.tasks && world.state.items == original.items)
        #expect(world.state.signalSeen == original.signalSeen && world.state.operatorSession == original.operatorSession)
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

    /// An unrecognized workspace key survives a save without creating sidebar rows.
    @Test func aProjectsKeyIsPreservedWithoutCreatingItems() throws {
        let data = Data(#"{"projects":[{"name":"one","nested":{"count":2}}],"tasks":[],"terminals":[]}"#.utf8)
        let state = try JSONDecoder().decode(AppState.self, from: data)
        #expect(state.items.isEmpty)
        let before = try JSONDecoder().decode(JSONValue.self, from: data)
        let after = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(state))
        #expect(after["projects"] == before["projects"])
    }

    /// A review of a branch opens in the row whose worktree git reports it checked out in — a
    /// task's or an earlier review's — decided by that checkout, not by the branch the row was
    /// created on. The same path in another project is another repository's row.
    @Test func testTheRowCheckingOutABranchIsFoundByItsWorktree() {
        let project = UUID(), other = UUID()
        func item(_ title: String, bound branch: String, in projectId: UUID, kind: TaskKind = .task) -> TaskItem {
            TaskItem.make(project: projectId, title: title, branch: branch, worktreePath: "/wt/" + title, kind: kind,
                model: "sonnet", appendTicket: true, createdAt: Date())
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
        let task = TaskItem.make(project: project, title: "A", branch: "feat/A", worktreePath: "/wt/a", model: "sonnet",
            appendTicket: true, createdAt: Date())
        var state = AppState.empty
        state.tasks = [task]
        let drifted = [Worktree(path: "/repo", branch: "main", lockReason: nil), Worktree(path: "/wt/a", branch: "feat/B", lockReason: nil)]
        #expect(state.task(checkingOut: "feat/A", in: project, worktrees: drifted) == nil)
        #expect(state.task(checkingOut: "feat/B", in: project, worktrees: drifted) == task)
    }
}
