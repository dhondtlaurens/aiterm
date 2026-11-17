import Foundation
import AiTermCore

/// The Operator proposes an agent row (and project) for a stage or a work tab; the Oracle agrees or
/// critiques, at most three rounds. The choice never reaches the person: with the Oracle off or
/// unavailable the proposal applies, and three disagreeing rounds fall back to the first row.
@MainActor final class AgentChoiceRounds {
    enum Scope: String, Sendable { case stage = "choose_agent", tab = "open_tab" }
    struct Proposal: Equatable, Sendable {
        var row: AgentChoice, project: UUID?, reason: String
        var text: String { "\(row.label)" + (project.map { " in project \($0.uuidString)" } ?? "") + ". " + reason }
    }
    enum Outcome: Equatable { case decided(AgentChoiceRecord), reply(JSONValue) }
    struct Ports {
        var weeklyUsage: @MainActor () -> [AgentKind: Int]
        var installedAgents: @MainActor () -> Set<AgentKind>
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let oracle: OracleConsult
    private let ports: Ports
    private let effects: OperatorInFlight
    init(workspace: WorkspaceStore, now: @escaping () -> Date, oracle: OracleConsult, ports: Ports,
         effects: OperatorInFlight = OperatorInFlight()) {
        self.workspace = workspace; self.now = now; self.oracle = oracle; self.ports = ports; self.effects = effects
    }

    /// Settles one call. The caller validated `proposal` against `rows` and `projects`. A
    /// critique returns `challenged` with its `challengeId`; the next proposal names it. The round holds
    /// the task and releases it before it returns, so the caller's launch or tab can claim it.
    func decide(task: TaskItem, scope: Scope, rows: [AgentChoice], projects: [UUID]?, proposal: Proposal,
                challenge: String?, work: String? = nil) async throws -> Outcome {
        guard workspace.state.operatorSession?.startingFresh == false, let claim = SignalClaim(task), claim.allows(in: workspace) else {
            throw ActionUnavailable("The Operator cannot choose right now.")
        }
        func decided(_ how: AgentChoiceRecord.Decided, row: AgentChoice? = nil, reason: String? = nil, round: Int? = nil, note: String? = nil) -> Outcome {
            .decided(AgentChoiceRecord(row: row ?? proposal.row, project: proposal.project, reason: reason ?? proposal.reason,
                                       decided: how, round: round, note: note, at: now()))
        }
        // One project and one row: only the project was open, and the Operator decides it alone.
        if rows.count == 1 { return decided(.operatorAlone) }
        let binding = try Self.json(["task": .string(task.id.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership)])
        guard effects.claim(task.id) else { return .reply(["status": "pending"]) }
        defer { effects.release(task.id) }
        var previous: OracleRound?
        if let open = oracle.saved(tool: scope.rawValue, key: binding) {
            guard challenge == open.id else {
                return .reply(["status": "challenged", "challengeId": .string(open.id), "round": .int(open.round ?? 1),
                               "critique": .string(open.critique ?? "Reply to this Oracle round before starting another.")])
            }
            previous = open
        } else if challenge != nil { throw ActionUnavailable("That Oracle round does not belong to this choice.") }
        guard oracle.isOn else {
            if let previous { oracle.clear(previous.id) }
            return decided(.oracleOff)
        }
        let arguments = try Self.json(["row": try JSONValue(encoding: proposal.row), "project": proposal.project.map { .string($0.uuidString) } ?? .null,
                                       "reason": .string(proposal.reason)])
        workspace.mutate { $0.updateSignalTask(task.id) { $0.currentAct = "consulting the Oracle" } }
        guard workspace.flush() else { throw ActionUnavailable("The choice couldn’t be saved.") }
        defer { workspace.mutate { state in if claim.holds(in: state) { state.updateSignalTask(task.id) { $0.currentAct = nil } } } }
        let line = { (id: UUID) -> OracleLaunch.ProjectLine in self.workspace.state.project(id: id).map { .known($0) } ?? .gone(id) }
        let check = OracleLaunch.AgentChoiceCheck(forTab: scope == .tab, item: task.signalTask?.current.item.identity ?? "", title: task.title,
            stagePrompt: task.signalTask?.current.prompt ?? "", work: work, project: line(proposal.project ?? task.projectId),
            candidateProjects: projects.map { $0.map(line) }, permittedRows: rows, row: proposal.row, reason: proposal.reason,
            weeklyUsage: ports.weeklyUsage(), installed: ports.installedAgents())
        let outcome = await oracle.consult(.agentChoice(check), binding: .init(claim: claim, round: .init(key: binding, arguments: arguments, proposal: proposal.text)),
                                           continuing: previous)
        guard claim.allows(in: workspace) else { throw ActionUnavailable("The task changed while the Oracle read the choice.") }
        switch outcome {
        case .agreed(_, let round):
            return decided(.oracleAgreed, round: round)
        case .critique(let text, let round, let challengeID?):
            return .reply(["status": "challenged", "challengeId": .string(challengeID), "round": .int(round), "critique": .string(text),
                           "next": "Revise the proposal, pass this challengeId and use a new key."])
        case .critique(let text, let round, nil):
            return decided(.disagreed, row: rows[0], reason: "The Operator proposed \(proposal.row.label): \(proposal.reason)", round: round, note: text)
        case .unavailable(.off):
            return decided(.oracleOff)
        case .person(let reason), .unavailable(.failed(let reason)), .unavailable(.unclear(let reason)):
            return decided(.oracleUnavailable, note: reason)
        case .retry:
            return .reply(["status": "retry", "next": "The Oracle's settings or the standing instructions changed during its check. Call run_status and propose again without challengeId."])
        }
    }
    nonisolated static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
