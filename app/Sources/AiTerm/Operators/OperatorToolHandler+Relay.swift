import Foundation
import AiTermCore

/// `relay_question` (B2, C2): a worker's question is the Operator's until it passes it on, which makes it a question for
/// the person, in the worker's own words, under Waiting on you. AiTerm takes the words from the worker's last message,
/// read now, so the relay is the same question, never a second one. The Oracle looks first, as the broadcast's Worker
/// questions setting says (`RelayCheck`): straight, challenged once, or agreed first (rounds until it has no major or
/// important point left, at most three). An Oracle that can't answer lets the question through, and its history says why.
/// The Operator's own questions (`ask_you`) are never vetted.
///
/// Each Oracle round is a `ChallengeRecord` of this tool, numbered by `round`, saved with the workspace: a lost reply or a
/// restart neither loses it nor relays twice. The record made last carries the question's key in `result`.
extension OperatorToolHandler {
    func relayQuestion(_ call: ToolCall, in run: OperatorRun) async throws -> JSONValue {
        let key = try call.string("key")
        guard !OperatorQuestion.aitermPrefixes.contains(where: key.hasPrefix) else {
            throw ToolRefusal("Keys starting with “prompt-”, “merged-on-host-” or “gate-” are AiTerm’s own questions. Choose another key.")
        }
        let task = try task(call, in: run)
        guard let operated = task.operated else { throw ToolRefusal("No task \(try call.string("task")) in this broadcast.") }
        let holds = try Self.holds(call, task: task.id, about: nil), choices = try Self.choices(call, about: nil)
        // The same key: the record already made.
        if let made = run.questions.first(where: { $0.id == key }) { return Self.relayAnswer(made, task: operated.key) }
        if let id = call.optionalString("challengeId") {
            return try await answerRound(id, call, in: run, task: task, holds: holds, choices: choices)
        }
        let worker = try workerQuestion(call, of: task, in: run)
        // Another key for the same worker turn: the one record.
        if let made = run.questions.first(where: { $0.task == task.id && $0.relayedFrom == worker.tab && $0.text == worker.text
                                                   && $0.resolution == nil }) {
            return Self.relayAnswer(made, task: operated.key)
        }
        let asked = QuestionStep(kind: .asked, text: worker.message, at: ports.now())
        let check: RelayCheck = (state.run(id: run.id)?.profile.oracle ?? run.profile.oracle).isOn ? run.relayCheckOrDefault : .straight
        guard check != .straight else {
            return relay(key, worker: worker, task: task, holds: holds, choices: choices, history: [asked], in: run)
        }
        return try await round(1, call, in: run, task: task, worker: worker, holds: holds, choices: choices, discussion: [asked])
    }

    /// What a worker asked at the end of its turn, read now: its tab, the question (`WorkerTurn.question`) and its last
    /// message in full.
    struct WorkerQuestion { var tab: String, text: String, message: String }

    /// The named worker's question, refused when there is none to relay: the task yours or finished, the tab unknown, no
    /// turn read, a turn answered with `message_task` already, or the worker at work again. The scan's verdict is not asked:
    /// a turn it didn't call a question can be relayed all the same (H2).
    private func workerQuestion(_ call: ToolCall, of task: TaskItem, in run: OperatorRun) throws -> WorkerQuestion {
        guard let operated = task.operated else { throw ToolRefusal("No task \(task.title) in this broadcast.") }
        let name = operated.key
        if operated.takenOver { throw ToolRefusal("\(name) is the person’s now: they answer its worker themselves.") }
        if operated.isFinished { throw ToolRefusal("\(name) has finished: nothing waits on its worker’s answer.") }
        let tab = call.optionalString("tab") ?? WorkerTab.firstKey
        let reading: WorkerTurnReader.Reading?
        if tab == WorkerTab.firstKey {
            reading = turnReadings()[task.id]
        } else {
            guard operated.extraTabs.contains(where: { $0.key == tab }) else {
                let tabs = [WorkerTab.firstKey] + operated.extraTabs.map(\.key)
                throw ToolRefusal("\(name) has no tab \(tab). Its tabs are \(tabs.joined(separator: ", ")).")
            }
            reading = extraTurnReadings()[task.id]?[tab]
        }
        guard let reading, let message = reading.lastMessage.said else {
            throw ToolRefusal("\(name)’s worker has no ended turn AiTerm has read: there is no question to pass on. Read it with read_task.")
        }
        if reading.messaged { throw ToolRefusal("\(name)’s worker has moved on since it asked: answer with message_task.") }
        if live.sessions.first(where: { $0.sessionId == reading.session })?.state == .working {
            throw ToolRefusal("\(name)’s worker is at work: pass its question on once its turn ends on it.")
        }
        return WorkerQuestion(tab: tab, text: WorkerTurn.question(message), message: message)
    }

