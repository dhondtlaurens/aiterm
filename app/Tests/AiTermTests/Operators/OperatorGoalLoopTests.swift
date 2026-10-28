import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The goal loop (broadcast setup v2, The goal loop): once every task is done, a broadcast with a goal waits for the
/// Operator's `check_goal`, which the Oracle vetoes, and either completes, plans what is missing within its extra rounds,
/// or stops with what is left for you. A broadcast with no goal completes as before.
@MainActor @Suite struct OperatorGoalLoopTests {
    let project = OperatorServiceFixtures.project()
    let met: JSONValue = ["met": true, "evidence": "A is merged at abc."]
    let notMet: JSONValue = ["met": false, "evidence": "A shipped; the search page did not.", "missing": ["Ship the search page."]]

    /// A new broadcast with `goal`, its one task `A` accepted at `abc` on a commit end, so every task is done, the
    /// Operator's tab listed, and the Oracle answering with `runner`.
    func world(goal: BroadcastGoal? = OperatorServiceFixtures.goal, runner: SecondOpinionRunner = .answering("YES\nA is merged."),
               budget: Duration = .seconds(60)) throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [project],
                                              state: .active, planRevision: 1, agents: OperatorServiceFixtures.agents,
                                              taskSettings: OperatorServiceFixtures.taskSettings, goal: goal)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted)
        task.operated?.acceptance = TaskAcceptance(resultSHA: "abc", prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                   at: Date(timeIntervalSince1970: 0))
        task.operated?.reviewVerdicts = [ReviewVerdict(tab: "review", sha: "abc", passed: true, round: 1, critical: 0, important: 0,
                                                       minor: 2, summary: "Two nits.", at: Date(timeIntervalSince1970: 0))]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
        }
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        return (world, run)
    }

    /// The world with its goal check due: settled once.
    func due(goal: BroadcastGoal? = OperatorServiceFixtures.goal, runner: SecondOpinionRunner = .answering("YES\nA is merged."),
             budget: Duration = .seconds(60)) throws -> (OperatorWorld, OperatorRun) {
        let (world, run) = try world(goal: goal, runner: runner, budget: budget)
        world.controller.runChanged(run.id)
        return (world, run)
    }

    // -- when the check is due ---------------------------------------------------------------
    @Test func everyTaskDoneWithAGoalWaitsForTheCheckAndWakesTheOperator() async throws {
        let (world, run) = try due()
        let waiting = try #require(world.run(run.id))
        #expect(waiting.state == .active && waiting.goalCheckDue && waiting.completedAt == nil)
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String
                == "[AiTerm] every task is done: check the goal with check_goal, call run_status")
        #expect(await world.call(run.id, "write_summary", ["text": "Done."]).message
                == "Every task is done but the goal is still to check: call check_goal first.")
    }

    /// A broadcast started before the Task step has no goal: it completes as it always did.
    @Test func aLegacyBroadcastCompletesAsBefore() throws {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        run.review = "Merge after Jan approves."
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .noChange)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.controller.runChanged(run.id)
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && !done.goalCheckDue && done.goalOutcome == nil && done.goalChecks.isEmpty)
    }

    /// A task not yet done keeps the check from being due, and a task reopened while it is due takes it back.
    @Test func aTaskStillOpenKeepsTheCheckFromBeingDue() throws {
        let (world, run) = try due()
        let task = try #require(world.state.tasks(inRun: run.id).first)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.goalCheckDue == false && world.run(run.id)?.state == .active)
    }

    @Test func checkGoalIsRefusedWhileNoCheckIsDue() async throws {
        let prompts = OperatorMergeTests.Prompts()
        let (world, run) = try world(runner: .answering("YES", receivePrompt: { prompts.append($0) }))
        let task = try #require(world.state.tasks(inRun: run.id).first)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        #expect(await world.call(run.id, "check_goal", met).message
                == "No goal check is due: AiTerm wakes you for it once every task is done.")
        #expect(prompts.list.isEmpty, "a refused check costs no Oracle run")
    }

    // -- the three answers -------------------------------------------------------------------
    /// The Oracle is asked with the goal, each task's result and the Operator's evidence; its yes completes the broadcast.
    @Test func aMetGoalTheOracleAgreesWithCompletes() async throws {
        let prompts = OperatorMergeTests.Prompts()
        let (world, run) = try due(runner: .answering("YES\nA is merged.", receivePrompt: { prompts.append($0) }))
        let answer = await world.call(run.id, "check_goal", met)
        #expect(answer.value?["answer"] == "complete")
        let prompt = try #require(prompts.list.first)
        #expect(prompt.contains("Every page of the sprint ships.") && prompt.contains("A is merged at abc."))
        #expect(prompt.contains(#""acceptedSHA":"abc""#) && prompt.contains("Two nits."))
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && !done.goalCheckDue && done.goalOutcome == .met)
        #expect(done.goalChecks.map(\.oracleAgreed) == [true] && done.goalChecks.first?.round == 0)
        #expect(done.revisionAtLastCheck == 1)
    }

    /// Not met with rounds left: a round is used and the Operator plans what is missing; once that revision's tasks are
    /// done, the check is due again.
    @Test func aGoalNotMetWithRoundsLeftPlansMore() async throws {
        let (world, run) = try due()
        let answer = try #require(await world.call(run.id, "check_goal", notMet).value)
        #expect(answer["answer"] == "planMore" && answer["roundsLeft"] == 1)
        #expect(answer["missing"] == ["Ship the search page."])
        #expect(answer["note"]?.stringValue == "Plan only what missing names: create_task, then submit_plan. If nothing can be planned, "
                + "call check_goal again before submitting anything, with new evidence saying why.")
        let planning = try #require(world.run(run.id))
        #expect(planning.state == .active && !planning.goalCheckDue && planning.roundsUsed == 1 && planning.goalOutcome == nil)
        #expect(planning.leftForYou.isEmpty)
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.state == .active && world.run(run.id)?.goalCheckDue == false, "it waits for the plan")
        // A revision submitted, and its tasks done: the goal is checked again.
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.planRevision = 2 } }
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.goalCheckDue == true)
    }

    /// Not met with no rounds left: what is missing goes to you, and the broadcast completes.
    @Test func aGoalNotMetWithNoRoundsLeftStops() async throws {
        let (world, run) = try due(goal: BroadcastGoal(text: "Every page of the sprint ships.", extraRounds: 1))
        _ = await world.call(run.id, "check_goal", notMet)
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.planRevision = 2 } }
        world.controller.runChanged(run.id)
        let answer = try #require(await world.call(run.id, "check_goal", notMet).value)
        #expect(answer["answer"] == "stopped" && answer["leftForYou"] == ["Ship the search page."])
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && done.goalOutcome == .notMet && done.roundsUsed == 1)
        #expect(done.leftForYou == ["Ship the search page."] && done.goalChecks.map(\.round) == [0, 1])
    }

    /// With 0 extra rounds the goal is checked once and only reported.
    @Test func withNoExtraRoundsTheGoalIsCheckedOnceAndReported() async throws {
        let (world, run) = try due(goal: BroadcastGoal(text: "Every page of the sprint ships.", extraRounds: 0))
        let answer = try #require(await world.call(run.id, "check_goal", notMet).value)
        #expect(answer["answer"] == "stopped")
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && done.goalOutcome == .notMet && done.roundsUsed == 0 && done.leftForYou == ["Ship the search page."])
    }

    /// Finding nothing can be planned, the Operator checks again before submitting anything: accepted, with no further
    /// round. Once a revision is submitted, a check before its tasks are done is refused.
    @Test func aRecheckWithoutANewRoundIsAcceptedUntilARevisionIsSubmitted() async throws {
        let (world, run) = try due()
        _ = await world.call(run.id, "check_goal", notMet)
        let nothing: JSONValue = ["met": false, "evidence": "The search page needs an API nobody has.", "missing": ["Ship the search page."]]
        let answer = try #require(await world.call(run.id, "check_goal", nothing).value)
        #expect(answer["answer"] == "stopped")
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && done.goalOutcome == .notMet && done.roundsUsed == 1 && done.goalChecks.count == 2)

        let (later, laterRun) = try due()
        _ = await later.call(laterRun.id, "check_goal", notMet)
        later.workspace.mutate { $0.updateRun(id: laterRun.id) { $0.planRevision = 2 } }
        let task = try #require(later.state.tasks(inRun: laterRun.id).first)
        later.workspace.mutate { $0.updateOperated(task.id) { $0.state = .working } }
        #expect(await later.call(laterRun.id, "check_goal", nothing).message
                == "No goal check is due: AiTerm wakes you for it once every task is done.")
    }

    /// The acting call again, its reply lost, answers what it answered: it is not taken for a re-check.
    @Test func theSameCheckAgainAnswersTheSame() async throws {
        let (world, run) = try due()
        let first = await world.call(run.id, "check_goal", notMet)
        #expect(await world.call(run.id, "check_goal", notMet) == first)
        let run2 = try #require(world.run(run.id))
        #expect(run2.goalChecks.count == 1 && run2.state == .active && run2.goalOutcome == nil)
    }

    @Test func aGoalNotMetNeedsWhatIsMissing() async throws {
        let prompts = OperatorMergeTests.Prompts()
        let (world, run) = try due(runner: .answering("YES", receivePrompt: { prompts.append($0) }))
        #expect(await world.call(run.id, "check_goal", ["met": false, "evidence": "The search page did not ship."]).message
                == "check_goal needs `missing` when the goal isn’t met: what is still to do, one line each.")
        #expect(prompts.list.isEmpty && world.run(run.id)?.goalCheckDue == true)
    }

    // -- the Oracle --------------------------------------------------------------------------
    /// An Oracle that cannot run lets the check act, recorded as not checked by the Oracle.
    @Test func aMissingOracleLetsTheCheckActUnchecked() async throws {
        let (world, run) = try due(runner: .unavailable)
        #expect(await world.call(run.id, "check_goal", met).value?["answer"] == "complete")
        let done = try #require(world.run(run.id))
        #expect(done.state == .complete && done.goalOutcome == .unchecked && done.goalChecks.map(\.oracleAgreed) == [nil])
    }

    /// The Oracle's no refuses the check with its reason, records nothing and notes no find: the Operator checks again.
    @Test func theOraclesNoRefusesTheCheck() async throws {
        let (world, run) = try due(runner: .answering("NO\nA's pipeline is red."))
        #expect(await world.call(run.id, "check_goal", met).message
                == "The Oracle judged your verdict on the goal wrong: A's pipeline is red. Check the goal again and call check_goal with what you find.")
        let waiting = try #require(world.run(run.id))
        #expect(waiting.goalCheckDue && waiting.goalChecks.isEmpty && waiting.finds.isEmpty && waiting.state == .active)
    }

    /// An Oracle still judging after the reply budget: nothing recorded yet, and the call again with its id acts on the yes.
    @Test func aPendingCheckIsCalledAgainWithItsId() async throws {
        let gate = OracleGate()
        let (world, run) = try due(runner: .answering("YES\nA is merged.", gate: gate), budget: .milliseconds(20))
        let first = try #require(await world.call(run.id, "check_goal", met).value)
        #expect(first["pending"] == true)
        #expect(first["note"] == "Nothing was recorded yet. The Oracle is still judging your verdict on the goal: call check_goal again with this challengeId in a little while.")
        #expect(world.run(run.id)?.goalChecks.isEmpty == true)
        let id = try #require(first["challengeId"]?.stringValue)
        await gate.open()
        await world.controller.tools.lastChallenge?.value
        #expect(await world.call(run.id, "check_goal", met.adding("challengeId", .string(id))).value?["answer"] == "complete")
        #expect(world.run(run.id)?.goalChecks.map(\.oracleAgreed) == [true])
    }

    /// Lost with AiTerm's restart, the Oracle's answer never holds the check up: the call again acts, not checked by it.
    @Test func aCheckWhoseOracleWasLostActsUnchecked() async throws {
        let gate = OracleGate()
        let (world, run) = try due(runner: .answering("YES", gate: gate), budget: .milliseconds(20))
        defer { world.controller.tools.cancelChallenges() }
        let id = try #require(await world.call(run.id, "check_goal", met).value?["challengeId"]?.stringValue)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        #expect(await restarted.call(run.id, "check_goal", met.adding("challengeId", .string(id))).value?["answer"] == "complete")
        #expect(restarted.run(run.id)?.goalOutcome == .unchecked)
    }

    // -- the merge check ---------------------------------------------------------------------
    /// A new broadcast's merge check is given the review prompt and the task's verdicts, not the Review and Done text.
    @Test func aNewBroadcastsMergeCheckReadsTheReviewPromptAndTheVerdicts() async throws {
        let prompts = OperatorMergeTests.Prompts()
        let m = try OperatorMergeTests().merging(answer: nil, runner: .answering("YES", receivePrompt: { prompts.append($0) }))
        m.world.workspace.mutate { state in
            state.updateRun(id: m.run.id) {
                $0.review = nil; $0.done = nil
                $0.taskSettings = OperatorServiceFixtures.taskSettings
                $0.questions = [OperatorQuestion(id: "rounds-A", text: "A is out of fix rounds.", task: m.task.id, askedAt: Date(timeIntervalSince1970: 0),
                                                 resolution: "The person accepted it as it is.", about: OperatorQuestion.fixRounds),
                                OperatorQuestion(id: "locale", text: "Which locale?", task: m.task.id, askedAt: Date(timeIntervalSince1970: 0),
                                                 resolution: "English.")]
            }
            state.updateOperated(m.task.id) {
                $0.reviewVerdicts = [ReviewVerdict(tab: "review", sha: m.sha, passed: true, round: 2, rounds: 3, critical: 0, important: 0,
                                                   minor: 1, summary: "One nit left.", at: Date(timeIntervalSince1970: 0))]
            }
        }
        m.host.update { $0.readiness = [.ready(head: m.sha)] }
        _ = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        let prompt = try #require(prompts.list.first)
        #expect(prompt.contains("The review prompt, as the person wrote it:\n\(OperatorServiceFixtures.taskSettings.review ?? "")"))
        #expect(prompt.contains("One nit left.") && prompt.contains(m.sha))
        #expect(prompt.contains("The person accepted it as it is.") && !prompt.contains("English."), "only its fix rounds' answers")
        #expect(!prompt.contains("The Review, as the person wrote it") && !prompt.contains("The Done, as the person wrote it"))
    }

    // -- a restart ---------------------------------------------------------------------------
    /// A check due when the helper attaches again (AiTerm's launch, or the daemon's restart) is said again, in one line
    /// with `reconnected`.
    @Test func aCheckDueWhenTheHelperAttachesWakesTheOperatorAgain() async throws {
        let (world, _) = try due()
        try await world.daemon.received("session.deliver")
        world.controller.daemonAttached()
        try await world.daemon.received("session.deliver", count: 2)
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String
                == "[AiTerm] reconnected, and every task is done: check the goal with check_goal, call run_status")
    }

    /// A check due when its Operator comes back from offline is said again, in one line with `reconnected`.
    @Test func aCheckDueWhenItsOperatorComesBackWakesItAgain() async throws {
        let (world, run) = try due()
        try await world.daemon.received("session.deliver")
        world.show([])
        #expect(world.run(run.id)?.state == .operatorOffline && world.run(run.id)?.goalCheckDue == true)
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        #expect(world.run(run.id)?.state == .active)
        try await world.daemon.received("session.deliver", count: 2)
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String
                == "[AiTerm] reconnected, and every task is done: check the goal with check_goal, call run_status")
    }

    // -- what the Oracle reads of each task ----------------------------------------------------
    @MainActor @Suite(.blocking) struct Results {
        let project = OperatorServiceFixtures.project()
        let git = GitRunner.hermetic()

        /// The JSON each task's result reads as, by its key.
        func results(_ world: OperatorWorld, _ run: OperatorRun) async throws -> [String: JSONValue] {
            let text = await world.controller.tools.goalResults(in: try #require(world.run(run.id)))
            let all = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).arrayValue ?? []
            return Dictionary(uniqueKeysWithValues: all.compactMap { result in result["key"]?.stringValue.map { ($0, result) } })
        }

        func commit(_ file: String, lines: Int, in repo: String) throws -> String {
            try (1...lines).map { "line \($0)" }.joined(separator: "\n").appending("\n")
                .write(toFile: repo + "/" + file, atomically: true, encoding: .utf8)
            try git.run(["add", file], in: repo)
            try git.run(["commit", "-q", "-m", "Add \(file)"], in: repo)
            return try git.run(["rev-parse", "HEAD"], in: repo)
        }

        func task(_ key: String, in run: OperatorRun, repo: String, sha: String, publication: TaskPublication? = nil) -> TaskItem {
            var task = OperatorServiceFixtures.task(in: run, project: project, key: key, state: .accepted, worktree: repo)
            task.baseBranch = "main"
            task.operated?.acceptance = TaskAcceptance(resultSHA: sha, prerequisiteSHAs: [], checkOutput: "ok", note: nil,
                                                       at: Date(timeIntervalSince1970: 0))
            task.operated?.publication = publication
            return task
        }

        /// A task merged by a merge commit here reads as that merge against its first parent; any other, merged or not,
        /// from where its branch left its base: a squash, a fast-forward on the host, a merge commit the host made that
        /// isn't here. A stat that comes out empty is left out, and the merge record carries only what the Oracle needs.
        @Test func eachTasksDiffStatIsItsOwnWorkMergedOrNot() async throws {
            let repo = try GitFixture.makeRepo(prefix: "op-goal-stat-")
            try git.run(["checkout", "-q", "-b", "feat/a"], in: repo)
            let a = try commit("a.txt", lines: 2, in: repo)
            try git.run(["checkout", "-q", "-b", "feat/b", "main"], in: repo)
            let b = try commit("b.txt", lines: 3, in: repo)
            try git.run(["checkout", "-q", "-b", "feat/c", "main"], in: repo)
            let c = try commit("c.txt", lines: 4, in: repo)
            try git.run(["checkout", "-q", "main"], in: repo)
            try git.run(["merge", "--no-ff", "-q", "-m", "Merge A", "feat/a"], in: repo)
            let mergedA = try git.run(["rev-parse", "HEAD"], in: repo)
            try git.run(["merge", "--squash", "-q", "feat/c"], in: repo)
            try git.run(["commit", "-q", "-m", "Squash C"], in: repo)
            let squashedC = try git.run(["rev-parse", "HEAD"], in: repo)
            // Merged on the host: E fast-forwarded there, F by a merge commit nothing fetched; main here moved for neither.
            try git.run(["checkout", "-q", "-b", "feat/e", "main"], in: repo)
            _ = try commit("e1.txt", lines: 1, in: repo)
            let e = try commit("e2.txt", lines: 1, in: repo)
            try git.run(["checkout", "-q", "-b", "feat/f", "main"], in: repo)
            let f = try commit("f.txt", lines: 5, in: repo)
            try git.run(["checkout", "-q", "main"], in: repo)

            let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1,
                                                  taskSettings: OperatorServiceFixtures.taskSettings, goal: OperatorServiceFixtures.goal)
            let tasks = [
                task("A", in: run, repo: repo, sha: a, publication: TaskPublication(mergeRequestURL: "https://git.example/mr/1", merged: true,
                                                                                    mergedSHA: mergedA, lastPushFailure: "hook said no")),
                task("B", in: run, repo: repo, sha: b),
                task("C", in: run, repo: repo, sha: c, publication: TaskPublication(merged: true, mergedSHA: squashedC)),
                // Merged by ancestry: no merge commit names it, and its accepted commit is in main already.
                task("D", in: run, repo: repo, sha: a, publication: TaskPublication(merged: true, landedSHA: a)),
                task("E", in: run, repo: repo, sha: e, publication: TaskPublication(merged: true, mergedSHA: e)),
                task("F", in: run, repo: repo, sha: f, publication: TaskPublication(merged: true, mergedSHA: String(repeating: "f", count: 40))),
            ]
            let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
            let results = try await results(world, run)
            #expect(results["A"]?["diffStat"] == "1 file changed, 2 insertions(+)")
            #expect(results["B"]?["diffStat"] == "1 file changed, 3 insertions(+)")
            #expect(results["C"]?["diffStat"] == "1 file changed, 4 insertions(+)")
            #expect(results["D"]?["diffStat"] == nil, "an empty stat is left out")
            #expect(results["E"]?["diffStat"] == "2 files changed, 2 insertions(+)", "a fast-forward is all the task's commits")
            #expect(results["F"]?["diffStat"] == "1 file changed, 5 insertions(+)", "a merge that isn't here")
            #expect(results["A"]?["merge"] == ["merged": true, "mergedSHA": .string(mergedA),
                                               "request": ["url": "https://git.example/mr/1", "state": "merged"]])
            #expect(results["B"]?["merge"] == nil)
        }

        /// A request's state is said only where the record can tell it: merged, merged with another head, or left for you.
        @Test func aRequestsStateIsSaidOnlyWhenTheRecordKnowsIt() async throws {
            let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1,
                                                  taskSettings: OperatorServiceFixtures.taskSettings, goal: OperatorServiceFixtures.goal)
            let url = "https://git.example/mr/2"
            let tasks = [
                task("G", in: run, repo: "", sha: "g", publication: TaskPublication(mergeRequestURL: url, mergedSHA: "other")),
                task("H", in: run, repo: "", sha: "h", publication: TaskPublication(mergeRequestURL: url)),
                task("I", in: run, repo: "", sha: "i", publication: TaskPublication(mergeRequestURL: url, leftForYou: true)),
            ]
            let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
            let results = try await results(world, run)
            #expect(results["G"]?["merge"] == ["mergedSHA": "other", "request": ["url": .string(url), "state": "mergedWithAnotherHead"]])
            #expect(results["H"]?["merge"] == ["request": ["url": .string(url)]])
            #expect(results["I"]?["merge"] == ["request": ["url": .string(url), "state": "leftForYou"]])
        }

        /// Reading the stats fetches nothing and reads every task at once, so many tasks stay inside the reply budget.
        @Test func manyTasksAreReadAtOnceWithNoFetch() async throws {
            let git = CountingGit()
            let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1,
                                                  taskSettings: OperatorServiceFixtures.taskSettings, goal: OperatorServiceFixtures.goal)
            let tasks = (1...6).map { task("T\($0)", in: run, repo: "/tmp/aiterm-goal-\($0)", sha: "sha\($0)") }
            let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks), git: git)
            let results = try await results(world, run)
            #expect(results.count == 6 && results.values.allSatisfy { $0["diffStat"] == "1 file changed, 1 insertion(+)" })
            #expect(!git.calls.contains { $0.contains("fetch") }, "\(git.calls)")
            #expect(git.most > 1, "the tasks were read one after another")
        }
    }
}

/// A git that answers every command with a one-line stat after a short wait, keeping each command and the most it ran
/// at once.
final class CountingGit: GitRunning, @unchecked Sendable {
    private let state = Mutex<(calls: [[String]], running: Int, most: Int)>(([], 0, 0))
    var calls: [[String]] { state.withLock { $0.calls } }
    var most: Int { state.withLock { $0.most } }
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        state.withLock { $0.calls.append(args); $0.running += 1; $0.most = max($0.most, $0.running) }
        defer { state.withLock { $0.running -= 1 } }
        Thread.sleep(forTimeInterval: 0.2)
        return " 1 file changed, 1 insertion(+)"
    }
}
