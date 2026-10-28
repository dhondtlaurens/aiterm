import Foundation
import AiTermCore

/// The gate on the Operator's shell (spec §A): each Bash command the Operator runs reaches AiTerm through its
/// `PreToolUse` hook as a `gate_command` request, and is answered allow or deny before it runs. A plain read inside
/// the broadcast's checkouts, worktrees and run folder runs at once (`ShellGate`); a push, a commit or a change to a
/// checkout, and a merge or a change to a merge request is refused outright (`ShellGate.hardDenial`); anything else is the
/// Oracle's to judge (`ChallengeLaunch.gatePrompt`). Its YES runs the command, its WORKER sends the Operator to a worker, and its
/// ASK opens a `gate-` question the person answers in the Operator's chat. Whenever the Oracle can't answer, the
/// command runs, logged as unchallenged. Every command judged is a line of the activity log, as `shell_read` or `shell`.
extension OperatorToolHandler {
    /// The request the hook's command comes as: no tool of the Operator's, so it never calls it itself.
    static let gateTool = "gate_command"

    /// The gate's answer to `request`: denied for a broadcast AiTerm no longer has, else `gate(_:in:)`'s.
    func gate(_ request: OperatorRequest) async -> JSONValue {
        let call = ToolCall(tool: request.tool, arguments: request.arguments)
        guard let id = UUID(uuidString: request.runId), let run = state.run(id: id) else {
            return Self.gateAnswer("deny", Self.goneReason, rewrite: nil)
        }
        return await gate(call, in: run)
    }

    static let goneReason = "This broadcast is no longer in AiTerm."

    /// Why the broadcast's shell no longer acts, if it doesn't: gone, or ended. The person's choice to let a command run
    /// when the Oracle can't answer is about the Oracle, never about an ended broadcast, so these deny.
    private func ended(_ id: UUID) -> String? {
        guard let run = state.run(id: id) else { return Self.goneReason }
        return run.hasEnded ? "This broadcast has ended; its shell no longer acts." : nil
    }

    private static func gateAnswer(_ decision: String, _ reason: String, rewrite: String?) -> JSONValue {
        ["decision": .string(decision), "reason": .string(reason), "rewrite": rewrite.map(JSONValue.string) ?? .null]
    }

