import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The Merge slice's Oracle verdict (spec §5): with the Oracle on, a finish_task that would merge goes ahead only
/// on its yes that the conditions written in the Review and the Done hold. A no, or no answer, refuses the merge
/// and is recorded on the task.
@MainActor @Suite(.blocking) struct OperatorMergeTests {
    struct Merging {
        let world: OperatorWorld, run: OperatorRun, task: TaskItem, host: FakeMergeHost, sha: String, prompts: Prompts
    }

    /// The prompts the Oracle was given, in order.
    final class Prompts: Sendable {
        private let all = Mutex<[String]>([])
        var list: [String] { all.withLock { $0 } }
        func append(_ prompt: String) { all.withLock { $0.append(prompt) } }
    }

    /// An Oracle that answers `answer` once `gate` is open (at once with none), or fails when `answer` is nil,
    /// keeping each prompt.
    static func oracle(_ answer: String?, gate: OracleGate? = nil, prompts: Prompts) -> SecondOpinionRunner {
        SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { _, arguments, _, _, _ in
            if let at = arguments.firstIndex(of: "-p"), at + 1 < arguments.count { prompts.append(arguments[at + 1]) }
            await gate?.wait()
            guard let answer else { return ProcessOutput(status: 1, stdout: "", stderr: "boom", timedOut: false) }
            let json = String(decoding: try JSONEncoder().encode(["result": answer]), as: UTF8.self)
            return ProcessOutput(status: 0, stdout: json, stderr: "", timedOut: false)
        })
    }

    /// A broadcast with the Oracle on and `slices` frozen, its Review and Done written, and one accepted task `A`
    /// ending in `end` on the branch of a repository with an origin.
    func merging(end: TaskEnd = .merge, slices: Slices = Slices(merge: true), review: String? = "Merge after Jan approves.",
                 answer: String?, gate: OracleGate? = nil, budget: Duration = .seconds(60), runner: SecondOpinionRunner? = nil) throws -> Merging {
        let fixture = try GitFixture.withOrigin(branch: "feat/a")
        let project = OperatorServiceFixtures.project(path: fixture.path)
        var profile = OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude)
        profile.slices = slices
        var run = OperatorServiceFixtures.run(profile, projects: [project], state: .active, planRevision: 1)
        run.review = review
        run.done = "Merged once the pipeline is green."
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .accepted, worktree: fixture.path,
                                                branch: "feat/a", end: end)
        task.baseBranch = "main"
        task.operated?.acceptance = TaskAcceptance(resultSHA: fixture.sha, prerequisiteSHAs: [], checkOutput: "12 passed", note: nil,
                                                   at: Date(timeIntervalSince1970: 0))
        let host = FakeMergeHost(), prompts = Prompts()
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), adjust: { ports in
            ports.publisher = { _ in host }
            ports.secondOpinion = runner ?? Self.oracle(answer, gate: gate, prompts: prompts)
            ports.challengeReplyBudget = budget
        })
        world.live.sessions = [OperatorServiceFixtures.session("operator", tag: run.id), OperatorServiceFixtures.session("worker", tag: task.id)]
        return Merging(world: world, run: run, task: task, host: host, sha: fixture.sha, prompts: prompts)
    }

    func publication(_ m: Merging) -> TaskPublication? { m.world.task(m.task.id)?.operated?.publication }

    @Test(arguments: [true, false]) func mergeEndConditionsJudgeTheAcceptedCommitBeforePublication(approved: Bool) async throws {
        let prompts = Prompts()
        let runner = SecondOpinionRunner.answering(approved ? "YES\nJan approved it." : "NO\nJan has not approved it.",
                                                    receivePrompt: { prompts.append($0) })
        let m = try merging(answer: nil, runner: runner)
        m.world.workspace.mutate { state in
            state.updateRun(id: m.run.id) { $0.done = "Pushed, request opened, merged to main, pipeline green." }
        }
        m.host.update { $0.readiness = [.ready(head: m.sha)] }
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        let prompt = try #require(prompts.list.first)
        #expect(prompt.contains("The act: merge the accepted commit \(m.sha) for task A."))
        #expect(prompt.contains("The merge, push and request described as end states in Done are effects of this act, not missing prerequisites."))
        #expect(prompt.contains("Judge the remaining conditions the person wrote, including tests, pipeline health and required reviews."))
        #expect(prompt.contains("An accepted or inReview state, or merged false, describes the state before this act and is not a reason to answer NO."))
        #expect(!prompt.contains("hold now"))
        #expect(prompt.contains("Merge after Jan approves.") && prompt.contains("Pushed, request opened, merged to main, pipeline green."))
        #expect(prompt.contains("Answer YES or NO alone on the first line"))
        if approved {
            #expect(answer.value?["result"] == "waitingToMerge")
            m.world.workspace.mutate { state in
                state.updateOperated(m.task.id) {
                    let since = $0.publication?.readySince
                    $0.publication?.readySince = since?.addingTimeInterval(-OperatorTiming.mergePoll - 1)
                }
            }
            let merged = await m.world.call(m.run.id, "finish_task", ["task": "A"])
            #expect(merged.value?["result"] == "published")
            #expect(publication(m)?.merged == true && publication(m)?.conditionsHeld == m.sha)
            #expect(m.host.log.contains("merge 12 at \(m.sha)"))
        } else {
            #expect(answer.message?.contains("Jan has not approved it.") == true)
            #expect(publication(m)?.conditionsHeld == nil && publication(m)?.merged != true)
            #expect(m.host.log.isEmpty)
        }
    }

    @Test func theOraclesNoRefusesTheMergeAndSaysWhyOnTheTask() async throws {
        let m = try merging(answer: "NO. Jan hasn't approved it yet.")
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(answer.message == "The Oracle judged that the conditions to merge A don’t hold yet: Jan hasn't approved it yet. "
                + "AiTerm recorded it on the task; call finish_task again once they hold.")
        #expect(publication(m)?.problem == "The Oracle judged that the conditions to merge don’t hold yet: Jan hasn't approved it yet.")
        #expect(publication(m)?.conditionsHeld == nil)
        #expect(m.host.log.isEmpty, "nothing pushed, opened or merged")
        let prompt = try #require(m.prompts.list.first)
        #expect(prompt.contains("Merge after Jan approves.") && prompt.contains("Merged once the pipeline is green."))
        #expect(m.world.task(m.task.id)?.operated?.state == .accepted)
    }

    @Test func theOraclesYesLetsTheMergeGoOn() async throws {
        let m = try merging(answer: "YES. Jan approved it.")
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(answer.value?["result"] == "waitingToMerge")
        #expect(publication(m)?.conditionsHeld == m.sha)
        #expect(m.host.log.contains { $0.hasPrefix("readiness") })
        // Asked again while it waits, the yes for the same commit stands: the Oracle is not asked twice.
        _ = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(m.prompts.list.count == 1)
    }

    @Test func anOracleThatDoesNotAnswerLetsTheMergeProceedUnchallenged() async throws {
        let m = try merging(answer: nil)
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(answer.value?["result"] == "waitingToMerge")
        #expect(publication(m)?.conditionsHeld == m.sha && publication(m)?.problem == nil)
        #expect(m.world.run(m.run.id)?.decisions.last?.why == "The Oracle didn’t answer, so the merge went ahead unchallenged.")
        #expect(m.host.log.contains { $0.hasPrefix("readiness") })
    }

    /// An Oracle still judging when the reply is due answers pending; the call again with its id acts on the yes.
    @Test func aPendingVerdictIsCalledAgainWithItsId() async throws {
        let gate = OracleGate()
        let m = try merging(answer: "YES.", gate: gate, budget: .milliseconds(10))
        let first = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(first.value?["pending"] == true)
        #expect(first.value?["note"]?.stringValue == "Nothing was done yet. The Oracle is still judging whether the conditions to merge A hold: "
                + "call finish_task again with this challengeId in a little while.")
        let id = try #require(first.value?["challengeId"]?.stringValue)
        #expect(m.host.log.isEmpty)
        await gate.open()
        await m.world.controller.tools.lastChallenge?.value
        let second = await m.world.call(m.run.id, "finish_task", ["task": "A", "challengeId": .string(id)])
        #expect(second.value?["result"] == "waitingToMerge")
        #expect(publication(m)?.conditionsHeld == m.sha)
    }

    /// Nothing merges, so nothing is asked: a draft end, a merge end going into review, a local merge's slice off.
    @Test func onlyACallThatWouldMergeAsksTheOracle() async throws {
        let draft = try merging(end: .draftMR, answer: "NO.")
        #expect(await draft.world.call(draft.run.id, "finish_task", ["task": "A"]).value?["result"] == "published")
        #expect(draft.prompts.list.isEmpty)

        let off = try merging(end: .mergeLocal, slices: .none, answer: "NO.")
        let refused = await off.world.call(off.run.id, "finish_task", ["task": "A"])
        #expect(refused.value?["result"] == "refused" && refused.value?["reason"]?.stringValue == "The Merge slice is off for this broadcast.")
        #expect(off.world.run(off.run.id)?.leftForYou.count == 1)
        #expect(publication(off)?.leftForYou == true)
        #expect(RunScheduler.isComplete(off.world.run(off.run.id)!, in: off.world.state))
        #expect(off.prompts.list.isEmpty)

        let reviewed = try merging(slices: Slices(review: true, merge: true), answer: "YES.")
        #expect(await reviewed.world.call(reviewed.run.id, "finish_task", ["task": "A"]).value?["result"] == "inReview")
        #expect(reviewed.prompts.list.isEmpty, "it goes into review; nothing merges yet")
        // The call that ends the review goes on to the merge: that one is asked.
        #expect(await reviewed.world.call(reviewed.run.id, "finish_task", ["task": "A"]).value?["result"] == "waitingToMerge")
        #expect(reviewed.prompts.list.count == 1)
    }

    /// The task accepted again on another commit while the Oracle judged: its yes was for the old commit, so it
    /// neither merges nor counts for the new one.
    func reaccept(_ m: Merging) {
        m.world.workspace.mutate { state in
            state.updateOperated(m.task.id) { $0.acceptance?.resultSHA = "5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed" }
        }
    }

    static let acceptedAgain = "A was accepted again on another commit while the Oracle judged its merge: call finish_task again without challengeId."

    @Test func aReacceptWhileTheOracleJudgesWithinTheReplyIsRefused() async throws {
        let gate = OracleGate()
        let m = try merging(answer: "YES.", gate: gate)
        let call = Task { await m.world.call(m.run.id, "finish_task", ["task": "A"]) }
        #expect(await eventually(describing: "the Oracle asked") { m.prompts.list.count == 1 })
        reaccept(m)
        await gate.open()
        let answer = await call.value
        #expect(answer.message == Self.acceptedAgain)
        #expect(publication(m)?.conditionsHeld == nil)
        #expect(m.host.log.isEmpty)
    }

    @Test func aReacceptWhileTheOracleIsPendingIsRefused() async throws {
        let gate = OracleGate()
        let m = try merging(answer: "YES.", gate: gate, budget: .milliseconds(10))
        let first = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        let id = try #require(first.value?["challengeId"]?.stringValue)
        reaccept(m)
        await gate.open()
        await m.world.controller.tools.lastChallenge?.value
        let second = await m.world.call(m.run.id, "finish_task", ["task": "A", "challengeId": .string(id)])
        #expect(second.message == Self.acceptedAgain)
        #expect(publication(m)?.conditionsHeld == nil)
        #expect(m.host.log.isEmpty)
    }
}

