import Foundation
import AiTermCore

/// `record_review`: a review tab's verdict on one commit of its task, kept on the task (`ReviewVerdict`).
extension OperatorToolHandler {
    func recordReview(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        throw ToolRefusal("record_review is not built yet.")
    }
}
