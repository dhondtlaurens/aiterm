import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A reopened window resumes the conversations its tabs last showed, in their order: the first in the
/// window's own tab, each other in a tab of its own; the task's agent on the model it was launched with.
extension AppControllerTests {
    @Test func reopeningResumesEachConversationInItsTabsOrder() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)   // a Codex task on "model"
        fixture.controller.workspace.mutate {
            $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2")]
        }

        await fixture.controller.reopen(task: task)?.value

        let window = try #require(server.requests("window.createTask").first)
        #expect(window.params["agentCommand"] as? String == "codex resume thread-1 --dangerously-bypass-approvals-and-sandbox -m model")
        let tabs = server.requests("tab.create")
        #expect(tabs.map { $0.params["agentCommand"] as? String } == ["claude --resume conv-2"])
        #expect(tabs.map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(tabs.map { $0.params["cwd"] as? String } == [task.worktreePath])
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
    }

    /// Each conversation after the first gets a tab of its own, opened in the order they were.
    @Test func reopeningThreeConversationsOpensTwoTabsInOrder() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.workspace.mutate {
            $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2"),
                                         TaskConversation(agent: .grok, id: "g-3")]
        }

        await fixture.controller.reopen(task: task)?.value

        #expect(server.requests("tab.create").map { $0.params["agentCommand"] as? String } == ["claude --resume conv-2", "grok --resume g-3"])
        #expect(server.requests("tab.create").map { $0.params["windowId"] as? String } == ["reopened", "reopened"])
    }

    /// With no conversation known it is a plain shell in the worktree, as Reopen Window always was.
    @Test func aTaskWithNoConversationReopensAPlainShell() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)

        await fixture.controller.reopen(task: task)?.value

        #expect(server.requests("window.createTask").first?.params["agentCommand"] == nil)
        #expect(server.requests("tab.create").isEmpty)
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
    }

    /// The window is the row's once it opened; a conversation whose tab would not open says so, and the
    /// rest wait for the person rather than be tried into a window that is failing.
    @Test func aConversationWhoseTabWouldNotOpenSaysSo() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["tab.create": "temporary_failure"])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: nil)
        fixture.controller.workspace.mutate {
            $0.tasks[0].conversations = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2"),
                                         TaskConversation(agent: .grok, id: "g-3")]
        }

        await fixture.controller.reopen(task: task)?.value

        #expect(fixture.controller.state.task(id: task.id)?.windowId == "reopened")
        #expect(server.requests("tab.create").count == 1)
        #expect(fixture.controller.issue?.title == "Reopened the window, but not every conversation.")
        #expect(fixture.controller.issue?.subject == task.id)
    }

    /// Never a resume command for an empty id, whatever a workspace holds.
    @Test func noResumeCommandIsBuiltForAnEmptyId() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        var task = try fixture.addTask(windowId: nil)
        task.conversations = [TaskConversation(agent: .codex, id: ""), TaskConversation(agent: .claude, id: "conv-2")]

        #expect(TaskLauncher.resumeCommands(for: task) == ["claude --resume conv-2"])
    }
}
