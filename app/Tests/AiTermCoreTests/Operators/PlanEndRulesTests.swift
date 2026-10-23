import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// M3's ends in a plan: draft MR and merge are allowed, and a stacked task's end must be one its
/// parent's end can carry.
@Suite struct PlanEndRulesTests {
    func plan(parent: TaskEnd, child: TaskEnd) -> [TaskItem] {
        var world = OperatedWorld()
        let run = world.addRun(.planning)
        let p = world.addTask("PLUTO-230", run: run, state: .planned, end: parent)
        world.addTask("PLUTO-231", run: run, state: .planned, end: child, dependsOn: [TaskDependency(task: p, kind: .code)])
        return world.state.tasks
    }

    @Test func everyEndIsAllowedOnItsOwn() {
        var world = OperatedWorld()
        let run = world.addRun(.planning)
        for (key, end) in [("A-1", TaskEnd.commit), ("A-2", .draftMR), ("A-3", .merge)] {
            world.addTask(key, run: run, state: .planned, end: end)
        }
        #expect(PlanEndRules.refusal(for: world.state.tasks) == nil)
    }

    /// A revision's child is held to its parent from an earlier, approved revision (spec §13).
    @Test func aChildInALaterRevisionIsCheckedAgainstItsEarlierParent() throws {
        var world = OperatedWorld()
        let run = world.addRun(.active)   // revision 1 submitted and approved; 2 is open
        let parent = world.addTask("PLUTO-230", run: run, state: .accepted, end: .commit, acceptedSHA: "4f2a91c")
        let child = world.addTask("PLUTO-231", run: run, state: .planned, end: .draftMR,
                                  dependsOn: [TaskDependency(task: parent, kind: .code)])
        world.state.updateOperated(child) { $0.revision = 2; $0.firstRevision = 2 }
        let why = try #require(PlanEndRules.refusal(for: world.state.tasks))
        #expect(throws: PlanRevision.Failure.endsDisagree(why)) {
            try PlanRevision.submit(2, run: run, in: &world.state)
        }
        #expect(world.state.runs[0].planRevision == 1, "nothing submitted")
        #expect(PlanRevision.Failure.endsDisagree(why).description == why)
        world.state.updateOperated(child) { $0.end = .commit }
        #expect(try PlanRevision.submit(2, run: run, in: &world.state).revision == 2)
    }

    @Test func aStackedEndMustBeOneItsParentCanCarry() {
        #expect(PlanEndRules.refusal(for: plan(parent: .draftMR, child: .draftMR)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .merge, child: .merge)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .merge, child: .draftMR)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .commit, child: .commit)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .draftMR, child: .commit)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .commit, child: .draftMR))
                == "PLUTO-231 ends in a draft MR but builds on PLUTO-230, which ends in a commit: its request would target a branch that is never pushed. Give PLUTO-230 a draft MR or a merge too, or end PLUTO-231 in a commit.")
        #expect(PlanEndRules.refusal(for: plan(parent: .commit, child: .merge))
                == "PLUTO-231 ends in a merge but builds on PLUTO-230, which ends in a commit: its request would target a branch that is never pushed. Give PLUTO-230 a draft MR or a merge too, or end PLUTO-231 in a commit.")
        #expect(PlanEndRules.refusal(for: plan(parent: .draftMR, child: .merge))
                == "PLUTO-231 ends in a merge but builds on PLUTO-230, which ends in a draft MR and never merges. Merge PLUTO-230 too, or end PLUTO-231 in a draft MR.")
    }

    /// A local merge pushes nothing, so no request builds on it; and it merges its parent's commits with its own, so it
    /// builds only on a parent that never waits on a review of its request.
    @Test func aLocalMergeIsStackedOnlyWhereItsParentCanCarryIt() {
        #expect(PlanEndRules.refusal(for: plan(parent: .mergeLocal, child: .mergeLocal)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .commit, child: .mergeLocal)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .mergeLocal, child: .commit)) == nil)
        #expect(PlanEndRules.refusal(for: plan(parent: .mergeLocal, child: .draftMR))
                == "PLUTO-231 ends in a draft MR but builds on PLUTO-230, which ends in a local merge: its request would target a branch that is never pushed. Give PLUTO-230 a draft MR or a merge, or end PLUTO-231 in a local merge too.")
        #expect(PlanEndRules.refusal(for: plan(parent: .mergeLocal, child: .merge))
                == "PLUTO-231 ends in a merge but builds on PLUTO-230, which ends in a local merge: its request would target a branch that is never pushed. Give PLUTO-230 a draft MR or a merge, or end PLUTO-231 in a local merge too.")
        #expect(PlanEndRules.refusal(for: plan(parent: .draftMR, child: .mergeLocal))
                == "PLUTO-231 ends in a local merge but builds on PLUTO-230, which ends in a draft MR and never merges. Merge PLUTO-230 too, or end PLUTO-231 in a draft MR.")
    }
}
