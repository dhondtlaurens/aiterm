import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

struct SignalStatusLineTests {
    @Test func aShortActStaysReadableBeforeTheBadgesReturn() {
        var pose = SignalBadgePose()
        let act = OperatorLine("Operator answering its worker", look: .acting)
        pose.update(act, at: 10)
        pose.update(nil, at: 10.1)
        #expect(pose.display == act)
        #expect(abs(pose.delay(at: 10.1) - 2.9) < 0.001)
        pose.update(nil, at: 13)
        #expect(pose.display == nil && pose.delay(at: 13) == 0)
    }
    @Test func aNewActReplacesThePreviousActDirectlyAndGetsItsOwnHold() {
        var pose = SignalBadgePose()
        let first = OperatorLine("Operator starting its worker", look: .acting)
        let next = OperatorLine("Operator consulting the Oracle", look: .acting)
        pose.update(first, at: 10); pose.update(next, at: 11)
        #expect(pose.display == next)
        pose.update(.init("waiting on a reviewer"), at: 11.1)
        #expect(pose.display == next)
        pose.update(.init("waiting on a reviewer"), at: 14)
        #expect(pose.display?.text == "waiting on a reviewer")
        pose.update(nil, at: 14.1)
        #expect(pose.display == nil, "A quiet state needs no extra action hold")
    }
    @Test func theLineSaysTheHeldActThenTheLineThenWorking() {
        let act = OperatorLine("Operator answering its worker", look: .acting)
        let waiting = OperatorLine("waiting on a reviewer")
        #expect(SignalStatusLine.shown(held: act, line: nil, working: true) == act, "A held act outlasts the line")
        #expect(SignalStatusLine.shown(held: nil, line: waiting, working: true) == waiting)
        #expect(SignalStatusLine.shown(held: nil, line: nil, working: true) == SignalStatusLine.working)
        #expect(SignalStatusLine.shown(held: nil, line: nil, working: false) == nil, "Empty, at its height")
        #expect(SignalStatusLine.working.look == .quiet, "The worker works; the Operator does not act")
    }
}
