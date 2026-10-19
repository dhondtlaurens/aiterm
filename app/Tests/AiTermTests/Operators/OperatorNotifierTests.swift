import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// When AiTerm notifies you (spec §4.1), by round 1's Routine rule until the plan's Task 8: a question
/// that holds up everything notifies at once, one that does not is held up to half an hour; a worker's
/// prompt, a blocked task, a waiting plan and a finished operation notify at once.
@MainActor @Suite struct OperatorNotifierTests {
    let notifications = RecordingNotifications(), clock = StepClock()
    func makeNotifier() -> OperatorNotifier { OperatorNotifier(notifications: notifications, now: { [clock] in clock.now }) }
    let project = OperatorServiceFixtures.project()

    func makeRun(state: OperatorRunState = .active) -> OperatorRun {
        OperatorServiceFixtures.run(projects: [project], state: state)
    }

    @Test func aQuestionThatHoldsUpEverythingNotifiesAtOnceAndOpensTheOverview() {
        let run = makeRun(), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: false)
        #expect(notifications.posted.map(\.target) == [.overview(run.id)])
        #expect(notifications.posted.first?.title == "The Operator asks you")
        #expect(notifications.posted.first?.body == "Which locale is the default?")
        #expect(notifier.held.isEmpty)
    }

    @Test func aHeldQuestionIsSentWhenTheOperationEnds() {
        let run = makeRun(), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question("a", at: clock.now), in: run, otherWorkCanProceed: true)
        notifier.questionAsked(OperatorServiceFixtures.question("b", at: clock.now), in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        var finished = run
        finished.state = .complete
        notifier.runComplete(finished)
        #expect(notifications.posted.map(\.body).contains("2 questions wait on you in “Sprint 42”."))
        #expect(notifications.posted.first?.body == "The Operator finished the operation.")
        #expect(notifier.held[run.id] == nil)
    }

    @Test func aHeldQuestionIsSentAfterHalfAnHour() {
        let run = makeRun(), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: true)
        notifier.releaseHeld(in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        clock.advance(by: 31 * 60)
        notifier.releaseHeld(in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.map(\.target) == [.overview(run.id)])
    }

    @Test func aWorkersPermissionPromptOpensThatTasksWindowAtOnce() {
        let run = makeRun()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        makeNotifier().workerPrompt(.permission, task: task, in: run)
        #expect(notifications.posted.last?.target == .task(task.id))
        #expect(notifications.posted.last?.id == "prompt-\(task.id.uuidString)")
        #expect(notifications.posted.count == 1)
    }

    @Test func aBlockedTaskOpensTheOverview() {
        let run = makeRun(), notifier = makeNotifier()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .blocked)
        notifier.taskBlocked(task, reason: "Retries used up.", in: run)
        #expect(notifications.posted.map(\.target) == [.overview(run.id)])
        #expect(notifications.posted.last?.body == "Task PLUTO-2: Retries used up.")
    }

    @Test func aBlockedTaskSendsTheQuestionsHeld() {
        let run = makeRun(), notifier = makeNotifier()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-3", state: .blocked)
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        notifier.taskBlocked(task, reason: "Retries used up.", in: run)
        #expect(notifications.posted.map(\.id) == ["blocked-\(task.id.uuidString)", "questions-\(run.id.uuidString)"])
        #expect(notifications.posted.last?.body == "Which locale is the default?")
        #expect(notifier.held[run.id] == nil)
    }

    @Test func theSameQuestionAskedTwiceIsHeldAndSentOnce() {
        let run = makeRun(), notifier = makeNotifier()
        let question = OperatorServiceFixtures.question("same", at: clock.now)
        notifier.questionAsked(question, in: run, otherWorkCanProceed: true)
        notifier.questionAsked(question, in: run, otherWorkCanProceed: true)
        #expect(notifier.held[run.id]?.count == 1)
        notifier.questionAsked(OperatorServiceFixtures.question("other", at: clock.now), in: run, otherWorkCanProceed: true)
        var finished = run
        finished.state = .complete
        notifier.runComplete(finished)
        #expect(notifications.posted.map(\.body).contains("2 questions wait on you in “Sprint 42”."))
    }

    @Test func aTargetSurvivesTheTripThroughANotificationsUserInfo() {
        let id = UUID()
        #expect(OperatorNote.Target(userInfo: OperatorNote.Target.task(id).userInfo) == .task(id))
        #expect(OperatorNote.Target(userInfo: OperatorNote.Target.overview(id).userInfo) == .overview(id))
        #expect(OperatorNote.Target(userInfo: [:]) == nil)
    }
}