    /// The question made, holding its task unless `holds` is false, and the round that made it, if any, marked acted with
    /// its key, so a repeat of that call answers it.
    private func relay(_ key: String, worker: WorkerQuestion, task: TaskItem, holds: Bool?, choices: [String]?,
                       history: [QuestionStep], in run: OperatorRun, round: String? = nil) -> JSONValue {
        if let made = state.run(id: run.id)?.questions.first(where: { $0.id == key }) {
            return Self.relayAnswer(made, task: task.operated?.key ?? task.title)
        }
        let question = OperatorQuestion(id: key, text: worker.text, task: task.id, askedAt: ports.now(), holds: holds == false ? false : nil,
                                        choices: choices, relayedFrom: worker.tab, history: history)
        mutate(in: run.id) { state in
            state.updateRun(id: run.id) { run in
                run.questions.append(question)
                if let round, let i = run.challenges.firstIndex(where: { $0.id == round }) {
                    run.challenges[i].stage = .acted
                    run.challenges[i].result = key
                }
            }
            if question.holdsTask { state.updateOperated(task.id) { $0.flags.insert(.waitingOnYou) } }
        }
        return Self.relayAnswer(question, task: task.operated?.key ?? task.title)
    }

    /// One Oracle round on the relay: asked, then answered within the reply budget, or said to be pending. `discussion` is
    /// what came before it: the worker's message, then each earlier round's critique and reply.
    private func round(_ number: Int, _ call: ToolCall, in run: OperatorRun, task: TaskItem, worker: WorkerQuestion, holds: Bool?,
                       choices: [String]?, discussion: [QuestionStep]) async throws -> JSONValue {
        let key = try call.string("key"), opinion = state.run(id: run.id)?.profile.oracle ?? run.profile.oracle
        let id = UUID().uuidString
        let record = ChallengeRecord(id: id, tool: call.tool, askedArguments: Self.invocation(call), askedAt: ports.now(), round: number)
        mutate(in: run.id) { $0.updateRun(id: run.id) { $0.challenges.append(record) } }
        let status = Self.json(currentStatus(of: run).flatMap { try? JSONValue(encoding: $0) } ?? .null)
        let said = discussion.filter { $0.kind != .asked }.map(\.said)
        let prompt = ChallengeLaunch.relayPrompt(task: task.operated?.key ?? task.title, question: worker.text, lastMessage: worker.message,
                                                 brief: task.operated?.brief ?? "", run: status, discussion: said)
        let runner = ports.secondOpinion, folder = OperatorCommand.runFolder(run.id, home: ports.home)
        let projects = run.projectIds.compactMap(state.project(id:)).map(\.path) + (task.hasCheckout ? [task.worktreePath] : [])
        let challenge = Task { () -> SecondOpinionRunner.Verdict? in
            let verdict = await runner.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
            return Task.isCancelled ? nil : Self.capped(verdict)
        }
        let consulting = OperatorActivity(run: run.id, task: task.id, act: .consultingTheOracle)
        onActing(consulting, true)
        let settled = Task { [weak self] in
            let verdict = await withTaskCancellationHandler { await challenge.value } onCancel: { challenge.cancel() }
            guard let self else { return }
            runningChallenges[id] = nil
            onActing(consulting, false)
            guard let verdict, state.run(id: run.id)?.challenges.first(where: { $0.id == id })?.stage == .running else { return }
            updateChallenge(id, in: run.id) { kept in
                switch verdict {
                case .critique(let critique): kept.stage = .ready; kept.critique = critique
                case .unchallenged(let reason): kept.stage = .unchallenged; kept.unchallengedReason = reason
                }
            }
        }
        runningChallenges[id] = settled
        lastChallenge = settled
        let answered = try? await Self.within(ports.challengeReplyBudget, cancelling: false) { await challenge.value }.get()
        switch answered {
        case nil:
            return Self.relayPending(id)
        case .unchallenged(let reason)?:
            updateChallenge(id, in: run.id) { $0.stage = .unchallenged; $0.unchallengedReason = reason }
            return relay(key, worker: worker, task: task, holds: holds, choices: choices,
                         history: discussion + [QuestionStep(kind: .unchallenged, text: reason, at: ports.now())], in: run, round: id)
        case .critique(let critique)?:
            updateChallenge(id, in: run.id) { $0.stage = .ready; $0.critique = critique }
            return judged(id, critique, number, call, in: run, task: task, worker: worker, holds: holds, choices: choices,
                          discussion: discussion)
        }
    }

