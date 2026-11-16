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

- [ ] 1a. **Codex.** The broadcast eval baseline, the two unread `operator-current` folders,
  `operator-records`, the retired-keys test, `operator-saved-format` and the `retired:` key lists;
  the eval keeps the current contract; `AGENTS.md`, `docs/testing.md`, `daemon/README.md`,
  `scripts/test-routes.tsv` and the provenance notes follow. The suite's `operatorOpen` test moves
  to the saved-format suite.
- [ ] 1b. **Codex.** The code-host and Jira write surface and everything only it uses: the request
  writes, thread replies, pipeline retry, user lookup, `JiraWrites`, `JiraAgile`, the confined
  search, the "outcome unknown" and "not sent" failures, `OperatorPorts.publisher`, `FakeMergeHost`,
  the dead thread prompt (HO F1, TS F1). `merge` stays as the one host write.
- [ ] 1c. **Codex.** The push and publish stack, `LocalMerge`, `BranchDrift`, `BackgroundWork.within`,
  the `CommitId` wrapper (its one rule moves beside the worker guard with `sameLocation`,
  `shortBranch` and `folded`), `pushReason`, `saidAsWritten`, `LoginShellLocator.refresh`, the dead
  error case and the six unnoted `WorkMeter` cases (CG F1 to F3).
- [ ] 1d. **Codex.** Core Operator leftovers: the dead Oracle prompts, `DiffDigest`, the acceptance
  half of `WorkerTurn`, the `AgentDelivery` struct, `OperatedBranch`, `TaskKeyReference`,
  `StallWatch` (its one live rule moves into the transcript reader), unread `OperatorTiming`
  constants, dead `OperatorModels`, `OperatorLine`, `WorkerTabs` and `ActivityLog` members, the
  never-produced branch item and `baseline` seen state, the dead saved fields (`peopleReview`,
  `ExtraTab` role and launch fields, unused round fields) and `SavedDefaults` (OC F1, F3, F8).
  `operator-signals/state.json` is re-recorded.
- [ ] 1e. **Codex.** Operator runtime leftovers: dead `OperatorPorts` fields, the transcript
  open-call reader, locator test hooks, `markOutcome`, members only tests call (RT F6).
- [ ] 1f. **Codex.** App leftovers: `ShelfRow` becomes `ArchiveSearch.Entry` and Shelf becomes
  Archive in code names; dead controller and coordinator members and empty comment stubs; the
  `queued` row state and its plumbing; the unread project hand-off counts; the test-only attention
  and Dock badge path (its live cases move to the projection's); dead pickers, the command preview,
  the segmented agent picker, the broadcast step config, the disabled prompt editor, subtitles that
  never draw; the branch type and name halves of `TaskDraft` (TL F4, SB F1, F2, SS F4, F7, F8, TS F2).
- [ ] 1g. **Codex.** Daemon leftovers: slash-command tracking, live model and effort attribution
  and the `PostModelSwitch` hook, `subagentsWrittenAt`, `title` on the wire, the `session.prompt`
  and `session.dismissStartup` requests, the prose wake rule and its fixture, `operator_token.py`
  folded, the test-only `settle_reads` seams, the Codex reader's test-only methods and the copied
  reference parser (DM F1, F7, F8, part of F3; WD F5 dead requests). Wire frames and driver
  fixtures are re-recorded.
- [ ] 1h. **Codex.** Every old-format reader and migration: Keychain per-key items, the support
  folder rename, the legacy status-line record, retired hook and push-key cleanup, the pre-0.15
  workspace decoders (single Jira project, flat project list, unnamed terminals), the earlier
  choice-block upgrade, old-helper decoding forms and
  defaults on the wire, the old GitLab URL form, Jira's paging fallbacks (CG F8, TL F7, PL F3,
  OC F15, WD F4 decoding paths only, HO F5 items 1 and 2).
- [ ] 1i. **Codex.** Find a Fix: its Core folder, session, views, banner and footer wiring, the fix
  fields on issues and creation failures, the Settings switch, tests, README and configuration
  lines. `AgentProcess` and `RegularFile` move to a process folder; the Oracle runner and the
  worker guard keep using them (PL F1).
