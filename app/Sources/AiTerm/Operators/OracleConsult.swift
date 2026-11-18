import Foundation
import AiTermCore

/// Runs every Oracle check, under the settings it started with. A check whose setting, standing
/// instructions or revision changed while it ran, or whose Operator stopped, is discarded as `retry`.
/// Only finished rounds are saved: a critique below a use's round limit waits for a revised proposal
/// that names its id, at most `Question.rounds` rounds. Nothing in flight is ever saved.
@MainActor final class OracleConsult {
    /// What a check reads from Settings › Operator, compared before and after it runs.
    struct Settings: Equatable {
        var oracle: OracleSetting, instructions: String, revision: Int
    }
    struct Ports {
        var settings: @MainActor () -> Settings
        /// The runner: the Oracle's critique text, or why it gave none.
        var ask: @MainActor (OracleSetting, String) async -> OracleRunner.Verdict
        var running: @MainActor () -> Bool
    }
    /// What a check is bound to: the task's claim when the use has one, and for a round use the key its rounds
    /// are saved under, the call's arguments and the Operator's proposal.
    struct Binding {
        struct Round: Equatable { var key: String, proposal: String }
        var claim: SignalClaim?
        var round: Round?
        static let none = Binding(claim: nil, round: nil)
    }
    enum Unavailable: Equatable { case off, failed(String), unclear(String) }
    enum Outcome: Equatable {
        case agreed(String, round: Int)
        /// A critique; `challengeId` names the saved round a revision continues, nil once the round limit is reached.
        case critique(String, round: Int, challengeId: String?)
        case person(String)
        case unavailable(Unavailable)
        case retry
    }

    private let workspace: WorkspaceStore
    private let folder: URL
    private let activity: OperatorActivityTracker
    private let now: () -> Date
    private let ports: Ports
    init(workspace: WorkspaceStore, folder: URL, activity: OperatorActivityTracker, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.folder = folder; self.activity = activity; self.now = now; self.ports = ports
    }

    /// Whether the Oracle is switched on in Settings.
    var isOn: Bool { ports.settings().oracle.isOn }

    /// Asks `question` once. `previous` is the saved round a revised proposal continues.
    func consult(_ question: OracleLaunch.Question, binding: Binding, continuing previous: OracleRound? = nil) async -> Outcome {
        let settings = ports.settings()
        guard ports.running(), settings.oracle.isOn else { remove(previous); return .unavailable(.off) }
        let round = (previous?.round ?? 0) + 1, discussion = Self.discussion(of: previous)
        let answer: OracleRunner.Verdict
        do {
            answer = try await activity.during("consulting the Oracle") {
                let folder = self.folder
                try await BackgroundWork.run { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                let prompt = OracleLaunch.standing(settings.instructions, prompt: try question.prompt(discussion: discussion))
                return await ports.ask(settings.oracle, prompt)
            }
        } catch { answer = .unanswered(OperationIssue.reason(of: error)) }
        guard ports.running(), ports.settings() == settings else { remove(previous); return .retry }
        let reply: OracleLaunch.Reply
        switch answer {
        case .unanswered(let reason): remove(previous); return .unavailable(.failed(reason))
        case .critique(let text): reply = question.reply(text)
        }
        // The use's own authority check refuses next; nothing is saved for a claim that no longer holds.
        let current = binding.claim.map { $0.allows(in: workspace) } ?? true
        switch reply {
        case .agreed(let text):
            if current { remove(previous) }
            return .agreed(text, round: round)
        case .person(let text):
            if current { remove(previous) }
            return .person(text)
        case .unclear(let text):
            if current { remove(previous) }
            return .unavailable(.unclear(text))
        case .critique(let text):
            guard current else { return .critique(text, round: round, challengeId: nil) }
            guard round < question.rounds, let tool = question.tool, let key = binding.round else {
                remove(previous); return .critique(text, round: round, challengeId: nil)
            }
            let history = discussion + ["Operator: " + key.proposal, "Oracle: " + text]
            var record = OracleRound(id: UUID().uuidString, tool: tool, stage: .delivered, critique: text,
                                     result: Self.encode(history), askedAt: now(), askedEvidence: key.key, round: round)
            record.reply = key.proposal
            workspace.mutate { state in
                if let previous { state.operatorSession?.oracleRounds.removeAll { $0.id == previous.id } }
                state.operatorSession?.oracleRounds.append(record)
            }
            workspace.flush()
            return .critique(text, round: round, challengeId: record.id)
        }
    }

    /// The saved round of `tool` for `key`, if any.
    func saved(tool: String, key: String) -> OracleRound? {
        workspace.state.operatorSession?.oracleRounds.first { $0.tool == tool && $0.askedEvidence == key }
    }
    /// Saves that an agreed answer is about to be delivered, in place of `replacing`; a restart that finds it asks the
    /// person instead of delivering twice.
    @discardableResult func saveReady(tool: String, binding: Binding.Round, round: Int, replacing: OracleRound? = nil) -> String {
        var record = OracleRound(id: UUID().uuidString, tool: tool, stage: .ready,
                                 askedAt: now(), askedEvidence: binding.key, round: round)
        record.reply = binding.proposal
        save(record, replacing: replacing)
        return record.id
    }
    /// Saves that this binding goes to the person, with why, in place of `replacing`; a retry gets the same outcome.
    func markPerson(tool: String, key: String, reason: String, replacing: OracleRound? = nil) {
        save(OracleRound(id: UUID().uuidString, tool: tool, stage: .unanswered, unansweredReason: reason,
                         askedAt: now(), askedEvidence: key, round: 0), replacing: replacing)
    }
    func clear(_ id: String) {
        workspace.mutate { $0.operatorSession?.oracleRounds.removeAll { $0.id == id } }
        workspace.flush()
    }

    private func save(_ record: OracleRound, replacing previous: OracleRound?) {
        workspace.mutate { state in
            if let previous { state.operatorSession?.oracleRounds.removeAll { $0.id == previous.id } }
            state.operatorSession?.oracleRounds.append(record)
        }
    }
    private func remove(_ round: OracleRound?) {
        guard let round else { return }
        clear(round.id)
    }
    static func discussion(of record: OracleRound?) -> [String] {
        record?.result.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
    private static func encode(_ discussion: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(discussion)) ?? Data("[]".utf8), as: UTF8.self)
    }
}
