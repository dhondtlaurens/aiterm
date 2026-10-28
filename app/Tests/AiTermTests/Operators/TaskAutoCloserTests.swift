import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite struct TaskAutoCloserTests {
    private func prepare(_ fixture: RaceFixture) throws -> (OperatorRun, TaskItem) {
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

    // The app's own closer does nothing until the helper's first connected snapshot, which only the wiring
    // tests deliver: every other test drives a closer of its own, alone.
    private func closer(_ fixture: RaceFixture, git: (any GitRunning)? = nil,
                        remove: (@MainActor (TaskItem, @MainActor () -> Bool) async throws -> Void)? = nil) -> TaskAutoCloser {
        let app = fixture.controller
        return TaskAutoCloser(workspace: app.workspace, live: app.live, git: git ?? fixture.git, now: { Date() },
                              remove: remove ?? { try await app.remover.removeAutomatically($0, starting: $1) })
    }

    private func note(_ task: TaskItem, in fixture: RaceFixture) -> String? {
        guard case .stopped(let note, _)? = fixture.controller.remover.removals[task.id] else { return nil }
        return note
    }

    @Test(arguments: [false, true]) func appWiringClosesOnCompletionAndEnd(ending: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        if ending {
            app.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .active; $0.summaryGivenUp = false } }
            #expect(await app.endNow(run))
        } else {
            app.workspace.mutate { $0.updateRun(id: run.id) { $0.summaryGivenUp = false; $0.summary = "Done." } }
            app.operatorController.runChanged(run.id)
        }
        app.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        await eventually { app.state.task(id: task.id) == nil && app.state.run(id: run.id)?.closedAt != nil }
        #expect(app.state.run(id: run.id)?.finished.first?.task == task.id)
    }

    @Test(arguments: [false, true]) func startupWaitsForSessionsThenResumesInterruptedClosing(ended: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        // What a quit mid-removal leaves: the record written, the row still there, the pass not closed.
        let interrupted = try #require(TaskAutoCloser.record(task, in: run, at: Date()))
        app.workspace.mutate { $0.updateRun(id: run.id) { $0.finished = [interrupted] } }
        if ended { app.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .stopped; $0.endedAt = Date() } } }
        app.helper.setDaemonClient(RecordingDaemon())
        app.operatorController.onRunChanged(run.id)
        for _ in 0..<10 { await Task.yield() }
        #expect(app.state.task(id: task.id) != nil)
        #expect(app.state.run(id: run.id)?.finished.map(\.task) == [task.id])
        var session = OperatorServiceFixtures.session("s", window: "alive", tag: task.id, agent: .codex)
        session.yourPrompt = "My turn"
        app.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session], usage: .empty)))
        await eventually { note(task, in: fixture) == TaskAutoCloser.waitingForTurn }
        await eventually { (try? app.savedWorkspace().run(id: run.id)?.finished.isEmpty) == true }
        #expect(app.state.task(id: task.id) != nil)
        session.yourPrompt = nil
        app.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [session], usage: .empty)))
        await eventually { app.state.task(id: task.id) == nil }
        #expect(app.state.run(id: run.id)?.finished.map(\.task) == [task.id])
    }

    @Test func reconnectResumesAHelperDeferredRemoval() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller, closer = closer(fixture)
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(note(task, in: fixture) == TaskAutoCloser.waitingForHelper)
        #expect(try app.savedWorkspace().run(id: run.id)?.finished.isEmpty == true)
        #expect(app.state.run(id: run.id)?.closedAt == nil)
        app.helper.setDaemonClient(RecordingDaemon())
        closer.sweep()
        await eventually { app.state.task(id: task.id) == nil }
        #expect(app.state.run(id: run.id)?.finished.map(\.task) == [task.id])
    }

    @Test func recordsBeforeRemovalAndRemovesWithoutShelvingOrQuestions() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        let closer = closer(fixture) { task, starting in
            try await app.remover.removeAutomatically(task) {
                #expect(try! app.savedWorkspace().run(id: run.id)?.finished.isEmpty == true)
                #expect(server.requests("window.close").isEmpty)
                let saved = starting()
                let record = try! app.savedWorkspace().run(id: run.id)?.finished.first
                #expect(record?.task == task.id)
                #expect(record?.acceptedSHA == task.operated?.acceptance?.resultSHA)
                return saved
            }
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
        #expect(fixture.controller.state.run(id: run.id)?.finished.isEmpty == true)
        #expect(note(task, in: fixture) == TaskAutoCloser.unsavedWork)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/file"))
    }

    @Test func changesMadeWhileClosingAreRefusedByGitAndKeptAsUnsavedWork() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let server = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(server)
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        // The file lands after the unsaved-work check, so only git's own refusal can keep it.
        await closer(fixture) { task, starting in
            try await app.remover.removeAutomatically(task) {
                try! "late".write(toFile: task.worktreePath + "/late", atomically: true, encoding: .utf8)
                return starting()
            }
        }.close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        #expect(FileManager.default.fileExists(atPath: task.worktreePath + "/late"))
        #expect(note(task, in: fixture) == TaskAutoCloser.unsavedWork)
        #expect(try app.savedWorkspace().run(id: run.id)?.finished.isEmpty == true)
    }

    @Test func workspaceEditsAloneDoNotStartClosing() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, _) = try prepare(fixture)
        let app = fixture.controller
        var attempts = 0
        let closer = closer(fixture) { _, _ in
            attempts += 1
            throw ActionUnavailable("Kept for this test")
        }
        app.workspace.mutate { $0.updateRun(id: run.id) { $0.summary = "Done" } }
        for _ in 0..<10 { await Task.yield() }
        #expect(attempts == 0)
        closer.changed(run.id)
        await eventually { attempts == 1 }
    }

    @Test func aDrivingTabWaitsWithItsReasonOnTheRowAndNoRecord() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        let server = RecordingDaemon()
        app.helper.setDaemonClient(server)
        var session = OperatorServiceFixtures.session("s", window: "alive", tag: task.id, agent: .codex)
        session.yourPrompt = "My turn"
        app.live.sessions = [session]
        let closer = closer(fixture)
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        #expect(server.requests("window.close").isEmpty)
        #expect(note(task, in: fixture) == TaskAutoCloser.waitingForTurn)
        #expect(app.state.run(id: run.id)?.finished.isEmpty == true)
        #expect(app.state.run(id: run.id)?.closedAt == nil)
        session.yourPrompt = nil
        app.live.sessions = [session]
        await eventually { app.state.task(id: task.id) == nil }
        #expect(app.state.run(id: run.id)?.finished.map(\.task) == [task.id])
    }

    @Test func aFailedRemovalTakesBackItsRecordAndLeavesTheRow() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        var attempts = 0
        let closer = closer(fixture) { _, starting in
            attempts += 1
            #expect(starting())
            throw ActionUnavailable("The window stayed open.")
        }
        await closer.close(run.id)
        await closer.close(run.id)
        #expect(attempts == 1)
        #expect(app.state.task(id: task.id) != nil)
        #expect(app.state.run(id: run.id)?.finished.isEmpty == true)
        #expect(try app.savedWorkspace().run(id: run.id)?.finished.isEmpty == true)
        #expect(app.state.run(id: run.id)?.closedAt != nil)
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

    @Test(arguments: [false, true]) func mergedBranchDeletionIsRecordedOnlyWhenEnabled(enabled: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        try "merged work".write(toFile: task.worktreePath + "/work", atomically: true, encoding: .utf8)
        try fixture.git.run(["add", "work"], in: task.worktreePath)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "work"], in: task.worktreePath)
        let sha = try fixture.git.run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        try fixture.git.run(["merge", "--ff-only", task.branch], in: fixture.repo.path)
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.taskSettings?.deleteMergedBranch = enabled }
            state.updateOperated(task.id) { $0.end = .mergeLocal; $0.state = .published; $0.acceptance?.resultSHA = sha }
        }
        await closer(fixture).close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.run(id: run.id)?.finished.first?.branchDeleted == enabled)
        #expect(try fixture.git.run(["branch", "--list", task.branch], in: fixture.repo.path).isEmpty == enabled)
    }

    @Test(arguments: [false, true]) func aMergedTaskKeepsItsLiveDiffAcrossACloserRestart(closeWhenDone: Bool) async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, original) = try prepare(fixture)
        let app = fixture.controller
        let base = try fixture.git.run(["rev-parse", "HEAD"], in: original.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        for file in ["first", "second"] {
            try file.write(toFile: original.worktreePath + "/" + file, atomically: true, encoding: .utf8)
            try fixture.git.run(["add", file], in: original.worktreePath)
            try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", file], in: original.worktreePath)
        }
        let sha = try fixture.git.run(["rev-parse", "HEAD"], in: original.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.state = .active; $0.summaryGivenUp = false; $0.taskSettings?.closeWhenDone = closeWhenDone }
            state.updateOperated(original.id) { $0.state = .working; $0.end = .mergeLocal; $0.acceptance = nil }
        }
        let tools = app.operatorController.tools
        _ = try await tools.markTask(ToolCall(tool: "mark_task", arguments: ["task": "A", "outcome": "accepted", "sha": .string(sha), "checkOutput": "passed"]), in: try #require(app.state.run(id: run.id)))
        #expect(app.state.run(id: run.id)?.finished.isEmpty == true)
        #expect(try app.savedWorkspace().task(id: original.id)?.operated?.diffBaseSHA == base)
        app.workspace.mutate { $0.updateRun(id: run.id) { $0.taskSettings?.closeWhenDone = true } }
        try fixture.git.run(["merge", "--ff-only", original.branch], in: fixture.repo.path)
        app.workspace.mutate { state in
            state.updateOperated(original.id) { $0.state = .published }
            state.updateRun(id: run.id) { $0.state = .complete; $0.summaryGivenUp = true }
        }
        app.helper.setDaemonClient(RecordingDaemon())
        await closer(fixture).close(run.id)
        let closed = try #require(app.state.run(id: run.id))
        let answer = try await tools.readTask(ToolCall(tool: "read_task", arguments: ["task": "A", "what": "diff"]), in: closed)
        let text = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
        #expect(text.contains("first"))
        #expect(text.contains("second"))
        #expect(closed.finished.first?.diffBaseSHA == base)
    }

    @Test func aBranchDeletionFailureDoesNotUndoRemoval() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.taskSettings?.deleteMergedBranch = true }
            state.updateOperated(task.id) { $0.end = .mergeLocal; $0.state = .published }
        }
        // A locked local ref prevents update-ref after the merge checks succeed.
        try "held".write(toFile: fixture.repo.path + "/.git/refs/heads/" + task.branch + ".lock", atomically: true, encoding: .utf8)
        let git = RemovalSavedGit(store: StateStore(url: fixture.root.appendingPathComponent("state.json")), task: task.id, run: run.id)
        await closer(fixture, git: git).close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: task.worktreePath))
        let record = try #require(app.state.run(id: run.id)?.finished.first)
        #expect(!record.branchDeleted)
        #expect(try app.savedWorkspace().run(id: run.id)?.finished.first?.branchDeleted == false)
        #expect(!record.result.hasPrefix("Not closed:"))
        #expect(try !fixture.git.run(["branch", "--list", task.branch], in: fixture.repo.path).isEmpty)
    }

    @Test func aMergeOnlyOnOriginIsFetchedThroughTheCloser() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller, git = fixture.git
        let remote = fixture.root.appendingPathComponent("remote.git").path
        try git.run(["clone", "--bare", fixture.repo.path, remote], in: fixture.root.path)
        try git.run(["remote", "add", "origin", remote], in: fixture.repo.path)
        try git.run(["fetch", "origin"], in: fixture.repo.path)
        let base = try git.run(["rev-parse", "origin/main"], in: fixture.repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "work"], in: task.worktreePath)
        let sha = try git.run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["push", remote, sha + ":refs/heads/main", sha + ":refs/heads/" + task.branch], in: task.worktreePath)
        #expect(try git.run(["rev-parse", "origin/main"], in: fixture.repo.path) == base)
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.taskSettings?.deleteMergedBranch = true }
            state.updateOperated(task.id) { $0.end = .merge; $0.state = .published; $0.acceptance?.resultSHA = sha }
        }
        app.helper.setDaemonClient(RecordingDaemon())
        await closer(fixture).close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.run(id: run.id)?.finished.first?.branchDeleted == true)
        #expect(try git.run(["rev-parse", "refs/heads/" + task.branch], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
    }

    @Test func endBroadcastRetriesAnEarlierFailure() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, task) = try prepare(fixture)
        let app = fixture.controller
        app.helper.setDaemonClient(RecordingDaemon())
        let closer = closer(fixture)
        try "work".write(toFile: task.worktreePath + "/file", atomically: true, encoding: .utf8)
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) != nil)
        try FileManager.default.removeItem(atPath: task.worktreePath + "/file")
        app.workspace.mutate { state in
            state.updateRun(id: run.id) { $0.state = .stopped; $0.endedAt = Date() }
        }
        await closer.close(run.id)
        #expect(app.state.task(id: task.id) == nil)
        #expect(app.state.run(id: run.id)?.finished.count == 1)
    }

    @Test func aStackedTasksDiffBaseIsItsParentsAcceptedCommit() async throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let (run, parent) = try prepare(fixture)
        let app = fixture.controller, parentSHA = try #require(parent.operated?.acceptance?.resultSHA)
        let path = fixture.repo.path + "/.worktrees/child"
        try fixture.git.run(["worktree", "add", "-b", "child", path, parent.branch], in: fixture.repo.path)
        try fixture.git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "child"], in: path)
        let sha = try fixture.git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        var child = OperatorServiceFixtures.task(in: run, project: fixture.project, key: "child", state: .working,
                                                 worktree: path, branch: "child", end: .commit)
        child.baseBranch = "main"
        child.operated?.dependsOn = [TaskDependency(task: parent.id, kind: .code)]
        child.operated?.stackedOn = parent.id
        app.workspace.mutate { state in
            state.tasks.append(child)
            state.updateRun(id: run.id) { $0.state = .active; $0.summaryGivenUp = false }
        }
        _ = try await app.operatorController.tools.markTask(
            ToolCall(tool: "mark_task", arguments: ["task": "child", "outcome": "accepted", "sha": .string(sha), "checkOutput": "passed"]),
            in: try #require(app.state.run(id: run.id)))
        #expect(app.state.task(id: child.id)?.operated?.diffBaseSHA == parentSHA)
        #expect(app.state.run(id: run.id)?.finished.isEmpty == true)
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
        child.operated?.diffBaseSHA = parent.operated?.acceptance?.resultSHA
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

/// The final branch operation must see the row's removal, and the record already saying the branch went, on disk.
private struct RemovalSavedGit: GitRunning {
    let store: StateStore
    let task: UUID, run: UUID
    let inner = GitRunner.hermetic()
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.first == "update-ref" {
            let state = try store.load()
            #expect(state.task(id: task) == nil)
            #expect(state.run(id: run)?.finished.first?.task == task)
            #expect(state.run(id: run)?.finished.first?.branchDeleted == true)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
