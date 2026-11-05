import Testing
import Foundation
@testable import AiTermCore

/// The words of the Notice for a refused wake line (`OperatorWakeNotice`): what waits on the Operator, and why.
@Suite struct OperatorWakeNoticeWordsTests {
    let run = UUID()

    func status(ready: [String] = [], stalled: [String] = [], uncertain: [String] = [], drift: [String] = [],
                prompts: [String] = []) -> RunStatus {
        RunStatus(revision: 3, run: RunStatus.Run(id: run, name: "Payments", state: .active, prompt: "Go", planRevision: 1, openRevision: 2),
                  obligations: RunStatus.Obligations(promptsWaitingOnYou: prompts, readyForAcceptance: ready, possiblyStalled: stalled,
                                                     uncertain: uncertain, branchDrift: drift))
    }

    func status(obligations: RunStatus.Obligations) -> RunStatus {
        RunStatus(revision: 3, run: RunStatus.Run(id: run, name: "Sprint 42", state: .active, prompt: "Go", planRevision: 1, openRevision: 2),
                  obligations: obligations)
    }

    @Test func itSaysWhatWaitsOnTheOperatorAndWhyItWasRefused() throws {
        let refusal = Delivery(result: .refused, reason: "its screen could not be read: timeout", code: .screenUnread)
        let notice = try #require(OperatorWakeNotice(run: run, status: status(ready: ["PAY-1", "PAY-2"]), refusal: refusal))
        #expect(OperatorWakeNotice.title == "The Operator can’t be woken")
        #expect(notice.run == run)
        #expect(notice.description == "2 tasks ready to accept in “Payments”. Its screen couldn’t be read.")
    }

    @Test func eachKindOfWaitingIsCountedAndWhatWaitsOnThePersonIsLeftOut() {
        #expect(OperatorWakeNotice.waiting(status(ready: ["A"], stalled: ["B", "C"], drift: ["D"], prompts: ["E"]))
                == "1 task ready to accept, 2 tasks possibly stalled and 1 task off its branch in “Payments”.")
        #expect(OperatorWakeNotice.waiting(status(uncertain: ["A"])) == "1 task uncertain in “Payments”.")
        #expect(OperatorWakeNotice.waiting(status(prompts: ["E"])) == "News waits for it in “Payments”.")
        #expect(OperatorWakeNotice.waiting(nil) == "News waits for it.")
    }

    @Test func everyReasonTheWakerWakesForIsNamed() {
        #expect(OperatorWakeNotice.waiting(status(obligations: .init(workerAsks: [RunStatus.WorkerAsk(key: "A", question: "Which?")])))
                == "1 task asking the Operator in “Sprint 42”.")
        #expect(OperatorWakeNotice.waiting(status(obligations: .init(changedAfterAcceptance: ["A"])))
                == "1 task changed after acceptance in “Sprint 42”.")
        #expect(OperatorWakeNotice.waiting(status(obligations: .init(finishedWithoutCommit: ["A"])))
                == "1 task finished with no commit in “Sprint 42”.")
        #expect(OperatorWakeNotice.waiting(status(obligations: .init(reviewQuiet: ["A"])))
                == "1 task in review with nothing waiting in “Sprint 42”.")
    }

    @Test func aPromptWaitingOnThePersonOrALineThatWentInIsNoNotice() {
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .refused, reason: "a menu prompt is open", code: .prompt)) == nil)
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .refused, reason: "you are typing", code: .typing)) == nil)
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .refused, reason: "unsent input", code: .unsentInput)) == nil, "not held yet")
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .delivered, reason: nil)) == nil)
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .partial, reason: "held", code: .typing)) == nil)
    }

    /// Text the screen shows in the Operator's input, or an input the keys and the screen leave unknown, holds the line: once
    /// it has waited long enough, the Notice says what waits and how to let the line in, and Settings, which can't, is not
    /// offered.
    @Test func inputThatMayHoldUnsentTextIsShownOnceTheWakeWasHeldOnIt() throws {
        let unsent = Delivery(result: .refused, reason: "unsent text waits in its input", code: .unsentInput)
        let notice = try #require(OperatorWakeNotice(run: run, status: status(ready: ["PAY-1", "PAY-2"]), refusal: unsent, held: true))
        #expect(notice.description == "2 tasks ready to accept in “Payments”. Text may wait unsent in its input: send it there, or clear it with ⌃U.")
        #expect(!notice.fixInSettings)
        let unread = Delivery(result: .refused, reason: "unrecognised screen", code: .unrecognisedScreen)
        #expect(try #require(OperatorWakeNotice(run: run, status: nil, refusal: unread)).fixInSettings)
        #expect(OperatorWakeNotice(run: run, status: nil, refusal: Delivery(result: .refused, reason: "you are typing", code: .typing), held: true) == nil)
    }

    /// With no keystroke monitor iTerm2 shows AiTerm none of your keys, so the line is not typed: the Notice says that,
    /// at once, never that text waits in an input nobody saw, and offers no Settings, which can't change it.
    @Test func keysAiTermCantSeeAreSaidAsSuch() throws {
        let unwatched = Delivery(result: .refused, reason: "iTerm2 gives AiTerm no keys to watch", code: .keysUnwatched)
        let notice = try #require(OperatorWakeNotice(run: run, status: status(ready: ["PAY-1"]), refusal: unwatched))
        #expect(notice.description == "1 task ready to accept in “Payments”. AiTerm can’t see your keys in iTerm2.")
        #expect(!notice.fixInSettings)
    }

    @Test func aRefusalFromADaemonThatNamesNoCodeStillSaysSomething() throws {
        let notice = try #require(OperatorWakeNotice(run: run, status: nil, refusal: Delivery(result: .refused, reason: "why")))
        #expect(notice.description == "News waits for it. AiTerm couldn’t type into its tab.")
    }
}
