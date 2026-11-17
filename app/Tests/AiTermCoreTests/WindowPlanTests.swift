import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Which windows `AppState.windowPlan` says rows take by their tag — or none.
@Suite struct WindowPlanTests {
    let project = UUID()

    func task(window: String?) -> TaskItem {
        TaskItem.make(project: project, title: "t", branch: "b", worktreePath: "/w", windowId: window)
    }

    func terminal(window: String?) -> TerminalItem {
        TerminalItem(id: UUID(), projectId: project, name: "Terminal", windowId: window, createdAt: Date(timeIntervalSince1970: 0))
    }

    func tab(_ id: String, window: String, task: TaskItem? = nil, terminal: TerminalItem? = nil) -> SessionInfo {
        var tab = SessionInfo.make(id, window: window, task: task?.id)
        tab.terminalId = terminal?.id.uuidString
        return tab
    }

    func state(tasks: [TaskItem] = [], terminals: [TerminalItem] = []) -> AppState {
        var state = AppState.empty
        state.tasks = tasks
        state.terminals = terminals
        return state
    }

    /// A driven task takes the window its tag is in, as any row does; without one it gets nothing here:
    /// a closed one opens only on your click, through the operator controller's worker opener.
    @Test func anOperatorsStartedTaskTakesItsTaggedWindowButIsNeverRestoredHere() {
        var working = task(window: nil)
        working.signalTask = SignalTask(signal: UUID(), item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        working.signalTask?.phase = .working
        #expect(state(tasks: [working]).windowPlan(sessions: []).isEmpty)
        let adopted = state(tasks: [working]).windowPlan(sessions: [tab("a", window: "w9", task: working)])
        #expect(adopted == [WindowAdoption(.task(working.id), windowId: "w9")])
    }

    @Test func aRowWithItsWindowNeedsNothing() {
        let open = task(window: "w1"), shell = terminal(window: "w2")
        let plan = state(tasks: [open], terminals: [shell]).windowPlan(
            sessions: [tab("a", window: "w1", task: open), tab("b", window: "w2", terminal: shell)])
        #expect(plan.isEmpty)
    }

    /// The one adoption rule: a row takes a window its tag is in when it has none, or when its own is
    /// not among them — a create whose reply was lost, a window iTerm2 renumbered or restored, a tab
    /// dragged out. A row whose own window still carries its tag keeps it.
    @Test func aRowTakesTheWindowItsTagIsIn() {
        let lost = task(window: nil), moved = task(window: "w1"), kept = task(window: "w3"), shell = terminal(window: "old")
        let plan = state(tasks: [lost, moved, kept], terminals: [shell]).windowPlan(
            sessions: [tab("a", window: "w5", task: lost), tab("b", window: "w6", task: lost), tab("c", window: "w2", task: moved),
                       tab("d", window: "w3", task: kept), tab("e", window: "w9", task: kept), tab("f", window: "w7", terminal: shell)])
        #expect(plan == [WindowAdoption(.task(lost.id), windowId: "w5"), WindowAdoption(.task(moved.id), windowId: "w2"),
                         WindowAdoption(.terminal(shell.id), windowId: "w7")])
    }

    @Test func resumeCommandsSkipAnEmptyIdAndOneThatReadsAsAFlag() {
        var owed = task(window: nil)
        owed.conversations = [TaskConversation(agent: .codex, id: ""), TaskConversation(agent: .claude, id: "--dangerously-skip-permissions"),
                              TaskConversation(agent: .claude, id: "conv-2")]
        #expect(owed.resumeCommands == ["claude --resume conv-2 --model m"])
    }
}
