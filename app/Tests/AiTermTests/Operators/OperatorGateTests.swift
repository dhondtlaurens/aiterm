import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The gate on the Operator's shell (spec §A): a plain read runs at once, anything else is the Oracle's to judge, its
/// ASK opening a question the person answers, and the command running whenever the Oracle can't answer.
@MainActor @Suite(.blocking) struct OperatorGateTests {
    let project = OperatorServiceFixtures.project()
    let worktree = "/tmp/aiterm-operators-gate-A"

    /// How many times the Oracle was asked, and what it was asked last.
    final class Asked: Sendable {
        private let prompts = Mutex<[String]>([])
        var count: Int { prompts.withLock { $0.count } }
        var last: String? { prompts.withLock { $0.last } }
        func record(_ prompt: String) { prompts.withLock { $0.append(prompt) } }
    }

    func makeWorld(oracle: Bool = true, oracleAgent: AgentKind = .claude, runner: SecondOpinionRunner) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: oracleAgent), projects: [project],
                                              state: .active)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .working, worktree: worktree)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.secondOpinion = runner
        }
        return (world, run, task)
    }

    func answering(_ answer: String, _ asked: Asked) -> SecondOpinionRunner {
        .answering(answer, receivePrompt: { asked.record($0) })
    }

    func gate(_ world: OperatorWorld, _ run: OperatorRun, _ command: String, in directory: String) async -> [String: JSONValue] {
        let answer = await world.call(run.id, "gate_command", ["command": .string(command), "directory": .string(directory),
                                                               "description": "Check the worktree."])
        return answer.value?.objectValue ?? [:]
    }

    /// The lines written so far, once every recording started has landed.
    func entries(_ world: OperatorWorld, _ run: OperatorRun) async -> [ActivityEntry] {
        await world.controller.tools.lastRecording?.value
        return ActivityLog.read(runFolder: OperatorCommand.runFolder(run.id, home: world.ports.home)).entries
    }

    @Test func aReadRunsWithoutTheOracle() async throws {
        let asked = Asked()
        let (world, run, _) = try makeWorld(runner: answering("ASK", asked))
        let answer = await gate(world, run, "git status", in: project.path)
        #expect(answer["decision"] == "allow" && answer["rewrite"] == .null)
        #expect(asked.count == 0)
        let recorded = await entries(world, run)
        #expect(recorded.map(\.tool) == ["shell_read"], "the gate's own line, never one for gate_command")
        #expect(recorded.first?.outcome == .ok && recorded.first?.line == "Read `git status`" && recorded.first?.isRead == true)
    }

    @Test func aReadThatWouldShowASecretRunsRewritten() async throws {
        let (world, run, _) = try makeWorld(runner: .unavailable)
        let answer = await gate(world, run, "env", in: project.path)
        #expect(answer["decision"] == "allow" && answer["rewrite"] == .string(ShellGate.maskedEnv))
    }

    @Test func aYesRuns() async throws {
        let asked = Asked()
        let (world, run, task) = try makeWorld(runner: answering("YES. Reinstalling dependencies repairs the worktree.", asked))
        let answer = await gate(world, run, "npm install", in: worktree)
        #expect(answer["decision"] == "allow")
        #expect(asked.count == 1)
        let prompt = try #require(asked.last)
        #expect(prompt.contains("npm install") && prompt.contains("Run in: \(worktree)") && prompt.contains("Check the worktree."))
        #expect(prompt.contains("run_status"))
        let recorded = try #require(await entries(world, run).first)
        #expect(recorded.tool == "shell" && recorded.outcome == .ok && recorded.line == "Ran `npm install`")
        #expect(recorded.task == task.id)
        #expect(world.controller.acting.broadcast(run.id) == nil, "the badge goes once the Oracle answered")
    }

    @Test func aWorkerAnswerSendsTheOperatorToAWorkerWithoutAQuestion() async throws {
        let (world, run, _) = try makeWorld(runner: .answering("WORKER: this edits src/cart.ts."))
        let answer = await gate(world, run, "sed -i '' s/a/b/ src/cart.ts", in: worktree)
        #expect(answer["decision"] == "deny")
        let reason = try #require(answer["reason"]?.stringValue)
        #expect(reason == "The Oracle: this edits src/cart.ts. Send this to a worker with message_task.")
        #expect(world.run(run.id)?.questions.isEmpty == true)
        let recorded = try #require(await entries(world, run).first)
        #expect(recorded.tool == "shell" && recorded.outcome == .challenged && recorded.line == "The Oracle stopped `sed -i '' s/a/b/ src/cart.ts`")
        #expect(recorded.reason == reason)
    }

    @Test func anAskOpensAQuestionOnTheTaskWhoseWorktreeHoldsTheCommand() async throws {
        let (world, run, task) = try makeWorld(runner: .answering("ASK: it reaches the staging database."))
        var changed: [UUID] = []
        let runChanged = world.controller.tools.onChange
        world.controller.tools.onChange = { changed.append($0); runChanged($0) }
        let answer = await gate(world, run, "npm run migrate", in: worktree + "/packages/api")
        #expect(changed == [run.id], "the run changed, as after ask_you: what the question holds waits")
        #expect(answer["decision"] == "deny")
        #expect(answer["reason"] == "The Oracle stopped this and asked the person (question gate-1). Wait for their answer, then resolve_question with allow, or withdraw the question if the command becomes moot.")
        let question = try #require(world.run(run.id)?.questions.first)
        #expect(question.id == "gate-1" && question.task == task.id && question.resolution == nil)
        #expect(question.text == "The Oracle stopped `npm run migrate` in \(worktree)/packages/api: it reaches the staging database.")
        #expect(question.gate == GateRequest(command: "npm run migrate", directory: worktree + "/packages/api"))
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)
        // The Operator's row says it waits on you about that task, as it does for a question it asked.
        let current = try #require(world.run(run.id))
        let requests = OperatorRequests.open(run: current, state: world.state)
        #expect(requests.map(\.kind) == [.question] && requests.first?.key == "gate-1" && requests.first?.taskId == task.id)
        let row = SidebarModel.operatorRow(current, tasks: world.state.tasks(inRun: run.id), acting: .none, requests: requests, sessions: [])
        #expect(row.line.look == .needsYou && row.line.text.hasPrefix("waiting on you") && row.line.text.contains("Task A"))
        // And the person is notified of it, as of any question the Operator asks.
        #expect(world.notifications.posted.map(\.body) == ["The Operator asks: \(question.text)"])
        // A second ASK gets the next key.
        _ = await gate(world, run, "npm run seed", in: project.path)
        #expect(world.run(run.id)?.questions.map(\.id) == ["gate-1", "gate-2"])
    }

    @Test func anAskInTheProjectCheckoutIsTheBroadcasts() async throws {
        let (world, run, task) = try makeWorld(runner: .answering("ASK: it deploys."))
        let answer = await gate(world, run, "npm run deploy", in: project.path)
        #expect(answer["decision"] == "deny")
        let question = try #require(world.run(run.id)?.questions.first)
        #expect(question.id == "gate-1" && question.task == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
    }

    @Test func anAllowedCommandPassesOnceAndOnlyExactly() async throws {
        let asked = Asked()
        let (world, run, task) = try makeWorld(runner: answering("ASK: it deploys.", asked))
        #expect(await gate(world, run, "npm run deploy", in: worktree)["decision"] == "deny")
        #expect(asked.count == 1)
        let resolved = await world.call(run.id, "resolve_question", ["key": "gate-1", "summary": "Laurens said go ahead.", "allow": true])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.gateAllowances == [GateRequest(command: "npm run deploy", directory: worktree)])
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)

        let allowed = await gate(world, run, "npm run deploy", in: worktree)
        #expect(allowed["decision"] == "allow" && asked.count == 1, "allowed by you, without the Oracle")
        #expect(world.run(run.id)?.gateAllowances.isEmpty == true)
        let line = try #require(await entries(world, run).last)
        #expect(line.tool == "shell" && line.outcome == .ok && line.reason == "allowed by you")

        _ = await gate(world, run, "npm run deploy", in: worktree)
        #expect(asked.count == 2, "the allowance passed the command once")
        _ = await world.call(run.id, "resolve_question", ["key": "gate-2", "summary": "Yes.", "allow": true])
        _ = await gate(world, run, "npm run deploy ", in: worktree)
        #expect(asked.count == 3, "a command one character apart is another command")
        _ = await gate(world, run, "npm run deploy", in: project.path)
        #expect(asked.count == 4, "the same command in another directory is another command")
    }

    @Test func aQuestionResolvedWithoutAllowIsDenied() async throws {
        let asked = Asked()
        let (world, run, _) = try makeWorld(runner: answering("ASK: it deploys.", asked))
        _ = await gate(world, run, "npm run deploy", in: worktree)
        let resolved = await world.call(run.id, "resolve_question", ["key": "gate-1", "summary": "Laurens said no."])
        #expect(resolved.value?["open"] == false && world.run(run.id)?.gateAllowances.isEmpty == true)
        #expect(await gate(world, run, "npm run deploy", in: worktree)["decision"] == "deny")
        #expect(asked.count == 2)
    }

    @Test func aWithdrawnGateGrantsNothingAndALaterCommandIsJudgedAfresh() async throws {
        let asked = Asked()
        let (world, run, task) = try makeWorld(runner: answering("ASK: it deploys.", asked))
        _ = await gate(world, run, "npm run deploy", in: worktree)
        let conflict = await world.call(run.id, "resolve_question", ["key": "gate-1", "summary": "Moved to a worker.", "withdrawn": true, "allow": true])
        #expect(conflict.message != nil)
        #expect(world.run(run.id)?.questions.first?.resolution == nil)
        #expect(world.run(run.id)?.gateAllowances.isEmpty == true)
        let answer = await world.call(run.id, "resolve_question", ["key": "gate-1", "summary": "Moved to a worker.", "withdrawn": true])
        #expect(answer.value?["withdrawn"] == true && answer.value?["open"] == false)
        #expect(world.run(run.id)?.gateAllowances.isEmpty == true)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
        #expect(asked.count == 1)
        let again = await world.call(run.id, "resolve_question", ["key": "gate-1", "summary": "Yes.", "allow": true])
        #expect(again.value == answer.value && world.run(run.id)?.gateAllowances.isEmpty == true)
        #expect(await gate(world, run, "npm run deploy", in: worktree)["decision"] == "deny")
        #expect(asked.count == 2)
        #expect(world.run(run.id)?.questions.last?.id == "gate-2")
    }

    @Test func noOracleMeansItRuns() async throws {
        let (off, offRun, _) = try makeWorld(oracle: false, runner: .answering("ASK"))
        #expect(await gate(off, offRun, "npm install", in: worktree)["decision"] == "allow")
        let offLine = try #require(await entries(off, offRun).first)
        #expect(offLine.tool == "shell" && offLine.reason == "unchallenged: the Oracle is off")

        let (missing, missingRun, _) = try makeWorld(runner: .unavailable)
        #expect(await gate(missing, missingRun, "npm install", in: worktree)["decision"] == "allow")
        let missingLine = try #require(await entries(missing, missingRun).first)
        #expect(missingLine.tool == "shell" && missingLine.reason?.contains("unchallenged") == true)
        #expect(missing.run(missingRun.id)?.questions.isEmpty == true)
    }

    /// PI has a headless run as Claude and Codex do: an Oracle on PI is asked, not taken as off.
    @Test func aPiOracleIsAsked() async throws {
        let asked = Asked()
        let (world, run, _) = try makeWorld(oracleAgent: .pi, runner: answering("ASK: it deploys.", asked))
        #expect(await gate(world, run, "npm run deploy", in: worktree)["decision"] == "deny")
        #expect(asked.count == 1)
    }

    @Test func anUnreadableAnswerRuns() async throws {
        let (world, run, _) = try makeWorld(runner: .answering("Looks fine to me"))
        #expect(await gate(world, run, "npm install", in: worktree)["decision"] == "allow")
        let recorded = try #require(await entries(world, run).first)
        #expect(recorded.tool == "shell" && recorded.outcome == .ok && recorded.reason?.contains("unchallenged") == true)
    }

    /// An ended broadcast's shell runs nothing: its command is denied, never let through as an Oracle that can't answer.
    @Test func anEndedBroadcastRunsNothing() async throws {
        let asked = Asked()
        let (world, run, _) = try makeWorld(runner: answering("YES", asked))
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.state = .stopped } }
        let answer = await gate(world, run, "npm run deploy", in: worktree)
        #expect(answer["decision"] == "deny" && answer["reason"] == "This broadcast has ended; its shell no longer acts.")
        #expect(asked.count == 0 && world.run(run.id)?.questions.isEmpty == true)
        let recorded = try #require(await entries(world, run).first)
        #expect(recorded.tool == "shell" && recorded.outcome == .refused && recorded.line == "run `npm run deploy`")

        let gone = await world.call(UUID(), "gate_command", ["command": "npm run deploy", "directory": .string(worktree)])
        #expect(gone.value?["decision"] == "deny" && gone.value?["reason"] == "This broadcast is no longer in AiTerm.")
    }

    @Test func aBroadcastStoppedWhileTheOracleJudgesRunsNothingAndAsksNothing() async throws {
        let asked = Asked(), latch = OracleGate()
        let (world, run, task) = try makeWorld(runner: .answering("ASK: it deploys.", gate: latch, receivePrompt: { asked.record($0) }))
        let pending = Task { await gate(world, run, "npm run deploy", in: worktree) }
        while asked.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = .stopped } }
        await latch.open()
        let answer = await pending.value
        #expect(answer["decision"] == "deny" && answer["reason"] == "This broadcast has ended; its shell no longer acts.")
        #expect(world.run(run.id)?.questions.isEmpty == true)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
        #expect(world.notifications.posted.isEmpty)
    }

    @Test func theOperatorCannotAskWithAGateKey() async throws {
        let (world, run, _) = try makeWorld(runner: .unavailable)
        let answer = await world.call(run.id, "ask_you", ["key": "gate-x", "question": "May I deploy?"])
        #expect(answer.message?.contains("gate-") == true)
        #expect(world.run(run.id)?.questions.isEmpty == true)
    }

    @Test func allowIsOnlyForGateQuestions() async throws {
        let (world, run, _) = try makeWorld(runner: .unavailable)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        let refused = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE.", "allow": true])
        #expect(refused.message?.contains("allow") == true)
        #expect(world.run(run.id)?.questions.first?.resolution == nil)
        #expect(await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE."]).value?["open"] == false)
    }

    /// Spec §A.2: a push, a worker's change to a checkout, and a merge or a change to a request are refused by AiTerm itself,
    /// never asked of the Oracle, whatever it would say, and on every path where a command would otherwise run unchallenged:
    /// an Oracle that says YES, one that is off, one with no headless run, one that fails or gives no clear answer, and an
    /// allowance you gave for that very command.
    @Test func hardDenialsAreRefusedBeforeTheOracleOnEveryPath() async throws {
        let refused: [(String, String)] = [
            ("git push origin feat/a", ShellGate.pushDenial), ("git -C \(worktree) clean -fdx", ShellGate.workerDenial("git clean")),
            ("git -C \(worktree) switch x", ShellGate.workerDenial("git switch")),
            ("git -c core.x=y reset --hard", ShellGate.workerDenial("git reset --hard")),
            ("gh pr close 12", ShellGate.hostDenial("gh pr close")), ("glab mr approve 3", ShellGate.hostDenial("glab mr approve")),
            ("gh api -X PUT repos/a/b/pulls/1/merge", ShellGate.apiDenial("gh")),
        ]
        let asked = Asked()
        let worlds = [
            try makeWorld(runner: answering("YES", asked)), try makeWorld(oracle: false, runner: answering("YES", asked)),
            try makeWorld(runner: .unavailable), try makeWorld(runner: .answering("Looks fine to me")),
        ]
        for (world, run, _) in worlds {
            for (command, reason) in refused {
                let answer = await gate(world, run, command, in: worktree)
                #expect(answer["decision"] == "deny" && answer["reason"] == .string(reason), "\(command)")
            }
            let lines = await entries(world, run)
            #expect(lines.count == refused.count && lines.allSatisfy { $0.tool == "shell" && $0.outcome == .refused })
            #expect(world.run(run.id)?.questions.isEmpty == true)
        }
        #expect(asked.count == 0, "the Oracle is never asked")

        let pi = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .pi), projects: [project], state: .active)
        let noHeadless = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [pi]))
        #expect(await gate(noHeadless, pi, "git push", in: project.path)["decision"] == "deny")

        // An allowance for the command, however it came to be, doesn't pass it either.
        let (world, run, _) = try makeWorld(runner: .unavailable)
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.gateAllowances = [GateRequest(command: "git push", directory: worktree)] } }
        #expect(await gate(world, run, "git push", in: worktree)["reason"] == .string(ShellGate.pushDenial))
    }

    /// A gh or glab read talks only to a host the broadcast's projects' origins are on: one that names another goes to the
    /// Oracle, as it would send the token there.
    @Test func aHostReadNamesOnlyTheProjectsHosts() async throws {
        var onGitLab = OperatorServiceFixtures.project(path: "/tmp/aiterm-operators-gate-hosts")
        onGitLab.remoteUrl = "git@gitlab.com:team/shop.git"
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [onGitLab],
                                              state: .active)
        let asked = Asked()
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [onGitLab], runs: [run])) { ports in
            ports.secondOpinion = answering("ASK: it sends the token to another host.", asked)
        }
        #expect(await gate(world, run, "glab api projects/1 --hostname gitlab.com", in: onGitLab.path)["decision"] == "allow")
        #expect(asked.count == 0)
        #expect(await gate(world, run, "glab api projects/1 --hostname other.host", in: onGitLab.path)["decision"] == "deny")
        #expect(await gate(world, run, "glab mr view 3 -R https://other.host/a/b", in: onGitLab.path)["decision"] == "deny")
        #expect(asked.count == 2, "both went to the Oracle")
    }
}
