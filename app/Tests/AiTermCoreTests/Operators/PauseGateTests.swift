import Testing
import Foundation
@testable import AiTermCore

/// A clock the gate sleeps on: `idle` is the seconds since your last key or click, nil while neither
/// iTerm2 nor AiTerm is in front; each sleep advances it unless `input` says you acted meanwhile.
@MainActor private final class Desk {
    var idle: TimeInterval? = 0
    var slept: [TimeInterval] = []
    /// Seconds after each sleep starts that you press a key, one entry per sleep; missing means none.
    var input: [TimeInterval?] = []
    var gate: PauseGate {
        PauseGate(pause: 5, idle: { [unowned self] in self.idle }, sleep: { [unowned self] seconds in
            let at = self.input.isEmpty ? nil : self.input.removeFirst()
            self.slept.append(seconds)
            if let at, let idle = self.idle { self.idle = seconds - at } else { self.idle = self.idle.map { $0 + seconds } }
        })
    }
}

@MainActor @Suite struct PauseGateTests {
    @Test func itIsQuietAfterFiveSecondsWithoutAKeyOrAClick() {
        let desk = Desk()
        desk.idle = 4.9
        #expect(!desk.gate.isQuiet)
        desk.idle = 5
        #expect(desk.gate.isQuiet)
    }

    @Test func itIsAlwaysQuietWithAnotherAppInFront() async {
        let desk = Desk()
        desk.idle = nil
        #expect(desk.gate.isQuiet)
        await desk.gate.quiet()
        #expect(desk.slept.isEmpty)
    }

    @Test func aWaitLastsUntilTheRestOfThePause() async {
        let desk = Desk()
        desk.idle = 2
        await desk.gate.quiet()
        #expect(desk.slept == [3])
    }

    @Test func aKeyOrAClickDuringTheWaitStartsThePauseAgain() async {
        let desk = Desk()
        desk.idle = 1
        desk.input = [3]  // during the 4 s sleep you act 3 s in, leaving 1 s of quiet
        await desk.gate.quiet()
        #expect(desk.slept == [4, 4])
        #expect(desk.gate.isQuiet)
    }

    @Test func aCancelledWaitEndsWithoutTheRestOfThePause() async {
        let gate = PauseGate(pause: 5, idle: { 0 }, sleep: { _ in throw CancellationError() })
        await gate.quiet()
        #expect(!gate.isQuiet)
    }

    @Test func aWaitNoLongerWantedEndsAfterAtMostOnePause() async {
        // You keep typing: idle stays 0, and the caller stops wanting the window during the first wait.
        var slept = 0, wanted = true
        let gate = PauseGate(pause: 5, idle: { 0 }, sleep: { _ in slept += 1; wanted = false })
        await gate.quiet(while: { wanted })
        #expect(slept == 1 && !gate.isQuiet)
    }

    @Test func theDefaultGateNeverWaits() async {
        #expect(PauseGate.never.isQuiet)
        await PauseGate.never.quiet()
    }

    @Test func windowsTakeTheTurnOneAtATime() async {
        let turn = WindowTurn()
        var log: [String] = []
        let first = Task { @MainActor in
            await turn.take { log.append("first in"); await Task.yield(); await Task.yield(); log.append("first out") }
        }
        await Task.yield()
        let second = Task { @MainActor in await turn.take { log.append("second in") } }
        let third = Task { @MainActor in await turn.take { log.append("third in") } }
        await first.value; await second.value; await third.value
        #expect(Array(log.prefix(2)) == ["first in", "first out"], "nothing else runs while the first holds the turn")
        #expect(Set(log.dropFirst(2)) == ["second in", "third in"] && log.count == 4)
    }

    @Test func aThrowingTurnPassesTheTurnOn() async {
        let turn = WindowTurn()
        await #expect(throws: CancellationError.self) { try await turn.take { throw CancellationError() } }
        #expect(await turn.take { 1 } == 1)
    }
}
