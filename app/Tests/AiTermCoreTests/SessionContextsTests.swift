import Foundation
import Testing
@testable import AiTermCore

/// The context fill each row keeps per provider (`SessionContexts`), as the tabs report it. The
/// app's `LiveSessions` feeds it the helper's events; these are the same rules on the value alone.
@Suite struct SessionContextsTests {
    let project = Project(id: UUID(), name: "Repo", path: "/repo", provider: .git, remoteUrl: nil,
                          addedAt: Date(timeIntervalSince1970: 0), collapsed: false)

    func tab(_ id: String, window: String, task: TaskItem? = nil, agent: SessionAgent, active: Bool, context: Int?) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: task?.id.uuidString, projectId: project.id.uuidString,
                    agent: agent, model: nil, state: .idle, title: id, cwd: "/repo", active: active, contextPercent: context)
    }

    /// A snapshot seeds each provider from its active tab; a tab change keeps the row's value until
    /// a tab reports, even one re-reporting an old value; missing telemetry never erases one; and a
    /// row that leaves the workspace takes its values with it.
    @Test func aTasksContextFollowsWhatItsTabsReport() {
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work", worktreePath: "/repo/.worktrees/work",
                            baseBranch: "main", jira: nil, agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(timeIntervalSince1970: 0), windowId: "w1")
        var state = AppState.empty
        state.append(project: project)
        state.tasks = [task]
        let first = tab("a", window: "w1", task: task, agent: .claude, active: true, context: 42)
        let second = tab("b", window: "w1", task: task, agent: .claude, active: false, context: 18)
        let codex = tab("c", window: "w1", task: task, agent: .codex, active: false, context: 64)
        var contexts = SessionContexts()
        contexts.seed(from: [first, second, codex], in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 42, .codex: 64])

        var firstInactive = first; firstInactive.active = false
        var secondActive = second; secondActive.active = true
        contexts.remember(firstInactive, replacing: first, in: state)
        contexts.remember(secondActive, replacing: second, in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 42, .codex: 64], "a tab change is not telemetry")

        var propagated = firstInactive; propagated.contextPercent = 18
        contexts.remember(propagated, replacing: firstInactive, in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 18, .codex: 64], "a tab re-reporting an old value still replaces it")

        var reported = secondActive; reported.contextPercent = 27
        contexts.remember(reported, replacing: secondActive, in: state)
        var silent = reported; silent.contextPercent = nil
        contexts.remember(silent, replacing: reported, in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 27, .codex: 64], "missing telemetry never erases a value")

        contexts.seed(from: [first, second, codex], in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 27, .codex: 64], "a snapshot only fills what is unknown")

        state.tasks = []
        contexts.prune(keeping: state)
        #expect(contexts.percents(forRow: task.id).isEmpty)
        #expect(contexts == SessionContexts())
    }

    /// With no active tab for a provider, its fullest tab seeds the row.
    @Test func withNoActiveTabTheFullestSeeds() {
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "b", worktreePath: "/w", baseBranch: "main",
                            jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(timeIntervalSince1970: 0), windowId: "w1")
        var state = AppState.empty
        state.tasks = [task]
        var contexts = SessionContexts()
        contexts.seed(from: [tab("a", window: "w1", task: task, agent: .claude, active: false, context: 12),
                             tab("b", window: "w1", task: task, agent: .claude, active: false, context: 30)], in: state)
        #expect(contexts.percents(forRow: task.id) == [.claude: 30])
    }

    /// A terminal's tabs carry no task tag, so they are matched on the window; a tab tagged with a
    /// task the workspace does not have counts for no row.
    @Test func aTerminalsContextIsMatchedOnItsWindow() {
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "w2", createdAt: Date(timeIntervalSince1970: 0))
        let other = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal 2", windowId: "w3", createdAt: Date(timeIntervalSince1970: 0))
        var state = AppState.empty
        state.terminals = [terminal, other]
        var contexts = SessionContexts()
        let shell = tab("t", window: "w2", agent: .shell, active: true, context: nil)
        contexts.seed(from: [shell], in: state)
        #expect(contexts == SessionContexts())

        var claude = shell; claude.agent = .claude
        contexts.remember(claude, replacing: shell, in: state)
        #expect(contexts == SessionContexts(), "the agent has not reported yet")
        var reporting = claude; reporting.contextPercent = 12
        contexts.remember(reporting, replacing: claude, in: state)
        #expect(contexts.percents(forRow: terminal.id) == [.claude: 12])
        #expect(contexts.percents(forRow: other.id).isEmpty, "another terminal's window is not this one")

        let stranger = TaskItem(id: UUID(), projectId: project.id, title: "Gone", branch: "b", worktreePath: "/w", baseBranch: "main",
                                jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                                createdAt: Date(timeIntervalSince1970: 0), windowId: "w2")
        let before = contexts
        contexts.remember(tab("x", window: "w2", task: stranger, agent: .claude, active: true, context: 90), replacing: nil, in: state)
        #expect(contexts == before, "a tab tagged with a task the workspace lacks is not the terminal's")
    }
}
