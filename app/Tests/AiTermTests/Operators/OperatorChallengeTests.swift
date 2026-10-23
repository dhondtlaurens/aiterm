import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The Oracle's challenge: a challenged call does not take effect on its first call; the Operator
/// reads the critique and calls again, and only that call acts, logged with the critique.
@MainActor @Suite struct OperatorChallengeTests {
    let project = OperatorServiceFixtures.project()

    /// `budget` is generous by default: a critique that is ready answers at once, and a whole-suite run
    /// can keep the main actor busy for seconds. The pending path names a short one.
    func makeWorld(oracle: Bool = true, runner: SecondOpinionRunner, budget: Duration = .seconds(60)) async throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude), projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
        }
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "Do A.", "project": "Shop", "agent": "claude",
                                                      "model": "claude-opus-5-5", "modelReason": "The default.", "end": "commit"])
        return (world, run)
    }

    @Test func theOracleChallengesAPlanAndOnlyTheCallAfterTheCritiqueSubmitsIt() async throws {
        let (world, run) = try await makeWorld(runner: .answering("A is two tasks."))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["challenged"] == true && first.value?["critique"] == "A is two tasks.")
        #expect(world.run(run.id)?.planRevision == 0)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        let second = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."])
        #expect(second.value?["submitted"] == true && world.run(run.id)?.planRevision == 1)
        let decision = try #require(world.run(run.id)?.decisions.last)
        #expect(decision.challenge == "A is two tasks." && decision.text == "Kept the plan despite the Oracle’s objection.")
        #expect(decision.task == nil)
        // The acting call again — its reply lost — answers what it answered, and acts no further.
        let decisions = world.run(run.id)?.decisions.count
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."]) == second)
        #expect(world.run(run.id)?.decisions.count == decisions && world.run(run.id)?.planRevision == 1)
        #expect(await world.call(run.id, "submit_plan", ["revision": 2, "challengeId": .string(id)]).message?
                .hasPrefix("Challenge \(id) has already acted") == true)
        #expect(await world.call(run.id, "mark_task", ["task": "A", "outcome": "accepted", "challengeId": .string(id)])
                .message?.hasPrefix("No challenge") == true)
    }

    /// The challenge is on disk before the acting call's reply: after AiTerm restarts, the call repeated
    /// answers the same and changes nothing (spec §11).
    @Test func anActedChallengeIsReplayedAfterARestart() async throws {
        let (world, run) = try await makeWorld(runner: .answering("A is two tasks."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        let acted = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "One change."])
        let saved = try world.workspace.file.load()
        #expect(saved.run(id: run.id)?.challenges.map(\.stage) == [.acted])
        let restarted = try OperatorWorld(saved)
        #expect(await restarted.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "One change."]) == acted)
        #expect(restarted.run(run.id)?.planRevision == 1 && restarted.run(run.id)?.decisions.count == saved.run(id: run.id)?.decisions.count)
    }

    /// A second opinion lost with AiTerm's restart never holds the act up: its next call proceeds, unchallenged.
    @Test func aChallengeStillRunningWhenAiTermQuitProceedsUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Late.", after: .seconds(2)), budget: .milliseconds(20))
        defer { world.controller.tools.cancelChallenges() }
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        #expect(await restarted.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(restarted.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    /// The Operator answered the critique and kept its act: a disagreement, logged with the Oracle's objection.
    /// A call revised instead agreed, and carries none.
    @Test func aDisagreementIsLoggedWithTheObjection() async throws {
        let (world, run) = try await makeWorld(runner: .answering("A is two tasks."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "A is one change."])
        let kept = try #require(world.run(run.id)?.decisions.last)
        #expect(kept.objection == "A is two tasks." && kept.text == "Kept the plan despite the Oracle’s objection.")

        let (revised, revisedRun) = try await makeWorld(runner: .answering("A is two tasks."))
        let second = try #require(await revised.call(revisedRun.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await revised.call(revisedRun.id, "submit_plan", ["revision": 1, "challengeId": .string(second)])
        #expect(revised.run(revisedRun.id)?.decisions.last?.objection == nil)
        #expect(revised.run(revisedRun.id)?.planRevision == 1)
    }

    @Test func withTheOracleOffTheCallActsAtOnce() async throws {
        let (world, run) = try await makeWorld(oracle: false, runner: .answering("never asked"))
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
    }

    @Test func aSecondOpinionThatCannotRunLetsTheActProceedUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .unavailable)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: claude isn’t installed.")
    }

    @Test func aSlowCritiqueIsPendingThenReadThenActedOn() async throws {
        let gate = OracleGate()
        let (world, run) = try await makeWorld(runner: .answering("Too broad.", gate: gate), budget: .milliseconds(20))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["pending"] == true && first.value?["critique"] == .null)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        await gate.open()
        await world.controller.tools.lastChallenge?.value
        let read = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(read.value?["critique"] == "Too broad." && world.run(run.id)?.planRevision == 0)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "Narrowed."])
        #expect(world.run(run.id)?.planRevision == 1)
    }

    /// The broadcast's line says `consulting the Oracle` while the Oracle runs, however long it outlasts the
    /// call that asked it, and the act ends when it answers.
    @Test func theOracleIsConsultedUntilItAnswers() async throws {
        let gate = OracleGate()
        let (world, run) = try await makeWorld(runner: .answering("Too broad.", gate: gate), budget: .milliseconds(20))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["pending"] == true)
        #expect(world.controller.acting.broadcast(run.id)?.0 == .consultingTheOracle, "the call has ended; the Oracle has not")
        let line = OperatorLine.broadcast(try #require(world.run(run.id)), tasks: world.workspace.state.tasks(inRun: run.id),
                                          acting: world.controller.acting.broadcast(run.id), requests: [])
        #expect(line == OperatorLine("consulting the Oracle", look: .acting))
        await gate.open()
        await world.controller.tools.lastChallenge?.value
        #expect(world.controller.acting == .none)
    }

    /// With the Oracle on, the first plan and the verdicts on a task (spec §8); with it off, nothing. A message
    /// to a worker never is, and create_task's veto is the backlog's, not a critique.
    @Test func whichCallsTheOracleChallenges() {
        func call(_ tool: String, _ arguments: JSONValue = [:]) -> ToolCall { ToolCall(tool: tool, arguments: arguments) }
        #expect(OperatorToolHandler.isChallenged(call("submit_plan"), oracleIsOn: true))
        for outcome in ["accepted", "blocked", "failed"] {
            #expect(OperatorToolHandler.isChallenged(call("mark_task", ["outcome": .string(outcome)]), oracleIsOn: true))
        }
        #expect(!OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "noChange"]), oracleIsOn: true))
        #expect(!OperatorToolHandler.isChallenged(call("message_task"), oracleIsOn: true))
        #expect(!OperatorToolHandler.isChallenged(call("create_task"), oracleIsOn: true))
        #expect(OperatorToolHandler.isChallenged(call("create_task"), oracleIsOn: true, backlog: .needsOracle), "past the limit it is vetoed")
        #expect(!OperatorToolHandler.isChallenged(call("create_task"), oracleIsOn: true, backlog: .free))
        #expect(!OperatorToolHandler.isChallenged(call("create_task"), oracleIsOn: false, backlog: .needsOracle))
        #expect(!OperatorToolHandler.isChallenged(call("report_find"), oracleIsOn: true))
        #expect(!OperatorToolHandler.isChallenged(call("submit_plan"), oracleIsOn: false))
        #expect(!OperatorToolHandler.isChallenged(call("mark_task", ["outcome": "accepted"]), oracleIsOn: false))
        #expect(!OperatorToolHandler.isChallenged(call("finish_task", ["task": "A"]), oracleIsOn: true))
        #expect(OperatorToolHandler.isChallenged(call("finish_task", ["task": "A", "noVerify": true]), oracleIsOn: true),
                "a push past the hook is the Oracle's, merge or not")
        #expect(!OperatorToolHandler.isChallenged(call("finish_task", ["task": "A", "noVerify": false]), oracleIsOn: true))
        #expect(!OperatorToolHandler.isChallenged(call("finish_task", ["task": "A", "noVerify": true]), oracleIsOn: false))
    }

    /// AiTerm quitting cancels a second opinion: that is not an answer, so the act is not recorded as
    /// unchallenged then. Its record stays running, and the next call proceeds unchallenged with the restart's reason.
    @Test func aChallengeCancelledByQuittingIsNotRecordedAsUnchallenged() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Late.", after: .seconds(30)), budget: .milliseconds(20))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        world.controller.stop()
        await world.controller.tools.lastChallenge?.value
        #expect(world.run(run.id)?.challenges.map(\.stage) == [.running])
        #expect(world.run(run.id)?.challenges.first?.unchallengedReason == nil && world.controller.tools.runningChallenges.isEmpty)
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)]).value?["submitted"] == true)
        #expect(world.run(run.id)?.decisions.last?.challenge == "unchallenged: AiTerm restarted before the second opinion answered.")
    }

    @Test func aCritiqueIsCappedAtEightKilobytes() async throws {
        let (world, run) = try await makeWorld(runner: .answering(String(repeating: "é", count: 20_000)))
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        let critique = try #require(first.value?["critique"]?.stringValue)
        #expect(critique.utf8.count <= OperatorToolHandler.critiqueLimit + 64 && critique.hasSuffix(OperatorToolHandler.truncationMarker))
        #expect(world.run(run.id)?.challenges.first?.critique == critique)
    }

    @Test func theSameChallengeIdWithOtherArgumentsIsRefused() async throws {
        let (world, run) = try await makeWorld(runner: .answering("Fine."))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id)])
        #expect(await world.call(run.id, "submit_plan", ["revision": 1, "extra": true, "challengeId": .string(id)]).message?
                .hasPrefix("Challenge \(id) has already acted") == true)
    }

    /// An active run with one working task and a tab for its worker, the Oracle on.
    func makeWorkerWorld(daemon: RecordingDaemon = RecordingDaemon()) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "W-1", state: .working, worktree: "/tmp/aiterm-operators-none/w1")
        task.operated?.ownership = 3
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon) { ports in
            ports.secondOpinion = .answering("Ask first.")
            ports.challengeReplyBudget = .seconds(60)
        }
        world.show([OperatorServiceFixtures.session("w1", tag: task.id, state: .done)])
        return (world, run, task)
    }

    /// Even with the Oracle on and the worker's turn over, a message goes at once: steering is never challenged.
    @Test func aMessageIsNeverChallenged() async throws {
        let (world, run, _) = try makeWorkerWorld()
        let sent = await world.call(run.id, "message_task", ["task": "W-1", "text": "Use nl-BE."])
        #expect(sent.value?["result"] == "delivered" && world.daemon.requests("session.deliver").count == 1)
        #expect(world.run(run.id)?.challenges.isEmpty == true)
    }

    /// A verdict on a task is critiqued first; the call that answers it acts, logged with the critique.
    @Test func aBlockedVerdictIsCritiquedThenActs() async throws {
        let (world, run, task) = try makeWorkerWorld()
        let first = await world.call(run.id, "mark_task", ["task": "W-1", "outcome": "blocked", "note": "Needs a key."])
        #expect(first.value?["critique"] == "Ask first." && world.task(task.id)?.operated?.state == .working)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        let acted = await world.call(run.id, "mark_task", ["task": "W-1", "outcome": "blocked", "note": "Needs a key.",
                                                            "challengeId": .string(id), "challengeReply": "The key is the person's."])
        #expect(acted.value?["state"] == "blocked" && world.controller.tools.actingChallenges.isEmpty)
        let decision = try #require(world.run(run.id)?.decisions.last)
        #expect(decision.task == task.id && decision.objection == "Ask first.")
    }

    /// A second call for a challenge that is mid-act is refused, not performed too.
    @Test func aSecondCallForAChallengeThatIsActingIsRefused() async throws {
        let (world, run, task) = try makeWorkerWorld()
        let blocked: JSONValue = ["task": "W-1", "outcome": "blocked", "note": "Needs a key."]
        let id = try #require(await world.call(run.id, "mark_task", blocked).value?["challengeId"]?.stringValue)
        world.controller.tools.actingChallenges.insert(id)
        let acting = JSONValue.object((blocked.objectValue ?? [:]).merging(["challengeId": .string(id)]) { $1 })
        #expect(await world.call(run.id, "mark_task", acting).message == "Challenge \(id) is already acting on mark_task; call again for its result.")
        #expect(world.task(task.id)?.operated?.state == .working)
        world.controller.tools.actingChallenges.remove(id)
        #expect(await world.call(run.id, "mark_task", acting).value?["state"] == "blocked")
    }
}

