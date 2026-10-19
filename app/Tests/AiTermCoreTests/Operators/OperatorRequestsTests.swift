import Testing
import Foundation
@testable import AiTermCore

/// What needs you in a broadcast (spec §4.1), as one list: each kind, said as the notification says it,
/// and nothing for a task you took over.
@Suite struct OperatorRequestsTests {
    let run = OperatorFixtures.run()

    func codexTask(_ key: String, _ state: OperatedState = .working, title: String = "Payment provider switch") -> TaskItem {
        var task = OperatorFixtures.task(key, state, run: run.id)
        task.agent = .codex
        task.title = title
        return task
    }

    func open(_ run: OperatorRun, _ tasks: [TaskItem], prompts: [UUID: String] = [:]) -> [Request] {
        OperatorRequests.open(run: run, state: OperatorFixtures.state(run, tasks), prompts: prompts)
    }

    @Test func aWorkersPromptWithItsCommandSaysWhatItAsksToRun() {
        let task = codexTask("PAY-1")
        var run = run
        run.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission", task: task.id, askedAt: OperatorFixtures.epoch)]
        let requests = open(run, [task], prompts: [task.id: "run npm install"])
        #expect(requests.map(\.kind) == [.permission])
        #expect(requests.first?.text == "Codex asks to run npm install in Payment provider switch.")
        #expect(requests.first?.taskId == task.id)
        #expect(requests.first?.id == "request-\(run.id.uuidString)-\(task.id.uuidString)-permission")
    }

    @Test func aPromptWithNoCommandIsSaidAsItWasRecorded() {
        let task = codexTask("PAY-2")
        var run = run
        run.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex shows a menu", task: task.id, askedAt: OperatorFixtures.epoch)]
        #expect(open(run, [task]).map(\.text) == ["Codex shows a menu in Payment provider switch."])
    }

    @Test func aPromptAnsweredInItsWindowIsNoRequest() {
        let task = codexTask("PAY-3")
        var run = run
        run.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission", task: task.id,
                                          askedAt: OperatorFixtures.epoch, resolution: "Answered in its window.")]
        #expect(open(run, [task]).isEmpty)
    }

    @Test func anOpenAskYouQuestionIsTheOperatorsRequest() {
        var run = run
        run.questions = [OperatorQuestion(id: "locale", text: "Which locale is the default?", task: nil, askedAt: OperatorFixtures.epoch),
                         OperatorQuestion(id: "old", text: "Answered one", task: nil, askedAt: OperatorFixtures.epoch, resolution: "Yes.")]
        let requests = open(run, [])
        #expect(requests.map(\.kind) == [.question])
        #expect(requests.first?.text == "The Operator asks: Which locale is the default?")
        #expect(requests.first?.id == "request-\(run.id.uuidString)-run-question")
    }

    @Test func aBlockedTaskGivesItsReasonWithOneFullStop() {
        var task = codexTask("PAY-4", .blocked)
        task.operated?.blockedReason = "Retries used up."
        #expect(open(run, [task]).map(\.text) == ["Payment provider switch is blocked: Retries used up."])
        task.operated?.blockedReason = "Past its runtime"
        #expect(open(run, [task]).map(\.text) == ["Payment provider switch is blocked: Past its runtime."])
    }

    @Test func aProblemIsSaidWithItsFirstLetterLowercasedAndIsNotAlsoBlocked() {
        var task = codexTask("PAY-5", .blocked)
        task.operated?.blockedReason = "Couldn’t check out the branch."
        task.operated?.problem = "git-checkout-1"
        let requests = open(run, [task])
        #expect(requests.map(\.kind) == [.problem])
        #expect(requests.first?.text == "Payment provider switch’s couldn’t check out the branch.")
    }

    @Test func aProblemOnATaskThatKeptItsStateStillAsks() {
        var task = codexTask("PAY-6", .accepted)
        task.operated?.problem = "git-rebase-1"
        #expect(open(run, [task]).map(\.kind) == [.problem])
    }

    @Test func aTaskYouTookOverContributesNone() {
        var task = codexTask("PAY-7", .blocked)
        task.operated?.takenOver = true
        task.operated?.blockedReason = "Retries used up."
        task.operated?.problem = "git-rebase-1"
        var run = run
        run.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission", task: task.id, askedAt: OperatorFixtures.epoch),
                         OperatorQuestion(id: "about-it", text: "Keep it?", task: task.id, askedAt: OperatorFixtures.epoch)]
        #expect(open(run, [task], prompts: [task.id: "run npm install"]).isEmpty)
    }

    @Test func anEndedBroadcastHasNoRequest() {
        var task = codexTask("PAY-8", .blocked)
        task.operated?.blockedReason = "Retries used up."
        var run = run
        run.state = .stopped
        run.questions = [OperatorQuestion(id: "q", text: "Still open?", task: nil, askedAt: OperatorFixtures.epoch)]
        #expect(open(run, [task]).isEmpty)
    }

    @Test func noRequestIsSaidWithAnEmDash() {
        var task = codexTask("PAY-9", .blocked)
        task.operated?.blockedReason = "Retries used up."
        var run = run
        run.questions = [OperatorQuestion(id: "q", text: "Which one?", task: nil, askedAt: OperatorFixtures.epoch)]
        #expect(open(run, [task], prompts: [task.id: "run npm install"]).allSatisfy { !$0.text.contains("—") })
    }
}