    /// The Oracle's critique of round `number`, read. Only the person can answer, or Agreed first with no major or important
    /// point left: the question is made. Otherwise the critique goes to the Operator, who answers the worker itself or
    /// replies. A critique with no verdict line counts as no answer: the relay goes ahead unchallenged.
    private func judged(_ id: String, _ critique: String, _ number: Int, _ call: ToolCall, in run: OperatorRun, task: TaskItem,
                        worker: WorkerQuestion, holds: Bool?, choices: [String]?, discussion: [QuestionStep]) -> JSONValue {
        let key = (try? call.string("key")) ?? ""
        let step = QuestionStep(kind: .oracle, text: critique, at: ports.now(), round: number)
        guard let verdict = ChallengeLaunch.relayVerdict(critique) else {
            let why = QuestionStep(kind: .unchallenged, text: "The Oracle gave no clear verdict.", at: ports.now())
            return relay(key, worker: worker, task: task, holds: holds, choices: choices, history: discussion + [step, why], in: run, round: id)
        }
        let agreed = run.relayCheckOrDefault == .agreeFirst && !verdict.weighty
        if verdict.relay || agreed {
            return relay(key, worker: worker, task: task, holds: holds, choices: choices, history: discussion + [step], in: run, round: id)
        }
        updateChallenge(id, in: run.id) { $0.stage = .delivered }
        return Self.relayChallenged(id, critique, task: task.operated?.key ?? task.title)
    }

