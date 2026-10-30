import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A worker that commits off its task branch is flagged in `run_status` on the next reconcile tick, and its
/// Operator told. Task-branch commits reset the no-commit clock; limits use the fresh reading and spare idle workers.
@MainActor @Suite(.blocking) struct BranchWatchTests {
    let git = GitRunner.hermetic()
    let clock = TestClock.operators()

    /// A project and a task working in its own worktree on `feat/pluto-1`, its worker's tab in `state`.
    func makeWorld(worker state: SessionState = .working, conversation: String? = nil,
                   adjust: (inout OperatorPorts) -> Void = { _ in })
        throws -> (OperatorWorld, OperatorRun, TaskItem, worktree: String) {
        let repo = try GitFixture.makeRepo(prefix: "op-drift-")
        let worktree = try GitFixture.folder("op-drift-wt-") + "/wt"
        try git.run(["worktree", "add", "-q", "-b", "feat/pluto-1", worktree], in: repo)
        let project = OperatorServiceFixtures.project(path: repo)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: worktree)
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0))
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.clock.now = { [clock] in clock.now }
            adjust(&ports)
        }
        world.show([OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: state, conversation: conversation)])
        return (world, run, task, worktree)
    }

    func tick(_ world: OperatorWorld) async {
        world.controller.reconcileTick()
        await world.controller.branchWatch.lastPoll?.value
    }

    func driftLines(_ world: OperatorWorld) -> [String] {
        world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.hasSuffix("call run_status") }
    }

    @Test func aPriorTaskHeadKeptAsRealWorkOnAnotherBranchStillDrifts() async throws {
        let (_, _, task, worktree) = try makeWorld()
        let before = try git.run(["rev-parse", "HEAD"], in: worktree)
        try "Retained off-branch work\n".write(toFile: worktree + "/retained.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "retained.txt"], in: worktree)
        try git.run(["commit", "-q", "-m", "Work saved elsewhere"], in: worktree)
        let saved = try git.run(["rev-parse", "HEAD"], in: worktree)
        try git.run(["branch", "feat/retained", saved], in: worktree)
        try git.run(["reset", "--hard", before], in: worktree)
        let named = BranchWatch.named(in: "Work is saved as \(saved) on feat/retained.", branch: task.branch,
                                      base: "main", worktree: worktree, git: git)
        #expect(named.contains { $0.commit == saved && !$0.onTaskBranch && $0.branches.contains("feat/retained") })
    }

    /// Each new task-branch head resets the stuck clock; its first reading only sets a baseline.
    @Test func newCommitsRestartTheStuckClockButAnUnchangedHeadDoesNot() async throws {
        let (world, _, task, worktree) = try makeWorld()
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 30 * 60 } }
        await tick(world)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 1800.0, "the first reading is only a baseline")
        for number in 1...2 {
            world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 89 * 60 } }
            try git.run(["commit", "--allow-empty", "-q", "-m", "work \(number)"], in: worktree)
            await tick(world)
            #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
        }
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 30 * 60 } }
        await tick(world)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 1800.0)
    }

    /// Progress on the tick that reaches the limit is read before that limit is decided.
    @Test func aCommitOnTheLimitTickIsReadBeforeBlocking() async throws {
        let (world, _, task, worktree) = try makeWorld()
        await tick(world)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 90 * 60 } }
        try git.run(["commit", "--allow-empty", "-q", "-m", "progress"], in: worktree)
        await tick(world)
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
        #expect(world.notifications.posted.isEmpty)
    }

    /// Work on another branch does not count as progress on the task.
    @Test func offBranchCommitsDoNotRestartTheStuckClock() async throws {
        let (world, _, task, worktree) = try makeWorld()
        await tick(world)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 30 * 60 } }
        try git.run(["checkout", "-q", "-b", "fix/elsewhere"], in: worktree)
        try git.run(["commit", "--allow-empty", "-q", "-m", "elsewhere"], in: worktree)
        await tick(world)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 1800.0)
    }

    /// A branch read without progress still applies the stuck limit and notifies the person.
    @Test(arguments: ["unchanged", "offBranch", "unreadable"])
    func aHeadReadingWithoutProgressStillBlocksAtNinetyMinutes(_ reading: String) async throws {
        let (world, run, task, worktree) = try makeWorld()
        await tick(world)
        if reading == "offBranch" {
            try git.run(["checkout", "-q", "-b", "fix/elsewhere"], in: worktree)
            try git.run(["commit", "--allow-empty", "-q", "-m", "elsewhere"], in: worktree)
        } else if reading == "unreadable" {
            try FileManager.default.removeItem(atPath: worktree + "/.git")
        }
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 90 * 60 } }
        await tick(world)
        #expect(world.task(task.id)?.operated?.state == .blocked)
        #expect(world.task(task.id)?.operated?.blockedReason == "Worked 90 minutes without a new commit.")
        #expect(world.notifications.posted.last?.target == .board(run.id))
    }

    /// Committing grants more no-commit time, but never more unattended time.
    @Test func commitsDoNotResetTotalWorkAndTheTotalCapStillBlocks() async throws {
        let (world, run, task, worktree) = try makeWorld()
        await tick(world)
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.runtimeUsed = 89 * 60
            $0.totalRuntimeUsed = 4 * 60 * 60 - 60
        } }
        try git.run(["commit", "--allow-empty", "-q", "-m", "progress"], in: worktree)
        clock.advance(by: 30)
        await tick(world)
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
        #expect(world.task(task.id)?.operated?.totalRuntimeUsed == 14370.0)
        try git.run(["commit", "--allow-empty", "-q", "-m", "more progress"], in: worktree)
        clock.advance(by: 30)
        await tick(world)
        #expect(world.task(task.id)?.operated?.totalRuntimeUsed == 14400.0)
        #expect(world.task(task.id)?.operated?.state == .blocked)
        #expect(world.task(task.id)?.operated?.blockedReason == "Worked 4 hours since it started or the Operator last resumed it.")
        #expect(world.notifications.posted.last?.target == .board(run.id))
    }

    /// The branch-read callback exempts an idle worker even past both limits, until it works again.
    @Test func aWatchedIdleWorkerPastBothLimitsIsBlockedOnlyOnceItWorksAgain() async throws {
        let (world, run, task, _) = try makeWorld(worker: .idle)
        await tick(world)
        #expect(world.task(task.id)?.operated?.runtimeHead != nil)
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.runtimeUsed = 91 * 60
            $0.totalRuntimeUsed = 241 * 60
        } }
        clock.advance(by: 60)
        await tick(world)
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 5460.0)
        #expect(world.task(task.id)?.operated?.totalRuntimeUsed == 14460.0)
        #expect(world.notifications.posted.isEmpty)

        // Change the live tab without a tick: the branch read's checkLimits must decide and notify.
        world.live.sessions = [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                               OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working)]
        world.controller.branchWatch.poll()
        await world.controller.branchWatch.lastPoll?.value
        #expect(world.task(task.id)?.operated?.state == .blocked)
        #expect(world.notifications.posted.last?.target == .board(run.id))
    }

    /// Every worker shares the branch, so an extra tab makes progress for the whole task.
    @Test func anExtraWorkersCommitRestartsTheSharedClock() async throws {
        let (world, run, task, worktree) = try makeWorld(worker: .idle)
        await tick(world)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.extraTabs = [
            ExtraTab(key: "review", agent: .codex, model: "m", reasoning: nil, modelReason: "Tests.", brief: "Write tests.",
                     launch: LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now), sessionId: "w2")
        ] } }
        var extra = OperatorServiceFixtures.session("w2", window: "w9", tag: task.id, agent: .codex, state: .working)
        extra.tabIndex = 1
        extra.tabKey = "review"
        world.show([OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .idle), extra])
        world.workspace.mutate { $0.updateOperated(task.id) { $0.runtimeUsed = 89 * 60 } }
        try git.run(["commit", "--allow-empty", "-q", "-m", "worker tests"], in: worktree)
        clock.advance(by: 60)
        await tick(world)
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
        #expect(world.task(task.id)?.operated?.totalRuntimeUsed == 60)
    }

    /// Restarting AiTerm preserves both clocks and the last branch head.
    @Test func savedProgressSurvivesRestartWithoutResettingEitherClock() async throws {
        let (world, _, task, _) = try makeWorld()
        await tick(world)
        world.workspace.mutate { $0.updateOperated(task.id) {
            $0.runtimeUsed = 30 * 60
            $0.totalRuntimeUsed = 120 * 60
        } }
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(world.workspace.file.load()) { ports in
            ports.clock.now = { [clock] in clock.now }
        }
        restarted.show(world.live.sessions)
        await tick(restarted)
        #expect(restarted.task(task.id)?.operated?.runtimeUsed == 1800.0)
        #expect(restarted.task(task.id)?.operated?.totalRuntimeUsed == 7200.0)
        #expect(restarted.task(task.id)?.operated?.runtimeHead == world.task(task.id)?.operated?.runtimeHead)
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
            driftLines(world) == ["[AiTerm] PLUTO-one needs its branch checked, call run_status"]
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

    /// With `CLAUDE_CONFIG_DIR` naming another folder, Claude keeps the conversation there, and it is read there.
    @Test func aCommitNamedInAConversationUnderAnotherClaudeFolderIsFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-alt",
                                                       adjust: { $0.claudeConfig = ClaudeConfig("~/claude-alt") })
        let elsewhere = try GitFixture.folder("op-drift-tmp-") + "/other"
        try git.run(["worktree", "add", "-q", "-b", "feat/my-own", elsewhere], in: worktree)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: elsewhere)
        let sha = try git.run(["rev-parse", "HEAD"], in: elsewhere)
        try saveReply("Done. Committed \(sha) on feat/my-own.", conversation: "conv-alt", in: world, claudeFolder: "claude-alt")
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift != nil)
    }

    @Test func aCommitTheLastMessageNamesOnItsBranchIsNotFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-2")
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        let sha = try git.run(["rev-parse", "HEAD"], in: worktree)
        try saveReply("Committed \(sha). Run 2f9c4b7e-5a1d-4c3b-9e8f-0a1b2c3d4e5f stays; 1234567 rows read.", conversation: "conv-2", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }

    /// A review tab's case: its last message says `main has moved on to <main's head>`. A commit its base branch holds is
    /// no work done off the task branch.
    @Test func aCommitOnTheBaseBranchTheLastMessageNamesIsNotFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-base")
        let repo = try #require(world.workspace.state.project(id: task.projectId)?.path)
        try git.run(["commit", "--allow-empty", "-q", "-m", "someone else's fix"], in: repo)
        let mainHead = try git.run(["rev-parse", "main"], in: worktree)
        try saveReply("Reviewed. Note main has moved on to \(mainHead); a rebase is due.", conversation: "conv-base", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }

    /// A worker asked to merge its accepted commit names the merge commit: one merged into main, and one made on a
    /// detached HEAD that no branch holds, each a merge of the task branch's own work, are no drift.
    @Test func aMergeOfTheTaskTheLastMessageNamesIsNotFlagged() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-merge")
        let repo = try #require(world.workspace.state.project(id: task.projectId)?.path)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        let loose = try GitFixture.folder("op-drift-tmp-") + "/loose"
        try git.run(["worktree", "add", "-q", "--detach", loose, "main"], in: repo)
        try git.run(["merge", "--no-ff", "-q", "-m", "Merge the fix, detached", "feat/pluto-1"], in: loose)
        let detached = try git.run(["rev-parse", "HEAD"], in: loose)
        try git.run(["merge", "--no-ff", "-q", "-m", "Merge the fix", "feat/pluto-1"], in: repo)
        let merged = try git.run(["rev-parse", "main"], in: repo)
        try saveReply("Merged locally as \(merged) (first try \(detached)).", conversation: "conv-merge", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
        #expect(BranchWatch.named(in: "\(detached)", branch: "feat/pluto-1", base: "main", worktree: worktree, git: git)
            .map { [$0.onTaskBranch, $0.onBaseBranch, $0.mergesTaskBranch] } == [[false, false, true]], "a merge no branch holds")
    }

    /// A hex string that is no commit in the repository is no evidence of drift: a session id or a hash the
    /// worker quotes. Only a commit the repository has, off the task branch, is flagged.
    @Test func aHexStringThatIsNoCommitIsIgnored() async throws {
        let (world, run, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-3")
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: worktree)
        let sha = try git.run(["rev-parse", "HEAD"], in: worktree)
        try saveReply("Committed \(sha). Evidence: session 0f3c9a7e1b2d4c5f6a7b8c9d0e1f2a3b, cache key 5e4d3c2b1a0f9e8.",
                      conversation: "conv-3", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
        let current = try #require(world.run(run.id))
        #expect(try #require(world.controller.status(of: current)).obligations.branchDrift.isEmpty)
        // The idle worker's turn, once read (`WorkerTurnReader`), is news of its own: no drift is.
        #expect(!driftLines(world).contains { $0.contains("committed off") }, "nothing to tell")
    }

    /// Each worker tab's last message is read once its own turn ended: an extra tab's names a commit off the task
    /// branch while the first worker is still at work.
    @Test func anExtraTabsLastMessageNamingACommitOffItsBranchIsFlagged() async throws {
        let (world, run, task, worktree) = try makeWorld(worker: .working, conversation: "conv-first")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.extraTabs = [
            ExtraTab(key: "review", agent: .claude, model: "m", reasoning: nil, modelReason: "Tests.", brief: "Write the tests.",
                     launch: LaunchAttempt(number: 1, requestedAt: Date(timeIntervalSince1970: 0), openedAt: Date(timeIntervalSince1970: 0)),
                     sessionId: "w2")
        ] } }
        var extra = OperatorServiceFixtures.session("w2", window: "w9", tag: task.id, state: .idle, conversation: "conv-review")
        extra.tabIndex = 1
        extra.tabKey = "review"
        world.show([OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working, conversation: "conv-first"), extra])
        let elsewhere = try GitFixture.folder("op-drift-tmp-") + "/other"
        try git.run(["worktree", "add", "-q", "-b", "feat/tests-elsewhere", elsewhere], in: worktree)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the tests"], in: elsewhere)
        let sha = try git.run(["rev-parse", "HEAD"], in: elsewhere)
        try saveReply("Tests written in \(sha) on feat/tests-elsewhere.", conversation: "conv-review", in: world)
        try saveReply("Still working.", conversation: "conv-first", in: world)
        await tick(world)
        let drift = try #require(world.task(task.id)?.operated?.branchDrift)
        #expect(drift.source == .lastMessage && drift.sha == sha && drift.branch == "feat/tests-elsewhere")
    }

    /// An idle worker's transcript is read again only once it was written since the last pass: a tick that finds it
    /// as it was reads what it read before, and one after it changed reads it afresh.
    @Test func anUnchangedTranscriptIsReadOnceAndAChangedOneAgain() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-4")
        func offBranch(_ branch: String) throws -> String {
            let elsewhere = try GitFixture.folder("op-drift-tmp-") + "/other"
            try git.run(["worktree", "add", "-q", "-b", branch, elsewhere], in: worktree)
            try git.run(["commit", "--allow-empty", "-q", "-m", "work on \(branch)"], in: elsewhere)
            return try git.run(["rev-parse", "HEAD"], in: elsewhere)
        }
        let file = world.ports.home.appendingPathComponent(".claude/projects/-wt/conv-4.jsonl")
        let first = try offBranch("feat/first")
        try saveReply("Committed \(first) on feat/first.", conversation: "conv-4", in: world)
        // A whole second, which a date set and read back keeps exactly.
        let written = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift?.sha == first)

        // Rewritten with its date put back: as far as the watch can tell, unchanged, so it is not read again.
        let second = try offBranch("feat/second")
        try saveReply("Committed \(second) on feat/second.", conversation: "conv-4", in: world)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift?.sha == first, "read once")

        try FileManager.default.setAttributes([.modificationDate: written.addingTimeInterval(60)], ofItemAtPath: file.path)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift?.sha == second, "read again once written")
    }

    /// A worker's last reply, in its Claude conversation file under the scratch home.
    /// The reply saved where Claude keeps the conversation: `claudeFolder` under the scratch home.
    func saveReply(_ text: String, conversation: String, in world: OperatorWorld, claudeFolder: String = ".claude") throws {
        let folder = world.ports.home.appendingPathComponent(claudeFolder + "/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: JSONValue = ["type": "assistant", "message": ["content": [["type": "text", "text": .string(text)]]]]
        try (JSONEncoder().encode(record) + Data("\n".utf8)).write(to: folder.appendingPathComponent(conversation + ".jsonl"))
    }
}

