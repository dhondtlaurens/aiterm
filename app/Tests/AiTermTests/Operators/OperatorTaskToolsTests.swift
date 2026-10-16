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
    func makeWorld(autonomy: Autonomy = .handsOff, retries: Int = 2) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-tools-"))
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: autonomy, retries: retries), projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: git).task
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        task.operated?.ownership = 3
        return (try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])), run, task)
    }

    @discardableResult
    func commit(_ file: String, in path: String) throws -> String {
        try "change\n".write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try git.run(["add", file], in: path)
        try git.run(["commit", "-q", "-m", "Add \(file)"], in: path)
        return try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
        #expect(diff["diff"]?.stringValue?.contains("login.swift") == true)
        #expect(diff["diff"]?.stringValue?.contains("moved-on.swift") == false && diff["commits"]?.stringValue?.contains("moved-on") == false)
        #expect(diff["diff"]?.stringValue?.contains("draft.swift") == false)
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
        #expect(diff["diff"]?.stringValue?.contains("login.swift") == true)
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
        #expect(world.controller.acting == [task.id])
        daemon.release()
        _ = await sending.value
        #expect(world.controller.acting.isEmpty)
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

    @Test func aRepeatedAcceptAnswersWhileThePersonHasPausedTheOperation() async throws {
        let (world, run, task) = try makeWorld()
        let tip = try commit("a.swift", in: task.worktreePath)
        let accepted = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .paused; $0.intent = .paused } }
        #expect(await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"]) == accepted)
        #expect(world.task(task.id)?.operated?.state == .accepted)
    }

    @Test func anEndedTaskIsNotMessaged() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        let tip = try commit("a.swift", in: task.worktreePath)
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "accepted", "sha": .string(tip), "checkOutput": "ok"])
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "One more thing."]).message
                == "PLUTO-1 is accepted: there is no worker to steer.")
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }

    @Test func aBlockedTaskNotifiesYouOnceAndARepeatOfTheSameReasonDoesNot() async throws {
        let (world, run, task) = try makeWorld(autonomy: .routine)
        let blocked: JSONValue = ["task": "PLUTO-1", "outcome": "blocked", "note": "Needs a decision."]
        _ = await world.call(run.id, "mark_task", blocked)
        #expect(world.notifications.posted.map(\.id) == ["blocked-\(task.id.uuidString)"])
        _ = await world.call(run.id, "mark_task", blocked)
        #expect(world.notifications.posted.count == 1)
    }

    @Test func aFailedTaskRepeatedWithTheSameReasonChangesAndNotifiesNothing() async throws {
        let (world, run, task) = try makeWorld(autonomy: .routine)
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

    @Test func anOperationWhoseEveryTaskEndedIsCompleteTheOperatorIsToldAndYouAreNotified() async throws {
        let (world, run, task) = try makeWorld()
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "noChange", "note": "Already fixed upstream."])
        #expect(world.run(run.id)?.state == .complete)
        #expect(world.notifications.posted.map(\.id) == ["done-\(run.id.uuidString)"])
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String == "[AiTerm] operation complete — call run_status")
        #expect(world.task(task.id)?.operated?.state == .noChange)
    }

    @Test func aFailedTaskIsRetriedWhileRetriesAreLeftAndABlockedOneResumes() async throws {
        let (world, run, task) = try makeWorld(retries: 1)
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "failed", "note": "The build broke."])
        #expect(await world.call(run.id, "retry_task", ["task": "PLUTO-1"]).value?["state"] == "queued")
        // Queued again, AiTerm starts it again at once.
        await world.controller.lastStart?.value
        let afterRetry = try #require(world.task(task.id)?.operated)
        #expect(afterRetry.retriesUsed == 1 && [.queued, .working].contains(afterRetry.state))
        #expect(afterRetry.lastFailure == "The build broke.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .failed } }
        #expect(await world.call(run.id, "retry_task", ["task": "PLUTO-1"]).message
                == "PLUTO-1 has used its 1 retry. Ask the person with ask_you how to go on.")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        _ = await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "blocked", "note": "Needs a decision."])
        #expect(world.state.tasks.first?.operated?.state == .blocked)
        #expect(await world.call(run.id, "resume_task", ["task": "PLUTO-1"]).value?["state"] == "working")
    }

    @Test func aPausedOperationDeliversAndAcceptsNothing() async throws {
        let (world, run, task) = try makeWorld()
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .paused; $0.intent = .paused } }
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        #expect(await world.call(run.id, "message_task", ["task": "PLUTO-1", "text": "x"]).message
                == "The person paused this operation. Wait until they resume it.")
        #expect(await world.call(run.id, "mark_task", ["task": "PLUTO-1", "outcome": "noChange"]).message
                == "The person paused this operation. Wait until they resume it.")
        #expect(world.daemon.requests("session.deliver").isEmpty)
    }
}
