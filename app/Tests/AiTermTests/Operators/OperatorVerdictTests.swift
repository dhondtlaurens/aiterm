import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite(.blocking) struct OperatorVerdictTests {
    func fixture(agent: AgentKind = .codex, brief: String = "Operator's extra instructions.") throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let (world, run, task) = try OperatorOpenTabTests().makeWorld(change: { task in
            task.operated?.extraTabs = [ExtraTab(key: "review", agent: agent, model: "review-model", reasoning: "high",
                modelReason: "Review", brief: brief, launch: LaunchAttempt(number: 1, requestedAt: Date()), role: .review),
                ExtraTab(key: "work", agent: .codex, model: "worker", reasoning: nil, modelReason: "Work", brief: "Work",
                launch: LaunchAttempt(number: 1, requestedAt: Date()))]
        })
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.taskSettings = TaskSettings(review: "Check correctness with /review.", end: .commit) } }
        return (world, run, task)
    }

    func arguments(sha: String, key: String = "first", passed: Bool = false) -> JSONValue {
        ["task": "PLUTO-1", "tab": "review", "sha": .string(sha), "key": .string(key), "passed": .bool(passed),
         "critical": 1, "important": 2, "minor": 3, "summary": "A race needs fixing.", "round": 1, "rounds": 2]
    }

    @Test(arguments: [AgentKind.claude, .codex, .pi]) func reviewLaunchNamesBranchHeadAndKeepsReviewCapabilities(agent: AgentKind) async throws {
        let (world, _, task) = try fixture(agent: agent, brief: String(repeating: "Operator context. ", count: 80))
        let git = GitRunner.hermetic()
        let sha = try git.run(["rev-parse", "refs/heads/" + task.branch], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["checkout", "--detach"], in: task.worktreePath)
        _ = try git.run(["commit", "--allow-empty", "-m", "Detached HEAD differs"], in: task.worktreePath)
        let tab = try #require(world.task(task.id)?.operated?.extraTabs.first)
        #expect(await world.controller.tabs.open(.init(task: task.id, key: tab.key), attempt: tab.launch) == .opened)
        let command = try #require(world.daemon.requests("tab.create").first?.params["agentCommand"] as? String)
        let prompt = try String(contentsOfFile: task.worktreePath + "/.aiterm/" + TabOpener.promptFile(for: tab.key), encoding: .utf8)
        #expect(prompt.hasPrefix("Check correctness with /review."))
        #expect(prompt.contains(sha) && prompt.contains(task.branch))
        #expect(prompt.contains("never edits, commits or pushes"))
        #expect(prompt.contains("subagents") && prompt.contains("read-only commands"))
        #expect(!prompt.contains("Commit only your own changes"))
        for field in ["passed:", "critical:", "important:", "minor:", "summary:"] { #expect(prompt.contains(field)) }
        #expect(prompt.hasSuffix(tab.brief))
        switch agent {
        case .claude:
            for denial in AgentCommand.operatedClaudeDenials + ["Edit", "Write", "NotebookEdit"] {
                #expect(command.contains(" " + AgentCommand.shellWord(denial) + " "))
            }
            #expect(command.contains("--permission-mode auto"))
            #expect(!command.contains("--allowedTools") && !command.contains("'Bash(git *)'") && !command.contains(" Task "))
        case .codex:
            #expect(command.contains("--sandbox read-only"))
            #expect(!command.contains("--dangerously-bypass-approvals-and-sandbox"))
        case .pi:
            #expect(prompt.contains("no read-only mode"))
        }
    }

    @Test func reviewWithNoOperatorBriefStillHasInstructionsAndVerdict() async throws {
        let (world, _, task) = try fixture(brief: "")
        let tab = try #require(world.task(task.id)?.operated?.extraTabs.first)
        #expect(await world.controller.tabs.open(.init(task: task.id, key: tab.key), attempt: tab.launch) == .opened)
        let command = try #require(world.daemon.requests("tab.create").first?.params["agentCommand"] as? String)
        let file = task.worktreePath + "/.aiterm/" + TabOpener.promptFile(for: tab.key)
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? command
        #expect(text.contains("Check correctness with /review."))
        #expect(text.contains("passed:") && text.contains("summary:"))
    }

    @Test func newRunsRefuseHeadlessReview() async throws {
        let (world, run, _) = try fixture()
        #expect(await world.call(run.id, "review_task", ["task": "PLUTO-1", "instructions": "Review."]).message
            == "Run the review in a tab: open_tab with role review, then record_review.")
    }

    @Test func recordsVerdictsAndReplaysTheOriginalPrefixAfterAnotherReviewAndReload() async throws {
        let (world, run, task) = try fixture()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = await world.call(run.id, "record_review", arguments(sha: sha))
        #expect(first.message == nil)
        #expect(first.value?["failed"] == 1)
        #expect(first.value?["verdicts"]?.arrayValue?.count == 1)
        let second = await world.call(run.id, "record_review", arguments(sha: sha, key: "second", passed: true))
        #expect(second.value?["failed"] == 1 && second.value?["verdicts"]?.arrayValue?.count == 2)
        let saved = try JSONEncoder().encode(world.state)
        let reloaded = try OperatorWorld(JSONDecoder().decode(AppState.self, from: saved))
        // A retry needs only its identity: changed or absent verdict arguments cannot overwrite the first answer.
        #expect(await reloaded.call(run.id, "record_review", ["task": "PLUTO-1", "key": "first"]) == first)
        #expect(reloaded.task(task.id)?.operated?.reviewVerdicts.count == 2)
        let verdict = try #require(reloaded.task(task.id)?.operated?.reviewVerdicts.first)
        #expect(verdict.sha == sha && verdict.tab == "review" && !verdict.passed)
        #expect(verdict.critical == 1 && verdict.important == 2 && verdict.minor == 3)
        #expect(verdict.round == 1 && verdict.rounds == 2 && verdict.summary == "A race needs fixing.")
    }

    @Test(arguments: ["main", "work", "missing"]) func refusesTabsThatAreNotThisTasksReview(tab: String) async throws {
        let (world, run, task) = try fixture()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args["tab"] = .string(tab)
        let answer = await world.call(run.id, "record_review", .object(args))
        #expect(answer.message?.contains("review tab") == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: ["passed", "critical", "important", "minor", "round", "rounds", "summary"])
    func refusesMalformedVerdictFields(field: String) async throws {
        let (world, run, task) = try fixture()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args[field] = field == "summary" ? "Two\nlines" : "wrong type"
        #expect(await world.call(run.id, "record_review", .object(args)).message?.contains(field) == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: ["critical", "important", "minor", "round", "rounds"])
    func refusesNegativeCountsAndRounds(field: String) async throws {
        let (world, run, task) = try fixture()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args[field] = -1
        #expect(await world.call(run.id, "record_review", .object(args)).message?.contains(field) == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func refusesACommitOffTheTaskBranchButAcceptsAnAncestor() async throws {
        let (world, run, task) = try fixture()
        let git = GitRunner.hermetic(), path = task.worktreePath
        let ancestor = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["commit", "--allow-empty", "-m", "Task branch advances"], in: path)
        _ = try git.run(["checkout", "-b", "other"], in: path)
        _ = try git.run(["commit", "--allow-empty", "-m", "Other branch"], in: path)
        let other = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        // HEAD deliberately differs: membership must use the task's named branch.
        #expect(await world.call(run.id, "record_review", arguments(sha: other)).message?.contains("branch") == true)
        #expect(await world.call(run.id, "record_review", arguments(sha: "--all")).message != nil)
        #expect(await world.call(run.id, "record_review", arguments(sha: ancestor)).value?["failed"] == 1)
    }
}
