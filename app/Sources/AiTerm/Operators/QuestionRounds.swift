import Foundation
import AiTermCore

/// The Operator proposes; the Oracle agrees or critiques, at most three times. Only ask_you
/// records a question asked in the Operator's chat. No board, menu or worker turn is blocked.
@MainActor final class QuestionRounds {
    struct Question: Equatable, Sendable {
        var session: String, tab: String, text: String, message: String
    }
    struct Input: Sendable {
        var task: TaskItem, question: Question, proposal: String, round: Int, discussion: [String]
    }
    enum Verdict: Equatable, Sendable { case agreed(String), critique(String), person(String), unavailable(String) }
    struct Ports {
        var oracleEnabled: @MainActor () -> Bool
        var question: @MainActor (UUID, String) -> Question?
        var oracle: @MainActor (Input) async throws -> Verdict
        var deliver: @MainActor (TaskItem, Question, String) async throws -> Void
    }
    private let workspace: WorkspaceStore
    private let journal: SignalJournal
    private let now: () -> Date
    private let ports: Ports
    private var running: Set<String> = []
    private var activeQuestions: Set<String> = []
    var changed: () -> Void = {}
    init(workspace: WorkspaceStore, journal: SignalJournal, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.journal = journal; self.now = now; self.ports = ports
    }
    func answer(task id: UUID, key: String, proposal: String, tab: String = "main", challenge: String? = nil,
                fromQuestion: String? = nil, person: Bool = false) async throws -> JSONValue {
        guard workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true, !key.isEmpty, !proposal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspace.state.operatorSession?.startingFresh == false else { throw ActionUnavailable("The Operator cannot answer right now.") }
        let operatorID = workspace.state.operatorSession?.id, operatorGeneration = workspace.state.operatorSession?.generation
        let ledgerKey = "answer_worker:" + key
        let arguments = try Self.json(["task": .string(id.uuidString), "tab": .string(tab), "proposal": .string(proposal),
                                       "challenge": challenge.map(JSONValue.string) ?? .null,
                                       "fromQuestion": fromQuestion.map(JSONValue.string) ?? .null, "person": .bool(person)])
        if let cached = workspace.state.operatorSession?.ledger.first(where: { $0.key == ledgerKey }) {
            guard cached.arguments == arguments else { throw ActionUnavailable("This key was already used for a different answer.") }
            var result: JSONValue?
            workspace.mutate { result = $0.operatorSession?.cached(key: ledgerKey, at: now()) }
            if let result { return result }
        }
        guard !running.contains(ledgerKey) else { return ["status": "pending"] }
        guard let task = workspace.state.task(id: id), let claim = SignalClaim(task), task.signalTask?.phase == .working,
              let question = ports.question(id, tab) else { throw ActionUnavailable("This worker has no current unanswered question.") }
        let binding = try Self.json(["task": .string(id.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership),
                                      "session": .string(question.session), "tab": .string(question.tab), "question": .string(question.text)])
        guard !activeQuestions.contains(binding) else { return ["status": "pending"] }
        func stillAsks() -> Bool {
            workspace.canChangeWorkspace && !Task.isCancelled && claim.holds(in: workspace.state)
                && ports.question(id, tab) == question && workspace.state.operatorSession?.startingFresh == false
                && workspace.state.operatorSession?.paused != true
                && workspace.state.operatorSession?.id == operatorID && workspace.state.operatorSession?.generation == operatorGeneration
        }
        running.insert(ledgerKey); activeQuestions.insert(binding)
        defer { running.remove(ledgerKey); activeQuestions.remove(binding) }
        var humanAnswer = false
        if let fromQuestion {
            guard let asked = workspace.state.operatorSession?.questions.first(where: { $0.id == fromQuestion }),
                  asked.resolvedAt != nil, asked.task == id, asked.stage == claim.stage, asked.ownership == claim.ownership,
                  asked.workerQuestion == question.text, asked.tab == tab, asked.answer == proposal else {
                throw ActionUnavailable("That recorded answer does not belong to this worker's current question.")
            }
            humanAnswer = true
        }
        var previous: ChallengeRecord?
        if !humanAnswer {
            if let asked = workspace.state.operatorSession?.questions.first(where: {
                $0.task == id && $0.stage == claim.stage && $0.ownership == claim.ownership && $0.tab == tab
                    && $0.workerQuestion == question.text && $0.resolvedAt == nil
            }) {
                return try remember(["status": "ask_you", "question": .string(asked.text), "questionKey": .string(asked.id),
                                     "next": "Wait for the person's answer in your chat."], key: ledgerKey, arguments: arguments)
            }
            if let open = workspace.state.operatorSession?.oracleRounds.first(where: { $0.tool == "answer_worker" && $0.askedEvidence == binding }) {
                if open.stage == .unchallenged || (open.round ?? 0) >= 3 {
                    return try remember(askPerson(question, reason: open.unchallengedReason ?? "The Operator and Oracle still disagree after three rounds."), key: ledgerKey, arguments: arguments)
                }
                if open.stage == .running || open.stage == .ready {
                    markForPerson(open.id, reason: "The earlier attempt was interrupted; check the worker before answering again.")
                    return try remember(askPerson(question, reason: "The earlier attempt was interrupted; check the worker before answering again."), key: ledgerKey, arguments: arguments)
                }
                guard challenge == open.id else {
                    return try remember(["status": "challenged", "challengeId": .string(open.id), "round": .int(open.round ?? 1),
                                         "critique": .string(open.critique ?? "Reply to this Oracle round before starting another.")], key: ledgerKey, arguments: arguments)
                }
                previous = open
            } else if challenge != nil { throw ActionUnavailable("That Oracle round does not belong to this worker's current question.") }
            if person || !ports.oracleEnabled() {
                let reason = person ? "The Operator says this is your decision." : "The Oracle is off."
                let marker = ChallengeRecord(id: UUID().uuidString, tool: "answer_worker", stage: .unchallenged,
                                             askedArguments: arguments, unchallengedReason: reason, askedAt: now(), askedEvidence: binding, round: 0)
                workspace.mutate { $0.operatorSession?.oracleRounds.append(marker) }
                return try remember(askPerson(question, reason: reason), key: ledgerKey, arguments: arguments)
            }
        }
        let round = (previous?.round ?? 0) + 1, roundID = UUID().uuidString
        let discussion = previous?.result.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        var record = ChallengeRecord(id: roundID, tool: "answer_worker", askedArguments: arguments, askedAt: now(),
                                     askedEvidence: binding, round: round)
        record.reply = proposal
        record.result = String(decoding: try JSONEncoder().encode(discussion), as: UTF8.self)
        workspace.mutate { state in
            if let challenge { state.operatorSession?.oracleRounds.removeAll { $0.id == challenge } }
            state.operatorSession?.oracleRounds.append(record)
            state.updateSignalTask(id) { $0.currentAct = humanAnswer ? "answering its worker" : "consulting the Oracle" }
        }
        guard workspace.flush() else { throw ActionUnavailable("The Oracle round couldn’t be saved.") }
        defer {
            workspace.mutate { state in
                if claim.holds(in: state) { state.updateSignalTask(id) { $0.currentAct = nil } }
            }
        }
        try await journal.append(.quoted(SignalQuote(source: "worker", text: question.text)), task: id)
        guard stillAsks() else { clear(roundID); throw ActionUnavailable("The task or its question changed.") }
        let verdict: Verdict
        if humanAnswer { verdict = .agreed("The person answered in the Operator's chat.") }
        else {
            do { verdict = try await ports.oracle(Input(task: task, question: question, proposal: proposal, round: round, discussion: discussion)) }
            catch { verdict = .unavailable(OperationIssue.reason(of: error)) }
        }
        guard stillAsks() else { clear(roundID); throw ActionUnavailable("The task or its question changed while the Oracle read it.") }
        switch verdict {
        case .agreed:
            // A crash after this marker may have delivered. A restart asks the person instead of
            // typing the same answer twice into a worker that may already be at work again.
            workspace.mutate { state in
                if let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == roundID }) {
                    state.operatorSession?.oracleRounds[index].stage = .ready
                    state.operatorSession?.oracleRounds[index].approved = true
                }
                state.updateSignalTask(id) { $0.currentAct = "answering its worker" }
            }
            guard workspace.flush() else { throw ActionUnavailable("The answer intent couldn’t be saved.") }
            try await journal.append(.ours("Proposed worker answer: " + proposal), task: id)
            guard stillAsks(), let current = workspace.state.task(id: id) else { clear(roundID); throw ActionUnavailable("The task or question changed.") }
            try await ports.deliver(current, question, proposal)
            guard claim.holds(in: workspace.state), !Task.isCancelled, workspace.state.operatorSession?.id == operatorID,
                  workspace.state.operatorSession?.generation == operatorGeneration else { clear(roundID); throw ActionUnavailable("The task changed while its answer was delivered.") }
            clear(roundID)
            return try remember(["status": "answered"], key: ledgerKey, arguments: arguments)
        case .critique(let text):
            if round >= 3 {
                markForPerson(roundID, reason: "The Operator and Oracle still disagree after three rounds. " + text)
                return try remember(askPerson(question, reason: "The Operator and Oracle still disagree after three rounds. " + text), key: ledgerKey, arguments: arguments)
            }
            let history = discussion + ["Operator: " + proposal, "Oracle: " + text]
            workspace.mutate { state in
                if let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == roundID }) {
                    state.operatorSession?.oracleRounds[index].stage = .delivered
                    state.operatorSession?.oracleRounds[index].critique = text
                    state.operatorSession?.oracleRounds[index].result = String(decoding: try! JSONEncoder().encode(history), as: UTF8.self)
                }
            }
            return try remember(["status": "challenged", "challengeId": .string(roundID), "round": .int(round), "critique": .string(text)], key: ledgerKey, arguments: arguments)
        case .person(let reason), .unavailable(let reason):
            markForPerson(roundID, reason: reason)
            return try remember(askPerson(question, reason: reason), key: ledgerKey, arguments: arguments)
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
        if task != nil, record == nil || record?.takenOver == true { throw ActionUnavailable("This task is no longer the Operator’s.") }
        var question = OperatorSession.Question(id: key, task: task, text: text, openedAt: now())
        question.stage = record?.stage; question.ownership = record?.ownership; question.tab = tab
        question.workerQuestion = task.flatMap { ports.question($0, tab)?.text }
        let binding: String?
        if let task, let current = workspace.state.task(id: task), let claim = SignalClaim(current), let worker = ports.question(task, tab) {
            binding = try Self.json(["task": .string(task.uuidString), "stage": .int(claim.stage), "ownership": .int(claim.ownership),
                                     "session": .string(worker.session), "tab": .string(worker.tab), "question": .string(worker.text)])
        } else { binding = nil }
        workspace.mutate { state in
            state.operatorSession?.questions.append(question)
            if let binding {
                state.operatorSession?.oracleRounds.removeAll {
                    $0.tool == "answer_worker" && $0.askedEvidence == binding && ($0.stage == .delivered || $0.stage == .unchallenged)
                }
            }
            state.operatorSession?.prune()
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
            state.operatorSession?.prune()
        }
        guard workspace.flush() else { throw ActionUnavailable("The answer couldn’t be saved.") }
        changed()
    }
    private func markForPerson(_ id: String, reason: String) {
        workspace.mutate { state in
            guard let index = state.operatorSession?.oracleRounds.firstIndex(where: { $0.id == id }) else { return }
            state.operatorSession?.oracleRounds[index].stage = .unchallenged
            state.operatorSession?.oracleRounds[index].unchallengedReason = reason
        }
    }
    private func clear(_ id: String) { workspace.mutate { $0.operatorSession?.oracleRounds.removeAll { $0.id == id } } }
    private func remember(_ result: JSONValue, key: String, arguments: String) throws -> JSONValue {
        workspace.mutate { $0.operatorSession?.remember(key: key, result: result, at: now(), arguments: arguments) }
        guard workspace.flush() else { throw ActionUnavailable("The answer couldn’t be saved.") }
        return result
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
