import Foundation
import AiTermCore

/// `check_goal`: the Operator's verdict on the broadcast's goal once every task is done, which the Oracle vetoes.
extension OperatorToolHandler {
    func checkGoal(_ call: ToolCall, in run: OperatorRun) throws -> JSONValue {
        throw ToolRefusal("check_goal is not built yet.")
    }
}
