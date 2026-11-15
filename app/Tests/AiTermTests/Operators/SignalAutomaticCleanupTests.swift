import Foundation
import Synchronization
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor @Suite(.blocking) struct SignalAutomaticCleanupTests {
    @Test func aJournalAppendDuringCleanupPreflightDoesNotChangeItsCheckoutAuthority() async throws {
        let git = PreflightHeldGit()
        let fixture = try await RaceFixture(controllerGit: git); let server = RecordingDaemon()
        defer { git.open(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let original = try await fixture.addTask(windowId: "alive")
        var record = SignalTask(signal: UUID(), item: .unknown(.null), startedAt: Date()); record.phase = .done
        fixture.controller.workspace.mutate { state in if let index = state.tasks.firstIndex(where: { $0.id == original.id }) { state.tasks[index].signalTask = record } }
        let task = try #require(fixture.controller.state.task(id: original.id))
        git.arm()
        let job = Task { try await fixture.controller.remover.removeAutomatically(task, starting: { true }) }
        await eventually { git.started }
        let note = TaskJournal.Entry(at: Date(), stage: 1, text: .ours("A saved decision."))
        fixture.controller.workspace.mutate { $0.updateSignalTask(task.id) { $0.journal.append(note) } }
        git.open()
        try await job.value
        #expect(fixture.controller.state.task(id: task.id) == nil)
    }
    @Test func automaticArchiveClosesAndSavesBeforeRemovingACleanCheckoutWithoutQuestions() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        try await fixture.controller.archiver.archiveAutomatically(task, starting: { true })
        #expect(fixture.prompter.asked.isEmpty)
        #expect(server.requests("window.close").count == 1)
        #expect(fixture.controller.state.archived(id: task.id) != nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(try fixture.git.run(["branch", "--list", task.branch], in: fixture.repo.path).isEmpty == false)
        #expect(try fixture.controller.savedWorkspace().archived(id: task.id) != nil)
    }

    @Test func automaticArchiveKeepsUnsavedWorkWithoutAskingToDiscardIt() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        let path = task.worktreePath + "/work.txt"
        try "Keep this".write(toFile: path, atomically: true, encoding: .utf8)
        await #expect(throws: ActionUnavailable.self) { try await fixture.controller.archiver.archiveAutomatically(task, starting: { true }) }
        #expect(fixture.prompter.asked.isEmpty && server.requests("window.close").isEmpty)
        #expect(fixture.controller.state.task(id: task.id) != nil && FileManager.default.fileExists(atPath: path))
    }

    @Test func losingCleanupAuthorityWhileTheWindowClosesKeepsTheCheckout() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.close")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        var allowed = true
        let job = Task { try await fixture.controller.archiver.archiveAutomatically(task, starting: { allowed }) }
        try await server.received("window.close")
        allowed = false; server.release()
        await #expect(throws: ActionUnavailable.self) { try await job.value }
        #expect(fixture.controller.state.task(id: task.id) != nil && fixture.controller.state.archive.isEmpty)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath) && fixture.prompter.asked.isEmpty)
    }

    @Test func pendingWorkDuringGitRemovalRestoresTheCheckoutBeforeTheRowCanBeForgotten() async throws {
        let git = RemovalHeldGit()
        let fixture = try await RaceFixture(controllerGit: git)
        let server = RecordingDaemon()
        defer { git.open(); fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")
        var allowed = true
        let job = Task { try await fixture.controller.remover.removeAutomatically(task, starting: { true }, stillAllowed: { allowed }) }
        await eventually { git.started }
        allowed = false; git.open()
        await #expect(throws: ActionUnavailable.self) { try await job.value }
        #expect(fixture.controller.state.task(id: task.id) != nil)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(fixture.prompter.asked.isEmpty)
    }
}

private final class RemovalHeldGit: GitRunning {
    private let began = Mutex(false)
    private let gate = DispatchSemaphore(value: 0)
    private let inner = GitRunner.hermetic()
    var started: Bool { began.withLock { $0 } }
    func open() { gate.signal() }
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        let result = try inner.run(args, in: dir, timeout: timeout, environment: environment)
        if args.starts(with: ["worktree", "remove"]) { began.withLock { $0 = true }; gate.wait() }
        return result
    }
}

private final class PreflightHeldGit: GitRunning {
    private let armed = Mutex(false), began = Mutex(false)
    private let gate = DispatchSemaphore(value: 0), inner = GitRunner.hermetic()
    var started: Bool { began.withLock { $0 } }
    func arm() { armed.withLock { $0 = true } }
    func open() { gate.signal() }
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        let value = try inner.run(args, in: dir, timeout: timeout, environment: environment)
        if args.first == "status", armed.withLock({ value in let old = value; value = false; return old }) {
            began.withLock { $0 = true }; gate.wait()
        }
        return value
    }
}
