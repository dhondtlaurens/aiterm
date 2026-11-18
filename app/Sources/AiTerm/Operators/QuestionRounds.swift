import Foundation
import CryptoKit
import AiTermCore

/// The Operator proposes; the Oracle agrees or critiques, at most three times. Only ask_you
/// records a question asked in the Operator's chat. No menu or worker turn is blocked.
@MainActor final class QuestionRounds {
    struct Question: Equatable, Sendable {
        var session: String, tab: String, text: String, message: String
        var conversation: String? = nil
        var fingerprint: String? = nil
        var identity: String {
            fingerprint ?? SHA256.hash(data: Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Ports {
        var question: @MainActor (UUID, String) -> Question?
        var deliver: @MainActor (TaskItem, Question, String) async throws -> Void
    }
    static let tool = "answer_worker"
    private let workspace: WorkspaceStore
    private let journal: SignalJournal
    private let now: () -> Date
    private let oracle: OracleConsult
    private let ports: Ports
    private let effects: OperatorInFlight
    /// Where a round shows as its task's act.
    private let activity: OperatorActivityTracker
    var changed: () -> Void = {}
    init(workspace: WorkspaceStore, journal: SignalJournal, now: @escaping () -> Date, oracle: OracleConsult, ports: Ports,
         effects: OperatorInFlight = OperatorInFlight(), activity: OperatorActivityTracker = OperatorActivityTracker()) {
        self.workspace = workspace; self.journal = journal; self.now = now; self.oracle = oracle; self.ports = ports; self.effects = effects
        self.activity = activity
    }
    /// One `answer_worker` call. The tool handler makes it idempotent by its key; this owner saves
    /// only the Oracle rounds and the agreed round that makes a restart ask the person.
    func answer(task id: UUID, proposal: String, tab: String = "main", challenge: String? = nil,
                fromQuestion: String? = nil, person: Bool = false) async throws -> JSONValue {
        guard workspace.canChangeWorkspace, !proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.state.operatorSession?.lifecycle.isChanging == false else { throw ActionUnavailable("The Operator cannot answer right now.") }
        let operatorID = workspace.state.operatorSession?.id, operatorGeneration = workspace.state.operatorSession?.generation
        guard let task = workspace.state.task(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), task.signalTask?.phase == .working,
              let question = ports.question(id, tab) else { throw ActionUnavailable("This worker has no current unanswered question.") }
        let binding = try Self.json(["task": .string(id.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership),
                                      "session": .string(question.session), "conversation": question.conversation.map(JSONValue.string) ?? .null,
                                      "tab": .string(question.tab), "fingerprint": .string(question.identity)])
        func stillAsks() -> Bool {
            claim.allows(in: workspace)
                && ports.question(id, tab) == question && workspace.state.operatorSession?.lifecycle.isChanging == false
                && workspace.state.operatorSession?.id == operatorID && workspace.state.operatorSession?.generation == operatorGeneration
        }
        // The round holds the task from its start through delivering the agreed answer.
        guard effects.claim(id) else { return ["status": "pending"] }
        defer { effects.release(id) }
        var humanAnswer = false
        if let fromQuestion {
            guard let asked = workspace.state.operatorSession?.questions.first(where: { $0.id == fromQuestion }),
                  asked.resolvedAt != nil, asked.task == id, asked.stage == claim.stage, asked.ownership == claim.ownership,
                  asked.workerBinding == binding, asked.tab == tab, asked.answer == proposal, asked.deliveredAt == nil else {
                throw ActionUnavailable("That recorded answer does not belong to this worker's current question.")
            }
            humanAnswer = true
        }
        let round = OracleConsult.Binding.Round(key: binding, proposal: proposal)
        func markPerson(_ reason: String, replacing: OracleRound? = nil) {
            oracle.markPerson(tool: Self.tool, key: binding, reason: reason, replacing: replacing)
        }
        var previous: OracleRound?
        if !humanAnswer {
            if let asked = workspace.state.operatorSession?.questions.first(where: {
                $0.task == id && $0.stage == claim.stage && $0.ownership == claim.ownership && $0.tab == tab
                    && $0.workerBinding == binding && $0.resolvedAt == nil
            }) {
                return ["status": "ask_you", "question": .string(asked.text), "questionKey": .string(asked.id),
                        "next": "Wait for the person's answer in your chat."]
            }
            if let open = oracle.saved(tool: Self.tool, key: binding) {
                if open.stage == .unanswered {
                    return askPerson(question, reason: open.unansweredReason ?? "The Operator and Oracle still disagree after three rounds.")
                }
                if open.stage == .ready {
                    markPerson("The earlier attempt was interrupted; check the worker before answering again.", replacing: open)
                    return askPerson(question, reason: "The earlier attempt was interrupted; check the worker before answering again.")
                }
                guard challenge == open.id else {
                    return ["status": "challenged", "challengeId": .string(open.id), "round": .int(open.round ?? 1),
                            "critique": .string(open.critique ?? "Reply to this Oracle round before starting another.")]
                }
                previous = open
            } else if challenge != nil { throw ActionUnavailable("That Oracle round does not belong to this worker's current question.") }
            if person || !oracle.isOn {
                let reason = person ? "The Operator says this is your decision." : "The Oracle is off."
                markPerson(reason, replacing: previous)
                return askPerson(question, reason: reason)
            }
        }
        if previous == nil, let challenge { oracle.clear(challenge) }
        return try await activity.acting(task: id, act: humanAnswer ? "answering its worker" : "consulting the Oracle") {
            try await journal.append(.quoted(SignalQuote(source: "worker", text: question.text)), task: id)
            guard stillAsks() else { throw ActionUnavailable("The task or its question changed.") }
            let outcome: OracleConsult.Outcome
            if humanAnswer { outcome = .agreed("The person answered in the Operator's chat.", round: 0) }
            else {
                outcome = await oracle.consult(.workerAnswer(question: question.text, workerMessage: question.message, proposal: proposal,
                                                             brief: task.signalTask?.current.prompt ?? ""),
                                               binding: .init(claim: claim, round: round), continuing: previous)
            }
            guard stillAsks() else {
                if case .critique(_, _, let saved?) = outcome { oracle.clear(saved) }
                throw ActionUnavailable("The task or its question changed while the Oracle read it.")
            }
            switch outcome {
            case .agreed(_, let number):
                // A crash after this marker may have delivered. A restart asks the person instead of
                // typing the same answer twice into a worker that may already be at work again.
                let readyID = oracle.saveReady(tool: Self.tool, binding: round, round: number)
                guard workspace.flush() else { throw ActionUnavailable("The answer intent couldn’t be saved.") }
                return try await activity.acting(task: id, act: "answering its worker") {
                    try await journal.append(.ours("Proposed worker answer: " + proposal), task: id)
                    guard stillAsks(), let current = workspace.state.task(id: id) else { oracle.clear(readyID); throw ActionUnavailable("The task or question changed.") }
                    try await ports.deliver(current, question, proposal)
                    guard claim.allows(in: workspace), workspace.state.operatorSession?.id == operatorID,
                          workspace.state.operatorSession?.generation == operatorGeneration else { oracle.clear(readyID); throw ActionUnavailable("The task changed while its answer was delivered.") }
                    if let fromQuestion {
                        workspace.mutate { state in
                            if let index = state.operatorSession?.questions.firstIndex(where: { $0.id == fromQuestion }) {
                                state.operatorSession?.questions[index].deliveredAt = now()
                            }
                        }
                    }
                    oracle.clear(readyID)
                    return ["status": "answered"]
                }
            case .critique(let text, let number, let challengeID?):
                return ["status": "challenged", "challengeId": .string(challengeID), "round": .int(number), "critique": .string(text)]
            case .critique(let text, _, nil):
                let reason = "The Operator and Oracle still disagree after three rounds. " + text
                markPerson(reason)
                return askPerson(question, reason: reason)
            case .person(let reason), .unavailable(.failed(let reason)), .unavailable(.unclear(let reason)):
                markPerson(reason)
                return askPerson(question, reason: reason)
            case .unavailable(.off):
                markPerson("The Oracle is off.")
                return askPerson(question, reason: "The Oracle is off.")
            case .retry:
                return ["status": "retry", "next": "The Oracle's settings or the standing instructions changed during its check. Call run_status and propose again without challengeId, with a new key."]
            }
        }
    }
    func askYou(key: String, task: UUID? = nil, text: String, tab: String = "main") throws {
        guard workspace.canChangeWorkspace, workspace.state.operatorSession != nil, !key.isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ActionUnavailable("A question needs a key and text.") }
        if let old = workspace.state.operatorSession?.questions.first(where: { $0.id == key }) {
            guard old.task == task && old.text == text else { throw ActionUnavailable("That question key is already in use.") }
            return
        }
        let record = task.flatMap { workspace.state.task(id: $0)?.signalTask }
        if task != nil, record == nil { throw ActionUnavailable("This task is no longer the Operator’s.") }
        var question = OperatorSession.Question(id: key, task: task, text: text, openedAt: now())
        question.stage = record?.stage; question.ownership = record?.ownership; question.tab = tab
        question.workerQuestion = task.flatMap { ports.question($0, tab)?.text }
        let binding: String?
        if let task, let current = workspace.state.task(id: task), let claim = SignalClaim(current), let worker = ports.question(task, tab) {
            binding = try Self.json(["task": .string(task.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership),
                                     "session": .string(worker.session), "conversation": worker.conversation.map(JSONValue.string) ?? .null,
                                     "tab": .string(worker.tab), "fingerprint": .string(worker.identity)])
        } else { binding = nil }
        question.workerBinding = binding
        workspace.mutate { state in
            state.operatorSession?.questions.append(question)
            if let binding {
                state.operatorSession?.oracleRounds.removeAll {
                    $0.tool == Self.tool && $0.askedEvidence == binding && ($0.stage == .delivered || $0.stage == .unanswered)
                }
            }
            state.operatorSession?.prune(at: now())
        }
        guard workspace.flush() else { throw ActionUnavailable("The question couldn’t be saved.") }
        changed()
    }
    func resolveQuestion(key: String, answer: String) throws {
        guard workspace.canChangeWorkspace, let index = workspace.state.operatorSession?.questions.firstIndex(where: { $0.id == key }) else {
            throw ActionUnavailable("No recorded question has that key.")
        }
        if let old = workspace.state.operatorSession?.questions[index], old.resolvedAt != nil {
            guard old.answer == answer else { throw ActionUnavailable("This question already has a different answer.") }; return
        }
        workspace.mutate { state in
            state.operatorSession?.questions[index].resolvedAt = now()
            state.operatorSession?.questions[index].answer = answer
            state.operatorSession?.prune(at: now())
        }
        guard workspace.flush() else { throw ActionUnavailable("The answer couldn’t be saved.") }
        changed()
    }
    private func askPerson(_ question: Question, reason: String) -> JSONValue {
        ["status": "ask_you", "question": .string(question.text), "reason": .string(reason),
         "next": "Ask the person in your chat, then record that question with ask_you."]
    }
    nonisolated private static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