    /// The gate's answer, as the daemon turns it into the hook's: `decision` allow or deny, `reason` said to the
    /// Operator, and `rewrite` the command to run instead, for a read that would show a secret.
    func gate(_ call: ToolCall, in run: OperatorRun) async -> JSONValue {
        // The words as the hook sent them: an allowance matches them exactly, so nothing is trimmed.
        let command = call.arguments["command"]?.stringValue ?? "", directory = call.arguments["directory"]?.stringValue ?? ""
        let request = GateRequest(command: command, directory: directory)
        let task = gateTask(holding: directory, in: run)
        // The answer, written to the activity log with `logged` as its reason: the answer's own unless given, nil for none.
        func answer(_ decision: String, _ reason: String, rewrite: String? = nil, tool: String = "shell",
                    outcome: ActivityEntry.Outcome = .ok, logged: String?? = .none) -> JSONValue {
            let value = Self.gateAnswer(decision, reason, rewrite: rewrite)
            recordGate(call, tool: tool, task: task, in: run.id, outcome: outcome, result: value, reason: logged ?? reason)
            return value
        }

        if let ended = ended(run.id) { return answer("deny", ended, outcome: .refused) }
        // AiTerm's own refusals (spec §A.2), before any allowance, read or Oracle: they hold whenever the Oracle can't answer.
        if let denied = ShellGate.hardDenial(command) { return answer("deny", denied, outcome: .refused) }
        let checkouts = run.projectIds.compactMap(state.project(id:)), projects = checkouts.map(\.path)
        let folder = OperatorCommand.runFolder(run.id, home: ports.home)
        let worktrees = state.tasks(inRun: run.id).map(\.worktreePath).filter { !$0.isEmpty }
        let hosts = Set(checkouts.compactMap { ProviderDetector.detect(remoteUrl: $0.remoteUrl).host })
        if case .read(let rewrite) = ShellGate.route(command, in: directory, roots: projects + worktrees + [folder.path], hosts: hosts) {
            return answer("allow", "A plain read.", rewrite: rewrite, tool: "shell_read", logged: .some(nil))
        }
        if let allowed = state.run(id: run.id)?.gateAllowances.firstIndex(of: request) {
            mutate(in: run.id) { $0.updateRun(id: run.id) { $0.gateAllowances.remove(at: allowed) } }
            return answer("allow", "allowed by you")
        }
        refreshOracleSettings()
        let generation = oracleGeneration(run.id)
        let opinion = state.run(id: run.id)?.profile.oracle ?? run.profile.oracle
        guard opinion.isOn else {
            return answer("allow", "unchallenged: the Oracle is off")
        }
        // Only a command the Oracle judges costs a status and a prompt.
        let status = Self.json(currentStatus(of: run).flatMap { try? JSONValue(encoding: $0) } ?? .null)
        let prompt = ChallengeLaunch.gatePrompt(command: command, directory: directory, reason: call.optionalString("description"), run: status)

        // Awaited however long it takes: the hook waits `OperatorTiming.gateTimeout`, past the Oracle's own limit.
        let consulting = OperatorActivity(run: run.id, task: task?.id, act: .consultingTheOracle)
        onActing(consulting, true)
        let verdict = await ports.secondOpinion.challenge(opinion, prompt: prompt, runFolder: folder, projects: projects)
        onActing(consulting, false)
        // The Oracle may take minutes: a broadcast that ended meanwhile runs nothing and asks nothing.
        if let ended = ended(run.id) { return answer("deny", ended, outcome: .refused) }
        refreshOracleSettings()
        if oracleGeneration(run.id) != generation {
            return state.run(id: run.id)?.profile.oracle.isOn == false
                ? answer("allow", "unchallenged: the Oracle is off")
                : answer("deny", "The Oracle settings changed while this check ran. Try the command again for a fresh check.", outcome: .refused)
        }
        let critique: String
        switch verdict {
        case .unchallenged(let why): return answer("allow", "unchallenged: \(why)")
        case .critique(let text): critique = text
        }
        switch ChallengeLaunch.gateVerdict(critique) {
        case .allow:
            return answer("allow", "The Oracle said yes.")
        case .unparsed:
            return answer("allow", "unchallenged: the Oracle gave no clear answer.")
        case .redirect(let why):
            let said = why.isEmpty ? "it writes product code." : Self.asSentence(why)
            return answer("deny", "The Oracle: \(said) Send this to a worker with message_task.", outcome: .challenged)
        case .escalate(let why):
            let key = openGateQuestion(request, why: why, task: task?.id, in: run.id)
            // As after ask_you: the person is notified of the question, and what it holds waits.
            onChange(run.id)
            return answer("deny", "The Oracle stopped this and asked the person (question \(key)). Wait for their answer, then "
                          + "resolve_question with allow, or withdraw the question if the command becomes moot.", outcome: .challenged,
                          logged: .some("The Oracle: \(why.isEmpty ? "the person decides." : Self.asSentence(why)) It asked you (question \(key))."))
        }
    }

    /// The task whose worktree holds `directory`; nil for a project checkout, the run folder or anywhere else, which
    /// are the broadcast's.
    private func gateTask(holding directory: String, in run: OperatorRun) -> TaskItem? {
        let path = Self.resolved(directory)
        return state.tasks(inRun: run.id).filter { !$0.worktreePath.isEmpty }.first { task in
            let root = Self.resolved(task.worktreePath)
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }

    /// Opens the next `gate-<n>` question about `request`, on `task` when one holds it, which then waits on you as a
    /// question `ask_you` puts on it does. Its key.
    private func openGateQuestion(_ request: GateRequest, why: String, task: UUID?, in id: UUID) -> String {
        let prefix = OperatorQuestion.gatePrefix
        let used = state.run(id: id)?.questions.compactMap { $0.id.hasPrefix(prefix) ? Int($0.id.dropFirst(prefix.count)) : nil } ?? []
        let key = prefix + String((used.max() ?? 0) + 1)
        let said = why.isEmpty ? "." : ": " + why
        let question = OperatorQuestion(id: key, text: "The Oracle stopped `\(request.command)` in \(request.directory)\(said)", task: task,
                                        askedAt: ports.now(), gate: request)
        mutate(in: id) { state in
            state.updateRun(id: id) { $0.questions.append(question) }
            if let task { state.updateOperated(task) { $0.flags.insert(.waitingOnYou) } }
        }
        return key
    }

    /// The gate's line in the activity log: the command, where it ran and the task it was about, and `reason`, why it
    /// went the way it did (nil for a plain read).
    private func recordGate(_ call: ToolCall, tool: String, task: TaskItem?, in id: UUID, outcome: ActivityEntry.Outcome, result: JSONValue,
                            reason: String?) {
        guard state.run(id: id) != nil else { return }
        let entry = ActivityEntry(at: ports.now(), tool: tool, task: task?.id, taskLabel: task.flatMap { $0.jira?.key ?? $0.operated?.key },
                                  arguments: call.arguments, outcome: outcome, result: Self.json(result),
                                  line: ActivityLine.line(tool: tool, arguments: call.arguments, task: task, outcome: outcome), reason: reason)
        append(entry, to: id)
    }
}
