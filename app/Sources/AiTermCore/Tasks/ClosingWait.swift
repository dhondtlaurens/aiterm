import Foundation

public enum ClosingWait: String, Codable, Sendable, LocalizedError {
    case turn, agentTurn, helper

    public var text: String {
        switch self {
        case .turn: "Waiting for your turn to end"
        case .agentTurn: "Waiting for its turn to end"
        case .helper: "Waiting for the helper"
        }
    }

    public var errorDescription: String? { text }
}
