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

    /// A latch the test opens: an Oracle held by it is still judging until then, however long the test takes, and
    /// one opened before it asks is not held at all.
    actor Gate {
        private var isOpen = false
        private var held: [CheckedContinuation<Void, Never>] = []
        func wait() async { if !isOpen { await withCheckedContinuation { held.append($0) } } }
        func open() { isOpen = true; held.forEach { $0.resume() }; held = [] }
    }

    /// An Oracle that answers `answer` once `gate` is open (at once with none), or fails when `answer` is nil,
    /// keeping each prompt.
    static func oracle(_ answer: String?, gate: Gate? = nil, prompts: Prompts) -> SecondOpinionRunner {
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
                 answer: String?, gate: Gate? = nil, budget: Duration = .seconds(60)) throws -> Merging {
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
            ports.secondOpinion = Self.oracle(answer, gate: gate, prompts: prompts)
            ports.challengeReplyBudget = budget
        })
        world.live.sessions = [OperatorServiceFixtures.session("operator", tag: run.id), OperatorServiceFixtures.session("worker", tag: task.id)]
        return Merging(world: world, run: run, task: task, host: host, sha: fixture.sha, prompts: prompts)
    }

    func publication(_ m: Merging) -> TaskPublication? { m.world.task(m.task.id)?.operated?.publication }

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

    @Test func anOracleThatDoesNotAnswerRefusesTheMerge() async throws {
        let m = try merging(answer: nil)
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(answer.message == "The Oracle didn’t answer, so AiTerm didn’t merge A. AiTerm recorded it on the task; call finish_task again.")
        #expect(publication(m)?.problem == "The Oracle didn’t answer whether the conditions to merge hold.")
        #expect(m.host.log.isEmpty)
    }

    /// An Oracle still judging when the reply is due answers pending; the call again with its id acts on the yes.
    @Test func aPendingVerdictIsCalledAgainWithItsId() async throws {
        let gate = Gate()
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
        #expect(off.world.run(off.run.id)?.leftForYou == ["Merge A: the Merge slice is off."])
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
        let gate = Gate()
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
        let gate = Gate()
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
