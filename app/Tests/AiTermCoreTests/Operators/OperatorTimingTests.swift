import Testing
import Foundation
@testable import AiTermCore

@Suite struct OperatorTimingTests {
    /// The contract's table, value for value.
    @Test func theTimingsAreTheContractsValues() {
        #expect(OperatorTiming.submitDelay == 0.4)
        #expect(OperatorTiming.typingQuiet == 10)
        #expect(OperatorTiming.messageFileThreshold == 2000)
        #expect(OperatorTiming.wakeCoalesce == 3)
        #expect(OperatorTiming.reconcileInterval == 60)
        #expect(OperatorTiming.stallAfter == 1200)
        #expect(OperatorTiming.challengeTimeout == 180)
        #expect(OperatorTiming.gateTimeout == 200)
        #expect(OperatorTiming.operatorRequestTimeout == 30)
        #expect(OperatorTiming.launchAdoptAfter == 60)
        #expect(OperatorTiming.mergePoll == 30)
        #expect(OperatorTiming.mergeWait == 3600)
        #expect(OperatorTiming.agentReviewTimeout == 900)
        #expect(OperatorTiming.liveQuietMinutes == 2)
    }

    /// The daemon spells the same constants in `aitermd/delivery.py` (part A): each shared value
    /// must read the same there. Before that file exists there is nothing to compare.
    @Test func theDaemonAgreesOnTheSharedTimings() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/aitermd/delivery.py")
        guard let python = try? String(contentsOf: file, encoding: .utf8) else { return }
        let shared: [(String, Double)] = [
            ("SUBMIT_DELAY", OperatorTiming.submitDelay), ("TYPING_QUIET", OperatorTiming.typingQuiet),
            ("MESSAGE_FILE_THRESHOLD", Double(OperatorTiming.messageFileThreshold)), ("WAKE_COALESCE", OperatorTiming.wakeCoalesce),
            ("RECONCILE_INTERVAL", OperatorTiming.reconcileInterval), ("STALL_AFTER", OperatorTiming.stallAfter),
            ("CHALLENGE_TIMEOUT", OperatorTiming.challengeTimeout), ("GATE_TIMEOUT", OperatorTiming.gateTimeout),
            ("OPERATOR_REQUEST_TIMEOUT", OperatorTiming.operatorRequestTimeout),
            ("LAUNCH_ADOPT_AFTER", OperatorTiming.launchAdoptAfter),
        ]
        for (name, value) in shared {
            let read = try #require(Self.pythonConstant(name, in: python), "delivery.py has no \(name)")
            #expect(read == value, "\(name) is \(read) in delivery.py and \(value) in OperatorTiming")
        }
    }

    /// The reader itself, so a comparison that quietly reads nothing cannot pass.
    @Test func theReaderReadsThePythonForms() {
        let python = "SUBMIT_DELAY = 0.4\nSTALL_AFTER: Final[float] = 20 * 60\nMESSAGE_FILE_THRESHOLD: int = 2_000\n# X = 1\n"
        #expect(Self.pythonConstant("SUBMIT_DELAY", in: python) == 0.4)
        #expect(Self.pythonConstant("STALL_AFTER", in: python) == 1200)
        #expect(Self.pythonConstant("MESSAGE_FILE_THRESHOLD", in: python) == 2000)
        #expect(Self.pythonConstant("X", in: python) == nil)
    }

    /// A module-level `NAME = number` or `NAME: type = number`, optionally `* number`.
    static func pythonConstant(_ name: String, in text: String) -> Double? {
        let pattern = "(?m)^" + name + #"(?:\s*:\s*[^=\n]+)?\s*=\s*([0-9_.]+)(?:\s*\*\s*([0-9_.]+))?"#
        guard let regex = try? Regex(pattern), let match = text.firstMatch(of: regex) else { return nil }
        func number(_ i: Int) -> Double? {
            match.output[i].substring.flatMap { Double($0.replacingOccurrences(of: "_", with: "")) }
        }
        guard let first = number(1) else { return nil }
        return first * (number(2) ?? 1)
    }

    /// Each end as the plan, the overview and a refusal say it.
    @Test func eachEndIsSaidByItsName() {
        #expect(TaskEnd.allCases.map(\.displayName) == ["commit", "draft MR", "merge", "local merge"])
    }
}
