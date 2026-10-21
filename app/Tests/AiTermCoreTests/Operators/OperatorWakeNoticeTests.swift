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

    @Test func aPromptWaitingOnThePersonOrALineThatWentInIsNoNotice() {
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .refused, reason: "a menu prompt is open", code: .prompt)) == nil)
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .delivered, reason: nil)) == nil)
        #expect(OperatorWakeNotice(run: run, status: status(), refusal: Delivery(result: .partial, reason: "held", code: .typing)) == nil)
    }

    @Test(arguments: DeliveryCode.allCases.map(Optional.some) + [nil])
    func everyReasonIsOneShortPlainSentence(_ code: DeliveryCode?) {
        let sentence = OperatorWakeNotice.sentence(code)
        #expect(sentence.hasSuffix(".") && sentence.filter { $0 == "." }.count == 1, "\(sentence)")
        #expect(!sentence.contains("—") && sentence.count <= 70, "\(sentence)")
    }

    @Test func aRefusalFromADaemonThatNamesNoCodeStillSaysSomething() throws {
        let notice = try #require(OperatorWakeNotice(run: run, status: nil, refusal: Delivery(result: .refused, reason: "why")))
        #expect(notice.description == "News waits for it. AiTerm couldn’t type into its tab.")
    }
}
