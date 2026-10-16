import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// When AiTerm notifies you (spec §4.1): the stop decides when a question does; a worker's prompt, a
/// blocked task, a waiting plan and a finished operation notify at once.
@MainActor @Suite struct OperatorNotifierTests {
    let notifications = RecordingNotifications(), clock = StepClock()
    func makeNotifier() -> OperatorNotifier { OperatorNotifier(notifications: notifications, now: { [clock] in clock.now }) }
    let project = OperatorServiceFixtures.project()

    func makeRun(_ autonomy: Autonomy, state: OperatorRunState = .active) -> OperatorRun {
        OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: autonomy), projects: [project], state: state)
    }

    @Test func askFirstNotifiesEveryQuestionAtOnceAndOpensTheOverview() {
        let run = makeRun(.askFirst), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.map(\.target) == [.overview(run.id)])
        #expect(notifications.posted.first?.body == "Which locale is the default?")
        #expect(notifier.held.isEmpty)
    }

    @Test func handsOffHoldsAQuestionUntilTheOperationEnds() {
        let run = makeRun(.handsOff), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question("a", at: clock.now), in: run, otherWorkCanProceed: false)
        notifier.questionAsked(OperatorServiceFixtures.question("b", at: clock.now), in: run, otherWorkCanProceed: true)
        clock.advance(by: 3 * 3600)
        notifier.releaseHeld(in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        var finished = run
        finished.state = .complete
        notifier.runComplete(finished)
        #expect(notifications.posted.map(\.body).contains("2 questions wait on you in “Sprint 42”."))
        #expect(notifier.held[run.id] == nil)
    }

    @Test func routineSendsHeldQuestionsAfterHalfAnHour() {
        let run = makeRun(.routine), notifier = makeNotifier()
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: true)
        notifier.releaseHeld(in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        clock.advance(by: 31 * 60)
        notifier.releaseHeld(in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.map(\.target) == [.overview(run.id)])
    }

    @Test func aWorkersPermissionPromptOpensThatTasksWindowAtOnceAtEveryStop() {
        for autonomy in Autonomy.allCases {
            let run = makeRun(autonomy)
            let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
            makeNotifier().workerPrompt(.permission, task: task, in: run)
            #expect(notifications.posted.last?.target == .task(task.id))
            #expect(notifications.posted.last?.id == "prompt-\(task.id.uuidString)")
        }
        #expect(notifications.posted.count == Autonomy.allCases.count)
    }

    @Test func aWaitingPlanAndABlockedTaskOpenTheOverview() {
        let run = makeRun(.routine), notifier = makeNotifier()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .blocked)
        notifier.planWaiting(run)
        notifier.taskBlocked(task, reason: "Retries used up.", in: run)
        #expect(notifications.posted.map(\.target) == [.overview(run.id), .overview(run.id)])
        #expect(notifications.posted.last?.body == "Task PLUTO-2: Retries used up.")
    }

    @Test func aBlockedTaskSendsTheQuestionsATrustedStopHeld() {
        let run = makeRun(.trusted), notifier = makeNotifier()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-3", state: .blocked)
        notifier.questionAsked(OperatorServiceFixtures.question(at: clock.now), in: run, otherWorkCanProceed: true)
        #expect(notifications.posted.isEmpty)
        notifier.taskBlocked(task, reason: "Retries used up.", in: run)
        #expect(notifications.posted.map(\.id) == ["blocked-\(task.id.uuidString)", "questions-\(run.id.uuidString)"])
        #expect(notifications.posted.last?.body == "Which locale is the default?")
        #expect(notifier.held[run.id] == nil)
    }

    @Test func theSameQuestionAskedTwiceIsHeldAndSentOnce() {
        let run = makeRun(.trusted), notifier = makeNotifier()
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