extension BranchWatchTests {
    @Test func aRebasedCommitQuotedAsHistoryIsAlreadyPresentByPatchIdentity() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-rebased")
        try "fix\n".write(toFile: worktree + "/fix.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "fix.swift"], in: worktree)
        try git.run(["commit", "-q", "-m", "the fix"], in: worktree)
        let old = try git.run(["rev-parse", "HEAD"], in: worktree)
        let project = try #require(world.state.project(id: task.projectId))
        try "base\n".write(toFile: project.path + "/base.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "base.swift"], in: project.path)
        try git.run(["commit", "-q", "-m", "base advanced"], in: project.path)
        try git.run(["rebase", "main"], in: worktree)
        let current = try git.run(["rev-parse", "HEAD"], in: worktree)
        #expect(old != current)
        // Prove patch equivalence still works after branch history metadata expires.
        try git.run(["reflog", "expire", "--expire=now", "refs/heads/" + task.branch], in: worktree)
        try saveReply("Before rebase: \(old). Current commit: \(current).", conversation: "conv-rebased", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }
}

extension BranchWatchTests {
    @Test func anAmendedHistoricalTaskHeadDoesNotBecomeOffBranchWork() async throws {
        let (world, _, task, worktree) = try makeWorld(worker: .idle, conversation: "conv-amended")
        try "old\n".write(toFile: worktree + "/fix.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "fix.swift"], in: worktree)
        try git.run(["commit", "-q", "-m", "first version"], in: worktree)
        let old = try git.run(["rev-parse", "HEAD"], in: worktree)
        try "corrected\n".write(toFile: worktree + "/fix.swift", atomically: true, encoding: .utf8)
        try git.run(["add", "fix.swift"], in: worktree)
        try git.run(["commit", "--amend", "-q", "--no-edit"], in: worktree)
        let current = try git.run(["rev-parse", "HEAD"], in: worktree)
        try saveReply("Superseded \(old), current commit \(current).", conversation: "conv-amended", in: world)
        await tick(world)
        #expect(world.task(task.id)?.operated?.branchDrift == nil)
    }
}
