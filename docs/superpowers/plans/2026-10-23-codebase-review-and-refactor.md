# Codebase review and refactor: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dead code and duplication left by repurposed features, apply the codebase's own practice where it departs, take work off hot paths, and fix the audited defects test-first, ending with fewer lines than it started.

**Architecture:** One task per subsystem lane with disjoint file ownership. Swift tasks run one after another (one worktree, one `.build`); the daemon lane runs in a separate Codex tab; cross-language edits wait for both sides. Refactors keep behaviour under the existing tests; every behaviour change starts with a test that fails.

**Tech Stack:** Swift 6.4 (SwiftUI/AppKit, Swift Testing) via `scripts/swift.sh`/`scripts/test.sh`; Python 3.11 daemon (pytest, mypy strict, ruff).

**Spec:** `docs/superpowers/specs/2026-10-23-codebase-review-and-refactor-design.md`

## Global Constraints

- Work only in this worktree on `chore/codebase-review-and-refactor-dead-code-duplicati`; push nothing.
- This session never edits `daemon/` or `hooks/` before Task 10; the Codex tab never edits anything else.
- Commit only your own paths (`git add <paths>`, never `-A`); on `index.lock`, wait a few seconds and retry.
- Build/test only through `scripts/swift.sh` and `scripts/test.sh`, never `swift` directly; iterate with `scripts/test.sh swift -- --filter <Suite>`; plain `scripts/test.sh` before each commit (it queues machine-wide: run it in the background).
- Before deleting any declaration: `git grep -n -w <name> -- app daemon scripts hooks` shows no reader left; name it in the task report.
- Wire and data contracts unchanged except where a task says so: daemon RPC names and keys, hook schemas, policy file, persisted JSON keys, MCP tool names and parameters, the `aiterm.overview` notification key, the `debrief-` notification id prefix.
- Every colour from `Palette`, every size from `Metrics`; a primitive/pattern inventory change updates `app/Sources/AiTermUI/README.md` in the same commit.
- Snapshots stay byte-identical to `build/snapshots-baseline` (drawn at b29ffc4) unless the task names the image it changes on purpose: check with `scripts/snapshots.sh build/snapshots-after` then `cmp` per file.
- Copy: no em dashes in anything a person or agent reads; Title Case menus and buttons; the README's wording rules.
- If a consolidation reads worse than the copies once in the code, keep the copies and say so in the report.

## Review Focus

- A saved workspace from b29ffc4 (runs with milestone-era fields, `jiraCreated` with `find_` keys, a `StoredJSON` row) must load and save back losslessly: Task 1 and Task 5 each add or keep a round-trip test over such a file.
- A run in flight when the app updates: removing the milestone ladder must not refuse an accept or a plan an M3 build accepted; Task 1 rewrites the M1-pinned tests at M3 and keeps every M3 assertion.
- Requests to Jira/GitHub/GitLab stay byte-identical after the host-client consolidation, except Jira's `+`: Task 6 asserts exact URLs before and after.
- Remove still cleans up its own half-finished removal (the case `deleteLeftover` exists for) while no longer deleting an unknown folder: Task 7 tests both.
- The Operator's tool handlers still refuse in the same order (slice before pause where documented): Task 4's preamble helpers keep `requestReview`/`replyThread` as they are and the refusal-order tests pass unchanged.

---

### Task 1: Operator core: dead code and the milestone ladder

**Files:** `app/Sources/AiTermCore/Operators/{OperatedTransitions,OperatedTransitions+State,PlanRevision,PublicationGuard,RunStatus,DeliveryCheck,OperatorTiming,OperatorCommand,OperatorRequests}.swift`, `app/Sources/AiTermCore/OperatorModels.swift`, `app/Sources/AiTermCore/Sidebar/{BroadcastRow,SidebarModel}.swift` (OperatorRequests callers only), `app/Sources/AiTerm/Operators/{OperatorController,OperatorNotifier,OperatorToolHandler+Tasks,OperatorToolHandler+Plan}.swift`, `app/Sources/AiTerm/{SidebarProjection,AppController}.swift` (call sites only), tests under `app/Tests/AiTermCoreTests/Operators/` and the app tests that pin `.m1` (`OperatorPlanToolsTests`, `OperatorBranchRaceTests`, `OperatorUpstreamTests`, `OperatorReviewTests`, `OperatorNotifierTests`).

**Interfaces:** Produces `OperatedContext` without `milestone`/`codeDependentStarted`; `OperatorRequests.open(run:state:)` without `prompts:`; `OperatorNotifier(notifications:state:)`.

