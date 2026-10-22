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
}
