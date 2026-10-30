import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A worker's ended turn is read once, on a task in any state (spec §E, §J): its last message from its conversation and
/// its worktree from git, so `run_status` says when it asks something, committed nothing, or moved on after acceptance,
/// and the Operator is woken saying which kind of news it is.
@MainActor @Suite(.blocking) struct WorkerTurnReaderTests {
    let git = GitRunner.hermetic()

    /// A project and task PLUTO-1 in `state`, in its own worktree on `feat/pluto-1` off `main`, its worker in conversation
    /// `conv-1` and at work.
    func makeWorld(_ state: OperatedState = .working, worker: SessionState = .working, agent: AgentKind = .claude,
                   launchedAt: Date = Date(timeIntervalSince1970: 0), conversation: String? = "conv-1", clock: TestClock? = nil)
        throws -> (OperatorWorld, OperatorRun, TaskItem, worktree: String) {
        let repo = try GitFixture.makeRepo(prefix: "op-turn-")
        let worktree = try GitFixture.folder("op-turn-wt-") + "/wt"
        try git.run(["worktree", "add", "-q", "-b", "feat/pluto-1", worktree], in: repo)
        let project = OperatorServiceFixtures.project(path: repo)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: state, agent: agent, worktree: worktree)
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: launchedAt, openedAt: launchedAt)
        if state != .working {
            let head = try git.run(["rev-parse", "HEAD"], in: worktree)
            task.operated?.acceptance = TaskAcceptance(resultSHA: head, prerequisiteSHAs: [], checkOutput: "ok", note: nil,
                                                       at: Date(timeIntervalSince1970: 0))
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            if let clock { ports.clock.now = { clock.now } }
        }
        world.show(sessions(run, task, worker, conversation: conversation))
        return (world, run, task, worktree)
    }

    func sessions(_ run: OperatorRun, _ task: TaskItem, _ worker: SessionState, conversation: String? = "conv-1") -> [SessionInfo] {
        [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
         OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: task.agent.session, state: worker, conversation: conversation)]
    }

    /// The worker's turn ends having said `reply`: its tab goes idle, and AiTerm reads the turn.
    func endTurn(saying reply: String, _ world: OperatorWorld, _ run: OperatorRun, _ task: TaskItem) async throws {
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": .string(reply)]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-1.jsonl"))
        world.show(sessions(run, task, .idle))
        await world.controller.turns.lastRead?.value
    }

    func status(_ world: OperatorWorld, _ run: OperatorRun) throws -> RunStatus.Obligations {
        let current = try #require(world.run(run.id))
        return try #require(world.controller.status(of: current)).obligations
    }

    /// The wake lines typed into the Operator's tab, in order: the worker's tab going to work is news of its own first.
    func wakeLines(_ world: OperatorWorld) -> [String] {
        world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.hasPrefix("[AiTerm]") }
    }

    /// The FE run's case: a worker that ends its turn asking is not ready, the Operator is told so, and message_task
    /// answering it clears the ask until the worker's next turn ends.
    @Test func aWorkerThatAsksIsListedUntilTheOperatorMessagesIt() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        #expect(try status(world, run).readyForAcceptance.isEmpty, "at work")
        try await endTurn(saying: "Tests pass.\n\nShould I also bump eslint?", world, run, task)
        var obligations = try status(world, run)
        #expect(obligations.workerAsks == [RunStatus.WorkerAsk(key: "PLUTO-1", question: "Should I also bump eslint?")])
        #expect(obligations.readyForAcceptance.isEmpty)
        #expect(world.controller.acting.turns[task.id] == .asks)
        #expect(await eventually(describing: "the Operator told") {
            wakeLines(world).last == "[AiTerm] PLUTO-one asks a question, call run_status"
        })

        _ = await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "No, leave eslint."])
        obligations = try status(world, run)
        #expect(obligations.workerAsks.isEmpty)
        #expect(obligations.readyForAcceptance.isEmpty, "its answer to the message is still to come")
        #expect(world.controller.acting.turns[task.id] == nil)

        world.show(sessions(run, task, .working))
        try await endTurn(saying: "Left eslint as it is. All tests pass.", world, run, task)
        obligations = try status(world, run)
        #expect(obligations.workerAsks.isEmpty && obligations.readyForAcceptance == ["PLUTO-1"])
    }

    /// A task taken over and handed back while its worker sits idle is read again on its handback: its turn ended with a
    /// commit, so it is ready, not held as a turn still to read.
    @Test func aTaskHandedBackWithItsWorkerIdleIsReadAgainAndReady() async throws {
        let (world, run, task, worktree) = try makeWorld(worker: .idle)
        await world.controller.turns.lastRead?.value
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        func takenOver(_ value: Bool) async {
            world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = value } }
            await world.controller.turns.lastRead?.value
        }
        await takenOver(true)
        #expect(world.controller.turns.readings[task.id] == nil, "a task you took over is not read")
        await takenOver(false)
        let obligations = try status(world, run)
        #expect(obligations.readyForAcceptance == ["PLUTO-1"])
        #expect(obligations.finishedWithoutCommit.isEmpty)
    }

    /// A turn that ends with nothing committed past the base branch is not ready, and wakes the Operator saying so.
    @Test func aTurnWithNoCommitIsFinishedWithoutCommit() async throws {
        let (world, run, task, _) = try makeWorld()
        try await endTurn(saying: "Nothing to update: the copy is already there.", world, run, task)
        let obligations = try status(world, run)
        #expect(obligations.finishedWithoutCommit == ["PLUTO-1"] && obligations.readyForAcceptance.isEmpty)
        #expect(world.controller.acting.turns[task.id] == .noCommit)
        #expect(await eventually(describing: "the Operator told") {
            wakeLines(world).last == "[AiTerm] PLUTO-one finished with no commit, call run_status"
        })
    }

    /// A Codex worker reads idle, with no conversation named, until its first hook half a minute after its launch (26 Oct
    /// 2026). Meanwhile it is still opening: at work, so neither ready nor finished without a commit, and `read_task` says
    /// it is still starting. Its launch over with still no conversation named, it opens no longer, and its turn is read.
    @Test func aCodexWorkerJustLaunchedIsOpeningUntilItsLaunchIsOver() async throws {
        let clock = TestClock.operators()
        let (world, run, task, _) = try makeWorld(worker: .idle, agent: .codex, launchedAt: clock.now, conversation: nil, clock: clock)
        clock.advance(by: 20)
        world.controller.reconcileTick()
        await world.controller.turns.lastRead?.value
        let current = try #require(world.run(run.id))
        var line = try #require(world.controller.status(of: current)?.tasks.first)
        #expect(line.opening == true)
        var obligations = try status(world, run)
        #expect(obligations.readyForAcceptance.isEmpty && obligations.finishedWithoutCommit.isEmpty)
        #expect(world.controller.acting.turns[task.id] == nil)
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value?["note"]
                == "Its worker is still starting: it hasn’t named a conversation yet. Read it again in a minute.")

        clock.advance(by: OperatorTiming.firstWorkerOpening)
        world.controller.reconcileTick()
        await world.controller.turns.lastRead?.value
        line = try #require(world.controller.status(of: current)?.tasks.first)
        #expect(line.opening == nil)
        obligations = try status(world, run)
        #expect(obligations.finishedWithoutCommit == ["PLUTO-1"])
    }

    /// Spec §C's own case: an accepted task is messaged to diagnose a failed push, which reopens it, and its worker answers
    /// without committing. Its HEAD is still the commit it was accepted on: ready to accept that commit again, never
    /// "finished with no commit". noChange is refused, since it would drop that commit; accepting it again works.
    @Test func aReopenedTaskWithNoNewCommitIsReadyToAcceptAgain() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        let accepted = try git.run(["rev-parse", "HEAD"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.reopenedFrom = accepted } }
        try await endTurn(saying: "The hook needs pnpm 9; nothing in the code to change.", world, run, task)
        let obligations = try status(world, run)
        #expect(obligations.readyForAcceptance == ["PLUTO-1"] && obligations.finishedWithoutCommit.isEmpty)
        #expect(world.controller.acting.turns[task.id] == nil, "its row says it is ready, not `no commit`")
        let current = try #require(world.run(run.id))
        let line = try #require(world.controller.status(of: current)?.tasks.first)
        #expect(line.reopenedFrom == accepted)

        let refused = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "noChange", "note": "Nothing to change."])
        #expect(refused.message == OperatedTransitionError.reopenedFromAcceptedCommit(accepted).description)
        #expect(refused.message?.contains("accept \(accepted.prefix(7)) again with mark_task accepted") == true)
        #expect(world.task(task.id)?.operated?.state == .working && world.task(task.id)?.operated?.reopenedFrom == accepted)

        let again = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(accepted),
                                                           "checkOutput": "12 passed"])
        #expect(again.value?["state"] == "accepted")
        #expect(world.task(task.id)?.operated?.acceptance?.resultSHA == accepted && world.task(task.id)?.operated?.reopenedFrom == nil)
    }

    /// A reopened task whose worker moved HEAD back past the accepted commit has nothing to accept again: still no commit.
    @Test func aReopenedTaskMovedBackIsStillFinishedWithoutCommit() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        let accepted = try git.run(["rev-parse", "HEAD"], in: worktree)
        try git.run(["reset", "-q", "--hard", "HEAD~1"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.reopenedFrom = accepted } }
        try await endTurn(saying: "Reverted.", world, run, task)
        let obligations = try status(world, run)
        #expect(obligations.finishedWithoutCommit == ["PLUTO-1"] && obligations.readyForAcceptance.isEmpty)
        #expect(world.controller.acting.turns[task.id] == .noCommit)
    }

    /// An accepted task whose worker someone worked in after its acceptance, a file changed or a commit on top, is listed;
    /// one whose worker ended a turn with its worktree as accepted is not.
    @Test func workAfterAcceptanceIsReadFromTheWorktree() async throws {
        let (world, run, task, worktree) = try makeWorld(.accepted)
        try await endTurn(saying: "Nothing changed.", world, run, task)
        #expect(try status(world, run).changedAfterAcceptance.isEmpty)

        world.show(sessions(run, task, .working))
        try Data("more\n".utf8).write(to: URL(fileURLWithPath: worktree).appendingPathComponent("notes.txt"))
        try await endTurn(saying: "I wrote the notes.", world, run, task)
        #expect(try status(world, run).changedAfterAcceptance == ["PLUTO-1"])

        world.show(sessions(run, task, .working))
        try git.run(["add", "notes.txt"], in: worktree)
        try git.run(["commit", "-q", "-m", "notes"], in: worktree)
        try await endTurn(saying: "Committed the notes.", world, run, task)
        #expect(try status(world, run).changedAfterAcceptance == ["PLUTO-1"], "HEAD is past the accepted commit")
    }

    /// The broadcast's case: a task listed as changed after acceptance, which the Operator then accepted again on its new
    /// head while its worker sat idle. No turn ends, but the reading was of the old acceptance: it is dropped at once and
    /// read again, and the task is listed no more.
    @Test func acceptingAgainWithTheWorkerIdleClearsChangedAfterAcceptance() async throws {
        let (world, run, task, worktree) = try makeWorld(.accepted)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        try await endTurn(saying: "Committed the fix.", world, run, task)
        #expect(try status(world, run).changedAfterAcceptance == ["PLUTO-1"])

        let head = try git.run(["rev-parse", "HEAD"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.acceptance?.resultSHA = head } }
        #expect(try status(world, run).changedAfterAcceptance.isEmpty, "not served while it is read again")
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).changedAfterAcceptance.isEmpty)
        #expect(world.controller.turns.readings[task.id]?.changedAfterAcceptance == false, "read again")
    }

    /// Reopened with its worker idle, a task's turn is read again as a working one's: its worktree moved back past the
    /// accepted commit, so it finished with no commit, and no longer counts as changed after an acceptance it has not got.
    @Test func reopeningWithTheWorkerIdleReadsTheTurnAgain() async throws {
        let (world, run, task, worktree) = try makeWorld(.accepted)
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        let accepted = try git.run(["rev-parse", "HEAD"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.acceptance?.resultSHA = accepted } }
        try git.run(["reset", "-q", "--hard", "HEAD~1"], in: worktree)
        try await endTurn(saying: "Reverted.", world, run, task)
        #expect(try status(world, run).changedAfterAcceptance == ["PLUTO-1"])

        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.state = .working; $0.reopenedFrom = accepted; $0.acceptance = nil
        } }
        await world.controller.turns.lastRead?.value
        let obligations = try status(world, run)
        #expect(obligations.finishedWithoutCommit == ["PLUTO-1"] && obligations.readyForAcceptance.isEmpty)
        #expect(obligations.changedAfterAcceptance.isEmpty)
    }

    /// A read still under way when the task is accepted again lands for the acceptance it was asked for: it is dropped,
    /// and the read asked for the new one is what counts.
    @Test func aReadOutdatedWhileUnderWayIsDropped() async throws {
        let (world, run, task, worktree) = try makeWorld(.accepted)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        let head = try git.run(["rev-parse", "HEAD"], in: worktree)
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Committed the fix."]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-1.jsonl"))
        world.show(sessions(run, task, .idle))
        let first = world.controller.turns.lastRead
        world.workspace.mutate { $0.updateOperated(task.id) { $0.acceptance?.resultSHA = head } }
        await first?.value
        await world.controller.turns.lastRead?.value
        #expect(world.controller.turns.readings[task.id]?.changedAfterAcceptance == false)
        #expect(try status(world, run).changedAfterAcceptance.isEmpty)
    }
    @Test func aNewConversationInTheSameIdleSessionReplacesThePreviousTurn() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        try await endTurn(saying: "All done.", world, run, task)
        #expect(try status(world, run).readyForAcceptance == ["PLUTO-1"])
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Should I include archived orders?"]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-2.jsonl"))
        world.show(sessions(run, task, .idle, conversation: "conv-2"))
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).workerAsks == [RunStatus.WorkerAsk(key: "PLUTO-1", question: "Should I include archived orders?")])
        #expect(try status(world, run).readyForAcceptance.isEmpty)
    }

    @Test func anExtraWorkerQuestionIsReadWhileTheMainWorkerIsBusy() async throws {
        let (world, run, task, _) = try makeWorld()
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.extraTabs = [ExtraTab(key: "review", agent: .claude, model: "m", reasoning: nil, modelReason: "Review", brief: "Review",
                                   launch: LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0)),
                                   sessionId: "review", conversation: "conv-review")]
        } }
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Should I review the migration too?"]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-review.jsonl"))
        var tabs = sessions(run, task, .working)
        var review = OperatorServiceFixtures.session("review", window: "w9", tag: task.id, agent: .claude, state: .idle, conversation: "conv-review")
        review.tabKey = "review"
        tabs.append(review)
        world.show(tabs)
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).workerAsks == [RunStatus.WorkerAsk(key: "PLUTO-1", question: "Should I review the migration too?", tab: "review")])
        #expect(world.controller.acting.turns[task.id] == .asks)
    }

    @Test func aReplacementWorkerCanFinishAfterTheOriginalTabCloses() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "replacement work"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.extraTabs = [ExtraTab(key: "replacement", agent: .claude, model: "m", reasoning: nil, modelReason: "Continue", brief: "Continue",
                                   launch: LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0)),
                                   sessionId: "replacement", conversation: "conv-replacement")]
        } }
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Rebase and build passed."]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-replacement.jsonl"))
        var replacement = OperatorServiceFixtures.session("replacement", window: "w9", tag: task.id, agent: .claude, state: .working, conversation: "conv-replacement")
        replacement.tabKey = "replacement"
        let op = OperatorServiceFixtures.session("op", window: "wo", tag: run.id)
        world.show([op, replacement])
        #expect(world.task(task.id)?.operated?.flags.contains(.uncertain) == false)
        replacement.state = .idle
        world.show([op, replacement])
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).readyForAcceptance == ["PLUTO-1"])
        #expect(try status(world, run).finishedWithoutCommit.isEmpty)
        let line = try #require(world.controller.status(of: run)?.tasks.first)
        #expect(line.tabs?.first?.closed == true)
    }

    @Test func anObservedReplacementHarnessReadsItsOwnTranscript() async throws {
        let (world, run, task, worktree) = try makeWorld(agent: .codex)
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Should I update the fixtures too?"]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-claude.jsonl"))
        let replacement = OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: .claude, state: .idle, conversation: "conv-claude")
        world.show([OperatorServiceFixtures.session("op", window: "wo", tag: run.id), replacement])
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).workerAsks == [RunStatus.WorkerAsk(key: "PLUTO-1", question: "Should I update the fixtures too?")])
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value?["lastMessage"] == "Should I update the fixtures too?")
    }

    @Test func aFollowupCompletionIsReadWhenItsWorkingHookWasMissed() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        try await endTurn(saying: "All done.", world, run, task)
        _ = await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "Check archived orders too."])
        #expect(try status(world, run).readyForAcceptance.isEmpty)
        // The next Stop snapshot is also idle: no working snapshot reached the app.
        try await endTurn(saying: "Should archived orders include cancelled ones?", world, run, task)
        world.controller.reconcileTick()
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).workerAsks == [RunStatus.WorkerAsk(key: "PLUTO-1", question: "Should archived orders include cancelled ones?")])
    }

    @Test func aWorkingWorkerWithoutAConversationReportsMissingIdentity() async throws {
        let (world, run, _, _) = try makeWorld(worker: .working, conversation: nil)
        let answer = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value)
        #expect(answer["availability"] == "identityUnavailable")
        #expect(answer["task"] == "PLUTO-1" && answer["tab"] == "main" && answer["sessionId"] == "w1")
        #expect(answer["note"]?.stringValue?.contains("hasn’t started") == false)
    }

    @Test func anExtraWorkersFreshCommitSupersedesTheIdleMainWorkersOldCount() async throws {
        let (world, run, task, worktree) = try makeWorld(worker: .idle)
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).finishedWithoutCommit == ["PLUTO-1"])
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.extraTabs = [ExtraTab(key: "fix", agent: .claude, model: "m", reasoning: nil, modelReason: "Fix", brief: "Fix",
                                   launch: LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0)),
                                   sessionId: "fix", conversation: "conv-fix")]
        } }
        var fix = OperatorServiceFixtures.session("fix", window: "w9", tag: task.id, agent: .claude, state: .working, conversation: "conv-fix")
        fix.tabKey = "fix"
        world.show(sessions(run, task, .idle) + [fix])
        try git.run(["commit", "--allow-empty", "-q", "-m", "fixed"], in: worktree)
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": "Committed the fix."]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent("conv-fix.jsonl"))
        fix.state = .idle
        world.show(sessions(run, task, .idle) + [fix])
        await world.controller.turns.lastRead?.value
        #expect(try status(world, run).readyForAcceptance == ["PLUTO-1"])
        #expect(try status(world, run).finishedWithoutCommit.isEmpty)
    }

}

