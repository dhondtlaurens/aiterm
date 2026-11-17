# Greenfield refactor: one owner per concept, no leftovers, no compatibility

Status: plan agreed on 2026-11-16. Each to-do has its own brief in
[`2026-11-16-greenfield-refactor/`](2026-11-16-greenfield-refactor/README.md): the implementing agent
for a step gets that folder's `README.md` and the step's brief, nothing else. Challenged by Codex
(see Review record). Research it adopts: `docs/research/2026-11-16-greenfield-audit/`
(eleven lane audits with file and line evidence, the audit brief, and the decisions taken while
planning). `docs/research/` is ignored by git, so the audits are in this worktree only. Where an
audit and this plan disagree, this plan wins: the audits were written before the decisions below.

## Goal

AiTerm and its Operator went through many phases in six weeks: broadcasts, a board, a finisher,
then signals, then four patches on top. The code still carries all of them. This plan works out
what the product is for, pictures how it would be built today knowing the end state, and moves the
code there: delete what earlier phases left behind, delete handling for cases that do not happen
here, give each concept one owner, and fix the flows that only make sense because of how the code
grew. The golden rule is to streamline: flows should feel native, natural and logical. It ships as
a major release.

What the product is for:

- A calm native sidebar that makes many coding agents across many repositories manageable. One task
  is one branch, one worktree, one real iTerm2 window and its conversations. iTerm2 stays the
  terminal and keeps running when AiTerm quits.
- The Operator is automation over those same tasks. A signal watches Jira, GitLab or GitHub; each
  matching item starts or continues exactly one task as a stage with a prompt, a done condition and
  a Then. One Operator chat is woken only for judgment, the Oracle gives second opinions, and
  questions for the person arrive in that chat. Trust, not gates.

## Approach

Eleven read-only audits each read one lane completely against a written greenfield picture and
applied "real, then likely" to every guard, fallback and finding: can it really happen in this app,
on one person's Mac, and would it plausibly happen? The planner re-checked the main claims in the
code (callers counted, the window plan read, the gate's refusal texts compared with the served tool
schema). The work is ordered so that deletion comes first and every later phase restructures a
smaller codebase.

The greenfield picture the code moves to:

1. One workspace model and one set of task lifecycle operations (create, open, restore, archive,
   remove, take over), used the same way by a click and by the Operator.
2. The Operator as pure decisions with thin effect owners, one tick, one saved record per task,
   one vocabulary: signal, item, task, stage, worker, Operator, Oracle.
3. One tool surface with one idempotency rule.
4. One Oracle mechanism behind every use.
5. Status derived once in the daemon and projected once for the sidebar.
6. One stepped-sheet frame; one heading module.
7. One code host interface with two adapters; Jira beside it.
8. Code that handles what really happens here and nothing else.

### Decided while planning

