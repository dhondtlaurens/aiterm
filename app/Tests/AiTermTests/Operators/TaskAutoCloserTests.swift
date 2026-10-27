import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite struct TaskAutoCloserTests {
    private func prepare(_ fixture: RaceFixture) throws -> (OperatorRun, TaskItem) {
        fixture.controller.operatorController.onRunChanged = { _ in }
        var run = OperatorServiceFixtures.run(projects: [fixture.project], state: .complete,
                                              taskSettings: TaskSettings(review: nil, end: .commit))
        run.completedAt = Date(timeIntervalSince1970: 10)
        run.summaryGivenUp = true
        var task = try fixture.addTask(windowId: "alive")
        let sha = try fixture.git.run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        task.operated = OperatedTask(runId: run.id, key: "A", state: .accepted, end: .commit, brief: "Work", revision: 1,
                                     acceptance: TaskAcceptance(resultSHA: sha, prerequisiteSHAs: [], checkOutput: "", note: nil, at: Date()))
        fixture.controller.workspace.mutate { $0.runs = [run]; $0.tasks = [task] }
        return (run, task)
    }

    private func closer(_ fixture: RaceFixture) -> TaskAutoCloser {
        let app = fixture.controller
        return TaskAutoCloser(workspace: app.workspace, live: app.live, tools: app.operatorController.tools,
                              remove: { try await app.remover.removeAutomatically($0, deleteMergedBranch: $1, git: fixture.git) })
    }

    @Test(arguments: [false, true]) func appWiringClosesOnCompletionAndEnd(ending: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        app.watchBoardRequests()
        if ending {
            app.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .active; $0.summaryGivenUp = false } }
            #expect(await app.endNow(run))
        } else {
            app.workspace.mutate { $0.updateRun(id: run.id) { $0.summaryGivenUp = false; $0.summary = "Done." } }
            app.operatorController.runChanged(run.id)
        }
        await eventually { app.state.task(id: task.id) == nil && app.state.run(id: run.id)?.closedAt != nil }
        #expect(app.state.run(id: run.id)?.finished.first?.task == task.id)
    }

    @Test func givingUpOnSummaryOutsideRunChangedStillCloses() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.workspace.mutate { $0.updateRun(id: run.id) { $0.summaryGivenUp = false } }
        app.helper.setDaemonClient(RecordingDaemon())
        app.watchBoardRequests()
        app.workspace.mutate { $0.updateRun(id: run.id) { $0.summaryGivenUp = true } }
        await eventually { app.state.task(id: task.id) == nil && app.state.run(id: run.id)?.closedAt != nil }
    }

    @Test func recordsBeforeRemovalAndRemovesWithoutShelvingOrQuestions() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        let closer = TaskAutoCloser(workspace: app.workspace, live: app.live, tools: app.operatorController.tools) { task, delete in
            let record = try #require(try app.savedWorkspace().run(id: run.id)?.finished.first)
            #expect(record.task == task.id)
            #expect(record.diffBaseSHA == task.operated?.acceptance?.resultSHA)
            return try await app.remover.removeAutomatically(task, deleteMergedBranch: delete, git: fixture.git)
        }
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.archive.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(server.requests("window.close").count == 1)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(app.state.run(id: run.id)?.closedAt != nil)
        #expect(try !fixture.git.run(["branch", "--list", task.branch], in: fixture.repo.path).isEmpty)
    }

    @Test(arguments: [false, true]) func dirtyAndUntrackedWorktreesAreUntouched(tracked: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let (run, task) = try prepare(fixture)
        try "work".write(toFile: task.worktreePath + "/file", atomically: true, encoding: .utf8)
        if tracked { try fixture.git.run(["add", "file"], in: task.worktreePath) }
        await closer(fixture).close(run.id)
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "alive")
        #expect(server.requests("window.close").isEmpty)
        #expect(fixture.prompter.asked.isEmpty)
        #expect(fixture.controller.state.run(id: run.id)?.finished.first?.result == TaskAutoCloser.unsavedWork)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/file"))
    }

    @Test func aWindowThatCannotBeClosedLeavesTheWorktreeAndRecord() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        // No daemon: there is no confirmation that its window closed.
        await closer(fixture).close(run.id)
        #expect(fixture.controller.state.task(id: task.id)?.windowId == "alive")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(fixture.controller.state.run(id: run.id)?.finished.first?.result.hasPrefix("Not closed:") == true)
        #expect(fixture.prompter.asked.isEmpty)
    }

    @Test func aDrivingTabWaitsAndAFailedRemovalKeepsItsReason() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        var session = OperatorServiceFixtures.session("s", window: "alive", tag: task.id, agent: .codex)
        session.yourPrompt = "My turn"
        app.live.sessions = [session]
        var attempts = 0
        let closer = TaskAutoCloser(workspace: app.workspace, live: app.live, tools: app.operatorController.tools) { _, _ in
            attempts += 1
            throw ActionUnavailable("The window stayed open.")
        }
        await closer.close(run.id)
        #expect(attempts == 0)
        session.yourPrompt = nil
        app.live.sessions = [session]
        await closer.close(run.id)
        #expect(attempts == 1)
        #expect(app.state.task(id: task.id) != nil)
        #expect(app.state.run(id: run.id)?.finished.first?.result.contains("window stayed open") == true)
    }

    @Test func aTurnStartedDuringTheWorktreeCheckDefersUntilItEnds() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        let closer = closer(fixture)
        // Hold the workflow queue so the person's turn starts after the closer's first check,
        // while Remove is waiting for its own worktree check.
        let gate = DispatchSemaphore(value: 0)
        TaskWorkflow.queue.async { gate.wait() }
        defer { gate.signal() }
        let closing = Task { await closer.close(run.id) }
        await eventually { app.remover.isRemoving(task.id) }
        var session = OperatorServiceFixtures.session("s", window: "alive", tag: task.id, agent: .codex)
        session.yourPrompt = "My turn"
        app.live.sessions = [session]
        gate.signal()
        await closing.value
        #expect(app.state.task(id: task.id) != nil)
        session.yourPrompt = nil
        app.live.sessions = [session]
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) == nil)
    }

    @Test func aWaitingTaskResumesAfterTheCloserIsRecreated() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        var session = OperatorServiceFixtures.session("s", window: "alive", tag: task.id, agent: .codex)
        session.yourPrompt = "My turn"
        app.live.sessions = [session]
        await closer(fixture).close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        session.yourPrompt = nil
        app.live.sessions = [session]
        await closer(fixture).close(run.id)
        #expect(app.state.task(id: task.id) == nil)
    }

    @Test func onlyTasksThatReachedTheirEndClose() {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project])
        for state: OperatedState in [.planned, .queued, .working, .failed, .stopped, .accepted, .published, .noChange] {
            for end: TaskEnd in [.commit, .draftMR, .merge, .mergeLocal] {
                var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: state, end: end)
                #expect(TaskAutoCloser.eligible(task) == (state == .published || state == .noChange || (state == .accepted && end == .commit)))
                task.operated?.publication = TaskPublication(leftForYou: true)
                #expect(!TaskAutoCloser.eligible(task))
            }
        }
    }

    @Test func mergedBranchDeletionIsRecordedOnlyWhenEnabled() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.taskSettings?.deleteMergedBranch = true }
            state.updateOperated(task.id) { $0.end = .mergeLocal; $0.state = .published }
        }
        await closer(fixture).close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.run(id: run.id)?.finished.first?.branchDeleted == true)
        #expect(try fixture.git.run(["branch", "--list", task.branch], in: fixture.repo.path).isEmpty)
    }

    @Test func endBroadcastRetriesAnEarlierFailure() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        let closer = closer(fixture)
        // A known window without the helper cannot be confirmed closed.
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        app.helper.setDaemonClient(RecordingDaemon())
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.state = .stopped; $0.endedAt = Date() }
        }
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.run(id: run.id)?.finished.count == 1)
    }

    @Test func stackedChildKeepsItsParentsAcceptedCommitBeforeEitherRowGoes() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, parent) = try prepare(fixture)
        let path = fixture.repo.path + "/.worktrees/child"
        try fixture.git.run(["worktree", "add", "-b", "child", path, parent.branch], in: fixture.repo.path)
        var child = OperatorServiceFixtures.task(in: run, project: fixture.project, key: "child", state: .accepted,
                                                 worktree: path, branch: "child", end: .commit)
        child.baseBranch = "main"
        child.operated?.dependsOn = [TaskDependency(task: parent.id, kind: .code)]
        child.operated?.stackedOn = parent.id
        child.operated?.acceptance = parent.operated?.acceptance
        fixture.controller.workspace.mutate { $0.tasks.append(child) }
        fixture.controller.helper.setDaemonClient(RecordingDaemon())
        await closer(fixture).close(run.id)
        let records = try #require(fixture.controller.state.run(id: run.id)?.finished)
        #expect(records.count == 2)
        #expect(records.first { $0.task == child.id }?.diffBaseSHA == parent.operated?.acceptance?.resultSHA)
        #expect(fixture.controller.state.tasks.isEmpty)
    }

    @Test(arguments: ["legacy", "disabled", "summary", "active"])
    func runsThatMustNotCloseAreUnchanged(_ mode: String) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, _) = try prepare(fixture)
        fixture.controller.workspace.mutate { state in
            state.updateRun(id: run.id) {
                switch mode {
                case "legacy": $0.taskSettings = nil
                case "disabled": $0.taskSettings?.closeWhenDone = false
                case "summary": $0.summaryGivenUp = false
                default: $0.state = .active
                }
            }
        }
        let before = fixture.controller.state
        await closer(fixture).close(run.id)
        #expect(fixture.controller.state == before)
    }
}
