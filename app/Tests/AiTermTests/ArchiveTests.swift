import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

extension AppControllerTests {
    @Test func archivingClosesTheWindowRemovesTheWorktreeKeepsTheBranchAndMovesTheRow() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        await archiving?.value

        #expect(server.requests("window.close").map { $0.params["windowId"] as? String } == ["alive"])
        #expect(controller.state.tasks.isEmpty)
        #expect(controller.state.archive.map(\.id) == [task.id])
        #expect(controller.state.archive.first?.task.windowId == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(!(try fixture.git.run(["branch", "--list", "feat/work"], in: fixture.repo.path)).isEmpty, "the branch stays")
        #expect(controller.toastState.toast?.message == "Task archived.")
        #expect(try controller.savedWorkspace().archive.map(\.id) == [task.id], "on disk")
    }

    @Test func archivingADirtyWorktreeAsksAndKeepLeavesTheTaskAsItWas() async throws {
        let prompter = ScriptedPrompter(answering: "Keep Task")
        let fixture = try RaceFixture(prompter: prompter)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)

        await (await fixture.controller.archive(task: task))?.value

        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons == ["Keep Task", "Delete Changes and Archive"])
        #expect(asked.detail == "Archiving deletes its uncommitted changes and untracked files. The branch is kept.")
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(server.requests("window.close").isEmpty)
        #expect(fixture.controller.removal(of: task.id) == nil, "kept before anything moved: no note")
    }

    @Test func deleteChangesAndArchiveArchivesTheDirtyWorktree() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "Delete Changes and Archive"))
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try "wip".write(toFile: task.worktreePath + "/wip.txt", atomically: true, encoding: .utf8)
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.archive.map(\.id) == [task.id])
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aDetachedWorktreeIsNotArchived() async throws {
        let prompter = ScriptedPrompter(answering: "OK")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try fixture.git.run(["checkout", "-q", "--detach"], in: task.worktreePath)
        await (await fixture.controller.archive(task: task))?.value
        #expect(prompter.asked.first?.message == "“Work” can’t be archived")
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func withoutADaemonAWindowedTaskIsNotArchived() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived: iTerm2 isn’t connected", worktreeRemoved: false))
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
    }

    @Test func aWindowThatWillNotCloseStopsTheArchiveAndIsGivenBack() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(failing: ["window.close": .itermUnavailable])
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"])
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived: its window did not close", worktreeRemoved: false))
    }

    @Test func anUnreadableProjectFolderStopsTheArchiveWithNothingMoved() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        let task = try fixture.addTask(windowId: "alive")
        try FileManager.default.removeItem(at: fixture.repo.appendingPathComponent(".git"))
        await (await fixture.controller.archive(task: task))?.value
        #expect(fixture.controller.state.tasks.map(\.id) == [task.id])
        #expect(fixture.controller.state.tasks.map(\.windowId) == ["alive"], "its window too")
        #expect(fixture.controller.state.archive.isEmpty)
        #expect(fixture.controller.removal(of: task.id) == .stopped(note: "Not archived", worktreeRemoved: false))
    }

    @Test func anArchiveThatCannotBeSavedLeavesTheWorktreeAndTheTask() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        let archiving = await controller.archive(task: task)
        try await server.received("window.close")
        // Saving breaks while the window closes: a directory stands where the backup goes.
        let backup = controller.workspace.file.backupURL
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        server.release()
        await archiving?.value

        #expect(controller.persistenceError != nil)
        #expect(controller.state.tasks.map(\.id) == [task.id], "a task again, owed its window")
        #expect(controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath), "nothing deleted")
        #expect(controller.removal(of: task.id) == .stopped(note: "Not archived", worktreeRemoved: false))
        #expect(controller.toastState.toast == nil)
    }

    @Test func archivingTwiceAtOnceArchivesOnce() async throws {
        let fixture = try RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")
        let first = await fixture.controller.archive(task: task)
        let second = await fixture.controller.archive(task: task)
        #expect(first != nil && second == nil)
        server.release()
        await first?.value
        #expect(fixture.controller.state.archive.count == 1)
    }
}
