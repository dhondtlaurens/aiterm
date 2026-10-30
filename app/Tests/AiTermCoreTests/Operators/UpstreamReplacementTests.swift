import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// M3 lifts M1's "no re-accept once a dependent started": a parent accepted again on a new commit
/// revokes what was built on the old one (spec §8).
@Suite struct UpstreamReplacementTests {
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    func acceptance(_ sha: String, prerequisites: [String] = []) -> TaskAcceptance {
        TaskAcceptance(resultSHA: sha, prerequisiteSHAs: prerequisites, checkOutput: "ok", note: nil, at: at)
    }

    /// A parent accepted on `old`, and a code dependent in `state`.
    func family(_ childState: OperatedState, childPrerequisites: [String] = ["old"]) -> (world: OperatedWorld, parent: UUID, child: UUID) {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("PLUTO-230", run: run, state: .accepted, end: .draftMR, acceptedSHA: "old")
        let child = world.addTask("PLUTO-231", run: run, state: childState, end: .draftMR,
                                  dependsOn: [TaskDependency(task: parent, kind: .code)],
                                  acceptedSHA: childState == .accepted ? "child" : nil)
        world.state.updateOperated(child) { if $0.acceptance != nil { $0.acceptance?.prerequisiteSHAs = childPrerequisites } }
        return (world, parent, child)
    }

    @Test func anAcceptedDependentLosesItsAcceptanceAndWorksAgain() throws {
        let made = family(.accepted)
        var world = made.world
        world.state.updateOperated(made.parent) { $0.acceptanceWorktreeFingerprint = "parent content" }
        world.state.updateOperated(made.child) { $0.acceptanceWorktreeFingerprint = "child content" }
        let changed = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        #expect(changed == [made.child])
        #expect(world.operated(made.parent)?.acceptance?.resultSHA == "new")
        #expect(world.operated(made.child)?.state == .working)
        #expect(world.operated(made.child)?.acceptance == nil)
        #expect(world.operated(made.parent)?.acceptanceWorktreeFingerprint == nil)
        #expect(world.operated(made.child)?.acceptanceWorktreeFingerprint == nil)
        #expect(world.operated(made.child)?.flags.contains(.upstreamReplaced) == true)
    }

    @Test func aWorkingDependentIsFlaggedOnly() throws {
        let made = family(.working)
        var world = made.world
        #expect(try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state) == [made.child])
        #expect(world.operated(made.child)?.state == .working)
        #expect(world.operated(made.child)?.flags.contains(.upstreamReplaced) == true)
    }

    @Test func anUnstartedDependentOrAnOrderOneIsLeftAlone() throws {
        let made = family(.queued)
        var world = made.world
        let ordered = world.addTask("PLUTO-232", run: world.state.runs[0].id, state: .accepted,
                                    dependsOn: [TaskDependency(task: made.parent, kind: .order)], acceptedSHA: "o")
        #expect(try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state).isEmpty)
        #expect(world.operated(made.child)?.flags.isEmpty == true)
        #expect(world.operated(ordered)?.state == .accepted)
    }

    @Test func aDependentAlreadyOnTheNewCommitIsLeftAlone() throws {
        let made = family(.accepted, childPrerequisites: ["new"])
        var world = made.world
        #expect(try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state).isEmpty)
        #expect(world.operated(made.child)?.state == .accepted)
    }

    @Test func theSameCommitAgainChangesNothing() throws {
        let made = family(.accepted)
        var world = made.world
        let before = world.state
        #expect(try UpstreamReplacement.reaccept(made.parent, as: acceptance("old"), in: &world.state).isEmpty)
        #expect(world.state == before)
    }

    @Test func aPublishedDraftIsAcceptedAgainAndKeepsItsRequest() throws {
        let made = family(.working)
        var world = made.world
        world.state.updateOperated(made.parent) { $0.state = .published; $0.publication = TaskPublication(pushedSHA: "old", mergeRequestNumber: 11) }
        _ = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        #expect(world.operated(made.parent)?.state == .accepted, "finish_task pushes the new commit to the same request")
        #expect(world.operated(made.parent)?.publication?.mergeRequestNumber == 11)
    }

