import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A worker that commits off its task branch is flagged in `run_status` on the next reconcile tick, and its
/// Operator told, instead of the task sitting with an empty branch until its runtime runs out.
@MainActor @Suite(.blocking) struct BranchWatchTests {
    let git = GitRunner.hermetic()

    /// A project and a task working in its own worktree on `feat/pluto-1`, its worker's tab in `state`.
    func makeWorld(worker state: SessionState = .working, conversation: String? = nil)
        throws -> (OperatorWorld, OperatorRun, TaskItem, worktree: String) {
        let repo = try GitFixture.makeRepo(prefix: "op-drift-")
        let worktree = try GitFixture.folder("op-drift-wt-") + "/wt"
        try git.run(["worktree", "add", "-q", "-b", "feat/pluto-1", worktree], in: repo)
        let project = OperatorServiceFixtures.project(path: repo)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: worktree)
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0))
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: state, conversation: conversation)])
        return (world, run, task, worktree)
    }

    func tick(_ world: OperatorWorld) async {
        world.controller.reconcileTick()
        await world.controller.branchWatch.lastPoll?.value
    }

    func driftLines(_ world: OperatorWorld) -> [String] {
        world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.contains("off its task branch") }
    }

    @Test func aWorkerOnItsTaskBranchIsNotFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld()
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }

    @Test func aWorktreeSwitchedToAnotherBranchIsFlaggedAndItsOperatorToldOnceUntilItIsBack() async throws {
        let (world, run, task, worktree) = try makeWorld()
        try git.run(["checkout", "-q", "-b", "fix/mine"], in: worktree)
        try git.run(["commit", "--allow-empty", "-q", "-m", "work"], in: worktree)
        let sha = try git.run(["rev-parse", "HEAD"], in: worktree)
        await tick(world)
        let drift = try #require(world.task(task.id)?.operated?.branchDrift)
        #expect(drift == BranchDrift(source: .head, branch: "fix/mine", sha: sha,
                                     found: "Its worktree is on branch fix/mine, not on its task branch feat/pluto-1."))
        let current = try #require(world.run(run.id))
        let status = try #require(world.controller.status(of: current))
        #expect(status.obligations.branchDrift == ["PLUTO-1"])
        #expect(await eventually(describing: "the operator told") {
            driftLines(world) == ["[AiTerm] PLUTO-1 committed off its task branch, call run_status"]
        })
        await tick(world)
        await world.controller.waker.lastSend?.value
        #expect(driftLines(world).count == 1, "told once")

        try git.run(["checkout", "-q", "feat/pluto-1"], in: worktree)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }

    /// A rebase detaches HEAD until it ends, back on its branch: that is no drift.
    @Test func aDetachedHeadMidRebaseIsNotFlaggedButOneLeftDetachedIs() async throws {
        let (world, _, task, worktree) = try makeWorld()
        try git.run(["checkout", "-q", "--detach"], in: worktree)
        let state = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"], in: worktree)
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
        try FileManager.default.removeItem(atPath: state)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift?.found.hasPrefix("Its worktree's HEAD is detached at ") == true)
    }

    /// The broadcast's case: told to make a new worktree and branch, the worker committed there, and its last
    /// message named the commit. Its task branch is empty, but the commit is found, and the branch it is on.
    @Test func aCommitTheIdleWorkersLastMessageNamesOffItsBranchIsFlaggedWithTheBranchItIsOn() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-1")
        let elsewhere = try GitFixture.folder("op-drift-tmp-") + "/other"
        try git.run(["worktree", "add", "-q", "-b", "feat/my-own", elsewhere], in: worktree)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: elsewhere)
        // In full: a short SHA could be all digits, which reads as a number.
        let sha = try git.run(["rev-parse", "HEAD"], in: elsewhere)
        try saveReply("Done. Committed \(sha) on feat/my-own; all 41 tests pass.", conversation: "conv-1", in: world)
        await tick(world)
        let drift = try #require(world.task(task.id)?.operated?.branchDrift)
        #expect(drift.source == .lastMessage && drift.sha == sha && drift.branch == "feat/my-own")
        #expect(drift.found == "Its last message names \(sha), which isn't on its task branch feat/pluto-1: it is on feat/my-own.")
    }

    @Test func aCommitTheLastMessageNamesOnItsBranchIsNotFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-2")
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        let sha = try git.run(["rev-parse", "HEAD"], in: worktree)
        try saveReply("Committed \(sha). Run 2f9c4b7e-5a1d-4c3b-9e8f-0a1b2c3d4e5f stays; 1234567 rows read.", conversation: "conv-2", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }

    /// A worker's last reply, in its Claude conversation file under the scratch home.
    func saveReply(_ text: String, conversation: String, in world: OperatorWorld) throws {
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": .string(text)]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent(conversation + ".jsonl"))
    }
}