extension OperatorChallengeTests {
    @Test func anOverruledObjectionIsCappedForTheDebrief() async throws {
        let objection = String(repeating: "x", count: 500)
        let (world, run) = try await makeWorld(runner: .answering(objection))
        let id = try #require(await world.call(run.id, "submit_plan", ["revision": 1]).value?["challengeId"]?.stringValue)
        _ = await world.call(run.id, "submit_plan", ["revision": 1, "challengeId": .string(id), "challengeReply": "One change."])
        let kept = try #require(world.run(run.id)?.decisions.last)
        #expect(kept.objection?.count == 300 && kept.objection?.hasSuffix("…") == true)
        #expect(kept.challenge == objection, "the full critique stays in the log")
    }
}

extension OperatorChallengeTests {
    /// finish_task's noVerify (spec §B): a push past a refusing pre-push hook goes ahead only on the Oracle's yes that the
    /// hook failed on the environment, not the code, judged from the hook's output and what the Operator tried. With no
    /// Oracle, or none answering, it goes ahead. A call that also merges asks both questions in one prompt.
    @MainActor @Suite(.blocking) struct NoVerify {
        struct Pushing {
            let world: OperatorWorld, run: OperatorRun, task: TaskItem, host: FakeMergeHost, sha: String, path: String
            let prompts: OperatorMergeTests.Prompts
        }

