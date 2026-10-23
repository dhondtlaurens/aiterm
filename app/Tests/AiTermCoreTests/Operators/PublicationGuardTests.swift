import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct PublicationGuardTests {
    let sha = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"

    func world(end: TaskEnd = .draftMR, state: OperatedState = .accepted, run runState: OperatorRunState = .active,
               slices: Slices = Slices(merge: true)) -> (world: OperatedWorld, task: UUID, run: UUID) {
        var world = OperatedWorld()
        let run = world.addRun(runState, slices: slices)
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
        for end in [TaskEnd.draftMR, .merge, .mergeLocal] {
            let (w, task, run) = world(end: end)
            #expect(refusal(w, task, run) == nil)
        }
        let (w, task, run) = world(run: .complete)
        #expect(refusal(w, task, run) == nil, "a complete broadcast still publishes")
    }

    @Test func aCommitEndHasNothingToFinish() {
        let (w, task, run) = world(end: .commit)
        #expect(refusal(w, task, run) == "PLUTO-231 ends in a commit: its plan opens no merge request, so there is nothing to finish.")
    }

    @Test func anOperationThatIsNotRunningPublishesNothing() {
        for (state, line) in [(OperatorRunState.paused, "The broadcast is paused; nothing is published until it runs again."),
                              (.operatorOffline, "The Operator is offline; nothing is published until the broadcast resumes."),
                              (.stopped, "The broadcast was stopped; it publishes nothing."),
                              (.planning, "The broadcast's plan hasn't been submitted yet.")] {
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

    /// The default branch is compared as the push compares it: case-folded and without `refs/heads/`.
    @Test(arguments: ["feat/pluto-231", "Feat/PLUTO-231", "refs/heads/feat/pluto-231"])
    func theDefaultBranchIsNeverPublished(_ defaultBranch: String) {
        let (w, task, run) = world()
        #expect(refusal(w, task, run, defaultBranch: defaultBranch) == "PLUTO-231's branch is the default branch, which AiTerm never pushes to.")
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
        #expect(refusal(w, task, run) == "The broadcast was stopped; it publishes nothing.")
        w.state.runs[0].state = .active
        w.state.runs[0].intent = .paused
        #expect(refusal(w, task, run) == "The broadcast is paused; nothing is published until it runs again.")
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
        #expect(recheck() == "The broadcast is paused; nothing is published until it runs again.")
        w.state.runs[0].intent = nil
        w.state.runs[0].state = .stopped
        #expect(recheck() == "The broadcast was stopped; it publishes nothing.")
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
    // MARK: - The Merge slice and AiTerm's floor (spec §5)

    /// A merge, through the request or local, happens only with the broadcast's Merge slice on; a draft needs none.
    @Test func mergeNeedsTheSlice() {
        for end in [TaskEnd.merge, .mergeLocal] {
            let (w, task, run) = world(end: end, slices: .none)
            #expect(refusal(w, task, run) == "The Merge slice is off for this broadcast.", "\(end)")
            #expect(refusal(w, task, run) == PublicationGuard.mergeSliceOff)
        }
        let (w, task, run) = world(end: .draftMR, slices: .none)
        #expect(refusal(w, task, run) == nil)
    }

    /// The slices froze when the broadcast started: turning Merge on in Settings changes only the next one.
    @Test func theSliceIsFrozen() {
        let defaults = UserDefaults(suiteName: "aiterm-guard-\(UUID().uuidString)")!
        var stored = OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: "high"))
        stored.slices = Slices(jira: true, review: true, merge: true)
        OperatorProfileStore.save(stored, defaults)
        #expect(OperatorProfileStore.load(defaults, claudeDefault: (model: "claude-opus-5-5", reasoning: "high")).slices.merge)
        let (w, task, run) = world(end: .merge, slices: .none)
        #expect(refusal(w, task, run) == PublicationGuard.mergeSliceOff, "the running broadcast keeps its own slices")
        #expect(PublicationGuard.recheck(task: w.state.tasks.first { $0.id == task }, run: w.state.runs.first { $0.id == run },
                                         ownership: 0, acceptedSHA: sha) == PublicationGuard.mergeSliceOff, "checked again before the merge")
    }

    /// The floor for a merge through the request: the host's head is the accepted commit, and every thread is resolved.
    @Test func anOpenThreadBlocksTheMerge() {
        func thread(_ id: String, _ resolved: Bool) -> ReviewThread { ReviewThread(id: id, resolved: resolved, lastAuthor: "jan", lastBody: "Why?") }
        #expect(PublicationGuard.mergeFloor(head: sha, acceptedSHA: sha, threads: [thread("d1", false), thread("d2", true), thread("d3", false)],
                                            request: "!418") == "2 review threads are still open on !418.")
        #expect(PublicationGuard.mergeFloor(head: sha, acceptedSHA: sha, threads: [thread("d1", false)], request: "!418")
                == "1 review thread is still open on !418.")
        #expect(PublicationGuard.mergeFloor(head: sha, acceptedSHA: sha, threads: [thread("d1", true)], request: "!418") == nil)
        #expect(PublicationGuard.mergeFloor(head: sha, acceptedSHA: sha, threads: [], request: "!418") == nil)
        #expect(PublicationGuard.mergeFloor(head: "0123456789abcdef", acceptedSHA: sha, threads: [], request: "!418")
                == "The request's branch is at 0123456 on the host, not the accepted 4f2a91c.")
    }

    /// With the Oracle on, a merge goes ahead only on its yes, for the commit accepted now, that the conditions written in
    /// the Review and the Done hold. A merge end going into review merges nothing yet, so it needs none.
    @Test func aMergeWithTheOracleOnNeedsItsYesForTheAcceptedCommit() {
        for end in [TaskEnd.merge, .mergeLocal] {
            var (w, task, run) = world(end: end)
            w.state.runs[0].profile.oracle.isOn = true
            let unconfirmed = "The Oracle hasn’t said that the conditions written in the Review and the Done hold for PLUTO-231, so AiTerm doesn’t merge it: call finish_task again."
            #expect(refusal(w, task, run) == unconfirmed, "\(end)")
            w.update(task) { $0.publication = TaskPublication(conditionsHeld: "0123456789abcdef") }
            #expect(refusal(w, task, run) == unconfirmed, "a yes for another commit, \(end)")
            w.update(task) { $0.publication = TaskPublication(conditionsHeld: sha) }
            #expect(refusal(w, task, run) == nil, "\(end)")
        }
        var (w, task, run) = world(end: .merge, slices: Slices(review: true, merge: true))
        w.state.runs[0].profile.oracle.isOn = true
        w.state.runs[0].review = "Assign Jan."
        #expect(refusal(w, task, run) == nil, "it goes into review first")
        let (d, draft, drun) = world(end: .draftMR)
        #expect(refusal(d, draft, drun) == nil)
    }

    /// A local merge builds on a stacked parent only once that parent's own end is done.
    @Test func aStackedLocalMergeWaitsForItsParent() {
        var world = OperatedWorld()
        let run = world.addRun()
        let parent = world.addTask("PLUTO-230", run: run, state: .accepted, end: .mergeLocal, acceptedSHA: "aaa")
        let child = world.addTask("PLUTO-231", run: run, state: .accepted, end: .mergeLocal,
                                  dependsOn: [TaskDependency(task: parent, kind: .code)], branch: "feat/pluto-231", acceptedSHA: sha)
        #expect(refusal(world, child, run, parent: parent) == "PLUTO-231 builds on PLUTO-230: finish PLUTO-230 first.")
        world.update(parent) { $0.state = .published; $0.publication = TaskPublication(merged: true, mergedSHA: "bbb") }
        #expect(refusal(world, child, run, parent: parent) == nil)
    }
}