extension OperatorMergeTests {
    @Test func aMissingOracleAlsoLetsTheMergeProceedUnchallenged() async throws {
        let m = try merging(answer: nil)
        let id = "lost-oracle"
        m.world.workspace.mutate { state in
            state.updateRun(id: m.run.id) { $0.challenges.append(ChallengeRecord(id: id, tool: "finish_task", kind: .veto,
                askedArguments: OperatorToolHandler.invocation(ToolCall(tool: "finish_task", arguments: ["task": "A"])),
                askedSHA: m.sha, askedAt: Date())) }
        }
        let other = await m.world.call(m.run.id, "finish_task", ["task": "B", "challengeId": .string(id)])
        #expect(other.message == "Challenge \(id) was asked about another finish_task. Call again without challengeId.",
                "an unanswered challenge proceeds only for the call it was asked about")
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A", "challengeId": .string(id)])
        #expect(answer.value?["result"] == "waitingToMerge")
        #expect(m.world.run(m.run.id)?.decisions.last?.why == "The Oracle didn’t answer, so the merge went ahead unchallenged.")
    }
}

extension OperatorMergeTests {
    @Test func aMissingAgentAndATimedOutOracleProceedUnchallenged() async throws {
        let timedOut = SecondOpinionRunner(locate: { _ in "/fake/oracle" }, run: { _, _, _, _, _ in
            ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true)
        })
        for runner in [SecondOpinionRunner.unavailable, timedOut] {
            let m = try merging(answer: nil, runner: runner)
            #expect(await m.world.call(m.run.id, "finish_task", ["task": "A"]).value?["result"] == "waitingToMerge")
            #expect(publication(m)?.conditionsHeld == m.sha)
            #expect(m.world.run(m.run.id)?.decisions.last?.why == "The Oracle didn’t answer, so the merge went ahead unchallenged.")
        }
    }
}
