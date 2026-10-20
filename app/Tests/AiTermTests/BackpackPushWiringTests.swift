import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What the app hands Backpack Mode's pushes: every row as the sidebar shows it, and the helper that
/// takes a push to iTerm2.
@MainActor
@Suite(.serialized) struct BackpackPushWiringTests {
    private func loaded() throws -> (AppController, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        return (controller, dir)
    }

    private let push = BackpackPush(needsInput: [.codex], done: [])

    /// A task whose Codex tab asks: its status and its agent, and nothing else of the task.
    @Test func aWaitingRowIsAPushRowWithItsAgent() throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = Project(id: UUID(), name: "client-x", path: "/client-x", provider: .git, remoteUrl: nil, addedAt: Date(),
                              collapsed: false)
        controller.workspace.mutate { $0.append(project: project) }
        let task = TaskItem.stub(in: project, title: "Fix the payroll export")
        controller.workspace.mutate { $0.tasks = [task] }
        controller.live.sessions = [SessionInfo.stub("a", window: "w1", task: task, state: .needsInput, agent: .codex)]
        #expect(controller.pushRows() == [PushRow(id: .task(task.id), status: .needsInput, agent: .codex)])
        #expect(controller.backpack.pushRows() == controller.pushRows(), "Backpack Mode reads them")
    }

    /// The broadcast is a row of its own, after the projects'.
    @Test func theBroadcastIsARowOfItsOwn() throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        var run = OperatorUIFixtures.run()
        run.questions = [OperatorUIFixtures.question("Which footer copy should it use?")]
        controller.workspace.mutate { $0.runs = [run] }
        #expect(controller.pushRows() == [PushRow(id: .broadcast(run.id), status: .needsInput, agent: .claude)])
    }

    @Test func aPushGoesToTheHelper() async throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = RecordingDaemon()
        controller.helper.setDaemonClient(server)
        #expect(await controller.backpack.sendPush(push) == nil)
        let sent = server.requests("companion.notify")
        #expect(sent.count == 1)
        #expect(sent.first?.params["title"] as? String == "AiTerm")
        #expect(sent.first?.params["body"] as? String == "Codex needs your input.")
    }

    @Test func aRefusalComesBackAsItsReason() async throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = RecordingDaemon()
        server.pushRefusal = "Notifications are turned off for iTerm2 Buddy. Enable them in iOS Settings on the paired phone."
        controller.helper.setDaemonClient(server)
        #expect(await controller.sendPush(push)
                == "Notifications are turned off for iTerm2 Buddy. Enable them in iOS Settings on the paired phone.")
        server.pushRefusal = "Notification delivery failed: The request timed out"
        #expect(await controller.sendPush(push) == "Notification delivery failed: The request timed out.", "a sentence, for the sheet")
    }

    /// A helper from before `companion.notify` answers unknown_method: a reason, never a crash.
    @Test func aHelperWithoutTheMethodIsAFailureNotACrash() async throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.helper.setDaemonClient(RecordingDaemon(failing: ["companion.notify": .unknownMethod]))
        #expect(await controller.sendPush(push) == "AiTerm’s helper is from another version.")
    }

    @Test func noHelperIsAFailure() async throws {
        let (controller, dir) = try loaded()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await controller.sendPush(push) == "AiTerm’s helper isn’t connected.")
    }
}
