import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// What AiTerm got wrong, as the Operator reports it (`report_snag`): kept on the run, and worded as the
/// prompt of an AiTerm task that fixes it.
@Suite struct OperatorSnagTests {
    private let runId = UUID(uuidString: "4F0E6A3C-1B7D-4C55-9E21-7A6D0B3C8F10")!
    private let at = Date(timeIntervalSince1970: 1_792_000_000)

    private func snag(task: Bool = true, evidence: String? = "Tab 2 showed \"Allow edits?\"; the sidebar said working.") -> OperatorSnag {
        OperatorSnag(key: "stale-prompt", title: "A prompt shows as working", showed: "The row said working.",
                     actual: "The worker was waiting on a permission prompt.", workaround: "Opened the tab and answered it.",
                     evidence: evidence, task: task ? UUID() : nil, taskKey: task ? "PAY-240" : nil, branch: task ? "feat/pay-240" : nil,
                     appVersion: "0.28.0", at: at)
    }

    /// The prompt an AiTerm task starts from, word for word: Laurens pastes it as it is.
    @Test func theFixTaskIsTheSpecsTemplate() {
        let stamp = ISO8601DateFormatter().string(from: at)
        #expect(snag().fixTask(broadcast: "Sprint 42", runId: runId) == """
            Fix in AiTerm: A prompt shows as working

            Seen in broadcast "Sprint 42" (4F0E6A3C-1B7D-4C55-9E21-7A6D0B3C8F10), task PAY-240 on feat/pay-240, AiTerm 0.28.0, \(stamp).

            What AiTerm showed: The row said working.
            What was true: The worker was waiting on a permission prompt.
            How the Operator got unstuck: Opened the tab and answered it.
            Evidence:
            Tab 2 showed "Allow edits?"; the sidebar said working.

            Make AiTerm show what was true here, so the Operator doesn't have to work around it.
            """)
    }

    /// A snag from the Operator's own chat names no task, and one with nothing to show has no evidence: those lines go.
    @Test func aSnagWithoutTaskOrEvidenceLeavesThoseOut() {
        let text = snag(task: false, evidence: nil).fixTask(broadcast: "Sprint 42", runId: runId)
        let seen = text.split(separator: "\n").first { $0.hasPrefix("Seen in") }
        #expect(seen?.hasPrefix("Seen in broadcast \"Sprint 42\" (4F0E6A3C-1B7D-4C55-9E21-7A6D0B3C8F10), AiTerm 0.28.0, ") == true)
        #expect(seen?.contains("task ") == false && !text.contains("Evidence:"))
        #expect(!snag(task: true, evidence: "  \n").fixTask(broadcast: "Sprint 42", runId: runId).contains("Evidence:"))
    }

    /// A broadcast saved before snags existed reads as having none, and a run with snags keeps them.
    @Test func aRunSavedBeforeSnagsDecodesWithNone() throws {
        let profile = OperatorProfile(model: "m", reasoning: nil)
        var run = OperatorRun(id: runId, name: "Sprint 42", profile: profile, prompt: "Do it", createdAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any])
        #expect(object.removeValue(forKey: "snags") != nil)
        let old = try decoder.decode(OperatorRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.snags == [])

        run.snags = [snag(), snag(task: false, evidence: nil)]
        #expect(try decoder.decode(OperatorRun.self, from: encoder.encode(run)) == run)
    }
}
