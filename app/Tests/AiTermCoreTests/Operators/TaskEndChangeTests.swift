import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The person's change of one running task's end, from its card (broadcast setup v2, Board): what it clears and keeps
/// of the publication, a switch below what is done finishing the task as it stands, and when it is refused.
@Suite struct TaskEndChangeTests {
    private let web = OperatorUIFixtures.project("webshop")

    private func run(merge: Bool = true, legacy: Bool = false) -> OperatorRun {
        var profile = OperatorUIFixtures.profile
        profile.slices = Slices(merge: merge)
        return OperatorUIFixtures.run(profile: profile, projectIds: [web.id], agents: legacy ? [] : OperatorUIFixtures.agents,
                                      taskSettings: legacy ? nil : OperatorUIFixtures.taskSettings)
    }

    private func task(in run: OperatorRun, _ state: OperatedState, end: TaskEnd = .merge, publication: TaskPublication? = nil) -> TaskItem {
        var operated = OperatorUIFixtures.operated(run: run.id, key: "cart-drawer", state: state, end: end,
                                                   sha: [.working, .queued].contains(state) ? nil : "4f2a91c7d")
        operated.publication = publication
        return OperatorUIFixtures.task("Cart drawer", jira: "PAY-231", project: web.id, operated: operated)
    }

    private func state(_ run: OperatorRun, _ tasks: [TaskItem]) -> AppState {
        var state = AppState()
        state.append(project: web)
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    /// A merge end waiting on the host, refused once by the Oracle: what was under way for it, and what already happened.
    private var waitingMerge: TaskPublication {
        TaskPublication(pushedSHA: "4f2a91c7d", mergeRequestURL: "https://gitlab.example/acme/webshop/-/merge_requests/412",
                        mergeRequestNumber: 412, targetBranch: "main", waitingSince: OperatorUIFixtures.epoch,
                        readySince: OperatorUIFixtures.epoch, problem: "the pipeline failed", conditionsHeld: "4f2a91c7d",
                        waitingReason: "the pipeline is running", mergeRefusal: "Jan has not approved it.")
    }

    @Test func aChangeClearsWhatWasUnderWayForTheOldEndAndKeepsWhatHappened() throws {
        let run = run()
        let task = task(in: run, .accepted, publication: waitingMerge)
        var state = state(run, [task])
        TaskEndChange.apply(.mergeLocal, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.end == .mergeLocal)
        let publication = try #require(operated.publication)
        #expect(publication.waitingSince == nil && publication.readySince == nil && publication.problem == nil)
        #expect(publication.mergeRefusal == nil && publication.conditionsHeld == nil)
        #expect(publication.pushedSHA == "4f2a91c7d", "the push happened")
        #expect(publication.mergeRequestNumber == 412 && publication.mergeRequestURL == waitingMerge.mergeRequestURL, "so did the request")
        #expect(operated.state == .accepted && !operated.isFinished, "the next finish_task follows the new end")
        #expect(state.run(id: run.id)?.leftForYou == [], "a local merge is no less than an open request: nothing is left for you")
    }

    @Test func aSwitchBelowWhatIsDoneFinishesTheTaskAsItStands() throws {
        let run = run()
        let task = task(in: run, .accepted, publication: waitingMerge)
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.end == .commit && operated.isFinished, "accepted on a commit end: finished")
        #expect(operated.publication?.mergeRequestNumber == 412, "the request is left open")
        #expect(operated.publication?.leftForYou == true, "and left for you: the closing skips it, and nothing merges it")
        #expect(!operated.reachedItsEnd)
        #expect(OperatorLine.ending(of: operated) == "left for you · 4f2a91c")
        #expect(state.run(id: run.id)?.leftForYou == [leftOpen])
    }

    private let leftOpen = "Close or merge !412 in webshop yourself: you changed cart-drawer’s end to commit, so AiTerm left it open."

    @Test func aTaskStillAtWorkHasItsOpenRequestLeftForYouToo() throws {
        let run = run()
        let task = task(in: run, .working, publication: waitingMerge)
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(!operated.isFinished && operated.state == .working, "it finishes once it is accepted")
        #expect(operated.publication?.leftForYou == true, "from now on AiTerm neither merges nor closes the request")
        #expect(state.run(id: run.id)?.leftForYou == [leftOpen])
    }

    @Test func aSwitchBackFromCommitHandsTheRequestBackToItsEnd() throws {
        let run = run()
        let task = task(in: run, .working, publication: waitingMerge)
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        TaskEndChange.apply(.draftMR, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.publication?.leftForYou == false, "the new end publishes it")
        #expect(operated.publication?.mergeRequestNumber == 412)
        #expect(state.run(id: run.id)?.leftForYou == [], "and the line the switch to Commit left goes")
        // Only that line: what else was left for you stays.
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        state.updateRun(id: run.id) { $0.leftForYou.insert("Review the analytics yourself.", at: 0) }
        TaskEndChange.apply(.merge, toTask: task.id, in: &state)
        #expect(state.run(id: run.id)?.leftForYou == ["Review the analytics yourself."])
        #expect(state.task(id: task.id)?.operated?.publication?.leftForYou == false)
    }

