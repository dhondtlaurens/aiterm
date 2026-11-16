# 0c. Tests build tasks, projects and tabs through the shared builders

Implementer: Codex `gpt-6.1-sol` at high effort. Depends on: 0a, 0b. Findings: TS F6.

## Why

Later phases change the workspace models: fields go from `TaskItem` (phases 1d, 4e, 5b), the wire
loses `title` and other `SessionInfo` fields (1g, 6a). Today about 220 test lines call the
`TaskItem`, `Project` and `SessionInfo` initialisers directly, and about thirty local helpers copy
what the shared builders already do, so each model change edits dozens of files. The shared
builders in `app/Tests/AiTermTestSupport/Builders.swift` exist for exactly this; newer tests use
them, older ones never moved. After this step a model change edits one builder. The step is
mechanical: no assertion changes and no behaviour changes. A right change passes the same values
the old call passed. A wrong one changes a value a test reads, or rewrites a test whose subject is
the initialiser or decoding itself.

## Today

- `Builders.swift` has `Project.make(id:name:path:provider:remoteUrl:addedAt:collapsed:jiraProjects:)`,
  `TaskItem.make(id:project:title:branch:worktreePath:baseBranch:jira:kind:agent:model:reasoning:firstPrompt:createdAt:windowId:)`
  and `SessionInfo.make(_:window:tabIndex:task:agent:state:cwd:conversation:tabKey:active:)`, plus
  `Build.epoch` and `Build.agents`. Its header comment names `OperatedTask`, `OperatorRun`,
  `OperatorUIFixtures` and `OperatedWorld`, none of which exist; `Build.agents`' comment speaks of
  "a broadcast".
- What the builders lack, judged by what direct calls pass: `TaskItem.make` has no `mr`,
  `appendTicket` (12 calls pass true) or `conversations`; `SessionInfo.make` has no `projectId`
  (about 10 calls pass one), `model` (4 pass one) or `title` (8 pass a non-empty one), and takes the
  task as a `UUID` where the initialiser takes `taskId` as a string.
- Direct calls outside `Builders.swift` (re-run; counts drift):
  - `grep -rnF 'TaskItem(id:' app/Tests | grep -v AiTermTestSupport/Builders.swift`: about 75 in
    36 files, most in `AppControllerTests` (14), `ModelsTests` (10), `SidebarModelTests` (7).
  - `grep -rnF 'Project(id:' app/Tests | grep -v AiTermTestSupport/Builders.swift`: about 117 in
    45 files, most in `AppControllerTests` (20), `SidebarModelTests` (17), `ModelsTests` (8).
  - `grep -rnF 'SessionInfo(sessionId:' app/Tests | grep -v AiTermTestSupport/Builders.swift`:
    about 26 in 12 files, 13 of them in `AppControllerTests`.
- Local builders returning these types:
  `grep -rnE "func [a-zA-Z]+\([^)]*\)( throws)? -> (TaskItem|Project|SessionInfo)\b" app/Tests | grep -v AiTermTestSupport`
  lists about 38, for example `CheckoutMonitorTests.task(_:)`, `DockBadgeTests.task(windowId:)` and
  `session(_:window:taskId:state:)`, `WindowPlanTests` and `WindowReconciliationTests`
  (`task(window:)`, `tab(_:window:task:)`), `TaskConversationsTests`, `SessionContextsTests.tab`,
  `ArchiveStateTests.task`, `StallGuardedGitTests`, `GitSpawnCountTests.task`,
  `DiffStatResolverTests` (local `task`), `SidebarModelTests` (`item`, `tab`, two `project`),
  `ModelsTests.project` and its local `item`, `TaskWorkflowTests` (local `row`),
  `SidebarInteractionTests`, `AlertPromptTests`, `RowAccessibilityTests`, `FileMenuTests`,
  `ReviewThreadsWatcherTests`, `ProjectJiraBadgeTests`, `SidebarProjectionTests.tab`,
  `SignalSidebarPresentTests.tab`, `AppControllerTests` (a local `session`).
- `docs/testing.md` (about lines 65 to 67) says new tests use the builders "and older tests still
  call the initialisers directly".

## Change

