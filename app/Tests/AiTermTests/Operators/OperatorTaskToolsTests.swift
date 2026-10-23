import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The tools an operator works a started task with (spec §6, §8): what it reads of a worker, what it
/// says to one, and the outcome it records.
@MainActor @Suite(.blocking) struct OperatorTaskToolsTests {
    let git = GitRunner.hermetic()

    /// An active run with one working task whose worktree is a real checkout off `main`.
    func makeWorld(adjust: (inout OperatorPorts) -> Void = { _ in }) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-tools-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: git).task
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        task.operated?.ownership = 3
        return (try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), adjust: adjust), run, task)
    }

    @discardableResult
    func commit(_ file: String, in path: String) throws -> String {
        try "change\n".write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try git.run(["add", file], in: path)
        try git.run(["commit", "-q", "-m", "Add \(file)"], in: path)
        return try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The patches an answer's `files` carry, joined; and the paths it lists.
    func patches(_ answer: JSONValue) -> String {
        (answer["files"]?.arrayValue ?? []).compactMap { $0["patch"]?.stringValue }.joined(separator: "\n")
    }
    func paths(_ answer: JSONValue) -> [String] { (answer["files"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue } }

    @Test func readTaskReadsTheLastReplyFromTheWorkersConversationFile() async throws {
        let (world, run, task) = try makeWorld()
        let file = world.ports.home.appendingPathComponent(".claude/projects/p/conv-1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Which locale?"}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done, conversation: "conv-1")])
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value?["lastMessage"] == "Which locale?")
    }

    @Test func theDiffIsTheCommittedWorkSinceTheBaseWentOnAndUncommittedEditsAreToldApart() async throws {
        let (world, run, task) = try makeWorld()
        let project = try #require(world.state.project(id: task.projectId))
        try commit("login.swift", in: task.worktreePath)
        try commit("moved-on.swift", in: project.path)
        try "draft\n".write(toFile: task.worktreePath + "/draft.swift", atomically: true, encoding: .utf8)
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(paths(diff) == ["login.swift"])
        #expect(diff["commits"]?.stringValue?.contains("moved-on") == false)
        #expect(diff["uncommitted"]?.stringValue?.contains("draft.swift") == true)
        try FileManager.default.removeItem(atPath: task.worktreePath + "/draft.swift")
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value?["uncommitted"] == "")
    }

    @Test func aBranchGitCannotReadIsRefusedInAiTermsWords() async throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { state in if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].baseBranch = "no-such-base" } }
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).message
                == "AiTerm couldn’t read PLUTO-1’s branch against no-such-base.")
    }

    /// A world whose task works in the project's own checkout on `feat/x`, branched from `origin/main` after someone else
    /// moved origin on, so the checkout's local `main` lags. `moved` is origin's `main`. `worldGit` is the git the world's
    /// tools run.
    func makeWorldBehindOrigin(worldGit: (any GitRunning)? = nil, adjust: (inout OperatorPorts) -> Void = { _ in })
        throws -> (world: OperatorWorld, run: OperatorRun, task: TaskItem, moved: String) {
        let path = try GitFixture.makeRepo(prefix: "op-origin-"), origin = try GitFixture.folder("origin-"), clone = try GitFixture.folder("clone-")
        try git.run(["init", "--bare", "-q", "--initial-branch=main", origin], in: "/")
        try git.run(["remote", "add", "origin", origin], in: path)
        try git.run(["push", "-q", "origin", "main"], in: path)
        try git.run(["clone", "-q", origin, clone], in: "/")
        let moved = try commit("origin-only.swift", in: clone)
        try git.run(["push", "-q", "origin", "main"], in: clone)
        try git.run(["fetch", "-q", "origin"], in: path)
        try git.run(["switch", "-q", "-c", "feat/x", "origin/main"], in: path)
        try commit("mine.swift", in: path)
        #expect(try git.run(["rev-parse", "main"], in: path) != moved, "the checkout's own main is behind origin's")
        let project = OperatorServiceFixtures.project(path: path)
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: path, branch: "feat/x")
        task.baseBranch = "main"
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        task.operated?.ownership = 3
        return (try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), git: worldGit ?? git,
                                  adjust: adjust), run, task, moved)
    }

    @Test func theDiffStartsAtOriginNotTheLocalMain() async throws {
        let (world, run, _, moved) = try makeWorldBehindOrigin()
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(paths(diff) == ["mine.swift"], "origin's own commit is not the worker's change")
        #expect(diff["base"] == .string(moved))
        #expect(diff["head"]?.stringValue?.count == 40)
        #expect(diff["commits"]?.stringValue?.contains("Add mine.swift") == true && diff["commits"]?.stringValue?.contains("origin-only") == false)
        #expect(diff["stat"]?.stringValue?.contains("mine.swift") == true && diff["stat"]?.stringValue?.contains("origin-only") == false)
        #expect(diff["truncated"] == false && diff["uncommitted"] == "")
        #expect(diff["diff"] == nil, "the patches are in files")
    }

    /// The base's fetch is bounded well inside the daemon's 30 s wait for the answer, and done at most once a minute for the
    /// same base: `read_task diff` and the review after it fetch once (spec §9, the reopen and read_task diff fixes).
    @Test func theBaseIsFetchedWithinTenSecondsAndAtMostOnceAMinute() async throws {
        let recording = RecordingGitRunner(forwardingTo: git), clock = TestClock.operators()
        let (world, run, _, moved) = try makeWorldBehindOrigin(worldGit: recording) { $0.now = { clock.now } }
        func fetches() -> [RecordingGitRunner.Call] { recording.calls.filter { $0.args.contains("fetch") } }
        func diff() async throws -> JSONValue { try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value) }
        #expect(try await diff()["base"] == .string(moved))
        #expect(fetches().count == 1)
        #expect(fetches().allSatisfy { $0.timeout == OperatorTiming.diffBaseFetchTimeout } && OperatorTiming.diffBaseFetchTimeout <= 10)
        #expect(OperatorTiming.diffBaseFetchTimeout * 2 < OperatorTiming.operatorRequestTimeout)
        clock.advance(by: 59)
        #expect(try await diff()["base"] == .string(moved))
        #expect(fetches().count == 1, "fetched under a minute ago")
        clock.advance(by: 2)
        _ = try await diff()
        #expect(fetches().count == 2)
    }

    /// A fetch that fails or runs out of time (offline, a VPN down) is no refusal: origin's branch is read as last fetched,
    /// and the next read within the minute doesn't wait on it again.
    @Test func aFetchThatFailsReadsOriginAsLastFetched() async throws {
        let failing = TimingOutGitRunner(GitRunner.stallGuard + ["fetch"], inner: git)
        let recording = RecordingGitRunner(forwardingTo: failing)
        let (world, run, _, moved) = try makeWorldBehindOrigin(worldGit: recording)
        let answer = await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"])
        #expect(answer.message == nil)
        let diff = try #require(answer.value)
        #expect(diff["base"] == .string(moved) && paths(diff) == ["mine.swift"])
        _ = await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"])
        #expect(recording.calls.filter { $0.args.contains("fetch") }.count == 1, "a failed try counts for the minute too")
    }

    @Test func aStackedTasksDiffStartsAtItsParentsAcceptedCommit() async throws {
        let (world, run, task) = try makeWorld()
        let accepted = try commit("parent.swift", in: task.worktreePath)
        try commit("child.swift", in: task.worktreePath)
        let project = try #require(world.state.project(id: task.projectId))
        var parent = OperatorServiceFixtures.task(in: run, project: project, key: "PARENT", state: .accepted)
        parent.operated?.acceptance = TaskAcceptance(resultSHA: accepted, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date(timeIntervalSince1970: 0))
        world.workspace.mutate { state in
            state.tasks.append(parent)
            state.updateOperated(task.id) { $0.dependsOn = [TaskDependency(task: parent.id, kind: .code)] }
        }
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(diff["base"] == .string(accepted))
        #expect(paths(diff) == ["child.swift"], "the parent's own commit is not the child's change")
        #expect(diff["commits"]?.stringValue?.contains("parent.swift") == false)
    }

    @Test func aParentsCommitOutsideTheBranchLeavesBaseLogAndDiffMeasuringFromTheSamePlace() async throws {
        let (world, run, task) = try makeWorld()
        let path = task.worktreePath, fork = try git.run(["rev-parse", "HEAD"], in: path)
        // The parent's accepted commit sits on a branch of its own: not in the child's history, as after a rebase.
        try git.run(["switch", "-q", "-c", "parent-side"], in: path)
        let accepted = try commit("parent.swift", in: path)
        try git.run(["switch", "-q", task.branch], in: path)
        try commit("child.swift", in: path)
        let project = try #require(world.state.project(id: task.projectId))
        var parent = OperatorServiceFixtures.task(in: run, project: project, key: "PARENT", state: .accepted)
        parent.operated?.acceptance = TaskAcceptance(resultSHA: accepted, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date(timeIntervalSince1970: 0))
        world.workspace.mutate { state in
            state.tasks.append(parent)
            state.updateOperated(task.id) { $0.dependsOn = [TaskDependency(task: parent.id, kind: .code)] }
        }
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(diff["base"] == .string(fork), "the commit log and diff measure from, not one the branch does not contain")
        #expect(paths(diff) == ["child.swift"])
        let commits = try #require(diff["commits"]?.stringValue)
        #expect(commits.contains("Add child.swift") && !commits.contains("parent.swift") && commits.split(separator: "\n").count == 1)
    }

    @Test func aWideDiffStaysSmallWhateverItsParts() async throws {
        let (world, run, task) = try makeWorld()
        let path = task.worktreePath
        for index in 0..<500 { try "line \(index)\n".write(toFile: path + "/file-\(index).swift", atomically: true, encoding: .utf8) }
        try git.run(["add", "-A"], in: path)
        try git.run(["commit", "-q", "-m", "Add five hundred files"], in: path)
        try git.run(["-c", "alias.steps=!for i in $(seq 120); do git commit --allow-empty -q -m \"Step $i\"; done", "steps"], in: path, timeout: 120)
        for index in 0..<150 { try "draft\n".write(toFile: path + "/draft-\(index).swift", atomically: true, encoding: .utf8) }
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        let encoded = try JSONEncoder().encode(diff)
        #expect(encoded.count < 40_000, "the answer is \(encoded.count) bytes")
        let files = try #require(diff["files"]?.arrayValue)
        #expect(files.count == DiffDigest.listedFiles + 1 && files.last?["path"] == "and 300 more files")
        let stat = try #require(diff["stat"]?.stringValue)
        #expect(stat.split(separator: "\n").count == DiffDigest.statLines && stat.contains("500 files changed"), "git's summary line is kept")
        #expect(diff["commits"]?.stringValue?.split(separator: "\n").count == DiffDigest.commitLines)
        #expect(diff["uncommitted"]?.stringValue?.split(separator: "\n").count == DiffDigest.uncommittedLines)
        #expect(diff["truncated"] == true)
    }

    @Test func readingThePromptWithNoHelperIsRefusedNotAnsweredAsNoPrompt() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .needsInput)])
        world.link.attached = false
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "prompt"]).message
                == "AiTerm’s helper isn’t connected; try again in a moment.")
    }

    @Test func readTaskShowsWhatTheBranchAddsAndTheOpenPrompt() async throws {
        let (world, run, task) = try makeWorld()
        try commit("login.swift", in: task.worktreePath)
        let diff = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "diff"]).value)
        #expect(diff["commits"]?.stringValue?.contains("Add login.swift") == true)
        #expect(paths(diff) == ["login.swift"] && patches(diff).contains("+change"))
        #expect(diff["truncated"] == false)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .needsInput)])
        world.daemon.prompts["w1"] = .permission
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "prompt"]).value?["prompt"] == "permission")
    }

    @Test func messageTaskDeliversWithTheTasksOwnershipAndNeverToATakenOverTask() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        world.daemon.deliveries = [Delivery(result: .partial, reason: "a prompt opened")]
        let answer = await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "Use nl-BE."])
        #expect(answer.value?["result"] == "partial" && answer.value?["reason"] == "a prompt opened")
        let sent = try #require(world.daemon.requests("session.deliver").first)
        #expect(sent.params["sessionId"] as? String == "w1" && sent.params["ownership"] as? Int == 3 && sent.params["wake"] as? Bool == false)
        #expect(sent.params["worktree"] as? String == task.worktreePath)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "x"]).message
                == "The person took over PLUTO-1. Leave it until they hand it back.")
        #expect(world.daemon.requests("session.deliver").count == 1)
    }

    @Test func theOperatorIsActingOnATaskWhileItsMessageIsInFlight() async throws {
        let daemon = RecordingDaemon(holding: "session.deliver")
        let (built, run, task) = try makeWorld()
        let world = try OperatorWorld(built.state, daemon: daemon)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let sending = Task { await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "Go on."]) }
        try await daemon.received("session.deliver")
        #expect(world.controller.acting.tasks == [task.id: .answering])
        daemon.release()
        _ = await sending.value
        #expect(world.controller.acting == .none)
    }

    @Test func markTaskAcceptsOnlyTheCommitItsBranchIsOnAndARepeatReturnsTheSame() async throws {
        let (world, run, task) = try makeWorld()
        let first = try commit("a.swift", in: task.worktreePath), tip = try commit("b.swift", in: task.worktreePath)
        let moved = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(first), "checkOutput": "ok"])
        #expect(moved.message == "PLUTO-1’s branch is at \(tip.prefix(7)), not \(first): accept the commit its branch is on.")
        let accepted = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(String(tip.prefix(9))),
                                                              "checkOutput": "12 tests passed"])
        #expect(accepted.value?["state"] == "accepted")
        let acceptance = try #require(world.task(task.id)?.operated?.acceptance)
        #expect(acceptance.resultSHA == tip && acceptance.checkOutput == "12 tests passed")
        let again = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "again"])
        #expect(again == accepted)
        #expect(world.task(task.id)?.operated?.acceptance == acceptance)
    }

    @Test func aRepeatedAcceptReturnsTheEarlierResultEvenAfterTheBranchMoved() async throws {
        let (world, run, task) = try makeWorld()
        let tip = try commit("a.swift", in: task.worktreePath)
        let accepted = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        try commit("b.swift", in: task.worktreePath)
        let again = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "later"])
        #expect(again == accepted)
        #expect(world.task(task.id)?.operated?.acceptance?.resultSHA == tip)
    }

    /// Self-healing (spec §D): an accepted task keeps its worker until its commit is on origin, so a failed push can be
    /// put to it. The message reopens the task; accepting again records what it came back with.
    @Test func anAcceptedTaskIsMessagedAndGoesBackToWork() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let tip = try commit("a.swift", in: task.worktreePath)
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        let answer = await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "The hook wants a changelog entry."])
        #expect(answer.value?["result"] == "delivered" && answer.value?["reopened"] == true)
        #expect(world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String } == ["The hook wants a changelog entry."])
        let operated = try #require(world.task(task.id)?.operated)
        #expect(operated.state == .working && operated.acceptance == nil && operated.reopenedFrom == tip)
        // A repeat of the delivered message answers from the record and reopens nothing twice.
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "The hook wants a changelog entry."]) == answer)
        #expect(world.daemon.requests("session.deliver").count == 1)
    }

    @Test func aMessageThatIsNotDeliveredLeavesAnAcceptedTaskAccepted() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let tip = try commit("a.swift", in: task.worktreePath)
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        world.daemon.deliveries = [Delivery(result: .refused, reason: "you are typing")]
        let answer = await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "One more thing."])
        #expect(answer.value?["result"] == "refused" && answer.value?["reopened"] == nil)
        #expect(world.task(task.id)?.operated?.state == .accepted)
    }

    @Test func aPublishedTaskIsStillNotMessaged() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let tip = try commit("a.swift", in: task.worktreePath)
        world.workspace.mutate {
            $0.updateOperated(task.id) {
                $0.state = .published
                $0.acceptance = TaskAcceptance(resultSHA: tip, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date())
                $0.publication = TaskPublication(pushedSHA: tip, mergeRequestNumber: 7)
            }
        }
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "One more thing."]).message
                == "PLUTO-1 is published: there is no worker to steer.")
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }

    @Test func anAcceptedTaskWhoseCommitIsOnOriginIsNotMessaged() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let tip = try commit("a.swift", in: task.worktreePath)
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        world.workspace.mutate { $0.updateOperated(task.id) { $0.publication = TaskPublication(pushedSHA: tip) } }
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "One more thing."]).message
                == "PLUTO-1 is accepted and its commit is on origin: there is no worker to steer.")
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }

    @Test func aBlockedTaskNotifiesYouOnceAndARepeatOfTheSameReasonDoesNot() async throws {
        let (world, run, task) = try makeWorld()
        let blocked: JSONValue = ["task": "PLUTO-1", "outcome": "blocked", "note": "Needs a decision."]
        _ = await world.call(run.id, "mark_task", blocked)
        #expect(world.notifications.posted.map(\.id) == ["request-\(run.id.uuidString)-\(task.id.uuidString)-blocked"])
        _ = await world.call(run.id, "mark_task", blocked)
        #expect(world.notifications.posted.count == 1)
    }

    @Test func aFailedTaskRepeatedWithTheSameReasonChangesAndNotifiesNothing() async throws {
        let (world, run, task) = try makeWorld()
        let failed: JSONValue = ["task": "PLUTO-1", "outcome": "failed", "note": "The build broke."]
        let first = await world.call(run.id, "mark_task", failed)
        let before = world.task(task.id)
        #expect(await world.call(run.id, "mark_task", failed) == first)
        #expect(world.task(task.id) == before && world.notifications.posted.isEmpty)
    }

    @Test func resumeAndRetryAreRefusedForATaskThePersonTookOver() async throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true; $0.state = .blocked } }
        let refusal = "The person took over PLUTO-1. Leave it until they hand it back."
        #expect(await world.call(run.id, "resume_task", ["task": "PLUTO-1"]).message == refusal)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .failed } }
        #expect(await world.call(run.id, "retry_task", ["task": "PLUTO-1"]).message == refusal)
        #expect(world.task(task.id)?.operated?.state == .failed)
    }

    @Test func aReplyBeyondTheTranscriptsTailIsUnknownNotSilence() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done, conversation: "conv-missing")])
        let answer = try #require(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value)
        #expect(answer["lastMessage"] == .null && answer["note"]?.stringValue?.contains("doesn’t mean it said nothing") == true)
    }

    @Test func aBroadcastWhoseEveryTaskEndedIsCompleteTheOperatorIsToldAndYouAreNotified() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "noChange", "note": "Already fixed upstream."])
        #expect(world.run(run.id)?.state == .complete)
        #expect(world.notifications.posted.isEmpty, "you are notified once its summary is written")
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String == "[AiTerm] broadcast complete, call run_status")
        #expect(world.task(task.id)?.operated?.state == .noChange)
        _ = await world.call(run.id, "write_summary", ["text": "Nothing to change: fixed upstream."])
        #expect(world.notifications.posted.map(\.id) == ["debrief-\(run.id.uuidString)"])
        #expect(world.notifications.posted.first?.body == "The summary is ready.")
    }

    @Test func aFailedTaskIsRetriedWhileRetriesAreLeftAndABlockedOneResumes() async throws {
        let (world, run, task) = try makeWorld()
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "failed", "note": "The build broke."])
        #expect(await world.call(run.id, "retry_task", ["task": "PLUTO-1"]).value?["state"] == "queued")
        // Queued again, AiTerm starts it again at once.
        await world.controller.lastStart?.value
        let afterRetry = try #require(world.task(task.id)?.operated)
        #expect(afterRetry.retriesUsed == 1 && [.queued, .working].contains(afterRetry.state))
        #expect(afterRetry.lastFailure == "The build broke.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .failed; $0.retriesUsed = OperatorTiming.retries } }
        #expect(await world.call(run.id, "retry_task", ["task": "PLUTO-1"]).message
                == "PLUTO-1 has used its 2 retries. Ask the person how to go on, in your chat and with ask_you.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "blocked", "note": "Needs a decision."])
        #expect(world.state.tasks.first?.operated?.state == .blocked)
        #expect(await world.call(run.id, "resume_task", ["task": "PLUTO-1"]).value?["state"] == "working")
    }

    @Test func aPausedBroadcastDeliversAndAcceptsNothing() async throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .paused; $0.intent = .paused } }
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "x"]).message
                == "The person paused this broadcast. Wait until they resume it.")
        #expect(await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "noChange"]).message
                == "The person paused this broadcast. Wait until they resume it.")
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }
}

