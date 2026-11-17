import Foundation

public extension TaskItem {
    /// For a stage that is about to launch: apply the only row, or wait in `choosing` for the
    /// Operator's choice of row and/or project. A stage without a startable row blocks.
    mutating func prepareLaunch(configuration: Signal, candidates: [UUID]?, at: Date) {
        guard let record = signalTask, record.phase == .launching else { return }
        switch AgentChoiceNeed.decide(permitted: configuration.agents, projects: candidates, conversationAgent: firstWorkerConversation?.agent) {
        case .ready(let row):
            agent = row.agent; model = row.model; reasoning = row.reasoning
        case .choose(let rows, let projects):
            guard var next = try? SignalTransitions.apply(.needChoice, to: record, at: at) else { return }
            next.choosableRows = rows; next.candidateProjects = projects
            signalTask = next
        case .unavailable:
            signalTask?.phase = .blocked; signalTask?.blockedReason = AgentChoiceNeed.unavailableReason
        }
    }

    /// What the Operator may choose now: a `choosing` stage's saved rows and projects, or, for a
    /// blocked stage, the rows it may resume on (its project is fixed). Nil for any other phase.
    func choiceNeed(configuration: Signal?) -> AgentChoiceNeed? {
        guard let record = signalTask else { return nil }
        switch record.phase {
        case .choosing:
            guard let rows = record.choosableRows, !rows.isEmpty else { return .unavailable }
            return .choose(rows: rows, projects: record.candidateProjects)
        case .blocked:
            guard let configuration else { return nil }
            return AgentChoiceNeed.decide(permitted: configuration.agents, projects: nil, conversationAgent: firstWorkerConversation?.agent)
        default: return nil
        }
    }
}
