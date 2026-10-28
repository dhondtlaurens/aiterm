import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite(.blocking) struct OperatorVerdictTests {
    func arguments(sha: String, key: String = "first", passed: Bool = false) -> JSONValue {
        ["task": "PLUTO-1", "tab": "review", "sha": .string(sha), "key": .string(key), "passed": .bool(passed),
         "critical": 1, "important": 2, "minor": 3, "summary": "A race needs fixing.", "round": 1, "rounds": 2]
    }

    /// The review prompt as the tab reads it, `review` and `brief` in their places.
    func expectedReviewPrompt(review: String?, brief: String?) -> String {
        let lines = """
        [AiTerm] You are already in this task's worktree, on branch task-branch. Commit only here, on task-branch. \
        Do not create another worktree or branch. Inventories, audits and lists go in your final message, never in a new file \
        in the repository. Never type /model, /effort or /config into a live agent session: they save the person's defaults. \
        To try a model or effort, use launch flags or a scratch CLAUDE_CONFIG_DIR.

        [AiTerm] Review commit abc123, the head of branch task-branch when this tab opened. You share this worktree with this \
        task's other workers.

        [AiTerm] This tab only reviews: it never edits, commits or pushes, so "Commit only here" above is for this task's \
        other workers. You may start subagents and run read-only commands.
        """
        let block = """
        End with this verdict block, replacing the placeholders. Set passed by the review prompt's criteria. \
        Counts are non-negative integers; summary is one line the Operator can copy into record_review with the sha as it stands.
        sha: abc123
        passed: <true or false>
        critical: <count>
        important: <count>
        minor: <count>
        summary: <one-line summary>
        """
        return [review, lines, brief, block].compactMap { $0 }.joined(separator: "\n\n")
    }

    @Test func reviewPromptPinsInstructionsBriefAndVerdictInOrder() {
        #expect(TabOpener.reviewPrompt(branch: "task-branch", sha: "abc123", review: "Check correctness with /review.", brief: "Operator context.")
            == expectedReviewPrompt(review: "Check correctness with /review.", brief: "Operator context."))
    }

    @Test func reviewPromptWithoutBriefPinsInstructionsAndVerdictInOrder() {
        #expect(TabOpener.reviewPrompt(branch: "task-branch", sha: "abc123", review: "Check correctness with /review.", brief: "")
            == expectedReviewPrompt(review: "Check correctness with /review.", brief: nil))
    }

    @Test(arguments: [nil, ""]) func reviewPromptWithoutReviewTextStartsWithAiTermsLines(review: String?) {
        #expect(TabOpener.reviewPrompt(branch: "task-branch", sha: "abc123", review: review, brief: "Operator context.")
            == expectedReviewPrompt(review: nil, brief: "Operator context."))
    }

    @Test func reviewPromptsCarryTheWorkersWorktreeLine() {
        #expect(TabOpener.reviewPrompt(branch: "task-branch", sha: "abc123", review: nil, brief: "")
            .hasPrefix(WorkerStarter.worktreeLine(branch: "task-branch") + "\n\n"))
    }

    @Test(arguments: ["HEAD", "main", "HEAD~0"])
    func refusesARefInsteadOfACommitSHA(ref: String) async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        #expect(await world.call(run.id, "record_review", arguments(sha: ref)).message
            == "sha must be a commit SHA, not a branch name or revision expression.")
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func refusesAHexNamedBranchOrTagThatIsNotItsOwnSHA() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let git = GitRunner.hermetic()
        _ = try git.run(["branch", "cafe", "refs/heads/" + task.branch], in: task.worktreePath)
        _ = try git.run(["tag", "beef", "refs/heads/" + task.branch], in: task.worktreePath)
        for ref in ["cafe", "beef"] {
            #expect(await world.call(run.id, "record_review", arguments(sha: ref, key: ref)).message
                == "sha must be a commit SHA, not a branch name or revision expression.")
        }
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func refusesACommitAlreadyOnTheBaseBranch() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let base = try GitRunner.hermetic().run(["rev-parse", "refs/heads/main"], in: task.worktreePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(await world.call(run.id, "record_review", arguments(sha: base)).message
            == "sha must be one of PLUTO-1's own commits, not one already on main.")
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func refusesAShortSHAThatMatchesMoreThanOneCommit() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        // Two commits whose SHAs share 5ef3, written as objects alone: their contents fix their SHAs.
        for n in [1, 626] {
            let file = task.worktreePath + "/.git-ambiguous-\(n)"
            try "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A <a@example.com> 0 +0000\ncommitter A <a@example.com> 0 +0000\n\nAmbiguous \(n)\n"
                .write(toFile: file, atomically: true, encoding: .utf8)
            _ = try GitRunner.hermetic().run(["hash-object", "-t", "commit", "-w", file], in: task.worktreePath)
        }
        #expect(await world.call(run.id, "record_review", arguments(sha: "5ef3")).message
            == "sha 5ef3 matches more than one object; give more of its digits.")
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func withNoBaseBranchTheRepositorysOwnDefaultIsTheBase() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let git = GitRunner.hermetic(), path = task.worktreePath
        let base = try git.run(["rev-parse", "refs/heads/main"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["branch", "-m", "main", "trunk"], in: path)
        _ = try git.run(["update-ref", "refs/remotes/origin/trunk", base], in: path)
        _ = try git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: path)
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].baseBranch = "" }
        }
        #expect(await world.call(run.id, "record_review", arguments(sha: base)).message
            == "sha must be one of PLUTO-1's own commits, not one already on trunk.")
    }

    @Test func withNoBaseBranchAndNoDefaultNoVerdictIsRecorded() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let git = GitRunner.hermetic(), path = task.worktreePath
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git.run(["branch", "-m", "main", "trunk"], in: path)
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].baseBranch = "" }
        }
        #expect(await world.call(run.id, "record_review", arguments(sha: sha)).message
            == "AiTerm can't tell PLUTO-1's own commits: it has no base branch and its repository names no default branch.")
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func aGitFailureIsNotCalledACommitOffTheBranch() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make(git: TimedOutVerdictGit())
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = try #require(await world.call(run.id, "record_review", arguments(sha: sha)).message)
        #expect(message.hasPrefix("AiTerm couldn't read PLUTO-1's branch"))
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func anAbbreviatedCommitSHARecordsTheFullSHA() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(await world.call(run.id, "record_review", arguments(sha: String(sha.prefix(12)))).message == nil)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.first?.sha == sha)
    }

    @Test func savingTheReviewConversationDuringTheCommitReadStillRecords() async throws {
        let git = HeldVerdictGit()
        let (world, run, task) = try OperatorVerdictFixtures.make(git: git)
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = Task { await world.call(run.id, "record_review", arguments(sha: sha)) }
        #expect(await eventually(describing: "verdict reading git") { git.waiting == 1 })
        let conversation = UUID().uuidString
        world.workspace.mutate { $0.updateOperated(task.id) { $0.extraTabs[0].conversation = conversation } }
        git.open()
        #expect(await pending.value.value?["verdicts"]?.arrayValue?.count == 1)
        #expect(world.task(task.id)?.operated?.extraTabs[0].conversation == conversation)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.first?.sha == sha)
    }

    @Test func refusesRoundZero() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args["round"] = 0
        #expect(await world.call(run.id, "record_review", .object(args)).message == "round must be an integer of at least 1.")
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: [0, -1, 1])
    func refusesInvalidRoundTotals(rounds: Int) async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args["round"] = 2
        args["rounds"] = .int(rounds)
        #expect(await world.call(run.id, "record_review", .object(args)).message
            == (rounds < 1 ? "rounds must be an integer of at least 1." : "round must not exceed rounds."))
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: [JSONValue.int(1), .null])
    func acceptsTheLastRoundOrAnUnspecifiedTotal(rounds: JSONValue) async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args["rounds"] = rounds
        #expect(await world.call(run.id, "record_review", .object(args)).message == nil)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.count == 1)
    }

    @Test(arguments: [AgentKind.claude, .codex]) func reviewLaunchNamesBranchHeadAndKeepsReviewCapabilities(agent: AgentKind) async throws {
        let (world, _, task) = try OperatorVerdictFixtures.make(agent: agent, brief: String(repeating: "Operator context. ", count: 80))
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
        #expect(prompt.contains(tab.brief + "\n\n" + ReviewVerdict.block(sha: sha)))
        #expect(prompt.hasSuffix(ReviewVerdict.block(sha: sha)))
        if agent == .claude {
            for denial in AgentCommand.operatedClaudeDenials + AgentCommand.reviewClaudeDenials {
                #expect(command.contains(" " + AgentCommand.shellWord(denial) + " "))
            }
            #expect(command.contains("--permission-mode auto"))
            #expect(!command.contains("--allowedTools") && !command.contains("'Bash(git *)'") && !command.contains(" Task "))
        } else {
            #expect(command.contains("--sandbox read-only"))
            #expect(!command.contains("--dangerously-bypass-approvals-and-sandbox"))
        }
    }

    @Test func reviewWithNoOperatorBriefStillHasInstructionsAndVerdict() async throws {
        let (world, _, task) = try OperatorVerdictFixtures.make(brief: "")
        let tab = try #require(world.task(task.id)?.operated?.extraTabs.first)
        #expect(await world.controller.tabs.open(.init(task: task.id, key: tab.key), attempt: tab.launch) == .opened)
        let command = try #require(world.daemon.requests("tab.create").first?.params["agentCommand"] as? String)
        let file = task.worktreePath + "/.aiterm/" + TabOpener.promptFile(for: tab.key)
        // AiTerm's lines alone are too long to type, so even a review with no brief reads its prompt file.
        #expect(command.contains("$(command cat"))
        let prompt = try String(contentsOfFile: file, encoding: .utf8)
        #expect(prompt.hasPrefix("Check correctness with /review.\n\n" + WorkerStarter.worktreeLine(branch: task.branch)))
        #expect(prompt.contains("read-only commands.\n\nEnd with this verdict block"))
    }

    @Test func reviewTabsNeverUseLegacyReviewText() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make(brief: String(repeating: "Context. ", count: 200))
        world.workspace.mutate { $0.updateRun(id: run.id) {
            $0.taskSettings?.review = nil
            $0.review = "Legacy instructions must not reach this tab."
        } }
        let tab = try #require(world.task(task.id)?.operated?.extraTabs.first)
        #expect(await world.controller.tabs.open(.init(task: task.id, key: tab.key), attempt: tab.launch) == .opened)
        let command = try #require(world.daemon.requests("tab.create").first?.params["agentCommand"] as? String)
        #expect(command.contains("$(command cat"))
        let prompt = try String(contentsOfFile: task.worktreePath + "/.aiterm/" + TabOpener.promptFile(for: tab.key), encoding: .utf8)
        #expect(!prompt.contains("Legacy instructions"))
    }

    @Test func overlappingKeysReturnOneRecordedVerdict() async throws {
        let git = HeldVerdictGit()
        let (world, run, task) = try OperatorVerdictFixtures.make(git: git)
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = Task { await world.call(run.id, "record_review", arguments(sha: sha)) }
        let second = Task { await world.call(run.id, "record_review", arguments(sha: sha, passed: true)) }
        #expect(await eventually(describing: "both verdicts reading git off the main thread") { git.waiting == 2 })
        git.open()
        let answer = await first.value
        #expect(answer.value?["verdicts"]?.arrayValue?.count == 1)
        #expect(await second.value == answer)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.count == 1)
    }

    @Test func overlappingDifferentKeysAnswerTheFreshVerdictList() async throws {
        let git = HeldVerdictGit()
        let (world, run, task) = try OperatorVerdictFixtures.make(git: git)
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = Task { await world.call(run.id, "record_review", arguments(sha: sha)) }
        let second = Task { await world.call(run.id, "record_review", arguments(sha: sha, key: "second")) }
        #expect(await eventually(describing: "both keys reading git") { git.waiting == 2 })
        git.open()
        let answers = [await first.value, await second.value]
        #expect(answers.compactMap { $0.value?["verdicts"]?.arrayValue?.count }.sorted() == [1, 2])
        #expect(world.task(task.id)?.operated?.reviewVerdicts.count == 2)
    }

    @Test(arguments: ["takeover", "ownership", "branch", "worktree", "tabRole", "tabReplaced", "tabRemoved", "taskRemoved", "pause", "ended"])
    func changesDuringTheCommitReadRefuseTheVerdict(change: String) async throws {
        let git = HeldVerdictGit()
        let (world, run, task) = try OperatorVerdictFixtures.make(git: git)
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = Task { await world.call(run.id, "record_review", arguments(sha: sha)) }
        #expect(await eventually(describing: "verdict reading git off the main thread") { git.waiting == 1 })
        world.workspace.mutate { state in
            switch change {
            case "pause": state.updateRun(id: run.id) { $0.intent = .paused }
            case "ended": state.updateRun(id: run.id) { $0.intent = .stopped }
            case "taskRemoved": state.tasks.removeAll { $0.id == task.id }
            case "takeover": state.updateOperated(task.id) { $0.takenOver = true }
            case "ownership": state.updateOperated(task.id) { $0.ownership += 1 }
            case "tabReplaced": state.updateOperated(task.id) { $0.extraTabs[0].agent = .claude }
            case "tabRole": state.updateOperated(task.id) { $0.extraTabs[0].role = .work }
            case "tabRemoved": state.updateOperated(task.id) { $0.extraTabs.removeFirst() }
            default:
                if let i = state.tasks.firstIndex(where: { $0.id == task.id }) {
                    if change == "branch" { state.tasks[i].branch = "other" }
                    else { state.tasks[i].worktreePath += "-moved" }
                }
            }
        }
        git.open()
        #expect(await pending.value.message != nil)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty != false)
    }

    @Test func newRunsRefuseHeadlessReview() async throws {
        let (world, run, _) = try OperatorVerdictFixtures.make()
        #expect(await world.call(run.id, "review_task", ["task": "PLUTO-1", "instructions": "Review."]).message
            == "Run the review in a tab: open_tab with role review, then record_review.")
    }

    @Test func recordsVerdictsAndReplaysTheOriginalPrefixAfterAnotherReviewAndReload() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
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
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args["tab"] = .string(tab)
        let answer = await world.call(run.id, "record_review", .object(args))
        #expect(answer.message?.contains("review tab") == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: ["passed", "critical", "important", "minor", "round", "rounds", "summary"])
    func refusesMalformedVerdictFields(field: String) async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args[field] = field == "summary" ? "Two\nlines" : "wrong type"
        #expect(await world.call(run.id, "record_review", .object(args)).message?.contains(field) == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test(arguments: ["critical", "important", "minor", "round", "rounds"])
    func refusesNegativeCountsAndRounds(field: String) async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
        let sha = try GitRunner.hermetic().run(["rev-parse", "HEAD"], in: task.worktreePath).trimmingCharacters(in: .whitespacesAndNewlines)
        var args = try #require(arguments(sha: sha).objectValue)
        args[field] = -1
        #expect(await world.call(run.id, "record_review", .object(args)).message?.contains(field) == true)
        #expect(world.task(task.id)?.operated?.reviewVerdicts.isEmpty == true)
    }

    @Test func refusesACommitOffTheTaskBranchButAcceptsAnAncestor() async throws {
        let (world, run, task) = try OperatorVerdictFixtures.make()
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
