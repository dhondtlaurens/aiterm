import Foundation
import Testing
@testable import AiTermCore

/// What `AppState.windowPlan` says to do about each row's window: take back a window its tag is in,
/// restore one it is owed, ask about a task closed alone, drop a terminal closed alone — or nothing.
@Suite struct WindowPlanTests {
    let project = UUID()

    func task(window: String?) -> TaskItem {
        TaskItem(id: UUID(), projectId: project, title: "t", branch: "b", worktreePath: "/w", baseBranch: "main", jira: nil,
                 agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(timeIntervalSince1970: 0), windowId: window)
    }

    func terminal(window: String?) -> TerminalItem {
        TerminalItem(id: UUID(), projectId: project, name: "Terminal", windowId: window, createdAt: Date(timeIntervalSince1970: 0))
    }

    func tab(_ id: String, window: String, task: TaskItem? = nil, terminal: TerminalItem? = nil) -> SessionInfo {
        var tab = SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: task?.id.uuidString, projectId: nil, agent: .claude,
                              model: nil, state: .idle, title: "", cwd: "/")
        tab.terminalId = terminal?.id.uuidString
        return tab
    }

    func state(tasks: [TaskItem] = [], terminals: [TerminalItem] = []) -> AppState {
        var state = AppState.empty
        state.tasks = tasks
        state.terminals = terminals
        return state
    }

    @Test func aRowWithItsWindowNeedsNothing() {
        let open = task(window: "w1"), shell = terminal(window: "w2")
        let plan = state(tasks: [open], terminals: [shell]).windowPlan(
            sessions: [tab("a", window: "w1", task: open), tab("b", window: "w2", terminal: shell)],
            settled: true, due: [], waiting: [], lettingGo: [])
        #expect(plan.isEmpty)
    }

    /// The one adoption rule: a row takes a window its tag is in when it has none, or when its own is
    /// not among them — a create whose reply was lost, a window iTerm2 renumbered or restored, a tab
    /// dragged out. A row whose own window still carries its tag keeps it.
    @Test func aRowTakesTheWindowItsTagIsIn() {
        let lost = task(window: nil), moved = task(window: "w1"), kept = task(window: "w3"), shell = terminal(window: "old")
        let plan = state(tasks: [lost, moved, kept], terminals: [shell]).windowPlan(
            sessions: [tab("a", window: "w5", task: lost), tab("b", window: "w6", task: lost), tab("c", window: "w2", task: moved),
                       tab("d", window: "w3", task: kept), tab("e", window: "w9", task: kept), tab("f", window: "w7", terminal: shell)],
            settled: false, due: [], waiting: [], lettingGo: [])
        #expect(plan == [.adopt(.task(lost.id), windowId: "w5"), .adopt(.task(moved.id), windowId: "w2"),
                         .adopt(.terminal(shell.id), windowId: "w7")])
    }

    @Test func anOwedRowIsRestoredOnlyOnceSettledAndNotWaiting() {
        let owed = task(window: nil), busy = task(window: nil), shell = terminal(window: nil)
        let base = state(tasks: [owed, busy], terminals: [shell])
        #expect(base.windowPlan(sessions: [], settled: false, due: [], waiting: [], lettingGo: []).isEmpty)
        #expect(base.windowPlan(sessions: [], settled: true, due: [], waiting: [busy.id], lettingGo: [])
                == [.restore(.task(owed.id)), .restore(.terminal(shell.id))])
    }

    /// A lone close whose hold is over: a task is asked about, a terminal goes — even if iTerm2 left
    /// after the hold. One with work on it, or waiting for another reason, is neither.
    @Test func aDueCloseAsksAboutATaskAndDropsATerminal() {
        let closed = task(window: nil), busy = task(window: nil), shell = terminal(window: nil)
        let plan = state(tasks: [closed, busy], terminals: [shell]).windowPlan(
            sessions: [], settled: false, due: [closed.id, busy.id, shell.id], waiting: [busy.id], lettingGo: [])
        #expect(plan == [.ask(closed.id), .drop(shell.id)])
    }

    /// A due task whose tab lives on in another window takes that window instead of being asked.
    @Test func aDueTaskWhoseTabLivesOnIsAdoptedNotAsked() {
        let moved = task(window: nil)
        let plan = state(tasks: [moved]).windowPlan(sessions: [tab("a", window: "other", task: moved)], settled: true,
                                                    due: [moved.id], waiting: [], lettingGo: [])
        #expect(plan == [.adopt(.task(moved.id), windowId: "other")])
    }

    /// A task whose removal has let its window go is the removal's: never handed a window, never restored.
    @Test func aTaskLettingItsWindowGoIsLeftToItsRemoval() {
        let leaving = task(window: nil)
        let plan = state(tasks: [leaving]).windowPlan(sessions: [tab("a", window: "w1", task: leaving)], settled: true,
                                                      due: [leaving.id], waiting: [], lettingGo: [leaving.id])
        #expect(plan.isEmpty)
    }

    @Test func resumeCommandsSkipAnEmptyIdAndOneThatReadsAsAFlag() {
        var owed = task(window: nil)
        owed.conversations = [TaskConversation(agent: .codex, id: ""), TaskConversation(agent: .claude, id: "--dangerously-skip-permissions"),
                              TaskConversation(agent: .claude, id: "conv-2")]
        #expect(owed.resumeCommands == ["claude --resume conv-2 --model m"])
    }
}