        /// One accepted task `A` ending in `end` on the branch of a repository with an origin, whose pre-push hook refuses
        /// with npm not found; the Oracle on or off, answering `answer`.
        func pushing(end: TaskEnd = .draftMR, oracle: Bool = true, answer: String = "YES\nnpm is missing from the hook's PATH.",
                     runner: SecondOpinionRunner? = nil) throws -> Pushing {
            let fixture = try GitFixture.withOrigin(branch: "feat/a")
            let hook = fixture.path + "/.git/hooks/pre-push"
            try "#!/bin/sh\necho 'lefthook: running pre-push'\necho 'sh: npm: command not found' >&2\nexit 1\n"
                .write(toFile: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
            let project = OperatorServiceFixtures.project(path: fixture.path)
            var profile = OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude)
            profile.slices = Slices(merge: true)
            var run = OperatorServiceFixtures.run(profile, projects: [project], state: .active, planRevision: 1)
            run.done = "Merged once the pipeline is green."
            var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, worktree: fixture.path,
                                                    branch: "feat/a", end: end)
            task.baseBranch = "main"
            task.operated?.acceptance = TaskAcceptance(resultSHA: fixture.sha, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                       at: Date(timeIntervalSince1970: 0))
            let host = FakeMergeHost(), prompts = OperatorMergeTests.Prompts()
            let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), adjust: { ports in
                ports.publisher = { _ in host }
                ports.secondOpinion = runner ?? .answering(answer, receivePrompt: { prompts.append($0) })
                ports.challengeReplyBudget = .seconds(60)
            })
            world.live.sessions = [OperatorServiceFixtures.session("operator", tag: run.id), OperatorServiceFixtures.session("worker", tag: task.id)]
            return Pushing(world: world, run: run, task: task, host: host, sha: fixture.sha, path: fixture.path, prompts: prompts)
        }

        func publication(_ p: Pushing) -> TaskPublication? { p.world.task(p.task.id)?.operated?.publication }
        func originTip(_ p: Pushing) throws -> String? { try Repository(p.path, git: GitRunner.hermetic()).originTip(of: "feat/a") }

        /// The push the hook refuses, which keeps its output on the task.
        func refusedPush(_ p: Pushing) async throws {
            let refused = await p.world.call(p.run.id, "finish_task", ["task": "A"])
            #expect(refused.value?["result"] == "failed")
            #expect(publication(p)?.lastPushFailure?.contains("sh: npm: command not found") == true)
        }

        @Test func noVerifyIsChallengedWithTheHookOutput() async throws {
            let p = try pushing()
            try await refusedPush(p)
            #expect(p.prompts.list.isEmpty, "a draft end's push without noVerify asks no Oracle")
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true,
                                                                      "reason": "Ran npm ci in the worktree; npm is still not found."])
            let prompt = try #require(p.prompts.list.first)
            #expect(p.prompts.list.count == 1)
            #expect(prompt.contains("lefthook: running pre-push\nsh: npm: command not found"))
            #expect(prompt.contains("Ran npm ci in the worktree; npm is still not found."))
            #expect(!prompt.contains("The act: merge"))
            #expect(answer.value?["result"] == "published")
            #expect(try originTip(p) == p.sha, "pushed past the hook")
            #expect(publication(p)?.conditionsHeld == nil, "a yes on the hook is no yes on a merge")
            // The same call again, its reply lost: what was done, with no Oracle run.
            let again = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true,
                                                                     "reason": "Ran npm ci in the worktree; npm is still not found."])
            // Less the draft note: a call says what it did to the request's draft state, and the repeat did nothing.
            func withoutNote(_ answer: ToolAnswer) -> JSONValue? {
                guard case .object(var fields)? = answer.value else { return answer.value }
                fields["draftNote"] = nil
                return .object(fields)
            }
            #expect(withoutNote(again) == withoutNote(answer))
            #expect(p.prompts.list.count == 1)
        }

        /// A commit accepted after the hook refused another was never run through it: nothing is known to push it past.
        @Test func aCommitAcceptedSinceTheRefusalNeedsItsOwnPushFirst() async throws {
            let p = try pushing()
            try await refusedPush(p)
            let git = GitRunner.hermetic()
            try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: p.path)
            let head = try git.run(["rev-parse", "HEAD"], in: p.path)
            p.world.workspace.mutate { $0.updateOperated(p.task.id) { $0.acceptance?.resultSHA = head } }
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(answer.value?["result"] == "refused")
            #expect(answer.value?["reason"] == "Push without noVerify first, so the hook's output is known.")
            #expect(p.prompts.list.isEmpty, "the old commit's output is not judged for the new one")
            #expect(try originTip(p) == nil)
        }

        /// Without a reason, what the Operator tried is its last shell commands in the task's worktree, as the activity log has them.
        @Test func withoutAReasonTheOracleReadsTheTasksLastShellCommands() async throws {
            let p = try pushing()
            try await refusedPush(p)
            let folder = OperatorCommand.runFolder(p.run.id, home: p.world.ports.home)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (n, task) in [(1, p.task.id), (2, nil), (3, p.task.id), (4, p.task.id), (5, p.task.id), (6, p.task.id), (7, p.task.id)] as [(Int, UUID?)] {
                try ActivityLog.append(ActivityEntry(at: Date(), tool: "shell", task: task, taskLabel: nil, arguments: [:], outcome: .ok,
                                                     result: "{}", line: "Ran `step \(n)`", reason: nil), runFolder: folder)
            }
            try ActivityLog.append(ActivityEntry(at: Date(), tool: "shell_read", task: p.task.id, taskLabel: nil, arguments: [:], outcome: .ok,
                                                 result: "{}", line: "Read `which npm`", reason: nil), runFolder: folder)
            _ = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            let prompt = try #require(p.prompts.list.first)
            #expect(prompt.contains("Ran `step 3`\nRan `step 4`\nRan `step 5`\nRan `step 6`\nRan `step 7`"))
            #expect(!prompt.contains("step 1") && !prompt.contains("step 2") && !prompt.contains("which npm"))
        }

        @Test func aNoOnNoVerifyPushesNothing() async throws {
            let p = try pushing(answer: "NO\nA test fails: cart.test.ts.")
            try await refusedPush(p)
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(answer.message?.contains("A test fails: cart.test.ts.") == true)
            #expect(answer.message?.contains("Have its worker fix it") == true)
            #expect(try originTip(p) == nil)
            #expect(!p.host.log.contains { $0.hasPrefix("create") })
            #expect(publication(p)?.pushedSHA == nil)
        }

        @Test func noVerifyWithoutAnOracleGoesAhead() async throws {
            let p = try pushing(oracle: false)
            try await refusedPush(p)
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(answer.value?["result"] == "published")
            #expect(try originTip(p) == p.sha)
            #expect(p.prompts.list.isEmpty)
        }

        /// An Oracle that can't answer lets the push past the hook go ahead, logged as unchallenged.
        @Test func anOracleThatDoesNotAnswerLetsNoVerifyGoAhead() async throws {
            let p = try pushing(runner: .unavailable)
            try await refusedPush(p)
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(answer.value?["result"] == "published")
            #expect(try originTip(p) == p.sha)
            #expect(p.world.run(p.run.id)?.decisions.last?.why == "The Oracle didn’t answer, so the push past the hook went ahead unchallenged.")
        }

        /// No refused push yet: nothing for the Oracle to judge, so it isn't asked, and the call is refused.
        @Test func noVerifyBeforeAFailedPushAsksNoOracle() async throws {
            let p = try pushing()
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(answer.value?["result"] == "refused")
            #expect(answer.value?["reason"] == "Push without noVerify first, so the hook's output is known.")
            #expect(p.prompts.list.isEmpty)
            #expect(try originTip(p) == nil)
        }

        /// A merge end whose merge the Oracle hasn't said yes to: one run, one prompt with both questions, and its yes holds for both.
        @Test func aMergingNoVerifyAsksBothQuestionsOnce() async throws {
            let p = try pushing(end: .merge)
            p.world.workspace.mutate { $0.updateOperated(p.task.id) {
                $0.publication = TaskPublication(problem: "The pre-push hook refused the push of feat/a: sh: npm: command not found",
                                                 lastPushFailure: "sh: npm: command not found", lastPushFailureSHA: p.sha)
            } }
            let answer = await p.world.call(p.run.id, "finish_task", ["task": "A", "noVerify": true])
            #expect(p.prompts.list.count == 1)
            let prompt = try #require(p.prompts.list.first)
            #expect(prompt.contains("sh: npm: command not found"))
            #expect(prompt.contains("The act: merge the accepted commit \(p.sha) for task A.") && prompt.contains("Merged once the pipeline is green."))
            #expect(prompt.contains("Answer YES only when the failure is the environment and the merge is permitted"))
            #expect(answer.value?["result"] == "waitingToMerge")
            #expect(try originTip(p) == p.sha)
            #expect(publication(p)?.conditionsHeld == p.sha)
        }
    }
}