extension WorkerTurnReaderTests {
    @Test func earlierLocalMainCommitsDoNotMakeAnEmptyTaskReadyWhenOriginLags() async throws {
        let (world, run, task, worktree) = try makeWorld()
        let project = try #require(world.state.project(id: task.projectId))
        let origin = try GitFixture.folder("op-count-origin-")
        try git.run(["init", "--bare", "-q", "--initial-branch=main", origin], in: "/")
        try git.run(["remote", "add", "origin", origin], in: project.path)
        try git.run(["push", "-q", "origin", "main"], in: project.path)
        try "earlier task\n".write(toFile: project.path + "/earlier.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "earlier.swift"], in: project.path)
        try git.run(["commit", "-q", "-m", "earlier task"], in: project.path)
        try git.run(["rebase", "main"], in: worktree)
        let baseline = try git.run(["rev-parse", "HEAD"], in: worktree)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.diffBaseSHA = baseline } }
        try await endTurn(saying: "Nothing to change; no files or commits changed.", world, run, task)
        #expect(world.controller.turns.readings[task.id]?.commitsAhead == 0)
        let obligations = try status(world, run)
        #expect(obligations.finishedWithoutCommit == ["PLUTO-1"])
        #expect(obligations.readyForAcceptance.isEmpty)
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(diff["commits"] == "" && diff["files"] == .array([]))
    }
}