extension OperatorTaskToolsTests {
    @Test func readTaskReadsTheWorkersConversationFromTheConfiguredClaudeFolder() async throws {
        let (world, run, task) = try makeWorld(adjust: { $0.claudeConfig = ClaudeConfig("~/profile") })
        let file = world.ports.home.appendingPathComponent("profile/projects/p/conv-1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Which locale?"}]}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done, conversation: "conv-1")])
        #expect(await world.call(run.id, "read_task", ["task": "PLUTO-1", "what": "lastMessage"]).value?["lastMessage"] == "Which locale?")
    }
}

/// Moved from OperatorReviewTests, where it sat apart from its subject.
extension OperatorTaskToolsTests {
    /// A repeat is a retry only while the daemon could still be waiting on the first call: within twice its wait for the
    /// app (`OperatorTiming.operatorRequestTimeout`) the same text to the same tab is answered from the record; past
    /// it, it is typed again.
    @Test func deliveredMessagesReplayForTwiceTheRequestTimeout() async throws {
        let clock = TestClock.operators()
        let window = 2 * OperatorTiming.operatorRequestTimeout
        let (world, run, _) = try OperatorServiceFixtures.oneWorkingTask { $0.now = { clock.now } }
        let args: JSONValue = ["task": "A", "text": "Continue"]
        let first = await world.call(run.id, "message_task", args)
        clock.advance(by: window - 1)
        #expect(await world.call(run.id, "message_task", args) == first)
        #expect(world.daemon.requests("session.deliver").count == 1)
        _ = await world.call(run.id, "message_task", ["task": "A", "text": "Different"])
        #expect(world.daemon.requests("session.deliver").count == 2)
        clock.advance(by: 2)
        _ = await world.call(run.id, "message_task", args)
        #expect(world.daemon.requests("session.deliver").count == 3, "typed again past the window")
    }
}