    @Test func aMergedOrUnacceptedTaskIsNotAcceptedAgain() {
        let made = family(.working)
        var world = made.world
        world.state.updateOperated(made.parent) { $0.publication = TaskPublication(pushedSHA: "old", mergeRequestNumber: 11, merged: true, mergedSHA: "m") }
        #expect(throws: UpstreamReplacement.Refusal.merged("PLUTO-230 is merged already; a new commit needs a new task.")) {
            try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        }
        #expect(throws: UpstreamReplacement.Refusal.notAccepted("PLUTO-231 isn't accepted; mark it accepted instead.")) {
            try UpstreamReplacement.reaccept(made.child, as: acceptance("new"), in: &world.state)
        }
    }

    @Test func aRequestTheHostMergedWithAnotherHeadIsNotAcceptedAgainEither() {
        let made = family(.working)
        var world = made.world
        world.state.updateOperated(made.parent) {
            $0.publication = TaskPublication(pushedSHA: "old", mergeRequestNumber: 11, merged: false, mergedSHA: "m", mergedHead: "other")
        }
        let before = world.state
        #expect(throws: UpstreamReplacement.Refusal.merged("PLUTO-230 is merged already; a new commit needs a new task.")) {
            try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        }
        #expect(world.state == before)
    }

    @Test func aReplacedDependentIsAcceptedOnlyOnceItContainsTheNewCommit() throws {
        let made = family(.accepted)
        var world = made.world
        _ = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        let task = try #require(world.state.tasks.first { $0.id == made.child })
        #expect(UpstreamReplacement.acceptRefusal(for: task, in: world.state, contains: { _ in false })
                == "PLUTO-231 doesn't contain PLUTO-230's accepted commit new yet: have its worker rebase on it first.")
        #expect(UpstreamReplacement.acceptRefusal(for: task, in: world.state, contains: { $0 == "new" }) == nil)
    }

    @Test func whatIsBuiltOnARevokedDependentIsReplacedToo() throws {
        let made = family(.accepted)
        var world = made.world
        let grandchild = world.addTask("PLUTO-232", run: world.state.runs[0].id, state: .accepted, end: .draftMR,
                                       dependsOn: [TaskDependency(task: made.child, kind: .code)], acceptedSHA: "grand")
        world.state.updateOperated(grandchild) { $0.acceptance?.prerequisiteSHAs = ["child"] }
        let changed = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        #expect(changed == [made.child, grandchild])
        #expect(world.operated(grandchild)?.state == .working && world.operated(grandchild)?.acceptance == nil)
        #expect(world.operated(grandchild)?.flags.contains(.upstreamReplaced) == true)
    }

    @Test func aDependentReachedTwoWaysIsChangedOnce() throws {
        let made = family(.working)
        var world = made.world
        let run = world.state.runs[0].id
        let other = world.addTask("PLUTO-233", run: run, state: .working, end: .draftMR,
                                  dependsOn: [TaskDependency(task: made.parent, kind: .code)])
        let both = world.addTask("PLUTO-234", run: run, state: .accepted, end: .draftMR,
                                 dependsOn: [TaskDependency(task: made.child, kind: .code), TaskDependency(task: other, kind: .code)],
                                 acceptedSHA: "both")
        world.state.updateOperated(both) { $0.acceptance?.prerequisiteSHAs = ["child"] }
        let changed = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        #expect(changed.filter { $0 == both }.count == 1)
        #expect(Set(changed) == [made.child, other, both])
    }

    @Test func aReplacedTaskWaitsForItsCodeParentToBeAccepted() throws {
        let made = family(.working)
        for parentState in [OperatedState.working, .blocked, .queued] {
            var world = made.world
            world.state.updateOperated(made.parent) { $0.state = parentState; $0.acceptance = nil }
            world.state.updateOperated(made.child) { $0.flags.insert(.upstreamReplaced) }
            let task = try #require(world.state.task(id: made.child))
            let reason = UpstreamReplacement.acceptRefusal(for: task, in: world.state, contains: { _ in
                Issue.record("No ancestry check without an accepted parent")
                return true
            })
            #expect(reason == "PLUTO-231 cannot be accepted until PLUTO-230, its code parent, is accepted.")
        }
    }

    @Test func aGrandchildCannotBeAcceptedBeforeItsRevokedParent() throws {
        let made = family(.accepted)
        var world = made.world
        let grandchild = world.addTask("PLUTO-232", run: world.state.runs[0].id, state: .accepted,
                                      dependsOn: [TaskDependency(task: made.child, kind: .code)], acceptedSHA: "grand")
        _ = try UpstreamReplacement.reaccept(made.parent, as: acceptance("new"), in: &world.state)
        let task = try #require(world.state.task(id: grandchild))
        #expect(UpstreamReplacement.acceptRefusal(for: task, in: world.state, contains: { _ in true })
                == "PLUTO-232 cannot be accepted until PLUTO-231, its code parent, is accepted.")
        world.state.updateOperated(made.child) { $0.state = .accepted; $0.acceptance = acceptance("rebased") }
        #expect(UpstreamReplacement.acceptRefusal(for: task, in: world.state, contains: { $0 == "rebased" }) == nil)
    }
}