    @Test func theWordsOfAHoldAndAFirstLetter() {
        #expect(TaskEndChange.mergeWaitsForFinish == "its end changed to merge; call finish_task to merge it")
        #expect("draft MR".capitalizingFirst == "Draft MR" && "".capitalizingFirst == "")
    }

    @Test func aTaskInPeoplesReviewSwitchedToCommitEndsItsReviewAndFinishes() throws {
        let run = run()
        var task = task(in: run, .inReview, publication: waitingMerge)
        task.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.state == .accepted && operated.isFinished)
        #expect(state.run(id: run.id)?.leftForYou.count == 1)
        #expect(operated.peopleReview?.ended == true)
    }

    @Test func aTaskInReviewWithNoRequestNumberSwitchedToCommitIsNotLeftInReview() throws {
        let run = run()
        var task = task(in: run, .inReview, publication: TaskPublication(pushedSHA: "4f2a91c7d"))
        task.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.state == .accepted && operated.isFinished && operated.peopleReview?.ended == true)
        #expect(operated.publication?.leftForYou == false && operated.reachedItsEnd, "no request to leave: done at its commit")
        #expect(state.run(id: run.id)?.leftForYou == [])
    }

    @Test func aTaskAtWorkOnlyTakesItsNewEnd() throws {
        let run = run()
        let task = task(in: run, .working, end: .draftMR)
        var state = state(run, [task])
        TaskEndChange.apply(.commit, toTask: task.id, in: &state)
        let operated = try #require(state.task(id: task.id)?.operated)
        #expect(operated.end == .commit && operated.state == .working && operated.publication == nil)
    }

    @Test func whatIsRefused() {
        let run = run(merge: false)
        let working = task(in: run, .working, end: .draftMR)
        #expect(TaskEndChange.refusal(.commit, for: working, in: run) == nil)
        #expect(TaskEndChange.refusal(.merge, for: working, in: run) == "Merge is off for this broadcast, so a task ends at a commit or a draft MR.")
        #expect(TaskEndChange.refusal(.mergeLocal, for: working, in: run) != nil)
        #expect(TaskEndChange.isSelectable(.draftMR, in: run) && !TaskEndChange.isSelectable(.merge, in: run))
        #expect(TaskEndChange.isSelectable(.mergeLocal, in: self.run()))

        #expect(TaskEndChange.refusal(.draftMR, for: working, in: run) == "Cart drawer already ends at draft MR.")
        var yoursNow = working
        yoursNow.operated?.takenOver = true
        #expect(TaskEndChange.refusal(.commit, for: yoursNow, in: run) == "You took Cart drawer over: hand it back to change its end.")

        let published = task(in: run, .published, end: .draftMR)
        #expect(TaskEndChange.refusal(.commit, for: published, in: run) == "Cart drawer has finished, so its end can’t change.")

        var ended = run
        ended.endedAt = OperatorUIFixtures.epoch
        ended.state = .stopped
        #expect(TaskEndChange.refusal(.commit, for: working, in: ended) == "This broadcast has ended.")

        let legacy = self.run(legacy: true)
        #expect(TaskEndChange.refusal(.commit, for: task(in: legacy, .working), in: legacy)
                == "This broadcast started before a task’s end could change.")

        let yours = OperatorUIFixtures.task("Mine", project: web.id, operated: nil)
        #expect(TaskEndChange.refusal(.commit, for: yours, in: run) == "That task isn’t the Operator’s.")
    }

    @Test func theWordsOfAnEnd() {
        #expect(TaskEnd.allCases.map(\.title) == ["Commit", "Draft MR", "Merge", "Local merge"])
        #expect(TaskEndChange.wakeReason(key: "cart-drawer", end: .draftMR) == "You changed cart-drawer’s end to draft MR")
    }

    @Test func whatReachesItsEnd() {
        let run = run()
        func reached(_ state: OperatedState, _ end: TaskEnd, leftForYou: Bool = false) -> Bool {
            var operated = OperatorUIFixtures.operated(run: run.id, key: "k", state: state, end: end)
            if leftForYou { operated.publication = TaskPublication(leftForYou: true) }
            return operated.reachedItsEnd
        }
        #expect(reached(.published, .merge) && reached(.noChange, .draftMR) && reached(.accepted, .commit))
        #expect(!reached(.accepted, .merge), "still to publish")
        #expect(!reached(.accepted, .draftMR, leftForYou: true), "its publication left for you")
        #expect(!reached(.stopped, .commit) && !reached(.failed, .commit) && !reached(.working, .commit))
    }
}