- **No compatibility and no fallbacks** (maintainer, 2026-11-16: "we will do a major release so you
  can break things and I don't want compatibility or fallback mechanisms"). No migration, no dual
  decoding, no reader for an older install, helper or driver. The saved state, the app/daemon wire
  and the Operator's contracts (tool replies, `run_status`, gate and Oracle wording) may change
  where that simplifies the code. A changed frozen fixture is re-recorded on purpose in the same
  commit, with a line in its `PROVENANCE.md`.
- **What an upgrade keeps.** Only the Operator's saved records change shape: `operatorSession` and
  each task's `signalTask`. The release notes' reset command clears exactly those. Projects, tasks,
  terminals, the archive, conversations, signal configurations and seen items still load from a
  workspace saved by today's build: no step renames or restructures a saved key outside those two
  records.
- **Switching builds while this is under way.** The installed app and development builds share one
  `state.json`, and one unreadable Operator record fails the whole load. So the reset command exists
  from phase 0 as `scripts/reset-operator-state.sh`; it clears the Operator's records only, and both
  builds load what is left. When to run it, with AiTerm quit:
  - Phases 1 to 3 keep the saved text of both records (a Swift name may change, its saved key and
    raw value stay), so a build of this branch opens a workspace the installed app wrote. Going
    back to the installed app needs the reset, because this branch stops writing keys the installed
    app expects.
  - From step 4e on, neither build reads the other's records: run it before switching either way.
  The release notes carry the same command.
- **One exception, kept on purpose:** the workspace file tolerates what it does not know
  (`PreservedFields`, `.unknown` enum cases, lenient raw decoding). Dev builds and the installed app
  share one `state.json`; without it, going back to the installed app can fail to load.
- **Closed view.** Closing a window asks nothing. The row stays and draws as a row without a window
  does today (no agent marks, no status mark, its own branch). Choosing the row opens its window
  with its conversations resumed. Nothing reopens by itself, also not after iTerm2 restarts. The
  same rule holds for tasks, driven tasks, terminals and the Operator chat; the Operator still
  reopens a worker's or its own window when it has to type into it.
- **Find a Fix is removed**, with its Settings switch ("Help with problems") and its README line.
- **Settings stays a sheet** with Save and Cancel; only dead staging paths go.
- **The broadcast eval baseline goes**, with the two unread `operator-current` fixture folders, the
  retired-keys test, its fixture and the `retired:` key lists. The opt-in eval keeps the current
  contract only.
- **Left as chosen earlier:** the mutual fold of the Operator and Projects sections; ⌘S, ⌘A, ⌘P.
- **Delivery:** nine phases after a safety net, each merged to `main` on its own after
  `scripts/test.sh all`. No release until the last one. After phase 2, the daemon (6) and hosts (7)
  can run in worktrees of their own beside the app track (3, 4, 5, 8); the machine-wide test queue
  makes three tracks the useful ceiling.
- **Who builds what** (maintainer's instruction): steps marked **Codex** are straightforward and go
  to Codex `gpt-6.1-sol` at high effort; steps marked **Opus** are difficult (cross-owner,
  concurrency, lifecycle or contract judgment) and go to Opus 5.5 at high effort. The implementing
  session orchestrates, reads each diff and runs the gate; it writes no product code itself.

### Standing rules for every step

- Re-read the step's evidence in the audit before changing anything: `main` moves and line numbers
  drift. A finding that no longer holds is dropped and noted under **Record**.
- Real, then likely, for every edge case met while building. Do not add a guard, fallback, retry or
  compatibility path that fails either test. Do not add compatibility for anything this plan removes.
- No reducer framework, event store, plugin architecture, protocol per class, generic job engine or
  line-count target.
- A deleted test names the surviving test that detects the same failure, unless the behaviour it
  tested is deleted by the same step.
- Visual values come from `app/Sources/AiTermUI/README.md`. Only the visible changes listed below
  change what a person sees; every other structural view change renders the same pixels.
- `scripts/test.sh` before each commit, `scripts/test.sh all` before a phase merges, both started
  in the background. Never `scripts/run-dev.sh`, the compat capture or the live eval: those are the
  maintainer's.
- One commit per to-do, in the project's commit style.

### Visible changes, agreed 2026-11-16

| Change | Today |
| --- | --- |
| Closing a task's window keeps the row without a window; choosing it reopens it | A Remove/Archive/Cancel question a second later; eager restore |
| Closing a terminal's window keeps its row; choosing it opens a fresh shell | The row is removed |
| After iTerm2 restarts, windows open per row when chosen | Every window is reopened and every conversation resumed |
| Remove asks everything before it acts, including about an unmerged branch; with no helper it refuses as Archive does | It can delete the worktree and then park the row for a second answer |
| Take Over makes the task fully the person's: an ordinary task, restored and removed like one; its resumed conversations carry no worker branch guard | A third kind of task that no owner restores |
| Stepped sheets show Cancel on every step; Escape closes an open list, then cancels | Cancel only on step 1; Escape goes back |
| The iTerm2 banner says what you can act on: iTerm2 isn't running (Open iTerm2), iTerm2 refused AiTerm, AiTerm isn't connected to iTerm2 (Open Settings), or the helper isn't working | "Reconnecting to iTerm2…" forever after a quit; "Waiting for iTerm2…" with nothing to do |
| New Signal shows agent readiness as advice for the signal's own agent rows and never disables Create for it | Every installed agent is checked; Create is silently disabled; Switch On skips the check |
| An Oracle check whose settings changed mid-way is discarded and run again, for every use | Five different outcomes; a worker's question goes to the person |
| Return on an empty heading runs its main command: New Task… for a project, Edit Signal… for a signal | A project opens its menu through a synthesized right-click; a signal does nothing |
| "Pull <branch>" names the default branch asked from git when the project's heading appears and after each pull; Edit Project's header shows it a moment after the sheet opens | From a two-second poll per project |
| Pause and Resume live on the Operator heading's menu with one wording | Two places, two wordings, one inside a "+" menu |
| "Switch On" loses "(starts n)" unless the Operator already holds the count | A sidebar heading polls the source to compute it |
| The amber "isn't installed" note on the agent step shows only when no agent can run, once | PI is named on every New Task and New Review |
| The selection follows its row: a vanished Operator row is deselected, a row hidden by a fold hands the selection to its heading | The hidden row stays selected and ⌘⌫ acts on it |
| Return commits one-field sheets (Rename, Add Divider, New Terminal) | Only ⌘Return |
| Add Project shows the chosen folder as a line with Choose… | Asks for the folder twice and validates a typed path |
| New Task's Base branch is the filtered field New Review uses | A pop-up of every branch |
| One wording for a saved model that is no longer offered; a signal agent row says why Continue is disabled | Three wordings; silent disable |
| Workers may run `git merge` locally | Refused, though the push guard already protects the branches that matter |
| The Operator's shell gate names tools that exist | Points at five removed tools |
| Upgrading: quit AiTerm, run the release notes' reset command once (it clears the Operator's saved records and keeps projects, tasks, the archive and conversations), no agent needs Repair unless its card says so | n/a |

## Files

Paths are under `app/Sources/` unless they start with `app/Tests/`, `daemon/`, `hooks/`, `compat/`,
`scripts/` or `docs/`. The audits name the lines.

| Phase | Files | Create, modify or delete, and why |
| --- | --- | --- |
| 0 | `app/Tests/AiTermTests/Operators/` (one new journey suite), `app/Tests/AiTermTestSupport/Builders.swift`, test files that build `TaskItem`, `Project`, `SessionInfo` by hand | create the signal journey; modify tests onto the shared builders |
| 1 | `app/Tests/**/Fixtures/operator-current/`, `operator-records/`, `operator-saved-format/`, `daemon/tests/fixtures/operator-current-tools.json`, `SignalRetiredKeysTests`, `SignalOperatorEvalTests`, `AGENTS.md`, `docs/testing.md` | delete the baseline, orphans and retired keys; modify the eval and docs |
| 1 | `AiTermCore/GitHub/`, `GitLab/`, `Jira/` (`JiraWrites`, `JiraAgile` deleted), `CodeHosts/`, `CodeHost.swift`, `HTTPJSON.swift`, `AiTerm/Operators/OperatorPorts.swift`, their tests and `FakeMergeHost` | delete the write surface nothing calls |
| 1 | `AiTermCore/Git/Repository+Publish.swift`, `LocalMerge.swift`, `CommitId.swift`, `GitRunner.swift`, `BranchDrift.swift`, `BackgroundWork.swift`, `WorkMeter.swift`, `LoginShellLocator.swift`, `OptionalString.swift`, `WorktreeError.swift` | delete; three live helpers move beside the worker guard |
| 1 | `AiTermCore/Operators/` top level (`ChallengeLaunch`, `DiffDigest`, `WorkerTurn`, `AgentDelivery`, `OperatedBranch`, `TaskKeyReference`, `StallWatch`, `OperatorTiming`, `OperatorModels`, `SavedDefaults`, `ModelChoice`, `ActivityLog`, `WorkerTabs`), `Operators/Signals/ItemRef.swift`, `SignalSeen.swift`, `Sidebar/OperatorLine.swift` | delete dead members and files |
| 1 | `AiTerm/Operators/` (`OperatorPorts`, `WorkerTranscript`, `ToolCall`, `SecondOpinionRunner`, `ThenRunner`, `SignalPoller`, `ItemRouter`), `AppController.swift`, `SheetCoordinator.swift`, `SheetKind.swift`, `ProjectActions.swift`, `ArchiveSheetModel.swift`, `AiTermCore/Tasks/ArchiveSearch.swift`, `AppState+Archive.swift`, `TaskCreator.swift`, `Sidebar/SidebarModel.swift`, `Interface/DockBadge.swift`, `Views/SearchPicker.swift`, `ChipsPicker.swift`, `SheetChrome.swift`, `DestinationLine.swift`, `PromptEditor.swift`, `NameSheet.swift`, `ArchiveSheet.swift`, `SidebarRows.swift`, `OperatorBadge.swift`, `CreationModel.swift` | delete residue; `ShelfRow` becomes `ArchiveSearch.Entry` |
| 1 | `daemon/aitermd/slash_commands.py` (deleted), `models.py`, `sessions.py`, `status.py`, `hook_router.py`, `hook_events.py`, `corroboration.py`, `service.py`, `delivery.py`, `operator_mcp.py`, `operator_token.py` (folded), `codex_sessions.py`, `daemon/tests/codex_reference.py` (deleted), `daemon/tests/fixtures/wake-lines.json` (deleted), `daemon/tests/wire/`, `AiTermCore/Daemon/` | delete facts and requests nobody reads; re-record wire frames |
| 1 | `AiTermCore/Models.swift`, `Keychain.swift`, `AiTermPaths.swift`, `Hooks/StatusLineOriginal.swift`, `Harnesses/ClaudeSettings.swift`, `Backpack/BackpackSettings.swift`, `Daemon/DaemonTypes.swift`, `DaemonClient.swift`, `Operators/Signals/TaskItem+AgentChoice.swift`, `OperatorSession.swift`, `CodeHosts/ReviewThreadsReader.swift`, `Jira/JiraClient.swift`, `AiTerm/AiTermApp.swift`, `AgentIntegrations.swift` | delete every old-format reader and migration |
| 1 | `AiTermCore/Fix/` (deleted; `AgentProcess`, `RegularFile` move), `AiTerm/FixSession.swift`, `Views/FixViews.swift`, `Notices.swift`, `CreationModel.swift`, `ReviewCreationModel.swift`, `Interface/OperationIssue.swift`, `Views/HarnessSettingsPane.swift`, `README.md`, `docs/configuration.md`, their tests | delete Find a Fix |
| 1 | `AiTermCore/Operators/OperatorCommand.swift` + `Signals/SignalOperatorCommand*.swift` (one `OperatorLaunch`), `SignalOperatorTool.swift`, `OperatorModels.swift` (`OracleRound`), `ShellGate+Denials.swift`, `ChallengeLaunch.swift`, `AiTerm/Operators/SecondOpinionRunner.swift`, `AiTermCore/Daemon/` and `daemon/aitermd/operator_mcp.py` (`runId`), comments across the tree | modify to one vocabulary |
| 2 | `AiTermCore/Git/` (`WatchedFileCache`, `RepositoryProbe`, `DiffStatResolver`, `BranchResolver`, `DefaultBranchResolver` deleted, `Repository+DefaultBranch`), `AiTerm/CheckoutMonitor.swift`, `TaskRemover.swift`, `AppPorts.swift`, `Workspace/WorkspaceScan.swift` | delete speculative git and checkout handling |
| 2 | `Hooks/TOMLStatements.swift`, `CodexHookConfig.swift`, `Harnesses/ModelFiles.swift` | modify to a smaller Codex config editor |
| 2 | `daemon/aitermd/codex_sessions.py`, `status.py`, `iterm_bridge.py`, `resolver.py`, `claude_sessions.py` | modify: one rollout cursor, no quiet window, no batched fallback |
| 2 | `AiTerm/Operators/SignalOperatorController.swift`, `SignalWorkerIO.swift`, `SignalHostIO.swift`, `AiTermCore/Operators/WorkerGuard/`, `ShellGate+Denials.swift`, `ReviewCreationModel.swift`, `OperatorProfileStore.swift`, `StateStore.swift`, `Backpack/`, `Updates/ReleaseFeed.swift`, budget tests | delete repair paths and speculative guards |
| 3 | `AiTerm/WindowReconciler.swift`, `RowFocus.swift`, `TaskLauncher.swift`, `LiveSessions.swift`, `PerRow.swift`, `AppPorts.swift`, `AiTermCore/Daemon/ClosedWindowTriage.swift` (deleted), `AppState+WindowPlan.swift`, `ItermConnection.swift`, `Sidebar/OperatorRow.swift` (deleted), `Views/SidebarView.swift`, `ItermSettingsCard.swift`, `docs/windows.md`, `docs/keyboard.md`, window tests | modify to the closed view and one window owner |
| 4 | `AiTerm/TaskRemover.swift`, `TaskArchiver.swift`, `WorktreeTeardown.swift` (one teardown), `TaskLauncher.swift`, `Prompter.swift`, `Notices.swift`, `AiTermCore/Tasks/TaskRemoval.swift`, `TaskWorkflow.swift`, `Interface/OperationIssue.swift`, `AiTerm/Operators/StageRunner.swift`, `SignalWorkerIO.swift`, `ThenRunner.swift`, `SidebarProjection.swift`, lifecycle tests | modify to one lifecycle |
| 5 | `AiTerm/Operators/` (all owners; new small owners for waking, the chat and the Oracle), `AiTermCore/Operators/Signals/` (regrouped to about fourteen files), `ChallengeLaunch.swift` (becomes the Oracle's Core home), `Sidebar/OperatorLine*.swift`, `AiTerm/SignalSidebar.swift`, `operator-signals/` fixtures | modify; fixtures re-recorded |
| 6 | `daemon/aitermd/` (telemetry regrouped by agent), `models.py`, `status.py`, `corroboration.py`, `resolver.py`, `service.py`, `sessions.py`, `AiTermCore/Daemon/` (`DaemonSupervisor`, `DaemonCommands`, `DaemonClient`, `DaemonTypes`), `AiTerm/DaemonConnection.swift`, `Sidebar/SidebarModel.swift`, `daemon/tests/wire/`, `docs/daemon-protocol.md`, `scripts/run-dev.sh` | modify the wire and the helper's ownership |
| 7 | `AiTermCore/CodeHosts/`, `GitHub/`, `GitLab/`, `Jira/`, `Signals/Sources/SignalHostReading.swift`, `AiTerm/Operators/SignalHostIO.swift`, `RequestWatch.swift`, `ReviewThreadsWatcher.swift` | modify to one interface and one status read |
| 8 | `AiTerm/SidebarProjection.swift`, `SignalSidebar.swift`, `SignalHeadingValue.swift`, `Views/SidebarRows.swift`, `SidebarView.swift`, `Views/Operators/SignalRows.swift`, `RowMenuAnchor.swift` (deleted), `Views/CreationSheet.swift`, `SheetChrome.swift`, `SteppedSheetFrame.swift`, `Views/Operators/SignalSheet.swift`, `NameSheet.swift`, `ProjectSheet.swift`, `NewTaskSheet.swift`, `ModelReasoningFields.swift`, `Steps/AgentStep.swift`, `Operators/SignalReadiness.swift`, `SignalModel.swift`, `DebouncedSearch.swift`, `SettingsView.swift`, `OperatorSettingsModel.swift`, `AiTermCore/Harnesses/Harness*.swift`, `Agents/HeadlessRun.swift` | modify the sidebar, sheets and agent table |
| 9 | `docs/architecture.md`, `operators.md`, `windows.md`, `status-model.md`, `daemon-protocol.md`, `configuration.md`, `keyboard.md`, `testing.md`, `README.md`, `daemon/README.md`, `scripts/README.md`, `app/Sources/AiTermUI/README.md`, `docs/release-notes/`, `docs/workflow/release.md` | modify the docs to the code; create the release notes |

## Proof

- **Gate:** `scripts/test.sh` before each commit and `scripts/test.sh all` before each phase merges,
  plain, with no override. A red gate is fixed in the step that broke it.
- **Journey net:** phase 0 adds one signal journey (a source read yields an item, a task starts, its
  worker ends, the done condition holds, Then archives). It and the existing journeys (create task
  to window, archive and restore, daemon reconnect, the wire contract) must pass after every phase.
  The close-window journeys are replaced in phase 3 by: a tagged window is adopted, a closed window
  leaves its row, choosing a row without a window opens it once, a failed open is reported on the
  click.
- **Deleted tests:** each step lists, in its commit body, the tests it deleted and either the
  surviving test for the same failure or the deleted behaviour.
- **Fixtures re-recorded on purpose:** `operator-signals/state.json` (phases 1, 4, 5),
  `operator-signals/brief.md` and `tools.json` only if a tool or the brief changes,
  `daemon/tests/wire/` (phases 1, 6), `compat/launch.json` and `compat/drivers/` (phase 1). Each
  with a provenance line saying which step changed it and why.
- **Budgets:** `reconcilerPass == 0`, the archive rank, the daemon's steady-tick ceilings and the
  status frame limit stay. Git-spawn counts become ceilings recorded at the new baseline. The
  files-written-per-save budget returns to 2 in phase 2, on purpose.
- **Visual:** phase 0 captures `scripts/snapshots.sh build/refactor-before`. Each step that changes
  or restructures a view captures again and the agent reads the PNGs against the UI README: equal
  pixels for structural steps, the listed change and nothing else for the visible ones.
- **Bundle:** `scripts/make-app.sh` then `scripts/test-app-bundle.sh build/AiTerm.app` at the end
  of phases 1, 2, 6 and 9 (resources and hooks change there).
- **The maintainer's, by hand, because they open windows or spend quota:**
  `scripts/compat-check.sh` after phases 1 and 2 (the Claude driver loses a hook, the Codex config
  editor changes); the Operator eval (`AITERM_LIVE_OPERATOR=1`) after phases 1 and 5 (gate wording,
  Oracle prompts, `run_status`); one smoke run through `scripts/run-dev.sh` after phase 9: create a
  task, close its window, choose the row, archive, restore, remove; a signal from match to done.
- **Upgrade rehearsal:** phase 0 keeps a copy of today's `operator-signals/state.json` under
  `build/refactor-before/`. The close-out runs the reset script on that copy and
  loads the result through the final `StateStore`: projects, tasks, the archive and conversations
  are all there, no Operator record is. The fixture holds no taken-over task, so the rehearsal
  also runs on a second copy in which one driven task is marked taken over, and checks that the
  task carries the mark afterwards and that a matching item does not continue it. The result goes in Record; no test is kept for it.
- **Adversarial review:** this plan before implementation; each phase's change before it merges
  (`psg:review`); the whole from phase 0 to the close-out at the end.

## To-dos

Audit references are `<lane> F<n>`: RT operator-runtime, OC operator-core, WD windows-daemon-link,
TL task-lifecycle, SS sheets-settings, SB sidebar-ui, DM daemon, CG core-git, HO hosts, PL platform,
TS tests-scripts.

### Phase 0. Safety net (no product change)

- [x] 0a. **Opus.** Full gate green on the starting commit; capture `build/refactor-before`
  snapshots and keep a copy of today's `operator-signals/state.json` there for the upgrade
  rehearsal; note all three under Record.
- [x] 0b. **Opus.** One signal journey test through `SignalWorld`: stub source returns an item, a
  task starts, the worker's turn ends, the done condition holds, Then archives (TS section 4).
- [x] 0c. **Codex.** Tests build `TaskItem`, `Project` and `SessionInfo` through the shared
  builders; local copies of those builders go (TS F6). No assertion changes.

- [x] 0d. **Codex.** `scripts/reset-operator-state.sh`: the reset command as a script. With AiTerm
  quit, it copies `state.json` to a dated file beside it, sets a task's `takenOver` mark where its
  signal record says it was taken over, then removes `operatorSession` and every task's and
  archived task's `signalTask`, using only what macOS ships. A guard script under `scripts/` runs
  it on scratch files.

### Phase 1. Delete what nothing calls (after 0)

- [x] 1a. **Codex.** The broadcast eval baseline, the two unread `operator-current` folders,
  `operator-records`, the retired-keys test, `operator-saved-format` and the `retired:` key lists;
  the eval keeps the current contract; `AGENTS.md`, `docs/testing.md`, `daemon/README.md`,
  `scripts/test-routes.tsv` and the provenance notes follow. The suite's `operatorOpen` test moves
  to the saved-format suite.
- [x] 1b. **Codex.** The code-host and Jira write surface and everything only it uses: the request
  writes, thread replies, pipeline retry, user lookup, `JiraWrites`, `JiraAgile`, the confined
  search, the "outcome unknown" and "not sent" failures, `OperatorPorts.publisher`, `FakeMergeHost`,
  the dead thread prompt (HO F1, TS F1). `merge` stays as the one host write.
- [x] 1c. **Codex.** The push and publish stack, `LocalMerge`, `BranchDrift`, `BackgroundWork.within`,
  the `CommitId` wrapper (its one rule moves beside the worker guard with `sameLocation`,
  `shortBranch` and `folded`), `pushReason`, `saidAsWritten`, `LoginShellLocator.refresh`, the dead
  error case and the six unnoted `WorkMeter` cases (CG F1 to F3).
- [x] 1d. **Codex.** Core Operator leftovers: the dead Oracle prompts, `DiffDigest`, the acceptance
  half of `WorkerTurn`, the `AgentDelivery` struct, `OperatedBranch`, `TaskKeyReference`,
  `StallWatch` (its one live rule moves into the transcript reader), unread `OperatorTiming`
  constants, dead `OperatorModels`, `OperatorLine`, `WorkerTabs` and `ActivityLog` members, the
  never-produced branch item and `baseline` seen state, the dead saved fields (`peopleReview`,
  `ExtraTab` role and launch fields, unused round fields) and `SavedDefaults` (OC F1, F3, F8).
  `operator-signals/state.json` is re-recorded.
- [x] 1e. **Codex.** Operator runtime leftovers: dead `OperatorPorts` fields, the transcript
  open-call reader, locator test hooks, `markOutcome`, members only tests call (RT F6).
- [x] 1f. **Codex.** App leftovers: `ShelfRow` becomes `ArchiveSearch.Entry` and Shelf becomes
  Archive in code names; dead controller and coordinator members and empty comment stubs; the
  `queued` row state and its plumbing; the unread project hand-off counts; the test-only attention
  and Dock badge path (its live cases move to the projection's); dead pickers, the command preview,
  the segmented agent picker, the broadcast step config, the disabled prompt editor, subtitles that
  never draw; the branch type and name halves of `TaskDraft` (TL F4, SB F1, F2, SS F4, F7, F8, TS F2).
- [x] 1g. **Codex.** Daemon leftovers: slash-command tracking, live model and effort attribution
  and the `PostModelSwitch` hook, `subagentsWrittenAt`, `title` on the wire, the `session.prompt`
  and `session.dismissStartup` requests, the prose wake rule and its fixture, `operator_token.py`
  folded, the test-only `settle_reads` seams, the Codex reader's test-only methods and the copied
  reference parser (DM F1, F7, F8, part of F3; WD F5 dead requests). Wire frames and driver
  fixtures are re-recorded.
- [x] 1h. **Codex.** Every old-format reader and migration: Keychain per-key items, the support
  folder rename, the legacy status-line record, retired hook and push-key cleanup, the pre-0.15
  workspace decoders (single Jira project, flat project list, unnamed terminals), the earlier
  choice-block upgrade, old-helper decoding forms and
  defaults on the wire, the old GitLab URL form, Jira's paging fallbacks (CG F8, TL F7, PL F3,
  OC F15, WD F4 decoding paths only, HO F5 items 1 and 2).
- [x] 1i. **Codex.** Find a Fix: its Core folder, session, views, banner and footer wiring, the fix
  fields on issues and creation failures, the Settings switch, tests, README and configuration
  lines. `AgentProcess` and `RegularFile` move to a process folder; the Oracle runner and the
  worker guard keep using them (PL F1).
- [x] 1j. **Codex.** One vocabulary. `OperatorCommand` and `SignalOperatorCommand` become one
  `OperatorLaunch`; `SignalOperatorTool` becomes `OperatorTool`; the saved round record becomes
  `OracleRound`; the second-opinion runner is named for the Oracle; `runId` and `runFolder` become
  the Operator session's id and folder, on the wire too; `operated` becomes worker. Comments that
  narrate broadcasts, boards, the Shelf or a spec section are rewritten to say what the code does.
  The shell gate's refusals and its Oracle prompt describe the signals Operator and name existing
  tools (OC F4, F5, RT F11, DM F7, and the comment lists in TL F4, SB F2, SS F4).

### Phase 2. Delete speculative handling (after 1)

- [x] 2a. **Codex.** Git: the per-key timeout back-off in the three resolvers (the project-level
  stall guard and "never store a failure" stay), reftable handling, the abandoned rebase scratch
  cleanup, the `.worktrees` symlink refusal (CG F4, F6, F9).
- [x] 2b. **Codex.** The default branch is asked from git when it is needed (when a project's
  heading appears, after a pull, when a sheet opens); `DefaultBranchResolver`, its map and its
  poll go (CG F5).
- [x] 2c. **Codex.** The checkout cleanup trusts the scan's confirmation; the second disk check,
  its port and its dictionary go (TL F6).
- [x] 2d. **Opus.** The Codex config editor writes its marked block, refuses on a conflicting
  table and removes its own entries by marker; the four-form string parser, the moved-hook
  reconciliation and the config-file model fallback go (PL F4). The refusal tests for unbalanced
  and conflicting files stay.
- [x] 2e. **Codex.** Daemon: the Codex rollout reader becomes one cursor (first record for the
  version, tail for the last boundary and token count, an unparsable line skipped); the subagent
  quiet window, the iTerm2 batched-read fallback and the resolver's root-change retry go
  (DM F3, F9, F10). The compat captures stay the proof.
- [x] 2f. **Codex.** Operator repair paths: the activity write queue, the Take Over repair loop,
  the mirrored source errors, the details cache reduced to a short cache by task and claim, launch
  recovery reduced to "a tagged tab with the planned agent, else block" (RT F10). The checkout save
  after a Take Over during a request checkout stays: without it the taken-over task has no folder
  and its next checkout is refused.
- [x] 2g. **Codex.** Worker guard: local `git merge` allowed, one argument table and one "this API
  call writes" rule shared with the shell gate, the GraphQL-file and deep alias paths go (OC F9).
- [x] 2h. **Codex.** Small ones: New Review's "press again" recheck, the profile save that cannot
  fail, guards behind controls that cannot send the input, one paging helper for the hosts, the
  duplicate Backpack rejoin delays and turn-off block, the release feed as constants
  (SS F16, HO F5 item 3, PL F6, F8).
- [x] 2i. **Codex.** The workspace backup is a plain second write; git-spawn budgets become
  ceilings; the two notes no test reads go (TL F8, TS F5).

### Phase 3. Windows (after 2)

- [x] 3a. **Opus.** Closed view. A closed window clears the row's window and nothing else. The
  close heuristic, the question and its Archive variant, the hold, eager restore and its triggers,
  and bringing AiTerm forward go. The window plan only adopts tagged windows. Choosing a row
  without a window opens it and reports a failure on the click. Terminals follow the same rule
  (WD F1, F3 moot, F6 moot; TL F5 moot).
- [x] 3b. **Opus.** One owner for "this row has or needs a window" for every row kind: manual task,
  driven task, terminal and the Operator chat, each adopted by its tag, with one `open(row)` that
  picks the opener. `RowFocus` keeps selection, peek and raising; its three opener slots, the five
  copies of "a signal task is not restored here" and the Operator's 180-second "opened" grace go.
  What choosing a row does is decided in `AppController.choose` alone (WD F2, SB F7).
- [x] 3c. **Codex.** The Operator row has one fixed id and a payload-free selection case; the
  derived id goes (WD F8, SB F6, OC F11). Row flags are kept once, not as a set plus a mirror
  (WD F9).
- [x] 3d. **Codex.** The iTerm2 banner says what a person can act on: iTerm2 isn't running (with
  Open iTerm2), iTerm2 refused AiTerm, AiTerm's helper isn't working; nothing while starting or
  connected (WD F7).
- [x] 3e. **Opus.** `docs/windows.md` rewritten for the closed view; the alert line in
  `docs/keyboard.md` and the "No window open" paragraph in `docs/status-model.md` follow.

### Phase 4. One task lifecycle (after 3)

- [x] 4a. **Opus.** Lifecycle tests join through one settled join, as the Operator's tests do, and
  no product function returns a task handle only for a test (TS F4).
- [x] 4b. **Opus.** Remove asks everything before it acts: the unmerged-branch question comes up
  at once, a row with a window and no helper is refused as Archive refuses it, and the
  "worktree removed, waiting for a retry" state with its banner actions goes (TL F1).
- [x] 4c. **Opus.** One teardown owner for archive and remove over the shared prepare and run, with
  consent as a policy (ask the person, or refuse while still allowed) and one per-row state that
  the row, the Dock badge and the checkout monitor read. The automatic variants and the remover's
  six dictionaries go; a task on its way out is filtered once, in the projection (TL F2, F9).
- [x] 4d. **Opus.** One restore (git, then the row back from the archive, then focus when a person
  asked), one "worker checkout for an item" and one window opener whose commands depend on
  ownership. The Operator's stage launch and a person's click call the same operations
  (TL F3, RT F4).
- [x] 4e. **Opus.** Take Over makes an ordinary task: the signal record goes, a small mark on the
  task (saved as the optional key `takenOver`) keeps later signals from continuing it, and it is
  opened, archived and removed like any task. The
  taken-over opener, its checkout copy and its resume commands go (RT F4, TL F3). Saved format
  changes; `operator-signals/state.json` re-recorded; `docs/operators.md` follows.

### Phase 5. Operator (after 4)

- [x] 5a. **Opus.** Every phase change goes through the stage machine, with actions for the
  recovered worker and the failed launch; the unreachable `stopped` phase, the unused `stop` action
  and the unread edge history go. One claim check covers workspace, pause, signal enabled and
  cancellation; the thirteen repeated pause checks go (RT F5, OC F2).
- [x] 5b. **Opus.** A task's record holds its current stage whole with a configuration that is
  always present; the eighteen `configuration ?? signal` fallbacks and the field-by-field stage
  copy go; one "question still pending" rule (OC F7 part b). Saved format re-recorded.
- [x] 5c. **Opus.** One Oracle owner: one consult with a kind, a binding and a round limit,
  returning agreed, critique, the person's call, unavailable or retry. Worker answers, agent
  choice, the merge veto, `ask_oracle` and the shell gate all go through it; every prompt lives in
  Core beside the invocation; a settings change discards the answer and retries; no in-flight
  marker is left behind by a crash (RT F3, OC F6). Prompts move byte for byte except where this
  plan changes them.
- [x] 5d. **Opus.** The controller composes owners and runs one ordered reconcile. Wake policy,
  the chat's window and session, the activity writer and retention each get one owner; Take Over
  already left in phase 4 (RT F1).
- [x] 5e. **Opus.** One tick with the existing event triggers: source polling, the host watch and
  settings are steps that ask whether they are due; one in-flight set per task shared by stage,
  Then, delivery and rounds; the 180-second grace has one name (RT F2). `busy` becomes a pure
  question and the live-work set is computed once per tick (RT F13).
- [x] 5f. **Opus.** The chat's lifecycle is one saved state with its generation; the three flags
  and four memory flags go; one idle rule (RT F8, OC F2). A row's current activity is runtime-only
  and leaves the saved task and the task line of `run_status` (RT F9).
- [x] 5g. **Opus.** The tool handler's ledger is the only ledger of calls: `answer_worker`'s second
  ledger entry and its own running set go, and the wake acknowledgement moves into the handler.
  The uniqueness rules on records stay with their owners, because those records outlive the
  ledger: a question id is recorded once, a resolved question keeps its answer, a snag key and a
  note key each name one record. The launch-time agent switch and `open_tab`'s choice move to the
  agent-choice owner (RT F7, F12). Changed refusal texts are listed in the commit.
- [x] 5h. **Codex.** `Signals/` regrouped by concept into about fourteen files with the source
  readers beside them; one helper for kind-tagged enums and one for open string enums with the
  same bytes; one JSON-lines appender for the activity log and the journals; delivery checks,
  `ClosingWait` and the merged-branch check move to their real homes; the task row's Operator
  wording is built in Core (OC F7 part a, F10, F12, F13, F14).

### Phase 6. Daemon and wire (after 2; beside the app track)

- [x] 6a. **Opus.** One ordered work list per session, each item saying whether it holds the turn;
  `background` plus `displayWork` with `legacyIndex`, and the app's merge, go (DM F2, SB F10).
  Wire frames and `docs/daemon-protocol.md` follow.
- [x] 6b. **Opus.** The app owns its helper: a stale holder of the socket is ended and a new one
  started; adoption, the held status, the mismatch hold and the unreadable-line limiter go; the
  stop in `scripts/run-dev.sh` becomes unnecessary (WD F4).
- [x] 6c. **Codex.** One method per daemon command returning its full reply; `workspace.snapshot`
  is the connection's own; callers that only want the tabs use the side-effect-free listing
  (WD F5).
- [x] 6d. **Codex.** Readings carry one session key and are dropped generically when it changed;
  the six hand-written identity checks and `Turn.generation` go (DM F6).
- [x] 6e. **Opus.** One owner for Codex thread identity: restored from the tab's tag, bound by
  hooks, asked by the readers, written back after the tick (DM F5). The tag's format stays.
- [x] 6f. **Opus.** Telemetry grouped by agent (Claude, Codex, PI), each turning its readings into
  evidence for one status entry point; the engine loses its agent-specific methods (DM F4). The
  Codex title stays a source.

### Phase 7. Hosts (after 1; beside the app track)

- [x] 7a. **Codex.** One `HostRepository` interface with the live operations and one factory; the
  four layered protocols and three factories go (HO F2).
- [x] 7b. **Codex.** One strict review-threads reader per host, which the badge counts; one Jira
  search with one mapping and shared date formatters; one "is this URL on the configured GitLab"
  rule that compares host and port (HO F4, F6, F7).
- [x] 7c. **Opus.** A request's state is read once per watch read and merge readiness is a pure
  rule per host with table tests; the repeated fetches of the same request go (HO F3). The merge
  floor still rests on one consistent read.

### Phase 8. Sidebar and sheets (sidebar after 5; sheets after 1)

- [x] 8a. **Codex.** One Core rule for "this task is under the Operator" (it has a signal record),
  read by the eight places that ask (SB F3). The defects the audit tied to a stopped task cannot
  be reached: nothing ever produced that phase, and 5a removes it.
- [x] 8b. **Opus.** The projection decides each row's mark and "needs you" once and hands views
  small row values, not altered task copies; attention uses that one flag; the pure row values
  leave the view file (SB F4, F14). Redraw budgets and pixels hold.
- [x] 8c. **Codex.** One heading module for projects and signals and one for the two section
  headings; Return on an empty heading runs its main command and the synthesized right-click goes;
  a removed signal's heading shows no pause mark and its fold is not written into task records
  (SB F5, F15).
- [x] 8d. **Codex.** Each row builds its commands once, drawn as both the context menu and the
  VoiceOver actions (SB F11). Pause and Resume have one home and one wording (SB F16, first item).
- [x] 8e. **Codex.** The selection follows its row (SB F8). "Which items would start" is one Core
  rule; a heading no longer reads the source (SB F9, SS F11).
- [x] 8f. **Opus.** One stepped-sheet frame that each sheet configures with its steps, create
  action, failure and closing block; it owns the stepper, Cancel on every step, Escape, Back,
  Continue and dismissal. Each sheet keeps its height. New Task, New Review and New Signal use it; one-field sheets
  commit on Return (SS F2, F3, F14 Return only).
- [x] 8g. **Codex.** Sheet fixes: readiness as advice for the signal's rows; the "isn't installed"
  note once and only when no agent can run; one unavailable-model wording and a visible reason for
  a disabled Continue; Add Project's folder as a line with Choose…; Base branch as the filtered
  field; one cancel rule in `DebouncedSearch`, which fixes the late ticket answer after a pick
  (SS F5, F6, F10, F12, F13, F15).
- [x] 8h. **Codex.** Settings tidy: the Operator profile save cannot silently fail, dead staging
  paths go, the copy about Cancel not undoing "Help with problems" goes with the switch (SS F1,
  tidy only).
- [x] 8i. **Codex.** Headless agent launches are described in the one agent table beside the
  interactive ones; effort constants live only there; the skill and project-file catalogues move
  beside the prompt step (PL F5, F7).

### Phase 9. Close-out (last)

- [ ] 9a. **Opus.** Docs brought to the code: architecture, Operator, windows, status model, daemon
  protocol, configuration, keyboard, testing, the READMEs and the UI README.
- [ ] 9b. **Opus.** Release notes for the major release: what changed for a person, and the
  upgrade procedure. The Operator's saved records change shape in phases 4 and 5 and nothing
  migrates them, so the notes carry the reset command of `scripts/reset-operator-state.sh` (0d),
  word for word, to run once with AiTerm closed: it removes
  `operatorSession` and every task's and archived task's `signalTask` from `state.json` and leaves
  everything else (projects, tasks, terminals, the archive, conversations, signals, seen items).
  A task that was taken over keeps that fact: before its `signalTask` goes, the command sets the
  task's `takenOver` mark from it, so no signal reclaims it. Other driven tasks become ordinary
  tasks and the Operator chat starts fresh. The command uses only what macOS ships.
- [ ] 9c. **Opus.** Full gate, bundle check, snapshots compared with `build/refactor-before` for
  every unlisted difference, the upgrade rehearsal, the whole change reviewed adversarially, and
  Record completed.

## Left out

- Moving the debug snapshots out of the app target (SB F13): large, and it touches the documented
  snapshot entry rule.
- Placing Claude's hooks by the tab header instead of a pid scan (DM F11) and retiring the Codex
  title as a source (DM F4, optional part): each needs a live probe first; a spike for
  `psg:research`.
- The test runner scripts (TS F8): they serve several worktrees side by side.
- The mutual section fold (SB F12), ⌘S, ⌘A and ⌘P (SS F14), the footer click that toggles Backpack
  Mode, the Focus View and List View names (SB F16), window re-framing on each click (WD F10),
  drag to reorder.
- A Settings window (SS F1): the maintainer chose to keep the sheet.
- The hook port as a constant (PL F2): the live compatibility capture and the shim's test point the
  shim and the PI extension at a listener of their own through the recorded port, so the port is
  varied on purpose.
- `WorkMeter` itself and its five live counts (CG F7).

## Review record

Codex, read-only, through `psg:adversarial-review`.

- **Round 1** (16 Nov), "not ready", three Important findings, all confirmed in the code and fixed
  in this plan:
  1. The upgrade instructions left saved Operator records that the new formats cannot read.
     Fixed: 9b's reset command, rehearsed in 9c.
  2. A constant hook port would send the live compatibility capture and the shim's test to the
     running daemon. Fixed: the step is dropped and listed under Left out.
  3. The handler's ledger cannot replace the record rules in `ask_you` and `resolve_question`.
     Fixed: 5g removes only `answer_worker`'s duplicate ledger and keeps the record rules.

- **Round 2** (16 Nov), "not ready", three Important findings, round 1's all settled:
  1. Deleting the checkout save after a Take Over during a request checkout would strand the
     task. Confirmed; fixed: 2f keeps it.
  2. The reset would erase the fact that a task was taken over, and a later signal could reclaim
     it. Confirmed; fixed: the reset carries it into the task's `takenOver` mark, 4e names that
     key, and the rehearsal covers a taken-over task.
  3. The step briefs did not exist yet. They were being written while the review ran; settled once
     every to-do has its brief.

- **Round 3** (16 Nov, with all 62 step briefs in place), "not ready", one Important finding, rounds
  1 and 2 all settled: brief 5f had retirement save the idle state without advancing the Operator's
  generation, so the next workload would try to register a revoked generation. Confirmed in
  `OperatorSessionKeeper.transition`; fixed in the brief, which now increments for retirement and
  renewal alike and names the test that proves it.
- **Round 4** (16 Nov), "ready": no findings, every earlier finding settled. A static review: no
  build, test, live capture or upgrade rehearsal was run, and the 62 briefs were not traced line by
  line.

## Record

Filled while implementing: per phase, the gate result, findings dropped on re-reading with the
reason, fixtures re-recorded, tests deleted with their survivors, and anything a step found and
left.

### Phase 0

- Starting commit: `d9e9ccaa Plan the greenfield refactor: one owner per concept, no leftovers, no
  compatibility, with a brief for each step`.
- Gate: plain `scripts/test.sh all`, exit 0, wall time 549 s (log in
  `build/refactor-before/gate.log`). Summary lines as printed: daemon
  `1601 passed, 1 skipped in 23.87s`, `Success: no issues found in 92 source files`,
  `All checks passed!`; after `Gate pass: main`,
  `Test run with 1702 tests in 168 suites passed after 110.043 seconds with 3 known issues.`;
  after `Gate pass: snapshots`, the closing line
  `Test run with 1 test in 1 suite passed after 3.022 seconds.` Passed on the first run; no
  flaky test.
- Snapshots: `build/refactor-before/`, 109 PNGs from `scripts/snapshots.sh` in default mode;
  `manifest.txt` beside them holds their SHA-256 sums, one line per PNG (109 lines).
- Saved-state copy: `build/refactor-before/state.json`, copied from the `operator-signals` fixture
  at `d9e9ccaa`, SHA-256
  `73f5f19b3d1f81e1f785a5a15503e45a4e12dc674b17c84f8082b7e30c7c8475` (equal to the fixture's sum
  at that commit).
- 0a differed from its brief in one point: the plan and the brief folder were already committed
  (`d9e9ccaa`), so the starting `git status` was clean rather than showing them untracked.
- 0b: `SignalJourneyTests.aJiraMatchRunsToItsDoneConditionAndThenArchivesItsTask` added; three
  filtered runs green; it fails at the archive expectations with Then `.keep` and with the ticket left
  at `To Do`. The brief's evidence held. The test wraps the stub's `Mutex` in a small `Sendable`
  class, because a noncopyable `Mutex` cannot be captured by the stub's escaping closure.
- 0c: 55 test files build `Project`, `TaskItem` and `SessionInfo` through the shared builders, which
  gained `mr`, `appendTicket`, `conversations`, `project`, `model` and `title`. No test added,
  deleted or renamed; no assertion changed. Direct initialiser calls kept: the six `ModelsTests`
  exceptions the brief names, plus `anUnknownSidebarItemKeepsItsPlaceAndIsNeverDrawnOrCounted`
  (it asserts a JSON round trip), and the six Find a Fix files (1i deletes them). The brief's
  `Project(id:` grep also matches `updateProject(id:` and `removeProject(id:`; those hits are not
  initialiser calls. Twenty local helpers stay as thin wrappers with three or more callers each.
- 0d: `scripts/reset-operator-state.sh` (one line: `pgrep`, `cp -p`, `date`, `osascript`) and its
  guard `scripts/test-reset-operator-state.sh`, run by `test-swift-toolchain.sh` beside the history
  guard and routed from both scripts and the `operator-signals/state.json` fixture
  (`test-test-select.sh` pins the three routes). The script was only ever run on scratch copies.
  `ArchivedTask` lives in `Models.swift`, not `Tasks/`; its keys are as the brief says.
- Phase close: plain `scripts/test.sh all` green on `f3df6271` (1702 Swift tests in 168 suites,
  daemon suite and lint, snapshots). Codex adversarial review of the phase's change: no findings,
  "ready" (static review). `main` had not moved since the branch (`247b305d`); merged to `main`.
  No manual check is owed for phase 0.

### Phase 1

- 1a: the broadcast eval baseline, the two unread `operator-current` folders, `operator-records`,
  `operator-saved-format`, `operator-current-tools.json` and the `retired:` key lists are gone; the
  live eval runs the current brief only. Tests deleted: `SignalRetiredKeysTests.anOldWorkspaceLoadsAndItsNextSaveDropsEveryBroadcastKey`
  and `ModelsTests.aTaskSavedWithLastSelectedAtStillDecodes` (behaviour deleted; unknown-key
  preservation is now held by `aKeyThisBuildDoesNotKnowOnATaskSurvivesASave` and
  `aKeyThisBuildDoesNotKnowOnAWorkspaceSurvivesASave`). `theProjectsAreTheDefaultSectionAndAnOpenOperatorIsKept`
  moved to `SignalSavedFormatTests`. Differences from the brief: `daemon/tests/wire/PROVENANCE.md`
  also named the deleted fixtures, so its sentence "The separate frozen operator-current tool and
  workspace fixtures were not regenerated." went (no fixture bytes changed); the eval's
  `read_task/lastMessage` replies went too, because the current `read_task` has no `what`
  argument and the stub could only match them under the old contract. `docs/testing.md` still names
  a nonexistent `OperatorWorkBudgetTests`; left for 9a.
- 1b: the code-host and Jira write surface went (request writes, thread replies and resolution,
  pipeline retry, user lookup, `JiraWrites`, `JiraAgile`, `search(jql:in:)`, the uncertain-outcome
  and not-sent failures, `OperatorPorts.publisher`, `FakeMergeHost`, the thread prompt); both
  `merge` bodies are byte-identical. Tests deleted with their behaviour, no survivor: `JiraWritesTests`,
  `JiraAgileTests`, `FakeMergeHostTests` and the write tests the brief lists in `GitHubPublishTests`,
  `GitLabPublishTests`, `MergeRequestPublisherTests` (renamed `HostRepositoryTests`),
  `GitHubClientTests` and `HTTPJSONTests`. Thread reads survive in `HostRepositoryTests.gitHubReadsThreadsByTheirNodeId`
  and `gitLabReadsEachThreadWithItsIdAndLastNote`. Differences: `JiraUser` lived in the deleted
  `JiraWrites.swift` and moved beside `signalUsers`; `readinessThatCannotBeAskedThrows` had no
  `retarget` line left. The Done-when grep for `func resolve(_` still matches
  `WatchedFileCache.resolve`, which the brief itself lists as unrelated (2b deletes the file).
  `JiraClient.approximateCount` has no source caller and is kept, as the brief says.
- 1c: the push and publish stack, `LocalMerge`, `CommitId`, `BranchDrift`, `BackgroundWork.within`,
  `pushReason`, `saidAsWritten`, `LoginShellLocator.refresh`, `WorktreeError.notARepository` and six
  `WorkMeter` cases went; `isFullCommit`, `sameLocation`, `shortBranch` and `folded` moved unchanged
  to `WorkerGuard+Names.swift`. Tests deleted with their behaviour: `LocalMergeTests`, the push tests
  of `PublishPushTests`, three `GitErrorTests.pushReason*`, `LoginShellLocatorTests.aRefreshReplacesTheKnownPathOnlyWhenTheShellAnswers`
  (`forgettingAsksTheShellAgain` stays), and the `CommitIdTests` merge and review rules. Survivors:
  `WorkerGuardRulesTests.aDefaultBranchIsRecognisedUnderAnySpelling` (new; for the two default-branch
  spelling tests), `WorkerGuardRulesTests.twoUrlsAreTheSamePlaceWhenHostAndPathAre` (moved table) and
  `WorkerGuardNamesTests.aFullCommitIdIsFortyOrSixtyFourAsciiHexDigits` (for `onlyACommitIdIsPushed`).
  `CommitIdTests` held two tests, not three.
- 1d: Core Operator leftovers went (`DiffDigest`, `OperatedBranch`, `TaskKeyReference`,
  `SavedDefaults`, `SignalBranchRef`, the `AgentDelivery` struct, the acceptance half of
  `WorkerTurn`, dead Oracle prompts, eighteen unread `OperatorTiming` constants, dead `OperatorModels`,
  `OperatorLine`, `WorkerTabs` and `ActivityLog` members, the branch item and `baseline` seen state,
  `peopleReview`, `agentPinned`, `role`, the dead Oracle round fields). `gateInstructions` is
  byte-identical. Fixture re-recorded: `operator-signals/state.json` with `AITERM_RECORD_SIGNAL_STATE=1`,
  exactly two lines removed (`"kind" : "critique"`, `"agentPinned" : false`), provenance section
  added; the committed fixture was first loaded through `StateStore` with its task and archived
  task intact. Tests deleted with their behaviour: `DiffDigestTests`, `OperatedBranchTests`,
  `TaskKeyReferenceTests`, `SavedDefaultsTests`, `AgentDeliveryTests` (version rules survive in
  `DeliveryCheckTests`), six dead-prompt `ChallengeLaunchTests` (the parser survives as
  `theOraclesAnswerIsReadByItsFirstWord`; four gate tests stay), three `WorkerTurnTests`
  acceptance tests, `ModelChoiceTests.rowsMatchAgentModelAndReasoningInListOrder`,
  `BranchTypeTests.testATitleSaysTheTypeWhenNoIssueTypeDoes`, `ActivityLogTests.whatOnlyLookedWaitsBehindShowEverything`;
  `identityContinuesOrdinaryTaskByTicketRequestOrProjectBranch` is now
  `identityContinuesOrdinaryTaskByTicketOrRequest`. The Done-when symbol grep matches the required
  provenance line naming `agentPinned`; no code names any of the symbols. Left for 1j: a
  `WorkerTabs.tabToBring` comment that names `BroadcastRequest`.
- 1e: Operator runtime leftovers went (`OperatorClock.sleep`, the unread port budgets and
  `appVersion`, `wakeCoalesce`, `openCallMinutes`, `StallWatch`, the transcript open-call reader,
  the locator's numbering and test hooks, `markOutcome`, `SecondOpinionRunner.cancelled`,
  `ThenRunner.isRunning`, `SignalPoller.onRead`); `ItemRouter.apply(signals:read:)` is now a
  test-only extension in `OperatorFakes.swift`. No test deleted; the `wakeCoalesce` timing row went
  with its constant. Added `WorkerTranscriptTests.aReplyIsReadAgainOnlyWhenItsFileChanged`; three
  `SignalPollerTests` moved from `onRead` to `onPass` with the same expectations.
- 1f: `ShelfRow` became `ArchiveSearch.Entry` and every Shelf name became Archive; dead controller
  and coordinator members, comment stubs, the `queued` row state, the hand-off counts, `DockBadge`
  and the model's attention helpers (one `SidebarProjection.needingAttention(skipping:)` remains),
  dead pickers and segments, the command preview, the broadcast step config, the disabled prompt
  editor, never-drawn subtitles and `TaskDraft`'s type and name halves went. Tests deleted with
  survivors: `DockBadgeTests` and three `SidebarModelTests` places (four new `SidebarProjectionTests`
  attention tests), `SearchPickerStateTests` (behaviour deleted; the keyboard tests live on as
  `DropdownKeysTests`), `CreationSheetStepsTests.broadcastCreatesOnStepFive` and the preview tests
  (prompt rules survive in `AgentCommandTests.testComposePrompt`, `DescriptionPromptTests`,
  `TicketSourcesTests`; quoting and PI cases now assert `build`), the queued mark and card variants,
  `TaskCreatorTests.testAnEditedNameStillTakesANewType` and `testATypedPrefixMovesIntoTheType`,
  `NewTaskSheetKeyboardTests.typingATypePrefixIntoTheBranchFieldPicksTheTypeAsYouType`,
  `BranchTypeTests.testABranchSplitsOnlyOnAKnownType`, and the disabled half of
  `PromptEditorTests` (now `theEditorAcceptsTypingAndTakesTheKeyboardOnAppear`); added
  `TaskCreatorTests.aWholeBranchFollowsAutomaticNamingUntilEdited`. Snapshots in
  `build/refactor-1f`: all 66 named sheet captures RGB-identical to `build/refactor-before`; only
  `marks.png` differs, one of the two known two-variant captures. Differences: the `SearchPicker`
  name was also rewritten in `docs/design/design-system.html` and `docs/design/ui-patterns.md`
  (names of deleted symbols, as the brief's decision says); one `TaskDraft` test passed a bare
  `bad..name` and now passes `feat/bad..name` with the same expectation. `AgentCommand.resumeWorker`
  is called only by tests; left, as the brief says.
- 1g: daemon leftovers went: slash-command tracking, live model and effort attribution and the
  `PostModelSwitch` hook, `subagentsWrittenAt`, `title` on the wire, `session.prompt` and
  `session.dismissStartup`, the prose wake rule (a wake line is the grammar or refused with
  `wakeText`) and `wake-lines.json`, `operator_token.py` (folded into `operator_session.py`), the
  `settle_reads` seams, the Codex reader's test-only methods and `codex_reference.py`. Fixtures
  re-recorded: `daemon/tests/wire/` with `AITERM_UPDATE_WIRE_FIXTURES=1` (only the session frames,
  the snapshot, the manifest and the two deleted request replies changed; provenance paragraph
  added) and `compat/drivers/claude-settings.json` with `AITERM_RECORD_COMPAT=1` (only the
  `PostModelSwitch` block left; `launch.json` and `codex-hooks.toml` unchanged; no provenance file
  exists for `compat/`). Decision: the brief expected no daemon budget number to move, but a steady
  tick's registry sorts fell from 6 to 4 with the slash step gone; per `docs/testing.md` ("a change
  lowers a number with the work that earned it") the four sort ceilings in
  `test_tick_budgets.py` were lowered to 4 in this step, nothing else. Tests deleted with their
  behaviour: all 39 of `test_slash_commands.py` (its helpers moved to `test_stop_failures.py`, the
  survivor for stopped-worker transcripts), the attribution tests in `test_hook_events.py`,
  `test_hook_router.py`, `test_sessions.py`, `test_status.py`, the prose wake tests (survivors:
  `test_a_wake_line_outside_the_app_grammar_is_refused`, `test_the_app_grammar_wake_line_passes`),
  the `session.prompt`/`dismissStartup` service tests (prompt recognition survives through test-owned
  screen helpers; `dismiss_startup` tests stay), `test_claude_transcript_shows_the_slash_command_and_its_output`,
  three `DaemonTypesTests` and four `DaemonOperatorWireTests` cases. The planner's points held.
- 1h: every old-format reader and migration went: Keychain per-key items, the support folder
  rename and its alert, the legacy status-line record, retired hook and push-key cleanup, the
  pre-0.15 workspace decoders (`Project` and `TerminalItem` now use synthesized coding: today's
  encoder always wrote every key they require, so a workspace saved by today's build loads; a flat
  `projects` key rides as a preserved unknown key), the earlier choice-block upgrade, the app's
  hand-written `SessionInfo` and `BackgroundJob` decoders (`background` is always sent), optional
  `generation` in the Operator MCP, Jira's paging fallbacks and the old GitLab URL form. Tests
  deleted with their behaviour: two `KeychainTests` separate-item tests (survivors
  `everySecretLivesInOneItem`, `theItemIsReadOncePerProcess`, `aRefusedReadIsNeverWrittenOver`),
  four `AiTermPathsTests` migration tests, `HookConfigTests.anOldJSONRecordIsMigratedAtLaunchWithoutAnInstall`
  and `testRetiredPreToolUseHookIsRemovedButForeignOnesStay`, `BackpackSettingsTests.anOldNotifiesChoiceIsReadPastAndDroppedOnTheNextSave`,
  four `ModelsTests` old-input tests, `StateStoreTests.testLegacyFileOnDiskLoadsAndSavesAsItems`,
  `SignalAgentChoiceTests.blocksSavedByAnEarlierBuildForAChoiceNowWaitForTheOperator`,
  `JiraClientTests.aPagingFieldOfTheWrongTypeIsReadAsNotSent`. Added
  `ModelsTests.aProjectsKeyIsPreservedWithoutCreatingItems`; `theLaunchProbeMigratesAnOldStatusLineRecord`
  became `theLaunchProbeRecordsTheHookPort`. Fixtures unchanged. Hand-built session JSON in tests
  now carries `active` and `background`.
- Found while proving 1i: since 1h made `background` required, the debug snapshot fixture
  (`Snapshots/Fixture.swift`) built sessions without it and decoded them with `try?`, so every
  sidebar snapshot lost its tabs. The gate did not see it (its snapshot pass covers the signal
  drawings only). Fixed in its own commit after 1h (`"background":[]` added); every sidebar PNG is
  again RGB-identical to `build/refactor-before`. Lesson for later steps: compare the full
  snapshot set, not only the gate.
- 1i: Find a Fix went (thirty files, 4,403 lines, 203 test declarations: its Core folder, session,
  views, banner and footer wiring, the fix fields, the Settings switch, compat entries, README and
  configuration lines). `AgentProcess` and `RegularFile` moved to `AiTermCore/Process/`; the
  `RegularFile` tests moved to `RegularFileTests` (symlink and absent-file checks added); the
  task-model test moved to `AgentIntegrationsTests`. Survivors: `AgentProcessTests`,
  `RegularFileTests`, `ChallengeLaunchTests`, the worker guard's tests, `OperationIssueTests`,
  `PullDefaultControllerTests`, `UnbornTaskCreationTests`. Fixture re-recorded: `compat/launch.json`
  with `AITERM_RECORD_COMPAT=1` (only `fixerApply` and `fixerLook` removed); the capture
  `daemon/tests/fixtures/compat/claude/headless/fixer-look.json` stays, unread. Snapshots in
  `build/refactor-1i`: 96 of 109 unchanged; `settings-agents.png` loses the Help with problems
  group (the planned change); the eleven Find a Fix images are gone and three plain banner and
  footer images replace them (`review-rebase-conflicted.png` equals the old unavailable state);
  `marks.png` is its known variant. The pull suite is named `PullDefaultControllerTests`, not
  `PullDefaultTests`. One plain gate run failed in `StatusLineShimTests` with 50 to 90 second
  timeouts under load (load average about 4.5); the next plain run was green with no change.
- 1j: one vocabulary. `OperatorCommand` and `SignalOperatorCommand` are one `OperatorLaunch`
  (`gate.json` bytes identical, `idleCompaction` encoded directly; the private-file writer is
  `PrivateFile`); `SignalOperatorTool` is `OperatorTool`; `ChallengeRecord` is `OracleRound` (saved
  keys and raw values unchanged, including `unchallenged`); `ChallengeLaunch` is `OracleLaunch`;
  `SecondOpinionRunner` is `OracleRunner`; `runId` is `operatorId` on the wire; `operated` is
  `worker`; comments across the tree stop narrating broadcasts, boards, runs or spec sections.
  Model-facing strings changed: the push, host and API refusals (they name `message_task` and the
  signal's merge choice; a new `ShellGateTests` case proves every tool-like word in a refusal is an
  `OperatorTool`), the gate's Oracle prompt (exactly the brief's lines), the gate's four reasons
  (`unchecked: ...`), the daemon's "AiTerm ran this command unchecked: {why}", the Oracle runner's
  failure texts ("The Oracle" for "The second opinion"). Fixture re-recorded:
  `daemon/tests/wire/event.operator.request.json` only, provenance paragraph added. No test deleted;
  `ChallengeLaunchTests` is `OracleLaunchTests`, `SecondOpinionRunnerTests` is `OracleRunnerTests`.
  Differences: `ChallengeKind`, `challengeReplyBudget` and the dead Oracle prompt APIs were already
  gone (1d). The orchestrator's note to Codex forbade any change under `operator-signals/`, so the
  orchestrator renamed `SignalOperatorCommand.brief` to `OperatorLaunch.brief` in its PROVENANCE.md
  itself (one docs line). Left for 9a: `docs/architecture.md` (two lines) and `docs/operators.md`
  (the upgrade paragraph) still narrate broadcasts, and `docs/keyboard.md` says what there is no
  board for; the brief leaves docs beyond the renamed lines to phase 9. Allowed sweep hits that stay:
  the daemon's event broadcasting, Jira's own "board" in sheet copy, the frozen brief's "you do not
  plan a board of tasks", negative assertions and a worker-message sample in `WorkerTurnTests`.
  `AgentCommand.resumeWorker` is still called only by tests.
- Phase close: plain `scripts/test.sh all` green on `e65ecd4d` (daemon suite and lint, 1043 app
  and 1391 core Swift tests, snapshots). Snapshots captured into `build/refactor-phase1`: against
  `build/refactor-before`, only `settings-agents.png` (Help with problems gone, planned) and
  `marks.png` (known variant) differ; the eleven Find a Fix images are gone and three plain banner
  and footer images are new. Bundle: `scripts/make-app.sh`, then `scripts/test-app-bundle.sh
  build/AiTerm.app` verified executable, resources, pinned helper dependencies and signature. Codex
  adversarial review: no findings, "ready on static review" (its base was `origin/main`, so it read
  phases 0 and 1 together). `main` had not moved beyond phase 0's merge; merged to `main`.
- Owed to the maintainer for phase 1: `scripts/compat-check.sh` (the Claude driver lost its
  `PostModelSwitch` hook, `compat/launch.json` lost the fixer entries) and the live Operator eval
  (`AITERM_LIVE_OPERATOR=1`: the gate's refusals and Oracle prompt and the reasons changed in 1j,
  the eval runs the current brief only since 1a).

### Phase 2

- 2a: the per-key timeout back-off in `WatchedFileCache`, `RepositoryProbe` and `DiffStatResolver`,
  reftable handling, the abandoned rebase scratch cleanup and the `.worktrees` symlink refusal went;
  "never store a failure" stays in every resolver and `StallGuardedGit` stays the one guard.
  `GitSpawnCountTests` numbers unchanged. Tests deleted: `WatchedFileCacheTests.aTimeoutIsNotAskedAgainUntilItsBackoffIsOver`
  (survivors `StallGuardedGitTests.theProjectIsAskedAgainOnceTheBackoffIsOver`,
  `GitSpawnCountTests.aHungMountCostsOneTimeoutAndHoldsUpNoOtherProject`),
  `BranchResolverTests.aFailedReadKeepsTheLastBranchAndIsRetried` (survivors
  `WatchedFileCacheTests.theKnownValueStandsAfterAFailedReadAndIsRetried`,
  `RemoteResolverTests.aFailedReReadKeepsTheLastAnswerAndIsRetried`), and with their behaviour the
  reftable tests in `BranchResolverTests`, `DiffStatResolverTests`, `DefaultBranchResolverTests`,
  `WorktreesTests.testRefusesSymlinkedWorktreesDir` and
  `DefaultBranchPullTests.testRemovesTheCheckoutOfARebaseThatNeverFinished` (the brief did not
  list the last two; they tested the deleted behaviour).
- 2b: `DefaultBranchResolver`, the scan's default-branch map and its poll went; `RepositoryProbe`
  no longer asks for the common directory. `ProjectActions` reads a project's default branch when
  its heading row appears and after each pull or rebase (a failed read leaves the last name), and
  the Edit Project sheet reads it when it opens (the header shows the folder alone until git
  answers: the accepted visible change). `GitSpawnCountTests` first pass: 45 to 43 spawns, no
  default-branch query per pass (2i turns the numbers into ceilings). Tests deleted with the cache:
  six `DefaultBranchResolverTests` (failure handling survives in the new `DefaultBranchNameTests`;
  `namesOriginsDefaultBranch` and `resolvesALinkedWorktreeToTheRepositorysDefault` moved to
  `DefaultBranchPullTests`), `UnbornRepositoryTests.theCachedDefaultFollowsAnUnbornBranchRename`
  (survivor `theUnbornBranchIsOfferedAsTheBase`); `TaskCreatorTests.aDraftTakesTheDefaultBranchItIsGivenWithoutAskingGit`
  is now `aDraftAsksGitForTheDefaultBranch`. Added `DefaultBranchNameTests`. A worker guard test
  named `defaultBranches...` was renamed `defaultBranchNames...` (behaviour unchanged).
- 2c: the checkout cleanup trusts the scan's confirmation; the second disk look, its port and its
  dictionary went, and `waitForRemoval` joins the record cleanup and the removal. Tests deleted with
  their behaviour: `CheckoutCleanupTests.aCheckoutThatCameBackBeforeTheCleanupActsIsNotForgotten`
  (survivor `aCheckoutThatComesBackStopsClosing`), `aConfirmationThatNeverAnswersLeavesTheMainActorFree`,
  `thePersonsRemoveRunsWhileAConfirmationHangs` (survivors `removingAnUnknownFolderKeepsItUnlessExplicitlyConfirmed`
  and the new `checkoutCleanupLeavesATaskAloneWhileRemoveIsInProgress`). Difference: a
  `RestoringRowTests` case expected the row to read as missing after the pass; with the cleanup now
  acting in the same turn the task is already forgotten, so it joins the removal and expects the task
  gone (a consequence of the step, not a weakened check).
- 2d: the Codex config editor writes its marked block in place when the span holds only AiTerm
  tables and blanks, and otherwise rebuilds (markers dropped, AiTerm tables dropped, every other
  table kept byte for byte, block appended); `hasAiTermEntries` replaces `containsOwnedTables`.
  `TOMLStatements` reads structure only. Codex models come from `models_cache.json` alone, else
  `gpt-5.6`. The block's bytes and `compat/` are unchanged; every guarantee test the brief lists
  passed unedited. Tests deleted with their behaviour: `codexRepairKeepsForeignChildrenAfterInterveningTables`,
  `stringReadsEveryTOMLForm`, `stringRejectsWhatIsNotOneTOMLString`, `keyIsNilForADottedKeyButValueStillReadsIt`,
  `testCodexConfigModelIdsStopAtTheirQuotes`, `testCodexConfigModelsAreReadByKeyPath`. Added
  `aStaleBlockIsReplacedInPlace` (failed first) and `aServerAddedBetweenTheMarkersIsKeptAndTheBlockIsStillReplacedOnce`
  (passed on the old code too; it guards the new one). Difference: two `ModelCatalogueTests` the brief
  did not name used `config.toml` as the Codex model source; their fixtures moved to
  `models_cache.json` with the same checks (stamping through a symlink, a file appearing, an in-place
  rewrite). Noticed and left: on the rebuild path a CRLF file still gets an extra `\n` after its
  last line, as before.
- 2e: the Codex rollout reader is one cursor (line 1 for the version on first sight, the tail for
  the last boundary and token count, later `session_meta` for the thread followed, an unparsable
  line skipped and logged once); the subagent quiet window, the iTerm2 per-name fallback and the
  resolver's root-change retry went. Compat captures and tick budgets unchanged. Four large-rollout
  cases changed their expectation exactly as the brief's decisions say (a boundary more than 8 MiB
  back reads as no turn; a `session_meta` outside line 1 and the first-sight tail is not seen).
  Tests deleted with their behaviour: three short-read and rewrite tests and four parser-isolation
  tests in `test_codex_sessions.py` (unchanged-file I/O survives in
  `test_context_is_not_reparsed_until_its_rollout_changes` and the tick budgets), four quiet-window
  tests in `test_status.py`, two fallback tests in `test_iterm_bridge.py`; a live-test assertion on
  `_batched_reads` went too. Added the unparsable-line test (written first).