    /// A call again with a round's `challengeId`: that round's answer when it came late, the relay made once the Operator
    /// replied (Challenged once, or Agreed first after its last round), another round with the reply in its prompt (Agreed
    /// first), or the relay unchallenged when the round was lost with AiTerm's restart or the Oracle failed.
    private func answerRound(_ id: String, _ call: ToolCall, in run: OperatorRun, task: TaskItem, holds: Bool?,
                             choices: [String]?) async throws -> JSONValue {
        let key = try call.string("key")
        guard let kept = run.challenges.first(where: { $0.id == id && $0.tool == call.tool }) else {
            throw ToolRefusal("No challenge \(id) for relay_question here; call again without challengeId.")
        }
        guard kept.askedArguments == Self.invocation(call) else {
            throw ToolRefusal("Challenge \(id) was asked about another relay. Call again without challengeId.")
        }
        if kept.stage == .acted, let made = kept.result.flatMap({ key in run.questions.first { $0.id == key } }) {
            return Self.relayAnswer(made, task: task.operated?.key ?? task.title)
        }
        let worker = try workerQuestion(call, of: task, in: run)
        let discussion = discussion(before: kept, worker: worker, in: run)
        let number = kept.round ?? 1
        switch kept.stage {
        case .running where runningChallenges[id] != nil:
            return Self.relayPending(id)
        case .running, .unchallenged:
            // Lost with AiTerm's restart, or the Oracle couldn't answer: it never holds the question up.
            let reason = kept.unchallengedReason ?? "AiTerm restarted before the Oracle answered."
            return relay(key, worker: worker, task: task, holds: holds, choices: choices,
                         history: discussion + [QuestionStep(kind: .unchallenged, text: reason, at: ports.now())], in: run, round: id)
        case .ready:
            return judged(id, kept.critique ?? "", number, call, in: run, task: task, worker: worker, holds: holds, choices: choices,
                          discussion: discussion)
        case .delivered, .acted:
            guard let reply = call.optionalString("challengeReply").said else {
                throw ToolRefusal("Answer the worker with message_task, or reply to each point in challengeReply and call again with "
                                  + "this challengeId.")
            }
            updateChallenge(id, in: run.id) { $0.stage = .acted; $0.reply = reply }
            let answered = discussion + [QuestionStep(kind: .oracle, text: kept.critique ?? "", at: kept.askedAt, round: number),
                                         QuestionStep(kind: .reply, text: reply, at: ports.now(), round: number)]
            guard run.relayCheckOrDefault == .agreeFirst, number < RelayCheck.rounds else {
                // Challenged once, or the last round still apart: it reaches the person with both sides.
                return relay(key, worker: worker, task: task, holds: holds, choices: choices, history: answered, in: run, round: id)
            }
            return try await round(number + 1, call, in: run, task: task, worker: worker, holds: holds, choices: choices,
                                   discussion: answered)
        }
    }

    /// The rounds before `kept` on this relay, oldest first: the worker's message, then each critique and its reply.
    private func discussion(before kept: ChallengeRecord, worker: WorkerQuestion, in run: OperatorRun) -> [QuestionStep] {
        let earlier = run.challenges.filter { $0.tool == kept.tool && $0.askedArguments == kept.askedArguments
                                              && ($0.round ?? 1) < (kept.round ?? 1) && $0.askedAt <= kept.askedAt }
            .sorted { ($0.round ?? 1) < ($1.round ?? 1) }
        var steps = [QuestionStep(kind: .asked, text: worker.message, at: earlier.first?.askedAt ?? kept.askedAt)]
        for round in earlier {
            steps.append(QuestionStep(kind: .oracle, text: round.critique ?? "", at: round.askedAt, round: round.round))
            if let reply = round.reply { steps.append(QuestionStep(kind: .reply, text: reply, at: round.askedAt, round: round.round)) }
        }
        return steps
    }

    /// The relay made: where the person sees it, and whether its task waits.
    static func relayAnswer(_ question: OperatorQuestion, task: String) -> JSONValue {
        var answer: [String: JSONValue] = ["question": .string(question.id), "open": .bool(question.resolution == nil),
                                           "resolution": question.resolution.map(JSONValue.string) ?? .null,
                                           "relayed": .string(question.text)]
        if question.resolution == nil {
            answer["note"] = .string("The person sees \(task)’s worker’s question under Waiting on you in AiTerm, in its worker’s words, "
                + (question.holdsTask ? "and the task waits on them until you resolve the question. " : "and the task doesn’t wait. ")
                + "Point to it in one line of your reply, and when run_status shows answeredHere, pass the answer on with message_task.")
        }
        return .object(answer)
    }

    private static func relayChallenged(_ id: String, _ critique: String, task: String) -> JSONValue {
        ["challenged": true, "challengeId": .string(id), "critique": .string(critique),
         "note": .string("Nothing was passed on. The Oracle thinks you can answer \(task)’s worker yourself: do it with message_task. "
                         + "If only the person can answer, reply to each point in challengeReply and call again with this challengeId.")]
    }

    private static func relayPending(_ id: String) -> JSONValue {
        ["challenged": true, "challengeId": .string(id), "critique": .null, "pending": true,
         "note": "Nothing was passed on yet. The Oracle is still reading the question: call relay_question again with this challengeId in a little while."]
    }
}
