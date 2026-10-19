import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct PublicationGuardTests {
    let sha = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"

    func world(end: TaskEnd = .draftMR, state: OperatedState = .accepted, run runState: OperatorRunState = .active)
        -> (world: OperatedWorld, task: UUID, run: UUID) {
        var world = OperatedWorld()
        let run = world.addRun(runState)
        let task = world.addTask("PLUTO-231", run: run, state: state, end: end, branch: "feat/pluto-231", acceptedSHA: sha)
        return (world, task, run)
    }

    func refusal(_ w: OperatedWorld, _ task: UUID, _ run: UUID, parent: UUID? = nil, tip: String?? = .none,
                 defaultBranch: String = "main") -> String? {
        let item = w.state.tasks.first { $0.id == task }!
        let parentItem = parent.flatMap { id in w.state.tasks.first { $0.id == id } }
        return PublicationGuard.refusal(task: item, run: w.state.runs.first { $0.id == run }!, parent: parentItem,
                                        defaultBranch: defaultBranch, branchTip: tip ?? sha)
    }

    @Test func anAcceptedDraftOrMergeTaskOnItsOwnBranchPasses() {
        for end in [TaskEnd.draftMR, .merge] {
            let (w, task, run) = world(end: end)
            #expect(refusal(w, task, run) == nil)
        }
        let (w, task, run) = world(run: .complete)
        #expect(refusal(w, task, run) == nil, "a complete operation still publishes")
    }

    @Test func aCommitEndHasNothingToFinish() {
        let (w, task, run) = world(end: .commit)
        #expect(refusal(w, task, run) == "PLUTO-231 ends in a commit: its plan opens no merge request, so there is nothing to finish.")
    }

    @Test func anOperationThatIsNotRunningPublishesNothing() {
        for (state, line) in [(OperatorRunState.paused, "The operation is paused; nothing is published until it runs again."),
                              (.operatorOffline, "The operator is offline; nothing is published until the operation resumes."),
                              (.stopped, "The operation was stopped; it publishes nothing."),
                              (.planning, "The operation's plan hasn't been submitted yet.")] {
            let (w, task, run) = world(run: state)
            #expect(refusal(w, task, run) == line)
        }
    }

    @Test func aTakenOverTaskIsNotPublished() {
        var (w, task, run) = world()
        w.update(task) { $0.takenOver = true }
        #expect(refusal(w, task, run) == "You've taken PLUTO-231 over; it is published only once you hand it back.")
    }

    @Test func onlyAnAcceptedTaskIsFinished() {
        let (w, task, run) = world(state: .working)
        #expect(refusal(w, task, run) == "Only an accepted task is finished; PLUTO-231 is working.")
    }

    @Test func aReplacedUpstreamBlocksPublication() {
        var (w, task, run) = world()
        w.update(task) { $0.flags.insert(.upstreamReplaced) }
        #expect(refusal(w, task, run) == "PLUTO-231's parent was accepted again on another commit: have its worker rebase, accept it again, then finish it.")
    }

    @Test func theDefaultBranchIsNeverPublished() {
        let (w, task, run) = world()
        #expect(refusal(w, task, run, defaultBranch: "feat/pluto-231") == "PLUTO-231's branch is the default branch, which AiTerm never pushes to.")
    }

    @Test func theDefaultBranchIsComparedCaseFoldedAndWithoutRefsHeads() {
        let (w, task, run) = world()
        for spelling in ["Feat/PLUTO-231", "refs/heads/feat/pluto-231"] {
            #expect(refusal(w, task, run, defaultBranch: spelling) == "PLUTO-231's branch is the default branch, which AiTerm never pushes to.", "\(spelling)")
        }
    }

    @Test func aTaskWithNoBranchIsRefused() {
        var (w, task, run) = world()
        w.state.tasks[0].branch = ""
        #expect(refusal(w, task, run) == "PLUTO-231's branch is the default branch, which AiTerm never pushes to.")
    }

    @Test func aBranchThatMovedOrWentIsRefused() {
        let (w, task, run) = world()
        #expect(refusal(w, task, run, tip: .some("0123456789abcdef")) == "feat/pluto-231 moved past the accepted commit 4f2a91c (it is at 0123456 now): accept it again first.")
        #expect(refusal(w, task, run, tip: .some(nil)) == "feat/pluto-231 moved past the accepted commit 4f2a91c (it is gone): accept it again first.")
    }

    @Test func aStackedTaskWaitsForItsParentsRequest() {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("PLUTO-230", run: run, state: .accepted, end: .draftMR, acceptedSHA: "aaa")
        let child = world.addTask("PLUTO-231", run: run, state: .accepted, end: .draftMR,
                                  dependsOn: [TaskDependency(task: parent, kind: .code)], branch: "feat/pluto-231", acceptedSHA: sha)
        #expect(refusal(world, child, run, parent: parent) == "PLUTO-231 builds on PLUTO-230, whose branch its request targets: finish PLUTO-230 first.")
        world.update(parent) { $0.publication = TaskPublication(pushedSHA: "aaa", mergeRequestNumber: 11) }
        #expect(refusal(world, child, run, parent: parent) == nil)
    }

    @Test func aTaskWithoutAnOperatorIsNotFinished() {
        var (w, task, run) = world()
        w.state.tasks[0].operated = nil
        #expect(refusal(w, task, run) == PublicationGuard.notOperated)
    }

    /// Your Pause or End is your intent, said before the run's state follows — and an ended complete
    /// operation stays `complete` with `intent == .stopped`.
    @Test func yourPauseOrEndIsHeardThroughTheIntent() {
        var (w, task, run) = world(run: .complete)
        w.state.runs[0].intent = .stopped
        #expect(refusal(w, task, run) == "The operation was stopped; it publishes nothing.")
        w.state.runs[0].state = .active
        w.state.runs[0].intent = .paused
        #expect(refusal(w, task, run) == "The operation is paused; nothing is published until it runs again.")
    }

    /// Before every later step: the run's state and your intent, the task's state, ownership and acceptance.
    @Test func theRecheckCatchesWhatChangedSinceTheFirstStep() {
        var (w, task, run) = world()
        func recheck() -> String? {
            PublicationGuard.recheck(task: w.state.tasks.first { $0.id == task }, run: w.state.runs.first { $0.id == run },
                                     ownership: 0, acceptedSHA: sha)
        }
        #expect(recheck() == nil)
        w.state.runs[0].intent = .paused
        #expect(recheck() == "The operation is paused; nothing is published until it runs again.")
        w.state.runs[0].intent = nil
        w.state.runs[0].state = .stopped
        #expect(recheck() == "The operation was stopped; it publishes nothing.")
        w.state.runs[0].state = .active
        w.update(task) { $0.ownership = 1 }
        #expect(recheck() == PublicationGuard.changedMidway, "taken over and handed back meanwhile")
        w.update(task) { $0.ownership = 0; $0.takenOver = true }
        #expect(recheck() == PublicationGuard.changedMidway)
        w.update(task) { $0.takenOver = false; $0.acceptance?.resultSHA = "5eed5eed" }
        #expect(recheck() == PublicationGuard.changedMidway, "accepted again on another commit")
        w.update(task) { $0.acceptance?.resultSHA = sha; $0.state = .working }
        #expect(recheck() == PublicationGuard.changedMidway, "its acceptance revoked")
        w.update(task) { $0.state = .accepted; $0.flags.insert(.upstreamReplaced) }
        #expect(recheck() == "PLUTO-231's parent was accepted again on another commit: have its worker rebase, accept it again, then finish it.")
        #expect(PublicationGuard.recheck(task: nil, run: w.state.runs.first, ownership: 0, acceptedSHA: sha) == PublicationGuard.gone)
    }
}