- [ ] 1j. **Codex.** One vocabulary. `OperatorCommand` and `SignalOperatorCommand` become one
  `OperatorLaunch`; `SignalOperatorTool` becomes `OperatorTool`; the saved round record becomes
  `OracleRound`; the second-opinion runner is named for the Oracle; `runId` and `runFolder` become
  the Operator session's id and folder, on the wire too; `operated` becomes worker. Comments that
  narrate broadcasts, boards, the Shelf or a spec section are rewritten to say what the code does.
  The shell gate's refusals and its Oracle prompt describe the signals Operator and name existing
  tools (OC F4, F5, RT F11, DM F7, and the comment lists in TL F4, SB F2, SS F4).

### Phase 2. Delete speculative handling (after 1)

- [ ] 2a. **Codex.** Git: the per-key timeout back-off in the three resolvers (the project-level
  stall guard and "never store a failure" stay), reftable handling, the abandoned rebase scratch
  cleanup, the `.worktrees` symlink refusal (CG F4, F6, F9).
- [ ] 2b. **Codex.** The default branch is asked from git when it is needed (when a project's
  heading appears, after a pull, when a sheet opens); `DefaultBranchResolver`, its map and its
  poll go (CG F5).
- [ ] 2c. **Codex.** The checkout cleanup trusts the scan's confirmation; the second disk check,
  its port and its dictionary go (TL F6).
- [ ] 2d. **Opus.** The Codex config editor writes its marked block, refuses on a conflicting
  table and removes its own entries by marker; the four-form string parser, the moved-hook
  reconciliation and the config-file model fallback go (PL F4). The refusal tests for unbalanced
  and conflicting files stay.
- [ ] 2e. **Codex.** Daemon: the Codex rollout reader becomes one cursor (first record for the
  version, tail for the last boundary and token count, an unparsable line skipped); the subagent
  quiet window, the iTerm2 batched-read fallback and the resolver's root-change retry go
  (DM F3, F9, F10). The compat captures stay the proof.
- [ ] 2f. **Codex.** Operator repair paths: the activity write queue, the Take Over repair loop,
  the mirrored source errors, the details cache reduced to a short cache by task and claim, launch
  recovery reduced to "a tagged tab with the planned agent, else block" (RT F10). The checkout save
  after a Take Over during a request checkout stays: without it the taken-over task has no folder
  and its next checkout is refused.
- [ ] 2g. **Codex.** Worker guard: local `git merge` allowed, one argument table and one "this API
  call writes" rule shared with the shell gate, the GraphQL-file and deep alias paths go (OC F9).
- [ ] 2h. **Codex.** Small ones: New Review's "press again" recheck, the profile save that cannot
  fail, guards behind controls that cannot send the input, one paging helper for the hosts, the
  duplicate Backpack rejoin delays and turn-off block, the release feed as constants
  (SS F16, HO F5 item 3, PL F6, F8).
- [ ] 2i. **Codex.** The workspace backup is a plain second write; git-spawn budgets become
  ceilings; the two notes no test reads go (TL F8, TS F5).

### Phase 3. Windows (after 2)

- [ ] 3a. **Opus.** Closed view. A closed window clears the row's window and nothing else. The
  close heuristic, the question and its Archive variant, the hold, eager restore and its triggers,
  and bringing AiTerm forward go. The window plan only adopts tagged windows. Choosing a row
  without a window opens it and reports a failure on the click. Terminals follow the same rule
  (WD F1, F3 moot, F6 moot; TL F5 moot).
- [ ] 3b. **Opus.** One owner for "this row has or needs a window" for every row kind: manual task,
  driven task, terminal and the Operator chat, each adopted by its tag, with one `open(row)` that
  picks the opener. `RowFocus` keeps selection, peek and raising; its three opener slots, the five
  copies of "a signal task is not restored here" and the Operator's 180-second "opened" grace go.
  What choosing a row does is decided in `AppController.choose` alone (WD F2, SB F7).
- [ ] 3c. **Codex.** The Operator row has one fixed id and a payload-free selection case; the
  derived id goes (WD F8, SB F6, OC F11). Row flags are kept once, not as a set plus a mirror
  (WD F9).
- [ ] 3d. **Codex.** The iTerm2 banner says what a person can act on: iTerm2 isn't running (with
  Open iTerm2), iTerm2 refused AiTerm, AiTerm's helper isn't working; nothing while starting or
  connected (WD F7).
