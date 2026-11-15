import Foundation
import AiTermCore

/// A stable editing identity, independent of the agent/model/reasoning combination being edited.
struct AgentChoiceRow: Identifiable, Equatable {
    var id = UUID()
    var choice: AgentChoice
}
