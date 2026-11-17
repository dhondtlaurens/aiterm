import Foundation
import AiTermCore

/// The private PreToolUse route always returns a gate decision. A stale token, paused session or
/// malformed call can never become a generic tool error (which the daemon treats as unavailable).
@MainActor final class SignalShellGate {
    let workspace: WorkspaceStore, folder: URL
    let now: () -> Date
    let validate: (OperatorRequest) throws -> Void
    let oracleEnabled: () -> Bool
    let oracle: (String) async throws -> String?
    var changed: () -> Void = {}
    init(workspace: WorkspaceStore, folder: URL, now: @escaping () -> Date,
         validate: @escaping (OperatorRequest) throws -> Void, oracleEnabled: @escaping () -> Bool,
         oracle: @escaping (String) async throws -> String?) {
        self.workspace = workspace; self.folder = folder; self.now = now; self.validate = validate
        self.oracleEnabled = oracleEnabled; self.oracle = oracle
    }
    func respond(_ request: OperatorRequest) async -> JSONValue {
        func answer(_ decision: String, _ reason: String, rewrite: String? = nil) -> JSONValue {
            ["decision": .string(decision), "reason": .string(reason), "rewrite": rewrite.map(JSONValue.string) ?? .null]
        }
        do { try validate(request) } catch { return answer("deny", OperationIssue.reason(of: error)) }
        guard let command = request.arguments["command"]?.stringValue, !command.isEmpty,
              let directory = request.arguments["directory"]?.stringValue, !directory.isEmpty else {
            return answer("deny", "The shell check needs its exact command and directory.")
        }
        if let denial = ShellGate.hardDenial(command) { return answer("deny", denial) }
        let state = workspace.state, gate = GateRequest(command: command, directory: directory)
        let roots = state.projects.map(\.path) + state.tasks.map(\.worktreePath).filter { !$0.isEmpty } + [folder.path]
        let hosts = Set(state.projects.compactMap { ProviderDetector.detect(remoteUrl: $0.remoteUrl).host })
        if case .read(let rewrite) = ShellGate.route(command, in: directory, roots: roots, hosts: hosts) {
            return answer("allow", "A plain read.", rewrite: rewrite)
        }
        if let index = state.operatorSession?.questions.lastIndex(where: {
            $0.gate == gate && $0.resolvedAt != nil && $0.gateConsumedAt == nil
        }), let asked = state.operatorSession?.questions[index] {
            workspace.mutate { $0.operatorSession?.questions[index].gateConsumedAt = now() }
            guard workspace.flush() else { return answer("deny", "The person's decision could not be saved.") }
            let allowed = asked.answer.map { OracleLaunch.gateVerdict($0) == .allow || $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "allow" } ?? false
            return answer(allowed ? "allow" : "deny", allowed ? "Allowed once by the person." : "The person did not allow this command.")
        }
        if let asked = state.operatorSession?.questions.first(where: { $0.gate == gate && $0.resolvedAt == nil }) {
            return answer("deny", "Ask the person in your chat, then resolve_question with question \(asked.id) and their exact answer.")
        }
        guard oracleEnabled() else { return answer("allow", "unchecked: the Oracle is off") }
        let status = (try? SignalOperatorToolHandler.json(JSONValue(encoding: OperatorDigest(state: state, at: now(), oracleOn: true)))) ?? "{}"
        let prompt = OracleLaunch.gatePrompt(command: command, directory: directory,
                                               reason: request.arguments["description"]?.stringValue, run: status)
        let response: String?
        do { response = try await oracle(prompt) }
        catch {
            if error is SignalOracleSettingsChanged, oracleEnabled() { return answer("deny", "The Oracle settings changed. Check this command again.") }
            do { try validate(request) } catch { return answer("deny", OperationIssue.reason(of: error)) }
            return answer("allow", "unchecked: the Oracle could not answer")
        }
        do { try validate(request) } catch { return answer("deny", OperationIssue.reason(of: error)) }
        guard oracleEnabled() else { return answer("allow", "unchecked: the Oracle is off") }
        switch response.map(OracleLaunch.gateVerdict) ?? .unparsed {
        case .allow: return answer("allow", "The Oracle said yes.")
        case .unparsed: return answer("allow", "unchecked: the Oracle gave no clear answer")
        case .redirect(let reason): return answer("deny", "Send this to a worker with message_task. " + reason)
        case .escalate(let reason):
            let key = "gate-" + UUID().uuidString
            var question = OperatorSession.Question(id: key, task: nil,
                text: "May the Operator run this command? " + reason + "\n" + command + "\nIn: " + directory, openedAt: now())
            question.gate = gate
            workspace.mutate { $0.operatorSession?.questions.append(question) }
            guard workspace.flush() else { return answer("deny", "The shell question could not be saved.") }
            changed()
            return answer("deny", "Ask the person as plain text in your chat: \(question.text)\nThen resolve_question with question \(key) and their exact answer. Never assume consent.")
        }
    }
}