- [ ] 3e. **Opus.** `docs/windows.md` rewritten for the closed view; the alert line in
  `docs/keyboard.md` and the "No window open" paragraph in `docs/status-model.md` follow.

### Phase 4. One task lifecycle (after 3)

- [ ] 4a. **Opus.** Lifecycle tests join through one settled join, as the Operator's tests do, and
  no product function returns a task handle only for a test (TS F4).
- [ ] 4b. **Opus.** Remove asks everything before it acts: the unmerged-branch question comes up
  at once, a row with a window and no helper is refused as Archive refuses it, and the
  "worktree removed, waiting for a retry" state with its banner actions goes (TL F1).
- [ ] 4c. **Opus.** One teardown owner for archive and remove over the shared prepare and run, with
  consent as a policy (ask the person, or refuse while still allowed) and one per-row state that
  the row, the Dock badge and the checkout monitor read. The automatic variants and the remover's
  six dictionaries go; a task on its way out is filtered once, in the projection (TL F2, F9).
- [ ] 4d. **Opus.** One restore (git, then the row back from the archive, then focus when a person
  asked), one "worker checkout for an item" and one window opener whose commands depend on
  ownership. The Operator's stage launch and a person's click call the same operations
  (TL F3, RT F4).
- [ ] 4e. **Opus.** Take Over makes an ordinary task: the signal record goes, a small mark on the
  task (saved as the optional key `takenOver`) keeps later signals from continuing it, and it is
  opened, archived and removed like any task. The
  taken-over opener, its checkout copy and its resume commands go (RT F4, TL F3). Saved format
  changes; `operator-signals/state.json` re-recorded; `docs/operators.md` follows.

### Phase 5. Operator (after 4)

- [ ] 5a. **Opus.** Every phase change goes through the stage machine, with actions for the
  recovered worker and the failed launch; the unreachable `stopped` phase, the unused `stop` action
  and the unread edge history go. One claim check covers workspace, pause, signal enabled and
  cancellation; the thirteen repeated pause checks go (RT F5, OC F2).
- [ ] 5b. **Opus.** A task's record holds its current stage whole with a configuration that is
  always present; the eighteen `configuration ?? signal` fallbacks and the field-by-field stage
  copy go; one "question still pending" rule (OC F7 part b). Saved format re-recorded.
- [ ] 5c. **Opus.** One Oracle owner: one consult with a kind, a binding and a round limit,
  returning agreed, critique, the person's call, unavailable or retry. Worker answers, agent
  choice, the merge veto, `ask_oracle` and the shell gate all go through it; every prompt lives in
  Core beside the invocation; a settings change discards the answer and retries; no in-flight
  marker is left behind by a crash (RT F3, OC F6). Prompts move byte for byte except where this
  plan changes them.
- [ ] 5d. **Opus.** The controller composes owners and runs one ordered reconcile. Wake policy,
  the chat's window and session, the activity writer and retention each get one owner; Take Over
  already left in phase 4 (RT F1).
- [ ] 5e. **Opus.** One tick with the existing event triggers: source polling, the host watch and
  settings are steps that ask whether they are due; one in-flight set per task shared by stage,
  Then, delivery and rounds; the 180-second grace has one name (RT F2). `busy` becomes a pure
  question and the live-work set is computed once per tick (RT F13).
- [ ] 5f. **Opus.** The chat's lifecycle is one saved state with its generation; the three flags
  and four memory flags go; one idle rule (RT F8, OC F2). A row's current activity is runtime-only
  and leaves the saved task and the task line of `run_status` (RT F9).
- [ ] 5g. **Opus.** The tool handler's ledger is the only ledger of calls: `answer_worker`'s second
  ledger entry and its own running set go, and the wake acknowledgement moves into the handler.
  The uniqueness rules on records stay with their owners, because those records outlive the
  ledger: a question id is recorded once, a resolved question keeps its answer, a snag key and a
  note key each name one record. The launch-time agent switch and `open_tab`'s choice move to the
  agent-choice owner (RT F7, F12). Changed refusal texts are listed in the commit.
- [ ] 5h. **Codex.** `Signals/` regrouped by concept into about fourteen files with the source
  readers beside them; one helper for kind-tagged enums and one for open string enums with the
  same bytes; one JSON-lines appender for the activity log and the journals; delivery checks,
  `ClosingWait` and the merged-branch check move to their real homes; the task row's Operator
  wording is built in Core (OC F7 part a, F10, F12, F13, F14).

