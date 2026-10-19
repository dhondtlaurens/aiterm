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
        #expect(notifications.posted.last?.body == "Task PAY-1’s couldn’t rebase it.")
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

    @Test func aNotificationAnEarlierRunLeftThatIsNoLongerAskedIsWithdrawnAndOneStillAskedIsNotPostedAgain() {
        ask("open")
        let stillOpen = "request-\(run.id.uuidString)-question-open"
        let resolved = "request-\(run.id.uuidString)-question-gone"
        let debrief = "debrief-\(UUID().uuidString)"
        notifications.deliveredAtLaunch = [stillOpen, resolved, debrief, "unrelated-id"]
        let notifier = makeNotifier()
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.isEmpty, "the one still asked is already showing")
        #expect(Set(notifications.withdrawn) == [resolved, debrief], "only what no run asks, and only AiTerm's ids")
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.isEmpty && notifications.withdrawn.count == 2, "the listing is taken once")
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

    @Test func aFinishedBroadcastPostsItsDebriefOnce() {
        let notifier = makeNotifier()
        change { state in
            state.updateOperated(task.id) { $0.state = .accepted }
            state.updateRun(id: run.id) { $0.state = .complete }
        }
        notifier.requestsChanged(run: current)
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.map(\.id) == ["debrief-\(run.id.uuidString)"])
        #expect(notifications.posted.first?.body == "The task is done. The debrief is ready.")
        change { $0.updateRun(id: run.id) { $0.state = .stopped } }
        notifier.requestsChanged(run: current)
        #expect(notifications.withdrawn == ["debrief-\(run.id.uuidString)"], "End takes the debrief away")
    }

    @Test func theDebriefCountsTheTasks() {
        let notifier = makeNotifier()
        change { state in
            for n in 2...8 { state.tasks.append(OperatorServiceFixtures.task(in: run, project: project, key: "PAY-\(n)", state: .accepted)) }
            state.updateRun(id: run.id) { $0.state = .complete }
        }
        notifier.requestsChanged(run: current)
        #expect(notifications.posted.first?.body == "All 8 tasks are done. The debrief is ready.")
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
        change { $0.updateRun(id: run.id) { $0.state = .complete } }
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
