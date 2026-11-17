import Foundation
import AiTermCore

/// The saved Operator ↔ Oracle rounds for one tool, bound to what they decide (`askedEvidence`).
/// A critique carries its `challengeId`; the next proposal names it to continue the same
/// discussion, at most three rounds. Owners decide what an outcome means; this only keeps the record.
@MainActor struct OracleRoundLedger {
    static let maximumRounds = 3
    let workspace: WorkspaceStore
    let now: () -> Date
    let tool: String

    /// The saved round for this binding, if any.
    func open(binding: String) -> ChallengeRecord? {
        workspace.state.operatorSession?.oracleRounds.first { $0.tool == tool && $0.askedEvidence == binding }
    }
    /// Saves round `previous.round + 1` (or 1) for `proposal`, replacing the round it continues.
    func begin(binding: String, arguments: String, proposal: String, previous: ChallengeRecord?) throws -> (id: String, round: Int, discussion: [String]) {
        let round = (previous?.round ?? 0) + 1, id = UUID().uuidString
        var record = ChallengeRecord(id: id, tool: tool, askedArguments: arguments, askedAt: now(), askedEvidence: binding, round: round)
        record.reply = proposal
        let discussion = Self.discussion(of: previous)
        record.result = String(decoding: try JSONEncoder().encode(discussion), as: UTF8.self)
        workspace.mutate { state in
            if let previous { state.operatorSession?.oracleRounds.removeAll { $0.id == previous.id } }
            state.operatorSession?.oracleRounds.append(record)
        }
        return (id, round, discussion)
    }
    /// Records the Oracle's critique; the round now waits for a revised proposal naming it.
    func critique(_ id: String, proposal: String, text: String, discussion: [String]) {
        let history = discussion + ["Operator: " + proposal, "Oracle: " + text]
        workspace.mutate { state in
            if let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == id }) {
                state.operatorSession?.oracleRounds[index].stage = .delivered
                state.operatorSession?.oracleRounds[index].critique = text
                state.operatorSession?.oracleRounds[index].result = String(decoding: try! JSONEncoder().encode(history), as: UTF8.self)
            }
        }
    }
    func ready(_ id: String) {
        workspace.mutate { state in
            if let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == id }) {
                state.operatorSession?.oracleRounds[index].stage = .ready
            }
        }
    }
    /// Ends the discussion without agreement; the record stays so a retry gets the same outcome.
    func unchallenged(_ id: String, reason: String) {
        workspace.mutate { state in
            guard let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == id }) else { return }
            state.operatorSession?.oracleRounds[index].stage = .unchallenged
            state.operatorSession?.oracleRounds[index].unchallengedReason = reason
        }
    }
    /// A marker that no Oracle round ran for this binding, with why.
    func marker(binding: String, arguments: String, reason: String) {
        let marker = ChallengeRecord(id: UUID().uuidString, tool: tool, stage: .unchallenged,
                                     askedArguments: arguments, unchallengedReason: reason, askedAt: now(), askedEvidence: binding, round: 0)
        workspace.mutate { $0.operatorSession?.oracleRounds.append(marker) }
    }
    func clear(_ id: String) { workspace.mutate { $0.operatorSession?.oracleRounds.removeAll { $0.id == id } } }
    static func discussion(of record: ChallengeRecord?) -> [String] {
        record?.result.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
}