- [ ] Delete `OperatedAction.publish`, `OperatedTransitionError.endIsCommit/.notInThisMilestone/.publishedSHANotAccepted` and their table rows, names and the publishing test.
- [ ] Delete `PlanRevision.Failure.nothingSubmitted`, `PublicationGuard.mergeLeftForYou` (+ its test), `DeliveryCheckFile.Entry.checkedAt`, the `commitsAhead:` parameter of `RunStatus.isReadyForAcceptance` (tests use the production path).
- [ ] Delete `TaskLiveFacts.lastCommit/.summary` and `RunStatus.TaskLine.lastCommit/.summary`; drop the arguments from `OperatorEvalGrading` scenarios and `RunStatusTests`. (`operator_mcp.py`'s description is Task 10.)
- [ ] Make `OperatorRun.leftForYouRecords` a non-optional `[String: String]` encoded only when non-empty, decoding the same key, like `jiraSprinted`.
- [ ] Remove `prompts:` from `OperatorRequests.open` and `OperatorNotifier`; the "<agent> asks to …" branch goes; repoint `OperatorNotifierTests.aWorkersPromptOpensItsWindow` at the recorded question text.
- [ ] Retire the milestone ladder: delete `OperatorMilestone`, `TaskEnd.availableFrom`, `OperatedContext.milestone`, `codeDependentStarted`, `.reacceptAfterDependentStarted`, `PlanRevision.Failure.unsupportedEnd`, `OperatorCommand.planRule(milestone:)`'s parameter, `OperatorPorts.milestone`, the `ports.milestone >= .m3` branches. `accept` allows `[.accepted, .published, .inReview]`. Every test that sets `.m1`/`.m2` is rewritten at today's rules or deleted when it pins only a pre-M3 refusal (`aDraftMROrMergeIsRefusedBeforeM3`, `eachEndArrivesWithItsMilestone`, `beforeM3ARepeatedAccept…`). The brief text must render as it does today: compare `OperatorCommand` output before/after for the default profile.
- [ ] Run `scripts/test.sh swift -- --filter 'Operat|PlanRevision|RunStatus|PublicationGuard|DeliveryCheck|BroadcastRow|BroadcastSection'`: PASS.
- [ ] Plain `scripts/test.sh`: PASS. Commit: "Retire the Operator's milestone ladder and drop the core's dead transitions, failures and facts".

### Task 2: Operator core: duplication, practice, tests and its two fixes

**Files:** `app/Sources/AiTermCore/Operators/*`, `app/Sources/AiTermCore/Sidebar/{BroadcastBoard,BroadcastRow,OperatorLine}.swift`, `app/Sources/AiTermCore/Operators/AppState+Operators.swift`, `app/Sources/AiTerm/Operators/OperatorToolHandler+Review.swift` (refusal copy only), tests in `app/Tests/AiTermCoreTests/Operators/`.

**Interfaces:** Produces `OperatorRun.isPaused: Bool` (state paused or operatorOffline, or intent paused), `SessionState.turnEnded: Bool` (idle or done), `BroadcastRequest.Kind` declared in urgency order with `CaseIterable` and a `rank`.

- [ ] Test first: in `OperatorWakeNoticeTests`, `waiting(status(obligations: .init(workerAsks: [WorkerAsk(key: "A", question: "Which?")])))` == `"1 task asking the Operator in “Sprint 42”."`; likewise one line each for `changedAfterAcceptance` ("changed after acceptance"), `finishedWithoutCommit` ("finished with no commit"), `reviewQuiet` ("in review with nothing waiting"). Run: FAIL. Extend `OperatorWakeNotice.waiting` with those four parts. Run: PASS.
- [ ] Test first: a table test in `ShellGateTests` that every `OperatorCommand.shellDenials` pattern's command is a hard denial of `ShellGate`. Run: PASS or FAIL; a FAIL is a real gap: fix the gate, not the test.
- [ ] One private first-word parser for `ChallengeLaunch.verdict`/`gateVerdict`.
- [ ] `BroadcastRequest.Kind` urgency order replaces the two literal lists in `OperatorLine.first` and `WorkerTabs.tabToBring` (no force unwraps).
- [ ] Replace the re-spelled predicates with `hasEnded`, `isPaused`, `turnEnded` (Core and the app's 4 `hasEnded` spellings); pass `requests` and the filtered tasks down in `SidebarModel.broadcastSection`/`broadcastRow`; compute `task.workerTabs(in:)` once in `OperatorLine.task`.
- [ ] `OperatorCommand.mcpConfig`/`gateSettings` and `OperatorProfileStore.save` throw instead of writing empty JSON; `prepare` propagates.
- [ ] `ShellGate.Judge.programs` stored once; `TaskPublisher`'s unreachable fallback names what it guards; `OperatorRequests` set renamed `silent`; the internal-only `public` names in the audit list made internal (`openThreads`, `fit`, `ending(of:)`, `Count`, `WorkerTurn.question/endsWithQuestion`, `BroadcastBoard.count/progress`, `ShellGate.maskedEnv`): compile is the check.
- [ ] Copy: `AgentReview` header and `defaultReviewer` doc name PI; `+Review`'s "Neither Claude nor Codex is installed" refusal says no reviewer agent is installed; "operation"/"second opinion" in Core comments and the Oracle prompt texts read "broadcast"/"the Oracle".
- [ ] Tests: fold `FinalFixTests` (move `acceptedPublicationStillNeedsItsEnd`, `waitingPublicationUsesTheHostsQuietReason` and the `freshStartMessage` "Why:" assertion to their home suites; delete the file); cut 3 of 4 `WorkerResumeTests` (keep `aCodexResumeKeepsTheBypass`), `RunSchedulerClaimTests.operationsAreClaimedOldestFirst`, `TaskPublicationTests.theMergeWaitIsBounded`; collapse the three pause-predicate tests into one on `isPaused`; date the eval baseline's comments; rename test names saying Operation.
- [ ] Filtered run as Task 1, then plain `scripts/test.sh`: PASS. Commit in two: "Give the Operator core's repeated rules one home" and "Name every wake reason in the wake Notice".

### Task 3: Operator app: functional fixes, test-first

**Files:** `app/Sources/AiTerm/Operators/{BranchWatch,OperatorController,OperatorToolHandler+Review,OperatorToolHandler+Plan,OperatorToolHandler+Tasks,OperatorToolHandler+Jira,OperatorToolHandler,WorkerTranscript}.swift`, `app/Sources/AiTerm/Views/HarnessSettingsPane.swift` (one string), tests in `app/Tests/AiTermTests/Operators/` and `FixerSettingsTests`.

- [ ] BranchWatch: test in `BranchWatchTests` beside `aCommitTheIdleWorkersLastMessageNamesOffItsBranchIsFlaggedWithTheBranchItIsOn`: world with `claudeConfig = ClaudeConfig("~/claude-alt")`, reply saved under `<home>/claude-alt/projects/x/<id>.jsonl`, tick, `#expect(branchDrift != nil)`. FAIL, pass `ports.claudeConfig` at `BranchWatch.swift:62`, PASS.
- [ ] Uncertain reason: test that `OperatorWaker.isPlain` holds for every literal reason `OperatorController` passes to `say`. FAIL, reword to "one task is uncertain, no worker confirmed in its window", PASS.
- [ ] `read_task what: review`: host whose `approvals(of:)` throws → answer has `threads`, `approvalsNote` (string), no `approvals`. FAIL, add the note as `threads` has, PASS.
- [ ] `hasCodeHost`: a git failure other than "no such remote" throws (refusal names git's sentence) instead of reading as no origin. Test with a failing `git remote get-url`. FAIL, fix, PASS.
- [ ] `resendOwnership()` keeps its task as `resending` (awaitable seam), cancelled in `stop()`; `reconnectingSetsEachTasksOwnershipAgain` awaits it.
- [ ] `message_task` replay window: test that an identical text to the same tab after `2 × OperatorTiming.operatorRequestTimeout + 1 s` is typed again, and within it is answered from the record. FAIL (today 600 s), set the window to `2 × operatorRequestTimeout`, PASS. Rename `deliveredMessagesReplayForTenMinutes` accordingly.
- [ ] `jira_edit`: the handler stops reading `key` (schema change is Task 10); `anEmptyEditIsRefused` updated; a call without `key` edits.
- [ ] Help with problems help text: "…a button asks the Operator for a fix: Claude Code, at the model and reasoning set in Settings › Operator. Nothing changes until you press Apply." and `FixerSettingsTests:59`. Snapshot `settings-help-with-problems.png` changes on purpose.
- [ ] Flaky `OperatorTaskToolsTests.aWideDiffStaysSmallWhateverItsParts`: use superpowers:systematic-debugging. First reproduce (run the test alone in a loop with `--filter`), then test the hypothesis that git's automatic maintenance (`gc --auto`/`maintenance --auto --detach` after the 120 commits) races the reads: add `GIT_CONFIG_COUNT`/`KEY`/`VALUE` for `gc.auto=0` and `maintenance.auto=false` to `HermeticGit.environment` and loop again. Keep the change only if it removes the failure; report what was found either way.
- [ ] Plain `scripts/test.sh`: PASS. Commit per fix group.

### Task 4: Operator app: dead code, duplication, practice, performance, tests

**Files:** `app/Sources/AiTerm/Operators/*`, `app/Sources/AiTerm/AppController+Operators.swift`, `app/Sources/AiTerm/AgentIntegrations.swift`, `app/Sources/AiTerm/Views/Operators/*`, `app/Sources/AiTerm/Views/OperatorBadge.swift`, `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift`, `app/Sources/AiTermCore/Operators/AppState+Operators.swift`, `app/Tests/AiTermTestSupport/OperatedWorld.swift`, `OperatorUIFixtures.swift`, tests in `app/Tests/AiTermTests/Operators/` and the operator view tests.

**Interfaces:** Produces `enum OperatorTool: String, CaseIterable` (AiTermCore/Operators) with the 30 tool names; `public mutating func updateOperated(_:_:)` and `task(inRun:named:)` on `AppState` in Core; `OperatorToolHandler.within(_:cancelling:_:)`.

- [ ] Dead: `WorkerStarter.onBlocked`'s reason, `mergeWatchStopped`'s `why`, the unreachable "Operation" name fallback (`broadcastName(from:)`), `OperatorReopening` collapsed to the cases read, `OperatorUIFixtures.profile(oracle:)`, the `find_` reservation and its test assertion, `"open_tab"` in `actsOnTask`, `proposeLessonIsGone`; fold the unreachable `.acted` arms.
- [ ] Move `updateOperated`/`task(inRun:named:)` into Core's `AppState+Operators.swift`, delete `AppState+Operations.swift` and `OperatedWorld.update`.
- [ ] One tick-pass helper for `BranchWatch.poll`/`ReviewWatcher.poll`; one host view for `BroadcastBoardHost`/`ShelvedBroadcastHost` (board source and refresh rule as parameters); TaskFinisher's two publisher closures from one builder, `recordProblem` via `recordFailure`, `advance` via `leaveForYou`; pause/end/forget's take-back through one helper; `tabsKnown` handed to the reconciler as a closure.
- [ ] One `skillAgents` and one skill-dedupe helper for `NewBroadcastModel`/`OperatorSettingsModel`; one timeout racer (`first` → `within(…, cancelling: false)`, drop `Once`); `operated(_:in:)` for the six task preambles, `jiraWrite(in:otherwise:)` for the six Jira writes, one `requireSlice` keyed by slice (keep `requestReview`/`replyThread`'s order); ChipsPicker shares SearchPicker's index/command/pick value; `OperatorSnapshots` duplicate builders.
- [ ] `OperatorTool` enum: `perform` switches on it, the act/mutating/challenged sets are typed; test `theAppNamesEveryToolTheDaemonServes` reads `daemon/aitermd/operator_mcp.py`'s `_tool("…"` names and compares to `allCases` (read-only).
- [ ] Practice: `activities`/`acting` `@ObservationIgnored` where no view reads them; `heardWorkspace` no longer re-runs `refreshRows` for workspace-originated changes; `summaryWaits` entry removed when it fires; `TaskFinisher.Result.result` an enum with the same raw strings; janitor Task → `defer`; `launchChoice` struct; `filingFinds` keyed by an enum; `_editorFocused` private; summary snags keyed by `key`; copy feedback via `.task(id:)`; rename `fixerModel(s)` to `taskModel(s)`, drop `fixModel`'s ignored argument.
- [ ] Performance: `gate` builds status and prompt only after `guard opinion.isOn`; `challengeGate` builds status JSON only for prompts that use it; one transcript locator (conversation → URL, validated by `fileExists`) shared by BranchWatch, WorkerTurnReader, WorkerQuietWatch and `read_task`; BranchWatch re-reads a tab's transcript only when `WorkerTranscript.modified` changed since its last pass (test: two ticks with an unchanged file read once).
- [ ] Names: overview → board (`presentOverview` → `presentBoard`, `watchOverviewRequests`, `OperatorNote.Target.overview` → `.board`, keeping the `aiterm.overview` userInfo string); "operation"/"debrief"/milestone words in comments and test names; `StepClock` replaced by TestSupport's `TestClock` for `ports.now` and `publishNow`.
- [ ] Tests: move the seven misfiled tests out of `OperatorReviewTests`; parameterise the 4+3+3 near-identical tests in `OperatorToolHandlerTests` and split it into `OperatorRecordToolsTests`/`OperatorJiraToolsTests`; cut `aRepeatedAcceptAnswersWhilePaused`, the two `OperatorWakeNoticeTests` repeats, fold `OperatorStallTests` into `RunReconcilerTests` and delete it.
- [ ] Snapshots: `cmp` against baseline for the board, New Broadcast and Operator images: identical.
- [ ] Plain `scripts/test.sh`: PASS. Commits per concern.

### Task 5: Core infrastructure

**Files:** `app/Sources/AiTermCore/{Daemon,Git,Tasks,Workspace}/*`, `Models.swift`, `StateStore.swift`, `FileStamps.swift`, `SerialThread.swift`, `Sidebar/SidebarModel.swift`, `Jira/{ADFText,JiraClient}.swift` (StoredJSON refs only), their tests, `app/Tests/AiTermTestSupport/TestDeadline.swift`.

**Interfaces:** Produces `JSONValue` at `app/Sources/AiTermCore/JSONValue.swift` (root), replacing `StoredJSON`; `protocol LenientRawDecodable` with `static var unrecognized`.

- [ ] RemoteResolver: test with origin/fork remotes, branch a tracks origin, b tracks fork, resolve on a, `git switch b`, expect fork's URL. FAIL, watch HEAD (or the reftable list) beside `config`, PASS.
- [ ] `BranchNaming.isValid` throws: `TaskCreator.create` with a runner timing out on `check-ref-format` throws the timed-out `GitError`, not `.invalidBranch`. FAIL, fix with `git.ask(…, none: [128])`, PASS.
- [ ] `SidebarModel.sessionTitles` with two tasks sharing an id does not trap. FAIL (trap), `uniquingKeysWith`, PASS.
- [ ] `DaemonClient` logs why a connection ended (all but `closedHere`) with `Log.daemon`.
- [ ] LocalMerge: a failing MERGE_HEAD check is an error, not "not merging" (FlakyGit test), and ExcludeFile logs a failed `rev-parse`.
- [ ] Dead: `SerialThread.enqueue`, `ClosedWindowTriage.isHolding` (tests read `held.isEmpty`), `TestDeadline.fromNow`, `Project`'s legacy `jiraProject` write.
- [ ] Duplication: `JSONValue` replaces `StoredJSON` (move to root first; a b29ffc4 state.json round-trips byte-identical: add the test); the lenient raw-value decoder protocol for the nine copies; one resolver shell for Branch/Remote/DefaultBranch resolvers (keep each one's locate/read/failure mapping); `Repository.forgetWorktreeRecord(at:)`; `Repository.toplevel` via `git.ask`; drop `DaemonClient.Envelope.encode(to:)`.
- [ ] Practice: Core-only `public` declarations internal (list in the audit; compile with `scripts/test.sh` is the check); `FileStamps.stamp` via `lstat`; stale `unrecognizedAgent` comment; SidebarModel blank lines.
- [ ] Tests: the duplicate and misplaced tests in the audit list (≈ −120).
- [ ] Plain `scripts/test.sh`: PASS. Commits per concern.

### Task 6: Core harnesses, hosts, fix, Backpack

**Files:** `app/Sources/AiTermCore/{Harnesses,Hooks,Agents,Fix,Updates,GitHub,GitLab,Jira,Backpack,Machine,Interface}/*`, `HTTPJSON.swift`, `ProcessRunner.swift`, `ClaudeConfig.swift`, `Operators/ChallengeLaunch.swift` (headless-run pieces only), `app/Sources/AiTerm/Operators/SecondOpinionRunner.swift` (PATH helper), `app/Sources/AiTerm/{UpdateController,AgentIntegrations}.swift` and `Resources/Info.plist` only as the feed removal needs, their tests, `app/Tests/AiTermTestSupport/{BackpackFakes,FixPipelineFake}.swift`.

**Interfaces:** Produces `HeadlessRun` (Agents/) owning the Claude and Codex read-only cores, `FixerInvocation` renamed `HeadlessInvocation`; `Harness.modelArguments(model:reasoning:) -> [String]`; `Harness.hookURL(port:) -> String`; `PipeDrain(fd:limit:onEnd:)`; `ProcessRunner.environment(runningCLI:overrides:)`.

- [ ] Jira `+`: stubbed `assignable(project:query: "me+jira@x.com")` request's query contains `query=me%2Bjira@x.com`. FAIL, move the `%2B` rule into `HTTPJSON.url` and delete the two client copies, PASS; GitHub/GitLab URL tests unchanged.
- [ ] `GitLabClient.encodedProject("feat/é") == "feat%2F%C3%A9"`. FAIL, ASCII-only allowed set, PASS.
- [ ] `JiraClient.projects()` with an endless `isLast: false` stub stops at the cap the other Jira pagers use. FAIL (hangs: guard with a time limit), cap, PASS.
- [ ] Decision 2: delete the Fix pipeline's Codex branches (`codexGitRoot`, `codexFiles`, Codex arms of look/apply/answer, `CodexEvent`, `readAnswerFile`) and their tests; repoint the FIFO/size answer-file tests at `RegularFile`.
- [ ] Decision 3: delete `GitLabReleaseSource`, ReleaseFeed's GitLab branch and its secrets/defaults parameters, `UpdateError.noToken/.tokenForOtherHost/.rejected`; move the credential-redirect tests to `HTTPJSONTests` first; `test-app-bundle.sh` keeps rejecting non-GitHub feeds.
- [ ] Dead: `AgentCommand.operatedAgents` (tests → `ModelChoice.pair`), `BackpackEnding` (plain `.ended`), `PiModelCatalog.discover(runner:)`, `SkillCatalog.frontmatterValue`, `BackpackStatus.degraded`, `AgentKind.fixer`, `UserConfigFile.Contents.value`, FixerAgent's Codable/CaseIterable, HarnessServiceError's payload, raw types nothing reads, `unsuccessfulResponse` (throw `URLError(.badServerResponse)`), unreachable else-branches, `FakeBackpack.init(defaults:)`; `FixApplied` becomes a throwing check.
- [ ] Duplication: `Harness.modelArguments` for both flag spellings (commands byte-identical: existing argv tests), `Harness.hookURL`, `HeadlessRun`, the PATH helper, `PipeDrain`, ClaudeConfig.settingsURL and the other paths, driver prologues, HarnessTestClient's round trip, the HTTP clients' `HostAPI`, `pagesUntilEmpty`, GraphQL cursor helper, lenient Jira decoders, rethrow helper, ADFText writer beside its reader. Every request byte-identical (stub tests).
- [ ] Performance: `ProjectFiles.outside` lists with resource keys and stats/resolves only the shown entries (test: a folder of `limit + 50` entries stats at most `limit`); `FileIndex.init` computes each depth once; CodexDriver.probe parses once; GitHub's two check reads `async let`; GitLab reviewers looked up concurrently.
- [ ] Names: `FixerChoice.swift` → `HelpWithProblems.swift`, "Fix with AI" comment, `StatusLineOriginal.record(_:home:)`, "shims", Grok TOML fixture names, `AgentCommand+Worker.swift` folded in, `OperationIssue.reason` forwarder inlined; Core-only `public` → internal, `FixPipelineFake` into AiTermCoreTests.
- [ ] Tests: StatusLineShimTests one-element loop, and the duplicates in the audit list; `ModelCatalogTests` → `ModelFilesTests`.
- [ ] Plain `scripts/test.sh`: PASS. Commits per concern.

### Task 7: App shell

**Files:** `app/Sources/AiTerm/*.swift` (not Operators/, Views/, Snapshots/), `app/Sources/AiTermCore/Git/Repository+Worktrees.swift` and `Tasks/TaskWorkflow.swift` for decision 6, `app/Sources/AiTermCore/Tasks/{AgentDraft,ReviewDraft}.swift` for defaults, `app/Sources/AiTerm/Appearance.swift`, tests in `app/Tests/AiTermTests/` for these.

**Interfaces:** Produces `CreationContext` (the shared creation dependencies, `.scratch()` for tests); `RaceFixture` in its own file with `checkoutPollInterval:` and `confirmsRemoval:`.

- [ ] Creation defaults: scratch preferences with `modelDefaults.claude` = the second model of `ScratchHome.catalogue(.claude)`; `presentNewTask`; `#expect(draft.model == thatId)`. FAIL, pass the controller's `defaults` through and drop the `.standard` defaults, PASS.
- [ ] Terminal reopen banner: `RecordingDaemon(failing: ["window.createTerminal": "temporary_failure"])`, clear the failure, select the terminal, `#expect(controller.issue == nil)`. FAIL, report with the terminal as subject and drop issues on success, PASS.
- [ ] Integrations Save with a saved, unchanged Jira writes 0 secrets (counting SecretStore). FAIL, write only what changed, PASS.
- [ ] `recoverAtLaunch` via `await worker.run`: engaged crash marker + a lid-sleep fake that blocks; a sibling main-actor task runs meanwhile. FAIL, fix, PASS.
- [ ] Decision 6: Remove deletes an unlisted leftover folder only when this row's earlier removal is recorded as having reached git; otherwise it asks (`AlertPrompt`, keep is the safe default). Tests: own half-finished removal still cleaned; an unknown folder asks and Keep keeps it.
- [ ] Dead: `TaskArchiver.running`, `BackpackController.password`, both `canMove`s, `FixSession.buttonTitle`, `State.unavailable`'s payload, `RowFocus.selectedOperationId`, the test-only forwarders, `CreationKind.stepCount/agentStep`; private where only the file uses them; test seams under `#if DEBUG`.
- [ ] Duplication: `CreationContext`; one fix-pipeline factory; `FixerResolution.agent`; `AlertPrompt.removeTask`, the removed toast, `kindName`; `TerminalActions.openWindow` binds or closes like TaskLauncher's.
- [ ] Practice and performance: log the three swallowed errors; `FixClone.sweep`/FixSession file work via `BackgroundWork`; tool cancellation inside `OperatorController.stop()`; LiveSessions registered first; `HelperLink.claudeDirectory` ignored; WorkspaceWriter on a SerialThread; board derived only while its sheet shows; remembered conversations do not invalidate the list (test `!invalidates`).
- [ ] Names and keys: SheetKind's "its overview" → "its board"; "operation" names for the Operator's row where not persisted (check `RowSelection` persistence first); retired keys `fixer`, `fixerIsOn`, `modelDefaults.grok` removed at launch beside Appearance's.
- [ ] Tests: the true duplicate, the review copies, `CheckoutFixture`/`RemoteFixture` onto `RaceFixture`, `RaceFixture.diverged`, the shim helper, file-local helpers for the seeded blocks, `AppControllerTests` split by owner, `test` prefixes.
- [ ] Plain `scripts/test.sh`: PASS. Commits per concern.

### Task 8: Views, UI kit, snapshots

**Files:** `app/Sources/AiTerm/Views/*` (not Operators/, OperatorBadge), `Views/Steps/*`, `app/Sources/AiTerm/Views/OperatorSettingsPane.swift` (`ModelFields` only), `app/Sources/AiTermUI/*` and its README, `app/Sources/AiTerm/Snapshots/*` (not OperatorSnapshots), view tests, `app/Tests/AiTermUITests/*`.

**Interfaces:** Produces `ModelReasoningFields` (Views/) used by Settings › Agents, the New Task agent step and Settings › Operator.

- [ ] Keyboard list: `KeyBindings.all` has no group help or action containing "overview". FAIL, ↩ reads "Go to the row’s window, fold or open a project or the broadcast’s group, or open an empty project’s menu", Sheets help ends "…New Broadcast and a broadcast’s board."; add the board's ⌘1–⌘3 and the Shelf's ⌘⌫ rows. PASS. `settings-interface-full.png` changes on purpose.
- [ ] Shelf host: a value function for the Shelf row's badges; GitLab-provider project with a github.com request URL shows GitHub and `#12`. FAIL, ArchiveRow draws `TaskBadges`, PASS.
- [ ] Decision 8: `ModelReasoningFields` with label prefix, missing-model label, disabled flag; reasoning fallback is the saved level if offered, else `defaultEffort`, else the first. Test that AgentStep shows the model's default effort when none is saved. FAIL, PASS. Images identical except where the fallback differs (name them).
- [ ] Dead: SymbolMark `.quiet`/`tint`/`style` (+README line 169), `SheetLayout(width:)`, `BannerFixPresentation.canDismiss`, one `canClose` rule, `TerminalRowAccessibility`'s `terminal`, `CheckFailureDetails(open:)`, `KeyboardSettingsPane.groups`, `StatusMark.spinnerRotation` into the test, `Destination.isShown`, hand-expanded `@State` storage private.
- [ ] Duplication: `Palette.rowHoverSolid = composited(rowHover)` only if every image stays byte-identical; SidebarSnapshots helpers; Shelf rows; `CheckChip`; ServiceCard fields; SheetLayout's two branches; `ColorProbe.hex` → `Icon.hexString`; the chevron; "macbook".
- [ ] Practice and performance: `.help(x ?? "")` for the conditional tooltips; TaskRowCaption's doc; stale comments in the audit list; PromptStep's placeholder in its own subview; Logos artwork cached by name.
- [ ] Tests: `chipsShowOnlyTheCLIAndTheDriver` (move its non-chip claim into HarnessMessagingTests), `settingsLeavesTheHarnessModelToTheAgentsPane`, fixed waits → `settle` with a condition, the duplicate and constant-only tests, `isReleasedWhenClosed` repeats, misplaced tests, `NewTerminalSheetGeometryTests` against `Sheet.fittingHeight`.
- [ ] UI README: add AddMenu, HeaderChevron, HeaderTitle, TaskRowMarkView, CheckFailureDetails, CommandPreview, SidebarBannerText, SidebarFooterHost, SelectedRowSidebarFooter, DecodeWordsView, OracleGroup, ModelReasoningFields; fix lines 88-90.
- [ ] Snapshots `cmp` against baseline: only the named images differ. Plain `scripts/test.sh`: PASS. Commits per concern.

### Task 9: Shared test support

**Files:** `app/Tests/AiTermTestSupport/*`, `app/Tests/AiTermUITests/TestSupport.swift`, `ColorProbe.swift`, the test files holding the copies.

**Interfaces:** Produces public `NSView.descendants<T>(_:) -> [T]`, `testWindow(hosting:size:)` in TestWindows, `ScratchFolder.make(_ prefix:) -> URL`, `keyDown(_:code:modifiers:in:)`; AiTermTests-local `HostedSidebar`.

- [ ] Replace the 11 `table(in:)` copies with `firstDescendant(NSTableView.self)`, the 4 `descendants(of:in:)` with the shared one, the sheet tests' key/command helpers, the SidebarView/PromptEditor/SettingsView/Input/SearchField hosting setups, the 8 local temp-folder helpers, `CountingGitRunner`, RedirectURLProtocol's store, BackpackControllerTests' hand-rolled waits, the UITests forwarding adapters.
- [ ] `PublicationGuardTests.theSliceIsFrozen` uses `ScratchDefaults.make()`; TestWindows registers its animation default instead of setting it; `disableWindowAnimations`/`ScratchHome.models` private.
- [ ] Plain `scripts/test.sh`: PASS. Commit.

### Task 10: Wire (after the Codex tab reports its daemon lane done)

**Files:** `daemon/aitermd/{operator_mcp,models,usage,delivery}.py`, `daemon/tests/` and `daemon/tests/wire/` as needed, `app/Sources/AiTermCore/Daemon/DaemonTypes.swift`, `app/Tests/AiTermCoreTests/{WireContractTests,Operators/OperatorTimingTests}.swift`.

- [ ] Drop `jira_edit`'s `key` from the schema; `run_status`'s description stops promising `lastCommit`/`summary`.
- [ ] Drop `Usage.plan` on both sides, regenerate the golden frames with the daemon's own script; keep `updatedAt` and `spend`.
- [ ] Drop `WAKE_COALESCE`, `RECONCILE_INTERVAL`, `STALL_AFTER`, `CHALLENGE_TIMEOUT`, `LAUNCH_ADOPT_AFTER` from `delivery.py`, its test line and the Swift test's tuple.
- [ ] `scripts/test.sh` (daemon and swift picked): PASS. Commit.

### Task 11: Scripts

**Files:** `scripts/*`, `scripts/fixtures/*`, `.gitignore`.

- [ ] Delete the toolchain guard's aggregate block and `TEST_SWIFT_TOOLCHAIN_SKIP_AGGREGATE`; route the unrouted scripts (`test-app-bundle.sh` → toolchain, the rest and `.claude/skills`, `.agents/*` → none) with two pinned cases; drop the `.superpowers/*` row and the two dead ignore lines; the lock fixture holds until a release file; one failure helper and one `changed_case` in the guard; one routes reader; Python ≥ 3.11 check before venv creation; missing-Swift message; snapshots.sh clears its folder and builds `--product AiTerm`; make-app copies only `__init__.py` and `delivery_check.py` from `daemon/tools`; the build-and-log block shared.
- [ ] `scripts/test.sh` (toolchain and selector guards): PASS; `scripts/test-app-bundle.sh` fixture case passes. Commit.

### Task 12: Docs, final verification, finish

**Files:** `docs/architecture.md`, `README.md`, `docs/keyboard.md`, `scripts/README.md`, `docs/sidebar.png` (removed), `docs/desktop.png` (only if the picture moved).

- [ ] architecture.md: one tool list of all 30 tools, mutating ones safe to repeat; the module table's row; the two missing-spec citations; "the modules below"; the Codex fixer line; the merge-left example. README.md picture note; `git rm docs/sidebar.png`; keyboard.md's ⌘F/⌘L in the Application table; scripts/README sections and bundle contents; snapshots.sh header.
- [ ] `scripts/test.sh all` (background): PASS (the wide-diff flake: rerun once, else report). `scripts/readme-picture.sh --check`: PASS, or redraw, look, commit.
- [ ] Whole-branch review (one reviewer, Opus); fix what it finds.
- [ ] superpowers:finishing-a-development-branch: keep the branch as it is.
- [ ] Fast-forward: if the main checkout is on `feat/refactor-broadcast`, clean, and the branch is where it was last merged in, `git -C <main checkout> merge --ff-only <head>`; else change nothing and report.

## Daemon lane (Codex tab; owns daemon/ and hooks/; stages only those)

Gate each commit with `scripts/test.sh daemon`. Leave Task 10's items alone.

- Functional, test-first: a prompt typed after Claude's `/clear` is credited to the person (reset `_prompted` only when AiTerm may have launched a prompt); a revoked token never comes back when unlinking fails; `_prompted` forgotten with the session; `_pasted` stamped after `send_text` returns; a relative or empty `claudeConfigDirectory` is `bad_params`; decision 7, a paste interrupted mid-send is `partial` with the input marked unsent.
- Performance: `pid_for_session` looks up its index and rescans only on a miss or stale stamp (counting test); one Codex listing per tick.
- Dead: `daemon.json` (test waits for the socket), `request_cookie`'s AppKit branch, the `codex_files is None` paths, `SessionResolver.resolve`, the hook handlers' dict-or-None types, `FakeIterm.closed`.
- Duplication: shared JSON-RPC helpers for the three MCP servers (each route keeps its bad-JSON answer; the stub wraps lists as `/operator` does), one whitespace-insensitive matcher, one trust-prompt constant, `_nonempty_string`, Bearer parsing, the three activate/frame handlers.
- Practice: await `open -a iTerm`, guard disconnect callbacks, `_reply` for any status, cache the policy file by stamp, no rescan per unknown token, typing nits, tests stop mutating `HARNESS_BY_AGENT`.
- Comments: hook_router telemetry note, hooks_server docstring, windows.py call count.
- Tests: claude_tab and Codex helpers in test_service; one RPC and one HTTP client in conftest; FRAME and write_token in conftest; test_delivery_check scaffolding; test_operator_surface's six unit repeats; test_operator_finish_task into test_operator_mcp; the listed overlaps; delete test_hook_router's Grok test and generalise test_hooks_server's to unknown agents; fold the "grok" policy key into the unknown-key test; the wire contract test uses a Claude tab.
