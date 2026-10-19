import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// M3's upstream replacement through `mark_task` (spec §8), on real checkouts.
@MainActor @Suite(.blocking) struct OperatorUpstreamTests {
    let git = GitRunner.hermetic()

    @discardableResult
    func commit(_ file: String, in path: String) throws -> String {
        try "change\n".write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
        try git.run(["add", file], in: path)
        try git.run(["commit", "-q", "-m", "Add \(file)"], in: path)
        return try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A published parent, PLUTO-230, accepted on `first` with request 11, and its code child PLUTO-231, which
    /// branched from `first`, committed `childTip` and is `childState` (accepted or published on it, or at work).
    struct Family {
        let world: OperatorWorld, run: OperatorRun, parent: TaskItem, child: TaskItem, first: String, childTip: String
    }

    func makeFamily(childState: OperatedState = .working, oracle: Bool = false, runState: OperatorRunState = .active,
                    runner: SecondOpinionRunner? = nil, milestone: OperatorMilestone = .m3) throws -> Family {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-upstream-"))
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude), projects: [project], state: runState)
        var parent = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-230", state: .working, end: .draftMR)
        parent = try TaskCreator.checkOutWorker(parent, project: project, start: "main", git: git).task
        let first = try commit("a.swift", in: parent.worktreePath)
        parent.operated?.state = .published
        parent.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        parent.operated?.acceptance = TaskAcceptance(resultSHA: first, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date())
        parent.operated?.publication = TaskPublication(pushedSHA: first, mergeRequestNumber: 11)
        var child = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-231", state: childState,
                                                 dependsOn: [TaskDependency(task: parent.id, kind: .code)], end: .draftMR)
        child = try TaskCreator.checkOutWorker(child, project: project, start: first, git: git).task
        child.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        let childTip = try commit("c.swift", in: child.worktreePath)
        if childState == .accepted || childState == .published {
            child.operated?.acceptance = TaskAcceptance(resultSHA: childTip, prerequisiteSHAs: [first], checkOutput: "ok", note: nil, at: Date())
        }
        if childState == .published { child.operated?.publication = TaskPublication(pushedSHA: childTip, mergeRequestNumber: 12) }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [parent, child])) { ports in
            ports.milestone = milestone
            if let runner { ports.secondOpinion = runner }
        }
        return Family(world: world, run: run, parent: parent, child: child, first: first, childTip: childTip)
    }

    func accept(_ key: String, _ sha: String, in family: Family, _ extra: [String: JSONValue] = [:]) async -> ToolAnswer {
        var arguments: [String: JSONValue] = ["task": .string(key), "outcome": "accepted", "sha": .string(sha), "checkOutput": "13 passed"]
        arguments.merge(extra) { $1 }
        return await family.world.call(family.run.id, "mark_task", .object(arguments))
    }

    @Test func aPublishedParentAcceptedAgainFlagsItsChildWhichIsAcceptedOnlyOnceItHoldsTheNewCommit() async throws {
        let family = try makeFamily()
        let (world, parent, child) = (family.world, family.parent, family.child)

        let second = try commit("b.swift", in: parent.worktreePath)
        let again = await accept("PLUTO-230", second, in: family)
        #expect(again.value?["state"] == "accepted")
        #expect(again.value?["revokedDependents"] == ["PLUTO-231"])
        #expect(world.task(parent.id)?.operated?.publication?.mergeRequestNumber == 11, "the request is kept")
        #expect(world.task(parent.id)?.operated?.acceptance?.resultSHA == second)
        #expect(world.task(child.id)?.operated?.flags.contains(.upstreamReplaced) == true)

        let early = await accept("PLUTO-231", family.childTip, in: family)
        #expect(early.message == "PLUTO-231 doesn't contain PLUTO-230's accepted commit \(second.prefix(7)) yet: have its worker rebase on it first.")
        #expect(world.task(child.id)?.operated?.state == .working)
        try git.run(["rebase", "-q", second], in: child.worktreePath)
        let rebased = try git.run(["rev-parse", "HEAD"], in: child.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let accepted = await accept("PLUTO-231", rebased, in: family)
        #expect(accepted.value?["state"] == "accepted")
        #expect(world.task(child.id)?.operated?.flags.contains(.upstreamReplaced) == false)
        #expect(world.task(child.id)?.operated?.acceptance?.prerequisiteSHAs == [second])
    }

    @Test func anAcceptedChildIsRevokedAndItsPublicationRefusesMidway() async throws {
        let family = try makeFamily(childState: .accepted)
        let (world, child) = (family.world, family.child)
        func recheck() -> String? {
            PublicationGuard.recheck(task: world.task(child.id), run: world.run(family.run.id), ownership: 0, acceptedSHA: family.childTip)
        }
        #expect(recheck() == nil, "a finish_task of the child may go on while its parent stands")

        let second = try commit("b.swift", in: family.parent.worktreePath)
        #expect(await accept("PLUTO-230", second, in: family).value?["revokedDependents"] == ["PLUTO-231"])
        #expect(world.task(child.id)?.operated?.state == .working && world.task(child.id)?.operated?.acceptance == nil)
        #expect(recheck() == PublicationGuard.changedMidway, "its step in flight stops before the next push, request or merge")
    }

    @Test func aRepeatOfTheAcceptedCommitChangesAndRevokesNothingEvenWhilePaused() async throws {
        let family = try makeFamily(childState: .accepted)
        let before = family.world.state
        let repeated = await accept("PLUTO-230", family.first, in: family)
        #expect(repeated.value?["state"] == "published")
        #expect(family.world.state == before)
        family.world.workspace.mutate { $0.updateRun(id: family.run.id) { $0.state = .paused; $0.intent = .paused } }
        let second = try commit("b.swift", in: family.parent.worktreePath)
        #expect(await accept("PLUTO-230", second, in: family).message == "The person paused this operation. Wait until they resume it.")
        #expect(family.world.task(family.child.id)?.operated?.state == .accepted)
    }

    @Test func aMergedParentOrOneMergedOnTheHostIsNotAcceptedAgain() async throws {
        let family = try makeFamily()
        let second = try commit("b.swift", in: family.parent.worktreePath)
        family.world.workspace.mutate { $0.updateOperated(family.parent.id) { $0.publication?.merged = true; $0.publication?.mergedSHA = "m" } }
        let refusal = "PLUTO-230 is merged already; a new commit needs a new task."
        #expect(await accept("PLUTO-230", second, in: family).message == refusal)
        family.world.workspace.mutate { $0.updateOperated(family.parent.id) { $0.publication?.merged = false } }
        #expect(await accept("PLUTO-230", second, in: family).message == refusal, "merged on the host with another head")
        #expect(family.world.task(family.parent.id)?.operated?.acceptance?.resultSHA == family.first)
        #expect(family.world.task(family.child.id)?.operated?.flags.isEmpty == true)
    }

    /// `waker.say` is the line for news the operator has not seen. A caller that was up to date is told by the
    /// answer's `revokedDependents`: the waker takes its own call's change as seen (`ownChange`), so no line follows.
    @Test func anOperatorBehindOnItsRunIsWokenOnceForAllTheDependentsItsReacceptRevoked() async throws {
        let family = try makeFamily(childState: .accepted)
        var second = family.world.state.tasks[1]
        second.id = UUID()
        second.operated?.key = "PLUTO-232"
        second.branch = "feat/pluto-232"
        family.world.workspace.mutate { $0.tasks.append(second) }
        family.world.show([OperatorServiceFixtures.session("op", tag: family.run.id)])
        // News the operator has not read yet, so its own call's change is not all it has to see.
        family.world.workspace.mutate { $0.updateOperated(second.id) { $0.state = .blocked; $0.blockedReason = "Needs a decision." } }
        try await family.world.daemon.received("session.deliver")
        await family.world.controller.waker.lastSend?.value

        let revoked = try commit("b.swift", in: family.parent.worktreePath)
        #expect(await accept("PLUTO-230", revoked, in: family).value?["revokedDependents"] == ["PLUTO-231", "PLUTO-232"])
        try await family.world.daemon.received("session.deliver", count: 2)
        await family.world.controller.waker.lastSend?.value
        let lines = family.world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        #expect(lines == ["[AiTerm] 1 update, call run_status",
                          "[AiTerm] PLUTO-231, PLUTO-232 needs a rebase: PLUTO-230 was accepted again, call run_status"],
                "the news, then one line for both dependents")
    }

    @Test func aCompleteOperationHoldingWorkAgainIsActive() async throws {
        let family = try makeFamily(childState: .published, runState: .complete)
        #expect(RunScheduler.isComplete(try #require(family.world.run(family.run.id)), in: family.world.state), "both drafts are out")
        let second = try commit("b.swift", in: family.parent.worktreePath)
        #expect(await accept("PLUTO-230", second, in: family).value?["revokedDependents"] == ["PLUTO-231"])
        #expect(family.world.task(family.parent.id)?.operated?.state == .accepted)
        #expect(family.world.task(family.child.id)?.operated?.state == .published, "its draft stays, flagged")
        #expect(family.world.run(family.run.id)?.state == .active)
    }

    /// The challenge gate wraps `mark_task`: a re-accept is challenged and acts only on the second call.
    @Test func aReacceptUnderHealthyDoubtActsOnlyOnTheCallAfterTheCritique() async throws {
        let family = try makeFamily(childState: .accepted, oracle: true, runner: .answering("Is the child rebased?"))
        let second = try commit("b.swift", in: family.parent.worktreePath)
        let first = await accept("PLUTO-230", second, in: family)
        #expect(first.value?["challenged"] == true && first.value?["critique"] == "Is the child rebased?")
        #expect(family.world.task(family.parent.id)?.operated?.acceptance?.resultSHA == family.first)
        #expect(family.world.task(family.child.id)?.operated?.state == .accepted)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        let acted = await accept("PLUTO-230", second, in: family, ["challengeId": .string(id), "challengeReply": "It will be."])
        #expect(acted.value?["revokedDependents"] == ["PLUTO-231"])
        #expect(family.world.task(family.parent.id)?.operated?.acceptance?.resultSHA == second)
        #expect(family.world.task(family.child.id)?.operated?.flags.contains(.upstreamReplaced) == true)
    }

    @Test func beforeM3ARepeatedAcceptWithAStartedDependentIsStillRefused() async throws {
        let family = try makeFamily(childState: .working, milestone: .m1)
        family.world.workspace.mutate { $0.updateOperated(family.parent.id) { $0.state = .accepted } }
        let second = try commit("b.swift", in: family.parent.worktreePath)
        #expect(await accept("PLUTO-230", second, in: family).message == OperatedTransitionError.reacceptAfterDependentStarted.description)
        #expect(family.world.task(family.child.id)?.operated?.flags.isEmpty == true)
    }

    @Test func aMergedTaskIsNotAcceptedAgain() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-upstream-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-240", state: .working, end: .merge)
        task = try TaskCreator.checkOutWorker(task, project: project, start: "main", git: git).task
        let first = try commit("a.swift", in: task.worktreePath)
        task.operated?.state = .published
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: Date())
        task.operated?.acceptance = TaskAcceptance(resultSHA: first, prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date())
        task.operated?.publication = TaskPublication(pushedSHA: first, mergeRequestNumber: 12, merged: true, mergedSHA: "m")
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        let second = try commit("b.swift", in: task.worktreePath)
        let refused = await world.call(run.id, "mark_task", ["task": "PLUTO-240", "outcome": "accepted", "sha": .string(second), "checkOutput": "ok"])
        #expect(refused.message == "PLUTO-240 is merged already; a new commit needs a new task.")
    }
}
