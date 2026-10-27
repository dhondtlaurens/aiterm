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
    func makeWorld(_ state: OperatedState = .working, worker: SessionState = .working)
        throws -> (OperatorWorld, OperatorRun, TaskItem, worktree: String) {
        let repo = try GitFixture.makeRepo(prefix: "op-turn-")
        let worktree = try GitFixture.folder("op-turn-wt-") + "/wt"
        try git.run(["worktree", "add", "-q", "-b", "feat/pluto-1", worktree], in: repo)
        let project = OperatorServiceFixtures.project(path: repo)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: state, worktree: worktree)
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0))
        if state != .working {
            let head = try git.run(["rev-parse", "HEAD"], in: worktree)
            task.operated?.acceptance = TaskAcceptance(resultSHA: head, prerequisiteSHAs: [], checkOutput: "ok", note: nil,
                                                       at: Date(timeIntervalSince1970: 0))
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show(sessions(run, task, worker))
        return (world, run, task, worktree)
    }

    func sessions(_ run: OperatorRun, _ task: TaskItem, _ worker: SessionState) -> [SessionInfo] {
        [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
         OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: worker, conversation: "conv-1")]
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
            wakeLines(world).last == "[AiTerm] one worker asks something, call run_status"
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
            wakeLines(world).last == "[AiTerm] one task finished with no commit, call run_status"
        })
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
}