1. Extend the builders, each new parameter defaulting to what the initialiser does today:
   `TaskItem.make` gains `mr` (nil), `appendTicket` (false) and `conversations` (empty);
   `SessionInfo.make` gains `project` (a `UUID?`, nil, written as the session's `projectId` string),
   `model` (nil) and `title` (empty). Keep parameter order natural: new ones after the closest
   existing neighbour. Rewrite the file's header comment to say what it is now: the one place tests
   build `Project`, `TaskItem` and `SessionInfo`, so a new field gets its default here. Rewrite
   `Build.agents`' comment to "Agents rows: Claude on Opus, Codex on Astra."
2. Replace every direct call outside the exceptions below with the builder, passing exactly the
   values the old call passed, except those equal to the builder's default. Where a test passed a
   `taskId` string built from a UUID, pass the UUID; where it passed any other string, build with
   `.make` and set `taskId` on the value afterwards.
3. Local helpers: replace each helper's body with a builder call. Then delete the helper and call
   the builder at its call sites when it has one or two callers or fixes nothing beyond the
   builder's defaults. Keep it as a thin wrapper when it fixes several suite-specific values for
   many callers (a suite's own fixture family, which the builders' comment allows).
   `OperatorServiceFixtures.project` and `.session` already wrap the builders: leave them.
4. In `docs/testing.md`, replace "new tests use them, and older tests still call the initialisers
   directly" with: tests build those values through them; only tests of the initialisers or of
   decoding call the initialisers directly.

## Keep

- Exceptions that keep their direct calls, because the initialiser or the decoding is their
  subject: in `ModelsTests`, `anUnknownTaskKindReadsAsATaskAndIsWrittenBackAsSaved`,
  `testAppStateRoundTripsThroughJSON`, `testATaskForAnUnknownAgentLoadsAndKeepsItsSavedName`,
  `testProjectWritesOnlyItsJiraProjectList`, `testTaskItemRoundTripsAReview` and
  `aTaskWithEveryFieldSetRoundTripsWhole`. Any other test whose assertion is about the encoded
  bytes or the decoding of that same model joins this list; name each one in your report.
- Find a Fix test files, which step 1i deletes whole: `AiTermCoreTests/FixPipelineTests.swift`,
  `FixLiveTests.swift`, `FixLandingTests.swift`, `AiTermCoreTests/Support/FixPipelineFake.swift`,
  `AiTermTests/ReviewFixTests.swift`, `BannerFixTests.swift`. Leave them as they are.
- Raw temporary folders (`temporaryDirectory`, `NSTemporaryDirectory`) stay as they are.
- Every `#expect`, `#require` and expected value stays. The builders' existing defaults stay.

## Decisions already taken

- A direct call that sits inside an `#expect` (an expected value built inline) is converted like
  any other; the expectation line changes only in that call.
- Dates: a call that passed `Date(timeIntervalSince1970: 0)` for `addedAt` or `createdAt` passes
  nothing (the builder's default is the same epoch). Any other date is passed.
- A test that builds a value field by field on purpose, mutating after `.make`, may stay that way.
- A local helper with a name that hides what it sets (`task(window:)`) keeps its name if it stays.
- `AppControllerTests` is large: convert it in place, no file splits or reordering.
- If a conversion makes a test fail, the old call passed a value you dropped: restore it. Never
  change the expectation.

## Tests

No test is added or deleted. Every test touched keeps its name and its assertions.

## Proof

- While iterating: `scripts/test.sh swift -- --filter <Suite>` for each suite you converted.
- `git diff app/Tests | grep -E '^[-+][^-+].*(#expect|#require)'` shows only lines whose inline
  initialiser became a builder call.
- Plain `scripts/test.sh` before reporting (a change under `AiTermTestSupport` runs all three
  Swift targets).

## Done when

- `grep -rnF 'TaskItem(id:' app/Tests`, `grep -rnF 'Project(id:' app/Tests` and
  `grep -rnF 'SessionInfo(sessionId:' app/Tests` find only `Builders.swift`, the `ModelsTests`
  exceptions above (and any you added and named) and the six Find a Fix files.
- The local-builder grep above lists only helpers kept as thin wrappers, each with several callers.
- `docs/testing.md` no longer says older tests call the initialisers.
- Plain `scripts/test.sh` is green.

## Not in this step

- Deleting the Find a Fix tests (1i) and changing model fields (1d, 1g, 4e, 5b, 6a).
- Moving raw temporary folders onto `ScratchFolder`.
- Joining lifecycle tests through one settled join (4a).