- 2f: Operator repair paths went: the activity write queue (a failed write is reported and the next
  written entry clears it), the Take Over repair loop, the mirrored source errors, the details
  read's flights and own timeout (now a short cache by task and claim), and launch recovery's scope
  file (a tagged tab running the planned agent is adopted). The checkout save after a Take Over
  during a request checkout is byte-for-byte unchanged and now has its own test. Tests deleted or
  replaced: `aStatusReadHasItsOwnBudgetAndNeverCachesATimedOutAnswer` (timeout deleted; caching
  survives in `repeatedStatusDetailsReuseTheHostReadButAChangedAuthorityDoesNot`), the replay,
  repair and scope-matching tests, replaced by `aFailedActivityWriteIsReportedAndTheNextWrittenEntryClearsIt`,
  `aTakeOverWhoseJournalCannotBeWrittenShowsAtOnce` and
  `anInterruptedLaunchAdoptsItsTaggedWorkerWithoutRepeatingThePrompt`.
- 2g: workers may run `git merge` locally (the publishing denial list and the guard's refusal
  dropped it; review workers still deny it); the guard and the shell gate share `gitValued`,
  `hostValued`, `hostPositionals` and `sendsToTheAPI`; the GraphQL-file inspection and the deep
  alias chain went (one configured alias lookup stays). Host-side merges stay refused. Tests deleted
  with their behaviour: `WorkerGuardCLITests.graphqlQueriesReadFromFilesStillRefuseMerge` and the
  `git merge main` refusal cases; `workerCanCommitAndPublishItsOwnBranch` now checks local merges are
  allowed. `WorkerGuardCodexTests` is opt-in and was not run (a live probe; not in the plan's owed list).
- 2h: small guards went: New Review's destination re-check ("press again"), the profile save that
  could not fail (now non-throwing), guards behind controls that cannot send the input, the hosts'
  separate paging loops (one helper in `HTTPJSON`), the duplicated Backpack rejoin delays and
  turn-off block, and the release feed parser and its `Info.plist` key (one `GitHubReleaseSource.aiTerm`
  constant). Tests deleted: `theSheetRefusesADestinationThatMovedSinceItWasShown` (survivors
  `aReviewOfTheBranchADriftedTaskLeftGetsAWorktreeOfItsOwn`, `aReviewOfTheBranchADriftedTaskMovedToOpensInThatTask`),
  `aSecondPressDuringTheDestinationCheckIsRefused` (survivor `duplicateSubmissionIsBlockedAndFailureKeepsDraft`;
  the brief did not name it), and `ReleaseFeedTests` (anonymous requests survive in
  `GitHubReleaseSourceTests`; a missing version in `aBuildWithoutAVersionSaysSo`). The bundle check
  no longer looks for the feed key.
- 2i: the workspace backup is a plain atomic second write of the validated previous bytes (the
  clone, staging and `copyfile` path went); files written per save is back to 2, on purpose.
  `WorkMeter.workerTabs` and `stateSave` and the `WorkerTabs` note went. Spawn budgets in
  `WorkBudgetTests` and `GitSpawnCountTests` are ceilings at the measured counts: archive 8, restore
  4, remove 7 (worktree listings 4, 1, 3); first checkout pass 43, path probes 9; expired pass 12,
  diffs 6, untracked listings 6. No test deleted. `docs/testing.md` says ceilings and names the
  four budget suites that exist.
- Phase close: plain `scripts/test.sh all` green on `a7c5999d` (daemon suite and lint, 1045 app and
  1367 core Swift tests, snapshots). Snapshots in `build/refactor-phase2`: against
  `build/refactor-phase1` only `marks.png` differs (known variant); against `build/refactor-before`
  only `settings-agents.png` (phase 1's planned change) besides phase 1's swapped Find a Fix images.
  Bundle: `scripts/make-app.sh` and `scripts/test-app-bundle.sh build/AiTerm.app` passed. Codex
  adversarial review of `main..HEAD`: no findings, "ready". `main` had only the refactor's own merges;
  merged to `main`.
- Owed to the maintainer for phase 2: `scripts/compat-check.sh` (the Codex config editor changed in
  2d). The opt-in `WorkerGuardCodexTests` probe (2g changed the worker guard) was not run either.

### Phase 3

- 3a: closed view. A closed window clears its row's window and nothing else; the close heuristic
  (`ClosedWindowTriage`), the question and its Archive variant, the hold, eager restore and its
  triggers, bringing AiTerm forward, the "Couldn't reopen" caption and `letsWindowGo` went.
  `AppState.windowPlan` returns adoptions only; the reconciler passes only on a snapshot, a closed
  window or a session event that moved `rowSessions`. Choosing a row without a window opens it (a
  terminal as a fresh shell) and reports a failed open on the click; a row chosen while iTerm2 is not
  synced starts iTerm2 and is chosen again (opened and raised) on the next connected snapshot if
  still selected. Tests deleted with their behaviour as the brief lists (`ClosedWindowTriageTests`,
  `WindowReconcilerTriggerTests`, ten `ClosedTaskWindowTests`, six `RestoringRowTests`, six
  `WindowPlanTests` and the single cases it names), survivors as it names
  (`CheckoutCleanupControllerTests.removingATaskClosesItsWindowBeforeDeletingItsWorktree`,
  `aCleanupWhoseWindowsCloseArrivesFirstStillForgetsTheTask`). New `ClosedViewControllerTests` (seven
  cases plus the two moved survivors); `RestoringRowTests` became `OpeningRowTests` with an added
  pending-open case. Snapshots in `build/refactor-3a` RGB-identical to `build/refactor-phase2`.
  Review rounds by the orchestrator: (1) the pending open now raises its window (the decision says
  that first click must not need a second one); the `holding token:` parameter and
  `WorktreeTeardown.work`, unused after the step, went; (2) two `TaskLauncher.create` messages that
  promised a window "once AiTerm reconnects" now say to choose the task. Differences: the brief's Tests
  wanted the not-connected sentence for a choose while iTerm2 is away; its Change and Decisions say
  nothing is reported, which was followed. `CheckoutCleanupControllerTests.filesystemRefreshRetainsUnconfirmedDeletion`
  (not named) relied on the deleted missing-changed trigger and now expects the kept task without a
  window. The second Done-when grep still matches an unrelated `"settled: "` message in
  `OperatorBadgeTests`. Left for 3b: `RowFocus`'s restore names.
- 3b: one owner for every row's window. `WindowReconciler` is `RowWindows`; `open(row)` picks the
  opener for a manual task, a taken-over task, a driven task, a terminal and the Operator chat (new
  `WindowRow.operatorChat`, adopted by its session's tag and never during a keeper handover).
  `RowFocus` keeps selection, peek and raising; its three opener slots, the copies of "a signal task
  is not restored here" and the Operator's 180-second "opened" grace went. What choosing a row does is
  decided in `AppController.choose` alone; a notification's Open and a restore from the Archive go
  through it. The chat reopens by itself only when a wake is pending or unread. Issue sources
  `.openWindow` and `.reopenWorker` went (a failed reopen is reported on the click). No test deleted;
  added `RowWindowsControllerTests` (8) and cases in `WindowPlanTests`, `WindowReconciliationTests`,
  `ModelsTests`, `SignalSessionKeeperTests`. Snapshots in `build/refactor-3b` RGB-identical to
  `build/refactor-3a`. Differences: a row chosen while iTerm2 is away is handed back to
  `AppController` through a new `onPendingOpen` hook (only `AppController` may select); the four
  taken-over `ItermFocusControllerTests` send a connected snapshot first (the uniform check order);
  choosing the Operator row with no work still starts nothing. Noticed and left: a chat closed before
  its conversation was recorded starts a new generation on the next reconcile (unchanged keeper logic,
  rare); a closed chat whose workload ended retires at the next scheduled pass. `docs/architecture.md`
  still names `WindowReconciler` (3e).
- 3c: the Operator row has one fixed id (`OperatorSession.rowID`) and a payload-free selection and
  row case (`.operatorChat`); `OperatorRow.swift` and its derived id went. Missing checkouts are kept
  once in `RowFlags` (a set with per-row observed cells) instead of a set plus a mirror. No test
  deleted; added `RowFlagsTests`. Snapshots in `build/refactor-3c`: only `marks.png` differs from
  `build/refactor-3b` (known variant). The brief's identity grep also matches `SignalOperatorRow`.
- 3d: the iTerm2 banner says what a person can act on: "iTerm2 isn’t running." with Open iTerm2,
  "iTerm2 refused AiTerm." with the Automation steps, "AiTerm isn’t connected to iTerm2." with Open
  Settings (after a ten-second grace), or "AiTerm’s helper isn’t working." (starting and unreachable
  after the grace, missing, Python, failing, mismatch at once); nothing while starting or connected.
  `DaemonBanner` became `ConnectionBanner`; `.itermReconnecting` became `.itermNotRunning` (from the
  cookie answer). Test deleted: `everyStateButConnectedKeepsItsBanner` (behaviour deleted; survivor
  `connectionBannersNameActionableProblemsAfterTheirGrace`); added `ConnectionBannerTests`.
  Snapshots in `build/refactor-3d`: only `sidebar-banners.png` changed (the four new states, the planned
  change; the brief's Proof said three, its Change four). Fix round 1: the gate failed in
  `SidebarScrollTests.scrollingContentStaysBelowTheTrafficLights`; with no always-present startup
  banner the sidebar `List` extended into the titlebar's safe area, so the list is now hosted in a
  small `NSHostingView` with no safe-area regions (`SidebarListViewport`). Keyboard, redraw-budget and
  snapshot tests are unchanged and green; the wrapper rebuilds an `AnyView` on each update, which the
  phase review should weigh.
- 3e: `docs/windows.md` rewritten for the closed view in the brief's nine sections; the alert lines
  in `docs/keyboard.md`, the "No window open" paragraph in `docs/status-model.md`, the `window.closed`
  row in `docs/daemon-protocol.md` and the window paragraph in `docs/architecture.md` follow.
  Differences, the code being the truth: a row chosen while iTerm2 isn't connected opens and comes
  forward by itself once iTerm2 connects if it is still selected (the brief said choose it again);
  a failed open's banner names the row only for a terminal. The brief's grep still matches one
  `docs/status-model.md` sentence about the Codex rollout read's one-second bound (not about windows).
  Left for 4b: `TaskRemoval.swift:9` mentions a "Couldn’t reopen" caption that no longer exists. One
  of the implementer's plain gate runs failed once in `HTTPJSONTests.aCancelledRequestStaysCancellationThroughMapping`
  (30 seconds, load average near 5); it passed alone and in the orchestrator's next plain run.
- Phase close, review round 1 (Codex, `main..HEAD`): one Important finding, confirmed in the code:
  after iTerm2 crashes (no `window.closed`), rows keep stale window ids, and choosing one raised the
  stale window instead of starting iTerm2. Fixed by the 3b implementer: while iTerm2 is not synced,
  choosing a task, terminal or the Operator chat starts iTerm2 and remembers the row whatever its
  saved window, and raises nothing; the connected snapshot then clears or adopts the window and the
  row is chosen again. Added `OpeningRowControllerTests.aRowWhoseWindowWentWithACrashedITerm2StartsItAndOpensOnceItConnects`;
  four tests that raised windows without ever sending a snapshot now send one first. Left: a peek
  (arrow keys) at a stale window while unsynced fails quietly.
- Phase close: review round 2 (with the triage): no findings, "ready". Plain `scripts/test.sh all`
  green on `12e69c93` (after the fix; also green on `ff00e600` before it). Snapshots in
  `build/refactor-phase3` against `build/refactor-phase2`: only `sidebar-banners.png` (3d, planned)
  and `marks.png` (known variant) differ. No bundle check is due after phase 3. `main` had only the
  refactor's own merges; merged to `main`. No manual check is owed for phase 3 by the plan; the smoke
  run after phase 9 covers the closed view.

### Phase 4

- 4a: every task lifecycle operation (archive, restore, remove, keep and delete branch, remove from
  the Archive, `perform`, `removeSelection`) is `async` and returns once its work is done; no product
  function returns a `Task` handle for a test, and `waitForRemoval` and the remover's `running` map
  went. Tests join by awaiting the call, or hold it at a port latch in a task of their own (a new
  `WorktreeAddHeldGit` in `ArchiveTests` for the restore races). No test deleted. Assertions that read
  a nil handle now assert the effect. Differences: restore's choosing lives in
  `AppController.restoreFromArchive`, which became `async` and awaits it; `perform(.rebaseDefault)`
  awaits the rebase; about 90 call sites, not 200. `docs/testing.md` says how lifecycle tests join.
- 4b: Remove asks everything before it acts: the Remove alert, the unlisted-folder and unsaved-work
  questions, then the unmerged-branch question (Delete Branch / Keep Branch, asked only when the box
  is ticked and the branch is on neither its base nor its upstream), and only then closes the window,
  removes the worktree and deletes or keeps the branch; a branch git still refuses is kept and said in
  the toast, and the row goes. A row with a window and no helper is refused ("Not removed: iTerm2
  isn’t connected"), as Archive refuses it. The "worktree removed, waiting for a retry" state, its
  banner actions (Keep, Delete), `BranchRefusal` and `awaitsRetry` went; the archived row's Remove
  asks the same branch question. Tests deleted with their behaviour: nine retry tests in
  `OperationIssueControllerTests`, `ArchiveControllerTests.aRowWaitingOnItsRemovalsRetryIsNotArchived`,
  `RowAccessibilityTests.aRowAwaitingItsRemovalsRetryOffersRemoveAlone`, two `OperationIssueTests`;
  `TaskWorkflowTests.removalRetainsUnmergedBranchAndRetryOnlyDeletesBranch` replaced by
  `anUnmergedBranchIsKeptAndSaidSoAgreedItIsDeleted`. Survivors and new coverage: the new
  `RemoveTaskControllerTests` (seven cases on real git) and
  `aBranchHasUnmergedCommitsOnlyWhenNeitherItsBaseNorItsUpstreamHasThem`. Differences: the toast no
  longer doubles a full stop after git's sentence; `closeWindow`'s `requiringDaemon:` went since every
  caller passes true; a workspace that locks while the branch question is up stops Remove with
  nothing changed. Snapshots in `build/refactor-4b`: the removal caption in `sidebar-removal*.png` and
  the second banner in `sidebar-banners.png` (a diverged pull with Rebase replaces the deleted
  branch-kept banner) changed, as the step implies. Environment: this capture carries no Display P3
  profile while earlier ones did (the display changed while the maintainer was away), so raw RGB
  differs on 48 files; converted to sRGB, every other file is within 16 per channel.
- 4c: one teardown owner, `TaskTeardown`, for archive and remove over one prepare and one run, with
  consent as a policy (`.ask`, or `.refuse(stillAllowed:)` for the Operator's automatic archive and
  remove) and one per-row state that the row, the Dock badge and the checkout monitor read.
  `TaskRemover`, `WorktreeTeardown` and `AutomaticCleanup` went (the archiver keeps only restore), and
  with them the remover's dictionaries and `recordCleanups`; a task on its way out is filtered once,
  in the projection (`needingAttention(skipping:)` went). No test deleted; added three refusal
  tests in `SignalAutomaticCleanupTests` and `aLeavingTaskIsNotWaitingOnYouNorCountedUnderAFoldedHeading`.
  Snapshots in `build/refactor-4c` byte-identical to `build/refactor-4b`. Differences: a missing
  checkout whose window cannot close for lack of a helper is skipped until the helper is back
  (instead of a "Closing" state that would flicker each pass); Archive's intermediate "The stage
  changed before archiving." refusal went, the later check still catches it; `removeArchived` does not
  throw. Noticed and left: Focus View's fold layout can still count a leaving task.
- 4d: one restore (`TaskLauncher.restore`: git, then the row back from the archive; `AppController.restoreFromArchive`
  adds the alert, project, toast and the choose a person asked for), one worker checkout for an item
  (`TaskLauncher.checkOutWorker`, the request path with its fork refusal or the default-branch path,
  with the late save before a refusal) and one window opener (`TaskLauncher.open`, whose commands
  depend on ownership: a driven task resumes its first worker under its guard). The Operator's stage
  launch and a person's click call the same operations through new `restore` and `checkout` ports;
  `TaskArchiver` and `SignalWorkerIO`'s prepare, request checkout, restore and reopen went. No test
  deleted; added `TaskWorkflowTests.aRequestCheckoutIsItsSourceBranchInAReviewWorktreeBasedOnItsTarget`,
  `ArchiveControllerTests.theLaunchersRestoreBringsTheRowBackSavedNeitherChosenNorToastedItsProjectFoldUntouched`,
  `SignalWorkerIOTests.aRequestStageChecksOutItsSourceBranchAndRefusesAFork`. Review round by the
  orchestrator: `StageRunner`'s second save of the checkout after `prepare` went (callers save
  nothing); the test `prepare` stubs save what they change, as the real port does. Differences: the
  taken-over opener already holds the task's token, so the checkout takes only the project's
  (`taskHeld`); a driven task without a checkout that is not launching opens nothing on a click instead
  of saying it has no conversation.
- 4e: Take Over makes an ordinary task: `AppState.takeOver` removes the signal record, sets the task's
  own `takenOver` mark (saved only when true; the key the reset script writes), opens the project and
  withdraws the task's questions and paused workers; `TaskLauncher.takeOver` saves, rewrites the
  recorded guard scopes once (ownership + 1) and makes the worktree when the task has none. A marked
  task is never continued or adopted by a match. The taken-over opener, its checkout copy, its resume
  commands, `SignalAction.takeOver`, `SignalTask.takenOver` and the `.takeOver` issue source went.
  Fixture re-recorded: `operator-signals/state.json` with `AITERM_RECORD_SIGNAL_STATE=1` (both
  records lose `takenOver: false`, a taken-over task with `takenOver: true` is added), provenance
  section added; the reset script's guard passed on it. Tests deleted: two `ItermFocusControllerTests`
  taken-over opener tests (survivors: phase 3's latest-click and tagged-window journeys),
  `SignalOperatorIssueTests.aTakeOverWhoseJournalCannotBeWrittenShowsAtOnce` and
  `OperatorIssuesTests.aPersonStartedActionNeedsYouAtOnceUntilThatSameActionSucceeds` (behaviour
  deleted), the `.takeOver` cases in `SignalDomainTests`. Added three Core tests (not continued or
  adopted; record removed and hold withdrawn; the mark round-trips). Snapshots in `build/refactor-4e`
  byte-identical to `build/refactor-4c`. `docs/operators.md` and `docs/windows.md` follow. Noticed and
  left: with `.takeOver` gone every `OperatorIssues.Source` is retried, so its non-retried branch and
  doc are dead (for 5d or 5h). From this step on, the installed app and this branch cannot read each
  other's Operator records: run `scripts/reset-operator-state.sh` with AiTerm quit before switching.
- Phase close, review round 1 (Codex, `main..HEAD`): (1) Important, confirmed: a Take Over while the
  stage's request checkout was still reading the request over HTTP left the task with no worktree
  and no banner (the stage's checkout saw the revoked claim before `git worktree add` and stopped).
  Fixed by the 4e implementer: the checkout's checks before git also pass when the task was taken
  over meanwhile (marked, same project and branch), so it finishes for the person; the final check
  still refuses the Operator, so no worker launches. Added
  `SignalWorkerIOTests.takeOverWhileTheStageReadsTheRequestStillLeavesTheTaskItsWorktree` (fails
  without the fix). (2) Minor, listed: choosing an ordinary task with no worktree says nothing; after
  fix 1 that is only a refused fork request, whose refusal banner was already shown. One plain gate run
  of the implementer failed once in `ItermFocusControllerTests.aTakenOverRequestOpensItsSourceBranchAndRefusesAFork(fork: false)`
  (21 seconds, no reason printed; the expectation now carries the banner's reason as its message);
  the next runs, including the orchestrator's, were green. Left: a fork found during the stage's read
  after a Take Over gives no banner (two unlikely things at once).
- Review round 2: the same race with a failing request read (HTTP error, timeout) still left the
  taken-over task with no checkout and no banner. Fixed by the 4e implementer: a checkout that fails
  after its task was taken over meanwhile reports "The task is yours, but its worktree couldn’t be
  made." on the task, once, in `checkOutWorker` (this also covers a fork found during that read). The
  round-1 test runs for a 200 and a 500 answer (`readFails:`).
- Review round 3 (the last allowed): two new Important findings, both confirmed and fixed (fix round
  3, by the 4d implementer), verified by the orchestrator's reading of the diff and the gates, with no
  fourth review round: (1) the shared task opener from 4d dropped the daemon's `commandError`, so a
  window whose resume command iTerm2 could not type showed a bare shell with no reason;
  `createTaskWindow` now returns `WorkerOpening` (id and command error) from its one decoding and the
  opener reports "Reopened the window, but not every conversation." or, for a driven task, "…but its
  worker didn’t resume." on the task (test `RowWindowsControllerTests.aWindowWhoseCommandWasNotTypedIsAdoptedAndSaidOnItsTask`,
  `DaemonClientTests.aTaskWindowWhoseCommandWasNotTypedReadsItsIdAndWhy`); (2) with a task's tabs in
  two windows, Remove closed one, the row adopted the other, and the task was forgotten with that
  window running; the teardown now closes every window the task holds (its own and each window one of
  its tagged tabs is in) before git runs (test `RemoveTaskControllerTests.aTaskWithTabsInTwoWindowsHasBothClosedAndItsRowAndWorktreeGo`).
  The same round fixed the race behind the two intermittent failures of
  `ItermFocusControllerTests.aTakenOverRequestOpensItsSourceBranchAndRefusesAFork`: a checkout scan
  adopted the test's local `origin` as the project's remote before the request lookup; the test's
  scanner now returns no remotes (five green runs in a row). Noticed and left: `TaskLauncher.create`
  also ignores a `commandError` (a new task's agent that iTerm2 could not type says nothing, as before
  the refactor); `openWorkerWindow` and `createTaskWindow` could merge (6c).
- Phase close: plain `scripts/test.sh all` green on `dc7e5f7e` (after review fix round 3; also green on
  `cd9278a8` before the review fixes). Snapshots in `build/refactor-phase4` identical to
  `build/refactor-4b` (no view changed after 4b). No bundle check is due after phase 4. `main` had only
  the refactor's own merges; merged to `main`. No manual check is owed for phase 4 by the plan. From
  this merge on, `main` and the installed app cannot read each other's Operator records: run
  `scripts/reset-operator-state.sh` with AiTerm quit before switching between them.

### Phase 5

- 5a: every phase change goes through `SignalTransitions`, with new actions `launchFailed` and
  `adopted` for the failed launch and the recovered worker; the unreachable `stopped` phase (a saved
  one decodes as `.unknown`), the `stop` action and the unread `edges` history went. One claim check,
  `SignalClaim.allows(in:)`, covers workspace, cancellation, pause, signal enabled, configuration and
  phase; the repeated pause checks went. Fixture re-recorded: `operator-signals/state.json` with
  `AITERM_RECORD_SIGNAL_STATE=1` (only the two empty `edges` arrays removed), provenance section added.
  Test deleted: `SignalRetentionTests.repeatedStagesRetainOnlyTheNewestTransitionTail` (behaviour
  deleted; its ownership count survives in `blockAndResumeRespectAuthority`). Added
  `SignalClaimTests`, three `SignalDomainTests` and
  `SignalEngineTests.aLaunchErrorAfterTheStageWasBlockedLeavesTheFirstReason`. Noticed and left: the
  doc comment of `LaunchAttempt.workerPending` names a `WorkerStarter.checkLaunches` that no longer exists.
- 5b: a task's record holds its current stage whole (`SignalTask.current: SignalStage`, whose
  `configuration` is always present); the `configuration ?? signal` fallbacks and the field-by-field
  stage copy went; `continueStage` makes the first pending stage the current one; one
  `Question.isPending` rule. Fixture re-recorded: `operator-signals/state.json` with
  `AITERM_RECORD_SIGNAL_STATE=1` (both records move signal, item, configuration and prompt under
  `current`, which gains `matchedAt`; nothing else), provenance section added. No test deleted; added
  two `SignalDomainTests` and `SignalRetentionTests.aQuestionIsPendingWhileOpenOrWhileAWorkersAnswerIsUndelivered`;
  new test builders `Signal.make` and `SignalTask.make`. Snapshots in `build/refactor-5b`
  byte-identical to `build/refactor-phase4`. Differences: two refusals for a missing signal now read
  "The task is no longer the Operator’s." for a task with no record (no test, fixture or doc names
  them); the drawn copy always carries the configuration. Found, not this step's: the signal sidebar
  snapshot fixtures (`Snapshots/SignalSidebarSnapshots.swift`) use real people's names as reviewers,
  in a public repository; changing them changes drawn pixels, so it is left to the maintainer.
- 5c: one Oracle owner, `OracleConsult`: one `consult(_:binding:continuing:)` with a kind
  (`OracleLaunch.Question`), a claim binding and a round limit, returning agreed, critique, the
  person's call, unavailable or retry. Worker answers, agent choice, the merge veto, `ask_oracle` and
  the shell gate all go through it; every prompt and parser lives in `OracleLaunch` (byte for byte,
  proven by new Core prompt tests); a settings or standing-instructions change discards the answer and
  retries; only finished rounds are saved (`OracleRound.Stage` lost `running`), so a crash leaves no
  in-flight marker. `OracleRoundLedger` and `SignalOracleSettingsChanged` went; one
  `JSONValue.canonicalJSON()`. Fixture re-recorded: `operator-signals/state.json` (the sample round
  is now a delivered critique), provenance line added. Model-facing strings changed: `answer_worker`
  and `ask_oracle` return `{"status":"retry", ...}` when settings changed mid-check (before: to the
  person / "could not answer"); the shell gate denies with "The Oracle settings changed. Check this
  command again." when the Oracle was switched off while it read (before: allowed unchecked); two
  flush errors now say "The question couldn’t be saved." and "The choice couldn’t be saved." (orchestrator
  review round). No test deleted; added `OracleConsultTests` (8), prompt and parser tests in
  `OracleLaunchTests`, and three held-check tests. Differences: the code's names (`unanswered`, "unchecked")
  were kept over the brief's; a person marker now replaces the round it continues; the round-limit check
  in `QuestionRounds` went (nothing at the limit is saved). Left for 5f: the merge veto still sets
  `currentAct`.
- 5d: the controller composes owners and runs one ordered reconcile (678 to 445 lines; the rest is
  owner construction and wiring): `OperatorWaker` owns waking, `OperatorChat` the chat's window and
  session (keeper, open, close), `ActivityWriter` the activity log and the issue record; retention is
  `AppState.pruneOperator(at:)` and `withdrawObsoleteQuestions(at:)` in Core. With Take Over gone,
  `OperatorIssues.Source.retried` and the non-retried branch went. No test deleted; added two
  `SignalRetentionTests`. Differences: the chat's opener was `openChat()` (3b), now `OperatorChat.open()`;
  the chat's parameter is labelled `wakeWaiting:` (the brief's grep matches `wakePending`). Left: `ItemRouter`
  also prunes seen items. The orchestrator's first plain gate failed once in
  `SignalWorkerIOTests.takeOverDuringARequestCheckoutKeepsItsFolderAndBaseBranchWithoutLaunchingAWorker`
  (its wait for the checkout reaching git timed out at a load average near 10); the rerun was green.
  That test is timing-sensitive on a loaded machine.
- 5e: one tick: `reconcile()` (name kept) runs the settings step, then the poll step (`poller.tick()`,
  even while iTerm2 is not connected), then the host watch when due, then 5d's steps; the per-host poll
  loops and `TickPass` went. One in-flight set per task, `OperatorInFlight`, shared by stage, Then,
  delivery, question and agent-choice rounds and the tool handler's message and open_tab; `busy` is a
  pure question and the live-work set is computed once per tick. The 180-second grace is
  `OperatorTiming.openingGrace`. No test deleted (`TickPass` behaviour stays in
  `SignalPollerTests.stopDropsALateReadAndOverlappingTicksStartNoDuplicate`); added five tests
  (tick polls while iTerm2 is away, a save mid-tick reads the edited signal, a worker-answer round
  holds its task, a stage queued during Then waits, busy has no side effect). Differences: a signal
  edited outside Save also polls at once (as before); `canPoll` also requires the workspace to be
  changeable. Two older test races, exposed under load (load average up to 10.6), were fixed test-side
  in this step after the gate went red: (attempt 1) attaching the daemon starts a checkout pass that
  adopted the fixture repository's real remote (none) over the declared GitLab remote, so a request stage
  that read the project afterwards refused before git; the three request-stage tests now use a scanner
  that keeps the declared remote and await the attach's pass; (attempt 2) tests that swap the workspace
  backup for a directory raced the teardown's debounced save; `ArchiveTests`, `CheckoutCleanupTests`
  and `ScratchController.breakSaving()` now flush first. Five filtered runs of each and the plain gate
  were green.
- 5f: the chat's lifecycle is one saved state, `OperatorSession.lifecycle` (idle, opening,
  `open(since:wake:)`, `closing(then:)`, `revoking(then:)`, unknown) with its generation; the saved
  `startingFresh`, `finishing`, `handover` and `wakeAwaitingRead`, and the runtime open record, waker
  flags and Oracle in-flight count went; one idle rule (`OperatorSession.chatIsIdle`). Retirement and
  renewal both advance the generation (asserted by `aMatchDuringTheLastChatsCloseStartsFreshAndIsNotLost`).
  A row's current activity is runtime-only (`OperatorActivityTracker.acting`), out of the saved task
  and `run_status`. Fixture re-recorded: `operator-signals/state.json` (`startingFresh` out, `lifecycle`
  in), provenance section added; `brief.md` and `tools.json` unchanged. Model-facing: `run_status`
  `tasks[].currentAct` removed; the two flush errors from 5c's review round went with the act's flush.
  No test deleted; added `OperatorLifecycleTests` and four keeper, activity and issue tests. Snapshots
  in `build/refactor-5f` byte-identical to `build/refactor-5b`; the Operator section poses are
  hosted-only (they need `AITERM_SNAPSHOT_HOSTED=1`, which opens windows), so they were not compared
  here: for 9c. Behaviour notes: retirement also waits for tracked acts, an unread wake and a window
  holding one tab (the one idle rule); an open chat closed before its conversation was recorded no
  longer reopens by itself.
- 5g: the tool handler's ledger is the only ledger of calls: `answer_worker`'s second ledger entry and
  its running set went; the wake acknowledgement (a scoped `run_status` refused while a wake is unread,
  a global one acknowledging it) moved into the handler; the controller routes `gate_command` to the
  shell gate and everything else to the handler. The record rules stay with their owners. The
  launch-time agent switch at the weekly limit and `open_tab`'s choice of rows moved to
  `AgentChoiceRounds` (decided at choice time, never for a tab or a stage with a saved conversation).
  Changed refusal texts: reusing an `answer_worker` key with other arguments now says "This key already
  names a different call. Use the original arguments to retry." (was "This key was already used for a
  different answer."); a failed save of its result says "The tool result couldn’t be saved." (was "The
  answer couldn’t be saved."). Tests deleted: `SignalQuestionRoundsTests.agreementAnswersOnceAndTheSavedKeySurvivesARestart`
  (survivor `SignalToolHandlerTests.anAgreedWorkerAnswerReplaysAfterARestartFromTheHandlersLedgerAlone`),
  `SignalWorkerIOTests.onlyAFallbackRowMovesOffAnAgentAtItsWeeklyLimit` (survivor of the same name in
  `SignalAgentChoiceTests`); added `onlyAGlobalStatusAcknowledgesAnUnreadWake`. No fixture changed.
  Noticed and left: `OracleRound.askedArguments` is written and never read.
- 5h decision (orchestrator, before implementation): Codex stopped because 5h's shared helper for
  kind-tagged enums throws "Missing … value" while 5f's `OperatorSession.Lifecycle` (written after the
  5h brief) decodes a known kind with a missing or invalid value as `.unknown(raw)` and keeps its bytes,
  protected by `OperatorLifecycleTests`. Decided within the plan's intent (the workspace file tolerates
  what it does not know; 5f's behaviour is decided and tested): the lifecycle keeps its behaviour. The
  helper applies the brief's rule to the enums the brief lists; the lifecycle uses the helper only if
  the helper can express "missing or invalid value becomes `.unknown`", else keeps its own decoder.
- 5h: `Operators/Signals/` regrouped by concept into fourteen files with the source readers beside
  them (`AiTermCore/Signals/` gone); one helper for kind-tagged enums and one for open string enums
  (`SavedEnums.swift`, bytes unchanged, pinned by the new `SavedEnumBytesTests`), with the lifecycle's
  unknown-value policy expressed through the same decoder (the decision above); one JSON-lines appender
  (`JSONLines.swift`) for the activity log and the journals; `DeliveryCheck`, `AgentVersions`,
  `ClosingWait` and the merged-branch check moved to their homes; the task row's Operator wording is
  built in Core (`OperatorLine+Task.swift`). Saved bytes and every snapshot unchanged. Tests deleted:
  `ActivityLogTests.aMalformedLineIsSkipped`, `aTornLastLineWaits`, `aMissingFileIsEmpty` (the product no
  longer reads the activity log; survivors in the new `JSONLinesTests`, `SignalJournalRecoveryTests`).
- Phase close: plain `scripts/test.sh all` green on `572d5035`. Snapshots in `build/refactor-phase5`
  identical to `build/refactor-phase4`. Review round 1 (Codex, `main..HEAD`): one Important finding,
  confirmed: while the automatic merge's Oracle veto held a working task, a `finish_stage` with outcome
  blocked or failed still went through (the block transition ignores the held flag) and the merge then
  proceeded on the blocked stage. Fixed by the 5e implementer: `StageRunner.finish` refuses any result
  while another effect holds the task, and the merge's checks after the veto require the phase it
  started from. Added `SignalWatchTests.aStageResultIsRefusedWhileTheMergeHoldsItsTaskAndTheMergeGoesAhead`
  and `aStageBlockedWhileTheVetoIsOutStopsTheMerge` (each fails without its fix). Noticed and left: a
  `SignalTransitionError` reaches the Operator as Foundation's generic "The operation couldn’t be
  completed." (no description of its own; older than this phase; giving it words changes Operator-visible
  text, so it is left for the maintainer).
- Review round 2: the same gap one step earlier, confirmed: a block during the watch's first host read
  (before the merge claims the task) was taken as the phase the merge started from. Fixed by the 5e
  implementer: the watch captures the phase before the first read (only working or watching) and every
  check from the read on requires the stage still in it. Added
  `SignalWatchTests.aStageBlockedWhileThePassReadsTheRequestIsNeverMerged` (fails without the fix).
- Review round 3: no findings, "ready". Plain `scripts/test.sh all` green on `e90cbbb1`. No bundle
  check is due after phase 5. `main` had only the refactor's own merges; merged to `main`.
- Owed to the maintainer for phase 5: the live Operator eval (`AITERM_LIVE_OPERATOR=1`): the Oracle's
  prompts moved into `OracleLaunch` (byte for byte), `answer_worker` and `ask_oracle` can now answer
  `retry`, the shell gate denies when the Oracle was switched off mid-read, `run_status` lost
  `tasks[].currentAct`, and two refusal texts of `answer_worker` changed (5c, 5f, 5g). Also for 9c: the
  hosted-only Operator section snapshot poses (they need `AITERM_SNAPSHOT_HOSTED=1`, which opens
  windows) were not captured during this phase.

### Phase 6

- 6a: one ordered work list per session (`work: [WorkItem(kind, text, holdsTurn)]`, built by the
  daemon's `work_items`), replacing `background`, `displayWork` and `legacyIndex`; the app's merge went
  and every reader (sidebar card, worker tabs, digest, live work) reads `work` and `holdsTurn`.
  `BackgroundJob.task_id` now compares. Fixtures re-recorded: `daemon/tests/wire/` with
  `AITERM_UPDATE_WIRE_FIXTURES=1` (only the four session payload frames changed), provenance paragraph
  added; `docs/daemon-protocol.md` and `docs/status-model.md` follow. Tests deleted:
  `test_same_text_refreshes_internal_identity_without_a_spurious_wire_change` (behaviour deleted),
  `DaemonTypesTests.displayWorkDistinguishesUnavailableAndKnownEmptySources` (replaced by
  `aSessionReadsItsWorkInOrderWithWhatHoldsTheTurn`), `SidebarModelTests.displaySourcesPreserveStopOrderAndNeverDecideStatus`
  (replaced by `theCardIsEveryTabsWorkAndOnlyWhatHoldsATurnDecidesStatus`); five display tests rewritten
  on `work`; added two status tests and `WorkerTabsTests.onlyWorkThatHoldsTheTurnKeepsAWorkerAtWork`.
  Differences: the brief's grep matches its own prescribed provenance wording; its "all three in the
  Stop's order" case is not reachable, the test asserts what happens. Behaviour note: a Stop shell the
  reader still lists now holds the turn mid-turn, so a needsInput tab with such a shell counts as at
  work (the brief's decisions accept this kind of difference).
- 6b: the app owns its helper: a helper still holding this socket (matched by the exact
  `aitermd run --socket <path>` command line) is ended (SIGTERM, then SIGKILL after the grace) and the
  app starts its own at once; a held socket with no such holder is a failed launch through the backoff.
  Adoption, the held status, the mismatch hold and the unreadable-line limiter went; the stop in
  `scripts/run-dev.sh` went (not run). Tests deleted with their behaviour: two supervisor adoption tests
  and two connection mismatch-hold tests; added `testOnlyAHelperOnThisExactSocketIsStale`,
  `testAStaleHelperHoldingTheSocketIsEndedAndTheChildStartedAgain` (a stand-in process on a scratch
  socket) and `testAHeldSocketWithNoStaleHelperIsAFailedLaunchRetriedThroughTheBackoff`. Docs and
  `docs/workflow/verify.md` follow. The brief's grep for "adopted" still matches other concepts
  (windows, workers, worktrees, remotes, the chat). Left: `SessionAgent`'s lenient-decoding doc cites
  adoption; the daemon and the app both launch iTerm2 at start.
- 6c: one method per daemon command returning its full reply (`Opening` with id and command error for
  windows and tabs; the worker-only openers and creation conveniences went); `workspace.snapshot` is
  the connection's own (`DaemonConnection.refresh()`, also used by Settings); callers that only want the
  tabs use `sessions()` (`sessions.list`, which now ticks first and answers the last registry if the tick
  fails, with no event in the app). Wire frames unchanged. No test deleted
  (`test_snapshot_survives_a_failing_tick` became `test_session_queries_survive_a_failing_tick` for both
  queries); added a session-list freshness test and refresh and tab-error tests.
- 6d decision (orchestrator, mid-step): Codex stopped because a repeated StopFailure with the same
  error keeps the old timestamp (`StoppedOn.at` is `compare=False` and `SessionRegistry._set` skips
  equal values), so a session key built from it could not tell two such stops apart, which the
  hand-written `is not stopped_on` identity check did. Decided within the step's intent (one session key
  that changes with each new stop): the registry records a new StopFailure's timestamp even when its
  error is the same, and the key includes it; the wire stays byte-identical if that can be kept, and if a
  repeated stop then announces a change, that is accepted (a real new event) with the frames re-recorded
  and a provenance line.
- 6d: readings carry one `SessionKey` (agent, job pid, conversation, the reader's extras) and are
  dropped generically in `Service.observe` when it changed (a whole-registry plan also when the
  session set changed); the six hand-written identity checks and `Turn.generation` went. Per the decision
  above, the registry records each StopFailure's timestamp while announcing only a changed wire value,
  so two stops with the same error give two keys and the wire is byte-identical. No test deleted; added
  the same-error regression, partial acceptance across two sessions and whole-plan cases. Tick budgets
  unchanged (an extra registry sort was avoided with a session-id lookup).
- 6e: one owner for Codex thread identity, `CodexThreads`: restored from the tab's tag at each
  snapshot (validated there), bound by hooks placed by evidence, asked by the readers, written back to
  the tag after the tick (once per new thread). The resolver only places posts and keeps pins; the
  registry no longer reads the tag. Tag format and wire unchanged. No test deleted; four Codex thread
  tests moved to the new `test_codex_threads.py`, plus `test_a_thread_restored_after_a_helper_restart_is_not_written_again`.
  Behaviour note: at a helper restart, each Codex tab restored from its tag gets one `session.changed`
  after its `session.opened` (identical payload).
- 6f: `aitermd/agents/` holds `claude.py`, `codex.py` and `pi.py`, each mapping its readings to
  `status.Evidence`, which `StatusEngine.apply_evidence` takes as the one tick entry point. The per-source rules sit in
  `_apply_state`, keyed by source, and the freshness ordering is unchanged. `apply_claude_progress` became
  `apply_progress`; `Harness.corroboration` and the six old modules went. Wire and compat captures are unchanged, and
  no assertion changed. Differences from the brief:
  - Its third Done-when grep cannot be empty as written: `\.corroboration\b` matches the two imports of the
    `corroboration` module the brief keeps. `corroboration=` and `_corroborate` have no hits.
  - The Codex thread capture moved out of the snapshot pass into `codex.tab_threads`. The service calls it right
    after the pass with no await between, so the timing is the same.
  - The rollout read failure now logs on `aitermd.agents.codex`, still under the `aitermd` handler.
  - Each plan function takes only what it uses.
  - The title evidence's time is the readers' clock, read once per snapshot (the same clock).
  Tests deleted: the `h.corroboration` assertion in `test_models.py` (the field is gone). Which agent gets which tick
  reading is still proved by `test_service.py` `test_tick_uses_claude_file_status_and_agent_exit`,
  `test_a_title_only_change_is_not_broadcast_yet_still_drives_a_codex_turn` and
  `test_tick_recovers_codex_completion_without_stop_or_seen_spinner`. Added: one mapping test each for Claude file
  status, the Codex title and the rollout boundary, plus the idle Claude-file "done" no-op. The step's bundle check
  passed (it holds `aitermd/agents/`).
  Noticed and left: `scripts/make-app.sh` does not clear `daemon/build/lib`, so a bundle built in a tree that once
  held the deleted modules still carries them, unimported. `docs/status-model.md` names `Service._apply_trust_prompts`
  (stale before this step; for 9a).
  Gate: the first plain run failed once in `GitLabClientTests.aCancelledRequestThrowsCancellation` (Swift, untouched
  here; it took 20.9 s under load, and the implementer's own run passed it); the rerun was green.
- Phase 6 gate: plain `scripts/test.sh all` green on `71ebf7ee` (daemon 1522 passed, 1 skipped). Snapshots in
  `build/refactor-phase6`: these captures carry the Display P3 profile again, so they compare with
  `build/refactor-phase3`, the last capture made with that profile (against phase 5, 47 images differ across the
  whole frame). Against phase 3 only the changes already recorded in 3d and 4b differ (`sidebar-banners.png`,
  `sidebar-removal*.png`), plus the known `marks.png` variant: phase 6 changed no snapshot. Bundle check
  (`scripts/make-app.sh` after clearing `daemon/build`, then `scripts/test-app-bundle.sh build/AiTerm.app`) passed.
- Review round 1, Important, confirmed: after an app crash the orphaned helper still accepts on the socket while
  the new child imports, so the 20 ms readiness probe reported `.listening`. The app then connected to the old
  helper before the child's exit 3 replaced it, which 6b's ownership forbids. Fixed by an Opus implementer:
  `SocketProbe.listenerPid` reads the listener's pid from the kernel (`LOCAL_PEERPID`), and the supervisor reports
  `.listening` only for its own child. Added
  `DaemonSupervisorTests.testAStaleHelperServingTheSocketIsNeverReportedAsTheChildListening`, with a real listener
  as the orphan (it fails without the fix).
- Review round 2: no findings, "ready". No check is owed to the maintainer for phase 6 beyond those already
  listed.
- Plain `scripts/test.sh all` green on `a42ce392`. `main` had only the refactor's own merges; merged to `main`
  (`6f6628db`).

### Phase 7
- 7a: one `HostRepository` protocol with its operations grouped by caller, and one factory,
  `CodeHosts.repository` (from `Connection.repository(session:)`, the only switch that builds a client). The
  `MergeRequestSearching`, `MergeRequestPublishing` and `SignalHostReading` protocols went. `request(number:)` is the
  one read by number; the Operator's watch uses it instead of a text search. Small differences: the brief's
  locations had drifted (`HostRepositoryTests` was already the publisher tests, the worker checkout is in
  `TaskLauncher.checkOutWorker`, and `SignalHostReading.swift` was under `Operators/Signals/Sources`); the publisher
  enum and the client `repository` property were already gone after 1b. Tests deleted:
  `aHostThatIsNotConnectedOrAnotherGitLabIsRefused` and `aRemoteOnNoConfiguredHostIsUnavailableNotGuessed`
  (duplicate refusals), whose survivor is `CodeHostsTests.eachRefusalSaysWhy` (plain-git and local remotes
  included). The rest of `MergeRequestSearchTests` moved to `CodeHostsTests`, and
  `searchAndRequestReadsAskTheSameConnection` became `HostRepositoryTests.repositoryBindingUsesTheResolvedConnection`.
  Added: `request(number:)` on both hosts (found, absent, real failures throw) and a bare-number search making the
  same single request.
- 7b: the badge counts the strict `threads(of:)` (the lenient reader, its ten-page bound and option pairs went).
  One `JiraClient.search(jql:limit:pageToken:)` with one field list and one mapping (25 a page for the picker, 100
  for signals). `HostDate` holds the formatters, built once. `GitLabConfig.serves(_:)` compares host and port for a
  web address, and `matches(remoteHost:)` compares host only for a git remote. Small difference: the 50-page
  cap tests the brief placed in `MergeRequestPublisherTests` are in `HostRepositoryTests`. Tests deleted:
  `GitHubClientTests.reviewThreadsStopAtTenPagesToo` and `GitLabClientTests.reviewThreadsStopAtTenPages` (the bound
  is gone; survivors `HostRepositoryTests.gitHubThreadsPastTheCapAreNoAnswer` and
  `gitLabThreadsPastTheCapAreNoAnswer`), and `ReviewThreadsReaderTests.aMergeRequestOnAnotherPortIsNotAskedOfTheConfiguredGitLab`
  (its cases moved to `GitLabHostRuleTests.webAddressesCompareHostAndPort`).
  `reviewThreadsReadEveryPageUntilAShortOne` became `...UntilAnEmptyOne`. Added `GitLabHostRuleTests`,
  `HostDateTests`, the Jira field-list parity test and the malformed-entry completeness test.
- 7c: one `status(of:)` per request on each host (`RequestStatus`: the request, its head and readiness from one fetch of the
  request, GitHub's check lists asked at that fetch's head, and approvals from their own listing, as before). Merge readiness is
  `MergeReadiness.gitHub(_:)` and `.gitLab(_:)`, pure rules over `GitHubPullFacts` and `GitLabMergeFacts`, with every
  reason word for word. `readiness(of:)`, `state(of:)`, `reviewers(of:)` (with its `/requested_reviewers` request) and
  `MergeRequestState` went; "someone is asked to review" is `MergeRequest.hasReviewer` (users or GitHub teams). The
  merge floor is unchanged. Differences from the brief: `MergeRequestPublisherTests` does not exist and the
  `RequestWatch` tests are `SignalWatchTests`; `HostRepositoryTests` also called `readiness(of:)` and was adjusted;
  `deleteMergedBranch` had no coverage, so `SignalHostIOTests.aMergedBranchLearnsItsMergedHeadFromTheStatus` was
  added; checks of a pull that is not open are `.notListedWhole` (never read by the rule then). Behaviour note: a
  merge watch whose known request number the host no longer has now fails its read (status throws not found), where
  it used to read an empty snapshot; a deleted request is an admin-only case on GitLab and impossible on GitHub, and a
  failed read leaves the stage as it is.
  Tests deleted, each with its survivor:
  - `GitHubPublishTests.readinessReadsThePullRequestItsCheckRunsAndItsStatuses` → the same rows in
    `GitHubReadinessTests` (as facts).
  - `GitHubPublishTests.theMergeAndRunStatusReadEveryCheckTheSameWay` →
    `GitHubReadinessTests.theMergeAndThePipelineWordReadEveryCheckTheSameWay`.
  - `GitHubPublishTests.gitHubStateReadsChecksApprovalsAndHead` → `GitHubReadinessTests.thePipelineWordIsFailurePendingSuccessOrNone`
    and `GitHubPublishTests.aStatusReadsThePullItsApprovalsAndItsChecks`.
  - `GitLabPublishTests.gitLabStateReadsPipelineApprovalsAndHead` → `GitLabPublishTests.aStatusReadsTheMergeRequestAndItsApprovals`.
  - `SignalReviewActivityTests.reviewersIncludeGitHubTeamsAndGitLabPeople` →
    `aRequestSaysWhetherAPersonOrATeamIsAskedToReview`.
  Six GitLab readiness tests moved word for word into `GitLabReadinessTests`
  (`readinessIsGitLabsOwnVerdictWithItsPipeline` renamed `readinessFollowsItsPipelineThenGitLabsMergeStatus`). Added:
  one-fetch consistency tests on both hosts (head A then B: everything names A, one GET of the request), a merged
  pull reads approvals but no checks, a failed status read throws, and request-count tests for a merge watch on both
  hosts.
- Phase 7 gate: plain `scripts/test.sh all` green on `425a83a8`. Snapshots in `build/refactor-phase7` against
  `build/refactor-phase6`: only the known `marks.png` variant differs. No bundle check is due after phase 7.
- Review round 1: one Minor, about this Record: the 7c entry said approvals came from the request's one fetch,
  but they come from their own listing. The entry is corrected. No code finding, verdict "ready with fixes", so no
  second round.
- Plain `scripts/test.sh all` green on `f700a7c4`. `main` had only the refactor's own merges; merged to `main`
  (`ec98214f`). No check is owed to the maintainer for phase 7.

### Phase 8
- 8a: `TaskItem.isUnderOperator` (true exactly when the task has a signal record) is the one way the app asks;
  the sidebar grouping, reveal, Take Over, the project fold, Remove Project's count, `RowFocus`, `PerRow`,
  `allSignalTasks`, the launcher, teardown and the item router read it. Per the brief, a `done` task under its signal
  still offers Take Over. Small differences: `adoptOnly:` was already gone from the window plan, the signal id is
  at `record.current.signal`, and `RequestWatch`'s boolean map over the record's phase became an explicit record
  read. No test deleted. Added the accessor test across every phase and a `SignalWorld` test that the places agree.
  Noticed and left: Remove Project's alert says "1 worktrees are run by signals" (grammar; older than this step).
- 8b: Core's `TaskRowMark` and the rows' `needsYou` are decided in `SidebarModel.taskRow` and the terminal
  mapping (done or needs input) and in 5h's `presentingOperator` (needs input only). Every attention reader uses
  `needsYou`. The projection's private `DrawnTask` key replaces the doctored task copies, and `TaskRowView` takes only
  its row. The five pure row values moved to `SidebarRowValues.swift`. Snapshots were identical (`build/8b-before`
  against `build/8b-after`; `marks.png` differs only in encoding), and every redraw and work budget held. Differences
  from the brief:
  - `TaskRow.windowOpen` was added, and `DrawnTask` carries it, for VoiceOver's "open its window" or "focus the
    window" hint. The old copies carried `windowId`, so no derivation is added.
  - 5h's function returns a `TaskRow`, so the mark and flag are set inside it in Core.
  - The Operator row's `mark` and `needsYou` are computed.
  - Two Done-when greps are not literally clean: `DeliveryCheck`'s unrelated `.needsAttention(String)` case
    matches, and `SidebarRows.swift` keeps `SidebarRowLayout` and the debug-only `RowBodyCounter` and `SeededHover`.
  Tests deleted: the two removing cases of `TaskRowMarkTests` (`SidebarRowRedrawTests.aRemovalRedrawsOnlyItsRow` and
  the `sidebar-removal` snapshots cover the spinner), and the two `task: nil` expectations of `RowAccessibilityTests`
  (behaviour deleted: a drawn row always has its task). Added: Core `TaskRowMarkTests` and `RowNeedsYouTests`,
  `SignalSidebarTests.theOperatorRowWithAQuestionNeedsYou`,
  `AppControllerTests.aDrivenTaskWhoseTabIsDoneIsCountedByNoReaderAndYourOwnByAll` and
  `SidebarProjectionTests.eachDrawnDrivenFactDerivesOnceAndChangesItsRow`. Not captured: the hosted-only
  `signals-waiting-marks.png` (it opens windows; for 9c with the other hosted poses).
- 8c: one `HeadingRow` drawing one `HeadingValue` for projects and signals (both `.equatable()`, both tagged by
  `SidebarView`), and one `SectionHeading` for OPERATOR and PROJECTS. Return on an empty heading presents New Task…
  (else New Terminal…) for a project and Edit Signal… for a signal, and `RowMenuAnchor` is gone. A removed signal's
  heading has no pause glyph, and its fold is a runtime set in the projection, so no task record is written.
  Snapshots: hosted captures (`AITERM_SNAPSHOT_HOSTED=1`, `build/8c-before-hosted` against `-after-hosted`) differ only
  in `signals-removed.png`, the pause glyph gone, as the brief allows. In the default capture, seven `sidebar*` images
  differ (`sidebar`, `-brand-colours`, `-collapsed`, `-extra-large`, `-large`, `-header-selected`,
  `-header-selected-collapsed`). The before images drew ImageRenderer's yellow "unsupported view" placeholder for the
  AppKit anchor behind each project heading, which the app never shows; I looked at the pair. The after images show
  the real heading. Small difference: the Done-when symbol grep also searches `app/.build`, so it is clean only with
  `--exclude-dir=.build`. Tests deleted: `RowMenuAnchorTests` (both tests; the behaviour is deleted) and
  `SidebarInteractionTests.returnOnAnEmptyHeaderOpensItsMenu`, replaced by
  `returnOnAnEmptyProjectHeadingPresentsItsMainSheet`, `returnOnAnEmptySignalHeadingEditsTheSignal` and
  `returnOnEmptyHeadingsPresentsNothingWhileLocked`. Added `SignalSidebarTests` for a removed signal's heading not
  paused, its fold leaving task records byte for byte, and reveal leaving its project's fold alone.
- 8d: each row (task, terminal, divider, project and signal heading, OPERATOR heading) builds one `RowCommand` list,
  drawn as its context menu and as its VoiceOver actions (the enabled ones, without "…"). Open in Finder and Open in
  VS Code come from one helper. Pause Operator and Resume Operator live only on the OPERATOR heading's context menu
  (enabled while the workspace can change); its "+" holds New Signal… alone, and the Operator row has no menu. The
  menus kept their items, groups and enabling; I compared the diff item by item. Snapshots identical apart from
  the known `marks.png` variant. Small difference: the Done-when `TerminalRowAccessibility` grep is clean only with
  `--exclude-dir=.build`. Tests deleted (all in `RowAccessibilityTests`, replaced by command-list tests):
  `aTaskRowOffersRemoveAndNoReopen`, `archiveIsOfferedBesideRemoveAndNamedWithoutAnEllipsis` and
  `aTaskRowBeingRemovedOffersNothing` → `taskCommandsKeepTheirGroupsKindsAndEnabledActions` (a row being removed
  now offers its open commands, as the brief decides); `aLockedWorkspaceOffersNoTaskActions` →
  `lockedTaskAndTerminalKeepOpenCommands`; `aRowsActionsAreItsMenuItemsTitles` → the task, terminal and divider
  command tests; `aTerminalRowOffersRenameAndRemoveWithOrWithoutItsWindow` → `terminalCommandsDoNotDependOnItsWindow`;
  `aDividerOffersOnlyWhatItsMenuHasEnabled` → `dividerCommandsAtBothEndsAndWhileLocked`.
- 8e: the projection answers whether a selection is drawn and which visible heading holds it. The controller's one
  re-derivation hands a selection that was drawn and no longer is to that heading, or clears it, as a browse only. A
  selection that was not drawn before is left for `reveal`. The Core rule `SignalStarts.items` beside
  `MatchDecision` is what the sheet's preview counts. The signal heading's command reads "Switch On" or "Switch Off",
  and no view reads a source. Removed-signal fold changes now go through the controller's re-derivation, so the
  hand-over sees them. Snapshots byte-identical. Small difference: the `(starts` Done-when grep matches an
  unrelated `(startsInSpan` in `CodexHookConfig.swift`. `SidebarRowRedrawTests`' question-only redraw test now
  clears the selection first, because opening OPERATOR would now deselect a selected project task (an intended
  selection change, not row data); its budget is unchanged. Tests deleted: none.
  `signalCommandsKeepSwitchCountAndOmitRemovedSignals` became `signalCommandsSwitchAndOmitRemovedSignals` (the count
  is deleted), and Focus View's old expectation that a hidden task stays selected now expects its heading. Added
  Core start-rule tests and app tests for each hand-over the brief lists. Noticed and left: Focus View and List View
  apply saved folds only, not a removed signal's runtime fold (as the 8c brief decided).
- 8f: one `SteppedSheet` frame, configured with `Step`s, owns the stepper, the footer, the keys and dismissal for New
  Task, New Review and New Signal. Each sheet keeps its height (500 and 560 pt). Cancel is on every step at the leading
  end, Back appears from step 2, Escape closes the step's open list and then cancels, and ⌘↩, ⌘1…n and Back are
  refused while a create runs. Rename, Add Divider and New Terminal commit on plain Return. `CreationSheet`,
  `SteppedSheetFrame`, `CreationFooter` and `CreationSteps` went; `SignalModel.error` is the sentence it shows.
  Decisions (within the agreed visible change "Stepped sheets show Cancel on every step"):
  - With the longest fix label ("Create Empty Commit and Retry"), Cancel, the fix button, Back and Create no longer
    fit one row: SwiftUI squeezed the primary button and shifted the whole footer. The fix button now sits under
    the failure notice it answers, leading, and the button row is always Cancel … Back, primary. No control or word
    changed. The four images with a fix button (`task-unborn-base`, `task-initialization-identity`, `review-rebase`,
    `review-switch-folder`) grow by that line, with the notice pixel-identical.
  - Settings › Interface said ⎋ is "Back a step, or close", which is now false; it reads "Close the list, or cancel"
    (`settings-interface-full.png` changes in that row only).
  Snapshots against `build/8f-before`: only the footer rows of the stepped sheets and their footer images changed,
  as the brief lists, plus the two decisions above. Small differences:
  - `creating` is read when a key acts (an autoclosure): SwiftUI kept stale actions on the hidden ⎋ button and the
    stepper's ⌘1, so a captured flag let Escape dismiss mid-create.
  - Leaving a step closes all of its open lists.
  - A redraw test reaches the frame through a small `Mirror` helper.
  Tests deleted: `CreationSheetStepsTests.taskAndReviewShareThreeStepsWithTheAgentLast` (survivors: the new
  footer-titles test in `SteppedSheetTests` and `NewReviewSheetTests.theDestinationAsksForTheSlugOnlyWhereItIsDrawn`)
  and `NewReviewSheetKeyboardTests.escapeOnAPreviewedLaterStepStepsBack` (behaviour deleted).
  `onlyCompletedStepsCanBeClickedOrReachedByTheirNumber` moved to `SteppedSheetTests`, and three Escape tests were
  rewritten to cancel. Added `SteppedSheetTests` and three `SheetDismissalTests`. Noticed and left (docs comments for
  9a): `SheetStepper`'s "no step is a button" and `SheetPrimaryButton`'s "New Review's Apply";
  `docs/design/design-system.html` still names the old types (design-system sync).
- 8g, the sheet fixes as the brief lists them:
  - New Signal's readiness checks only the signal's own agents and is advice: "Checking agents…" or "Fix this before
    its tasks start" above the buttons, never disabling Create.
  - The "isn't installed" note shows once, in amber, only when no agent can run.
  - One wording, "Unavailable: <model>", for a saved model no longer offered, with one help line (New Task, New
    Review, Settings › Agents and Operator).
  - `Step.whyNot` says why New Signal's Agents step cannot continue.
  - Add Project shows the chosen folder as a line with Choose…, with no typed path or second inspection.
  - New Task's Base branch is the filtered `BranchInput` New Review uses, and an empty base disables Continue.
  - `DebouncedSearch` has one cancel rule, so a late opening ticket search after a pick is dropped.
  Snapshots against `build/8g-before`: the six `step1-*` images (Base branch field) and `add-project.png` (folder
  line), as listed. `step3-agent.png` also differs by 10 pixels with a channel delta of 1 on glyph edges, the same
  render noise the phase 6 comparison showed on that image. Tests deleted:
  `ProjectSheetModelTests.anOldFolderInspectionCannotReplaceTheNewerOne` (typed folders deleted) and
  `DebouncedSearchTests.theTicketFieldShowsWhatItsOwnRuleShowed` (the second rule deleted;
  `thePickersSearchShowsWhatItsOwnRuleShowed` and the new held ticket-search test in `ReviewTicketFieldTests`
  cover the one rule). Rewritten: `aLockedWorkspaceOrFailedInspectionCannotSaveAPreviousFolder` →
  `aFailedChoiceKeepsThePreviousFolderAndStaysSaveableALockedWorkspaceCannotSave`, `aModelOffTheCatalogueIsStillOffered`
  → `aSavedModelOffTheCatalogueShowsAsUnavailableAndSaveKeepsIt`, `onlyTheAgentsTheOperatorMayPlanOnAreWaitedFor` →
  `onlyTheSignalsOwnAgentsAreChecked`. Added the brief's model, sheet, Agents-reason and base-field tests. Noticed
  and left: `SignalContext.read` picks the first catalogue model when a resolved preference is empty.
- 8h: the profile save was already non-throwing after 2h. `OperatorSettingsModel.save()` now guards on `original`
  alone, and `HarnessSettingsModel.save()` lost its redundant `loaded.contains`. The Agents tab's closing help, the
  Settings comments, and `docs/configuration.md` and `docs/keyboard.md` say what Save stages and what applies at
  once. Differences from the brief:
  - The `try?` Done-when grep still matches one line, `catalogue.models(for:)` (a catalogue read, not the profile
    save).
  - `settings-agents.png` is byte-identical because the changed help line falls below its captured viewport; the
    only other differing image is the known `marks.png` variant.
  No test deleted or added. Noticed and left for 9a: `docs/keyboard.md` still says "There are no ended broadcasts
  to open." (Archive section).
- 8i: the agent table describes the Oracle's read-only headless run as well. Each entry holds its model words, its
  read-only launch (Codex), its headless arguments, where its answer is read from, and its effort lists.
  `HeadlessRun.swift` went, and `OracleLaunch` asks the table. `HeadlessInvocation` moved to `Harnesses/` without its
  `environment` and `sessionID`, which were always empty and nil. `SkillCatalog` and `ProjectFiles` moved to
  `AiTermCore/Prompt/`. Every command line is byte for byte (`CompatContractTests`), and `compat/` is unchanged.
  Small differences: `RegularFileTests` read the deleted answer-limit constant and now uses the same number, and a
  stale comment in `OracleLaunchTests` was updated. No test deleted or added.
- Phase 8 gate: plain `scripts/test.sh all` green on `55970cda`. Snapshots in `build/refactor-phase8` against
  `build/refactor-phase7`: 64 images differ, each one recorded above:
  - the stepped sheets' footer row (8f: Cancel at the leading end on every step);
  - the four images with a fix button, now under its notice (8f);
  - `settings-interface-full.png`, the ⎋ line (8f);
  - the `step1-*` Base branch field and `add-project.png` (8g);
  - the seven `sidebar*` images that lost ImageRenderer's placeholder for the deleted menu anchor (8c);
  - the known `marks.png` variant.
  `step3-agent.png` also carries delta-1 noise above its footer. No bundle check is due after phase 8.
- Review round 1: one Minor, confirmed: `presentingOperator` still checked `signalTask != nil` instead of 8a's
  accessor. Fixed by Codex (one line), gate green. No code finding of Critical or Important severity, verdict "ready
  with fixes", so no second round.
- Plain `scripts/test.sh all` green on `b07327a4`. `main` had only the refactor's own merges; merged to `main`
  (`d1599de8`). No check is owed to the maintainer for phase 8.

### Phase 9
