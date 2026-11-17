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
    struct Input: Sendable {
        var task: TaskItem, scope: Scope, rows: [AgentChoice], projects: [UUID]?, proposal: Proposal, round: Int, discussion: [String]
        /// A work tab's own brief; nil for a stage, whose brief is the task's saved prompt.
        var work: String? = nil
    }
    enum Verdict: Equatable, Sendable { case agreed(String), critique(String), unavailable(String) }
    enum Outcome: Equatable { case decided(AgentChoiceRecord), reply(JSONValue) }
    struct Ports {
        var oracleEnabled: @MainActor () -> Bool
        var oracle: @MainActor (Input) async throws -> Verdict
    }
    private let workspace: WorkspaceStore
    private let now: () -> Date
    private let ports: Ports
    private var active: Set<String> = []
    init(workspace: WorkspaceStore, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.now = now; self.ports = ports
    }

    /// Settles one call. The caller validated `proposal` against `rows` and `projects`. A
    /// critique returns `challenged` with its `challengeId`; the next proposal names it.
    func decide(task: TaskItem, scope: Scope, rows: [AgentChoice], projects: [UUID]?, proposal: Proposal,
                challenge: String?, work: String? = nil) async throws -> Outcome {
        guard workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true,
              workspace.state.operatorSession?.startingFresh == false, let claim = SignalClaim(task), claim.canAct(in: workspace.state) else {
            throw ActionUnavailable("The Operator cannot choose right now.")
        }
        func decided(_ how: AgentChoiceRecord.Decided, row: AgentChoice? = nil, reason: String? = nil, round: Int? = nil, note: String? = nil) -> Outcome {
            .decided(AgentChoiceRecord(row: row ?? proposal.row, project: proposal.project, reason: reason ?? proposal.reason,
                                       decided: how, round: round, note: note, at: now()))
        }
        // One project and one row: only the project was open, and the Operator decides it alone.
        if rows.count == 1 { return decided(.operatorAlone) }
        let ledger = OracleRoundLedger(workspace: workspace, now: now, tool: scope.rawValue)
        let binding = try Self.json(["task": .string(task.id.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership)])
        guard !active.contains(binding) else { return .reply(["status": "pending"]) }
        var previous: OracleRound?
        if let open = ledger.open(binding: binding) {
            switch open.stage {
            case .delivered:
                guard challenge == open.id else {
                    return .reply(["status": "challenged", "challengeId": .string(open.id), "round": .int(open.round ?? 1),
                                   "critique": .string(open.critique ?? "Reply to this Oracle round before starting another.")])
                }
                previous = open
            default:
                // A round a restart interrupted: the Oracle's verdict is lost, so the proposal applies.
                ledger.clear(open.id); workspace.flush()
                return decided(.oracleUnavailable, note: "An earlier Oracle round was interrupted.")
            }
        } else if challenge != nil { throw ActionUnavailable("That Oracle round does not belong to this choice.") }
        guard ports.oracleEnabled() else {
            if let previous { ledger.clear(previous.id); workspace.flush() }
            return decided(.oracleOff)
        }
        let arguments = try Self.json(["row": try JSONValue(encoding: proposal.row), "project": proposal.project.map { .string($0.uuidString) } ?? .null,
                                       "reason": .string(proposal.reason)])
        let (roundID, round, discussion) = try ledger.begin(binding: binding, arguments: arguments, proposal: proposal.text, previous: previous)
        active.insert(binding); defer { active.remove(binding) }
        workspace.mutate { $0.updateSignalTask(task.id) { $0.currentAct = "consulting the Oracle" } }
        guard workspace.flush() else { throw ActionUnavailable("The Oracle round couldn’t be saved.") }
        defer { workspace.mutate { state in if claim.holds(in: state) { state.updateSignalTask(task.id) { $0.currentAct = nil } } } }
        let verdict: Verdict
        do { verdict = try await ports.oracle(Input(task: task, scope: scope, rows: rows, projects: projects, proposal: proposal, round: round, discussion: discussion, work: work)) }
        catch is SignalOracleSettingsChanged where ports.oracleEnabled() {
            ledger.clear(roundID); workspace.flush()
            return .reply(["status": "retry", "next": "The Oracle's settings or the standing instructions changed during its check. Call run_status and propose again without challengeId."])
        } catch { verdict = .unavailable(OperationIssue.reason(of: error)) }
        guard claim.canAct(in: workspace.state), !Task.isCancelled else {
            ledger.clear(roundID); workspace.flush(); throw ActionUnavailable("The task changed while the Oracle read the choice.")
        }
        switch verdict {
        case .agreed:
            ledger.clear(roundID); workspace.flush()
            return decided(.oracleAgreed, round: round)
        case .critique(let text):
            guard round >= OracleRoundLedger.maximumRounds else {
                ledger.critique(roundID, proposal: proposal.text, text: text, discussion: discussion); workspace.flush()
                return .reply(["status": "challenged", "challengeId": .string(roundID), "round": .int(round), "critique": .string(text),
                               "next": "Revise the proposal, pass this challengeId and use a new key."])
            }
            ledger.clear(roundID); workspace.flush()
            return decided(.disagreed, row: rows[0], reason: "The Operator proposed \(proposal.row.label): \(proposal.reason)", round: round, note: text)
        case .unavailable(let reason):
            ledger.clear(roundID); workspace.flush()
            return decided(ports.oracleEnabled() ? .oracleUnavailable : .oracleOff, note: reason)
        }
    }
    nonisolated static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
