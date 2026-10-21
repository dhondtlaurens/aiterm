import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// When AiTerm notifies you (spec §4.1): the moment something needs you, and never again for the same
/// thing; withdrawn once it is answered, unblocked or the broadcast ends.
@MainActor @Suite struct OperatorNotifierTests {
    let notifications = RecordingNotifications()
    let project = OperatorServiceFixtures.project()
    let workspace: Box
    let run: OperatorRun
    let task: TaskItem

    /// The state the notifier reads, which a test changes between its calls.
    @MainActor final class Box { var state = AppState.empty }

    init() {
        let project = OperatorServiceFixtures.project()
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-1", state: .working, agent: .codex)
        run.name = "Payment broadcast"
        self.run = run
        self.task = task
        workspace = Box()
        workspace.state = OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])
    }

    func makeNotifier(prompts: [UUID: String] = [:]) -> OperatorNotifier {
        OperatorNotifier(notifications: notifications, state: { [workspace] in workspace.state }, prompts: { prompts })
    }

    func change(_ edit: (inout AppState) -> Void) { edit(&workspace.state) }
    var current: OperatorRun { workspace.state.runs[0] }

    func ask(_ key: String = "q1", text: String = "Which locale is the default?") {
        change { $0.updateRun(id: run.id) { $0.questions.append(OperatorQuestion(id: key, text: text, task: nil, askedAt: Date(timeIntervalSince1970: 0))) } }
    }

    @Test func aRequestPostsAtOnce() {
        let notifier = makeNotifier()
        ask()
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 1)
        let note = notifications.posted.first
        #expect(note?.title == "Payment broadcast")
        #expect(note?.body == "The Operator asks: Which locale is the default?")
        #expect(note?.id == "request-\(run.id.uuidString)-question-q1")
        #expect(note?.target == .overview(run.id))
    }

    @Test func aRequestAlreadyPostedIsNotPostedAgain() {
        let notifier = makeNotifier()
        ask()
        notifier.requestsChanged(run: current)
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 1 && notifications.withdrawn.isEmpty)
    }

    @Test func aWorkersPromptOpensItsWindow() {
        let notifier = makeNotifier(prompts: [task.id: "run npm install"])
        change { state in
            state.updateRun(id: run.id) {
                $0.questions.append(OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission",
                                                     task: task.id, askedAt: Date(timeIntervalSince1970: 0)))
            }
            state.tasks[0].title = "Payment provider switch"
        }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.body) == ["Codex asks to run npm install in Payment provider switch."])
        #expect(notifications.posted.first?.target == .task(task.id))
    }

    @Test func aBlockedTaskAndAProblemNotifyOnTheOverview() {
        let notifier = makeNotifier()
        change { $0.updateOperated(task.id) { $0.state = .blocked; $0.blockedReason = "Retries used up." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.body) == ["Task PAY-1 is blocked: Retries used up."])
        #expect(notifications.posted.first?.target == .overview(run.id))
        change { $0.updateOperated(task.id) { $0.problem = "git-rebase-1"; $0.blockedReason = "Couldn’t rebase it." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.last?.body == "Task PAY-1: Couldn’t rebase it.")
        #expect(notifications.withdrawn == ["request-\(run.id.uuidString)-\(task.id.uuidString)-blocked"], "the problem replaces the block")
    }

    @Test func aResolvedRequestIsWithdrawn() {
        let notifier = makeNotifier()
        ask()
        notifier.requestsChanged(run: current)
        change { $0.updateRun(id: run.id) { $0.questions[0].resolution = "en-GB." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 1)
        #expect(notifications.withdrawn == ["request-\(run.id.uuidString)-question-q1"])
    }

    @Test func eachOpenQuestionIsItsOwnNotificationAndResolvingOneWithdrawsOnlyIt() {
        let notifier = makeNotifier()
        ask("a")
        ask("b", text: "Which currency?")
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.id) == ["request-\(run.id.uuidString)-question-a", "request-\(run.id.uuidString)-question-b"])
        #expect(Set(notifications.posted.map(\.body)) == ["The Operator asks: Which locale is the default?", "The Operator asks: Which currency?"])
        change { $0.updateRun(id: run.id) { $0.questions[0].resolution = "en-GB." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 2)
        #expect(notifications.withdrawn == ["request-\(run.id.uuidString)-question-a"])
    }

    func leftOver() -> (open: String, resolved: String, debrief: String) {
        let ids = ("request-\(run.id.uuidString)-question-open", "request-\(run.id.uuidString)-question-gone", "debrief-\(UUID().uuidString)")
        notifications.delivered = [ids.0, ids.1, ids.2, "unrelated-id"]
        return ids
    }

    @Test func aNotificationAnEarlierRunLeftThatIsNoLongerAskedIsWithdrawnAndOneStillAskedIsNotPostedAgain() async {
        ask("open")
        let ids = leftOver()
        let notifier = makeNotifier()
        await notifier.lastListing?.value
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.isEmpty, "the one still asked is already showing")
        #expect(Set(notifications.withdrawn) == [ids.resolved, ids.debrief], "only what no run asks, and only AiTerm's ids")
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.isEmpty && notifications.withdrawn.count == 2)
    }

    /// The centre's listing is asynchronous: a change before it arrives posts as it goes and fixes nothing, and
    /// the stale note is still taken back when the listing lands.
    @Test func aListingThatArrivesAfterTheFirstChangeStillWithdrawsWhatIsStale() async {
        ask("open")
        let ids = leftOver()
        let notifier = makeNotifier()
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.id) == [ids.open] && notifications.withdrawn.isEmpty)
        await notifier.lastListing?.value
        #expect(Set(notifications.withdrawn) == [ids.resolved, ids.debrief])
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 1, "nothing is posted twice")
    }

    /// A note an earlier run left that is still asked when the listing lands, then resolved before the run's
    /// first change: that change takes it back, and so does an end.
    @Test func aLeftOverNoteStillAskedWhenTheListingLandsIsWithdrawnOnceResolved() async {
        ask("open")
        let ids = leftOver()
        let notifier = makeNotifier()
        await notifier.lastListing?.value
        #expect(!notifications.withdrawn.contains(ids.open), "still asked")
        change { $0.updateRun(id: run.id) { $0.questions[0].resolution = "en-GB." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.withdrawn.contains(ids.open))
        #expect(notifications.posted.isEmpty)
    }

    @Test func aLeftOverNoteStillAskedWhenTheListingLandsIsWithdrawnWhenTheRunEnds() async {
        ask("open")
        let ids = leftOver()
        let notifier = makeNotifier()
        await notifier.lastListing?.value
        change { $0.updateRun(id: run.id) { $0.state = .stopped; $0.intent = .stopped } }
        notifier.requestsChanged(run: current)
        #expect(notifications.withdrawn.contains(ids.open))
    }

    @Test func aTaskThatIsUnblockedIsWithdrawn() {
        let notifier = makeNotifier()
        change { $0.updateOperated(task.id) { $0.state = .blocked; $0.blockedReason = "Retries used up." } }
        notifier.requestsChanged(run: current)
        change { $0.updateOperated(task.id) { $0.state = .working; $0.blockedReason = nil } }
        notifier.requestsChanged(run: current)
        #expect(notifications.withdrawn == ["request-\(run.id.uuidString)-\(task.id.uuidString)-blocked"])
    }

    @Test func endingWithdrawsAll() {
        let notifier = makeNotifier()
        ask()
        change { $0.updateOperated(task.id) { $0.state = .blocked; $0.blockedReason = "Retries used up." } }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.count == 2)
        change { $0.updateRun(id: run.id) { $0.state = .stopped } }
        notifier.requestsChanged(run: current)
        #expect(Set(notifications.withdrawn) == Set(notifications.posted.map(\.id)))
    }

    /// The plan done is not the summary ready: nothing is posted while the Operator writes it.
    @Test func aFinishedBroadcastWaitsForItsSummary() {
        let notifier = makeNotifier()
        change { state in
            state.updateOperated(task.id) { $0.state = .accepted }
            state.updateRun(id: run.id) { $0.state = .complete; $0.completedAt = Date(timeIntervalSince1970: 0) }
        }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.isEmpty, "the Operator is writing its summary")
    }

    @Test func aWrittenSummaryPostsOnce() {
        let notifier = makeNotifier()
        change { state in
            state.updateOperated(task.id) { $0.state = .accepted }
            state.updateRun(id: run.id) {
                $0.state = .complete; $0.completedAt = Date(timeIntervalSince1970: 0)
                $0.summary = "It merged."; $0.summaryAt = Date(timeIntervalSince1970: 60)
            }
        }
        notifier.requestsChanged(run: current)
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.id) == ["debrief-\(run.id.uuidString)"], "the id delivered notes already carry")
        #expect(notifications.posted.first?.body == "The summary is ready.")
        #expect(notifications.posted.first?.target == .overview(run.id))
        change { $0.updateRun(id: run.id) { $0.state = .stopped } }
        notifier.requestsChanged(run: current)
        #expect(notifications.withdrawn == ["debrief-\(run.id.uuidString)"], "End takes the note away")
    }

    /// AiTerm gave up waiting for the summary: the note says the tasks are done, counting them.
    @Test func aSummaryGivenUpSaysTheTasksAreDone() {
        let notifier = makeNotifier()
        change { state in
            state.updateOperated(task.id) { $0.state = .accepted }
            state.updateRun(id: run.id) { $0.state = .complete; $0.completedAt = Date(timeIntervalSince1970: 0); $0.summaryGivenUp = true }
        }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.id) == ["debrief-\(run.id.uuidString)"])
        #expect(notifications.posted.first?.body == "The task is done.")
        change { state in
            for n in 2...3 { state.tasks.append(OperatorServiceFixtures.task(in: run, project: project, key: "PAY-\(n)", state: .accepted)) }
        }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.last?.body == "All 3 tasks are done.")
    }

    @Test func copyHasNoEmDash() {
        let notifier = makeNotifier(prompts: [task.id: "run npm install"])
        ask()
        change { state in
            state.updateRun(id: run.id) {
                $0.questions.append(OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission",
                                                     task: task.id, askedAt: Date(timeIntervalSince1970: 0)))
            }
            state.updateOperated(task.id) { $0.state = .blocked; $0.blockedReason = "Retries used up." }
        }
        notifier.requestsChanged(run: current)
        change { $0.updateOperated(task.id) { $0.problem = "git-rebase-1" } }
        notifier.requestsChanged(run: current)
        change { $0.updateRun(id: run.id) { $0.state = .complete; $0.completedAt = Date(timeIntervalSince1970: 0); $0.summaryGivenUp = true } }
        notifier.requestsChanged(run: current)
        #expect(!notifications.posted.isEmpty)
        #expect(notifications.posted.allSatisfy { !$0.title.contains("—") && !$0.body.contains("—") })
    }

    @Test func aTargetSurvivesTheTripThroughANotificationsUserInfo() {
        let id = UUID()
        #expect(OperatorNote.Target(userInfo: OperatorNote.Target.task(id).userInfo) == .task(id))
        #expect(OperatorNote.Target(userInfo: OperatorNote.Target.overview(id).userInfo) == .overview(id))
        #expect(OperatorNote.Target(userInfo: [:]) == nil)
    }
}