### Phase 6. Daemon and wire (after 2; beside the app track)

- [ ] 6a. **Opus.** One ordered work list per session, each item saying whether it holds the turn;
  `background` plus `displayWork` with `legacyIndex`, and the app's merge, go (DM F2, SB F10).
  Wire frames and `docs/daemon-protocol.md` follow.
- [ ] 6b. **Opus.** The app owns its helper: a stale holder of the socket is ended and a new one
  started; adoption, the held status, the mismatch hold and the unreadable-line limiter go; the
  stop in `scripts/run-dev.sh` becomes unnecessary (WD F4).
- [ ] 6c. **Codex.** One method per daemon command returning its full reply; `workspace.snapshot`
  is the connection's own; callers that only want the tabs use the side-effect-free listing
  (WD F5).
- [ ] 6d. **Codex.** Readings carry one session key and are dropped generically when it changed;
  the six hand-written identity checks and `Turn.generation` go (DM F6).
- [ ] 6e. **Opus.** One owner for Codex thread identity: restored from the tab's tag, bound by
  hooks, asked by the readers, written back after the tick (DM F5). The tag's format stays.
- [ ] 6f. **Opus.** Telemetry grouped by agent (Claude, Codex, PI), each turning its readings into
  evidence for one status entry point; the engine loses its agent-specific methods (DM F4). The
  Codex title stays a source.

### Phase 7. Hosts (after 1; beside the app track)

- [ ] 7a. **Codex.** One `HostRepository` interface with the live operations and one factory; the
  four layered protocols and three factories go (HO F2).
- [ ] 7b. **Codex.** One strict review-threads reader per host, which the badge counts; one Jira
  search with one mapping and shared date formatters; one "is this URL on the configured GitLab"
  rule that compares host and port (HO F4, F6, F7).
- [ ] 7c. **Opus.** A request's state is read once per watch read and merge readiness is a pure
  rule per host with table tests; the repeated fetches of the same request go (HO F3). The merge
  floor still rests on one consistent read.

### Phase 8. Sidebar and sheets (sidebar after 5; sheets after 1)

- [ ] 8a. **Codex.** One Core rule for "this task is under the Operator" (it has a signal record),
  read by the eight places that ask (SB F3). The defects the audit tied to a stopped task cannot
  be reached: nothing ever produced that phase, and 5a removes it.
- [ ] 8b. **Opus.** The projection decides each row's mark and "needs you" once and hands views
  small row values, not altered task copies; attention uses that one flag; the pure row values
  leave the view file (SB F4, F14). Redraw budgets and pixels hold.
- [ ] 8c. **Codex.** One heading module for projects and signals and one for the two section
  headings; Return on an empty heading runs its main command and the synthesized right-click goes;
  a removed signal's heading shows no pause mark and its fold is not written into task records
  (SB F5, F15).
- [ ] 8d. **Codex.** Each row builds its commands once, drawn as both the context menu and the
  VoiceOver actions (SB F11). Pause and Resume have one home and one wording (SB F16, first item).
- [ ] 8e. **Codex.** The selection follows its row (SB F8). "Which items would start" is one Core
  rule; a heading no longer reads the source (SB F9, SS F11).
- [ ] 8f. **Opus.** One stepped-sheet frame that each sheet configures with its steps, create
  action, failure and closing block; it owns the stepper, Cancel on every step, Escape, Back,
  Continue and dismissal. Each sheet keeps its height. New Task, New Review and New Signal use it; one-field sheets
  commit on Return (SS F2, F3, F14 Return only).
- [ ] 8g. **Codex.** Sheet fixes: readiness as advice for the signal's rows; the "isn't installed"
  note once and only when no agent can run; one unavailable-model wording and a visible reason for
  a disabled Continue; Add Project's folder as a line with Choose…; Base branch as the filtered
  field; one cancel rule in `DebouncedSearch`, which fixes the late ticket answer after a pick
  (SS F5, F6, F10, F12, F13, F15).
- [ ] 8h. **Codex.** Settings tidy: the Operator profile save cannot silently fail, dead staging
  paths go, the copy about Cancel not undoing "Help with problems" goes with the switch (SS F1,
  tidy only).
- [ ] 8i. **Codex.** Headless agent launches are described in the one agent table beside the
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
