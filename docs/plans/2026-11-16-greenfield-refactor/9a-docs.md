# 9a. Docs brought to the code

Implementer: Opus 5.5 at high effort. Depends on: every step of phases 0 to 8, merged. Findings:
none of its own; it closes the documentation the phases left (each step fixed a false line or two
in its own commit and left larger rewrites here).

## Why

The documents describe AiTerm as it stood on 16 Nov 2026: a window close followed by a question,
three teardown owners, an Operator controller that held waking, Oracle prompts and the activity
log, Find a Fix, wire fields such as `displayWork` and `subagentsWrittenAt`, and paragraphs about
broadcasts. Phases 1 to 8 changed all of that. The end state: every document listed below says what
the code at `HEAD` does, in the vocabulary signal, item, task, stage, worker, Operator, Oracle,
Archive, and nothing about how it got there (no "no longer", "used to", "since the refactor"). A
right edit makes a sentence match a symbol or behaviour you can find in the code. A wrong one
describes intent the code does not have, keeps a symbol that is gone, or rewrites a section that
nothing made false.

## Today

Documents in scope, and the steps that were to fix some of their lines in-step (verify those; do
not assume they were done):

| Document | Fixed in-step by |
| --- | --- |
| `docs/architecture.md` | 1a (retired-keys sentence) |
| `docs/operators.md` | 4e (Take Over), 8d, 8e (pause, Switch On), and any visible step it describes |
| `docs/windows.md` | 3e (rewritten for the closed view) |
| `docs/status-model.md` | 3e ("No window open" paragraph) |
| `docs/daemon-protocol.md` | 6a (the work list) |
| `docs/configuration.md` | 1i (Help with problems) |
| `docs/keyboard.md` | 3e (the close alert line), 8c to 8f where they changed keys |
| `docs/testing.md` | 0b, 0c, 1a, 2i |
| `README.md` | 1i (Find a Fix) |
| `daemon/README.md` | 1a (eval fixture line) |
| `scripts/README.md` | none |
| `app/Sources/AiTermUI/README.md` | none |
| `AGENTS.md` | 1a (eval baselines) |

Out of scope: `docs/release-notes/` (historical), `docs/workflow/release.md` (9b), `docs/plans/`,
`docs/research/`, `docs/reviews/`, `docs/design/design-system.html` (synced only on request).

## Change

1. Run the vocabulary sweep:
   `grep -rnE "[Bb]roadcast|Shelf|[Ss]helve|\bboard\b|finisher|\boperated\b|Find a Fix|Help with problems|runId|run_id|runFolder|ClosedWindowTriage|WindowReconciler|TaskRemover|TaskArchiver|WorktreeTeardown|SecondOpinionRunner|OracleRoundLedger|AgentChoiceRounds|QuestionRounds|ChallengeRecord|ChallengeLaunch|SignalOperatorCommand|SignalOperatorTool\b|SteppedSheetFrame|CreationSheet|ProjectHeaderRow|SidebarHeader|SignalHeader|SignalOperatorHeading|SignalOperatorRow|OperatorRow\.id|RowMenuAnchor|displayWork|legacyIndex|PostModelSwitch|subagentsWrittenAt|slash_commands|session\.prompt|session\.dismissStartup|Reconnecting to iTerm2|Couldn.t reopen|takenOver|TickPass|CommitId|LocalMerge|outcomeUnknown|HostAPI|FixSession|startingFresh|SignalEdge|hundred edges" README.md AGENTS.md CONTRIBUTING.md daemon/README.md scripts/README.md app/Sources/AiTermUI/README.md docs/*.md`.
   For each hit, grep the symbol in `app/Sources`, `daemon/aitermd`, `hooks` and `scripts`. A hit
   for something the code no longer has is rewritten or removed. A hit for something that still
   exists stays only if its sentence is true. "broadcast" stays nowhere in these files.
2. Walk the checklist below, document by document. For each item, read the code it names, then fix
   the sentence or tick it as already true. Keep each document's structure and tone; replace
   sentences, do not add sections unless an item says so.
3. Check every relative link in the files you edited still resolves (the target file exists and,
   for an anchor, the heading exists).

### Checklist

`docs/architecture.md`
- Package boundaries, the paragraph on `BackgroundWork`, `SerialThread`, `ThreadWork`,
  `FolderCheck`, `AgentProcess` (1c removed `BackgroundWork.within`; 1i moved `AgentProcess` and
  `RegularFile` to a process folder): every name exists and is placed right.
- "Commit ids, remote URLs, real paths and file stamps each have one Core home" (about line 24):
  1c deleted `CommitId` and moved its rule, `sameLocation`, `shortBranch` and `folded` beside the
  worker guard. Name the homes as they are now.
- Workspace and observation: the broadcast prerequisite (about line 35) goes; link to the release
  procedure's Operator format section instead. The retired-keys sentence (1a) is gone; "unknown keys
  round-trip" stays. `SignalHeadingValue` became `HeadingValue` (8c).
- The `AppController` paragraph: no Fix pipeline in `AppPorts` (1i); `AppController.choose` alone
  decides what choosing a row does (3b); creation sheets use `SteppedSheet` configured with `Step`s
  (8f), not `CreationSheet`; `TickPass` only if it still exists (5e); `DebouncedSearch` has one
  cancel rule (8g).
- Task and window operations: no Fix landing, no local merge (1i, 1c). One restore on
  `TaskLauncher`, one worker checkout for an item, one window opener whose commands follow
  ownership (4d). Launch recovery adopts a tagged tab with the planned agent, else blocks (2f).
  The `WindowReconciler` paragraph becomes `RowWindows` (3b): it adopts tagged windows for every row
  kind; a closed window clears the row's window and nothing else; no close question, no
  `ClosedWindowTriage`, no restore triggers (3a). `TaskTeardown` (4c) owns archive and remove with
  consent as a policy; Remove asks everything before it acts and has no waiting-for-retry state
  (4b). Point to `windows.md`.
- Operator ownership: a `SignalTask` holds its current stage whole with a configuration always
  present (5b). Rebuild the owner table from the code: the stage machine with its actions and no
  `stopped` (5a); one `SignalClaim.allows(in:)` (5a); `OracleConsult` for every Oracle use, prompts
  in Core `OracleLaunch` (5c); `OperatorWaker`, `OperatorChat`, `ActivityWriter` and
  `AppState.pruneOperator(at:)` (5d); one tick and one in-flight set per task (5e);
  `OperatorSession.Lifecycle` (5f); the handler's ledger as the only ledger (5g); Take Over ends the
  signal record (4e); one `RequestStatus` read and pure `MergeReadiness` (7c). Drop rows for owners
  that are gone.
- "Every consequential effect rechecks...": one claim check (5a). "A changed in-flight Oracle
  setting or instruction invalidates its answer": now discarded and asked again, for every use (5c).
- State tails: no edge limit (5a removed edges); check every number against Core constants.
- Integration and platform owners: no host or Jira writes besides merge (1b): drop "publication must
  refuse an incomplete safety read", `HostFailure.outcomeUnknown` and the per-host token user. One
  `HostRepository` interface and one factory (7a); one review-threads reader per host and the
  host-and-port rule (7b). `HarnessDriver` and headless launches in one agent table (8i). The
  `FixSession` paragraph goes (1i). The release feed is constants (2h).
- Daemon: readings carry one session key, `Turn.generation` gone (6d); `CodexThreads` (6e);
  telemetry by agent in `aitermd/agents/claude.py`, `codex.py`, `pi.py` (6f); the app ends a stale
  helper holding the socket and starts its own, no adoption (6b).
- Where the facts come from: delete the rows "a worker's live model and effort" and "what became of
  a slash command" (1g). Recheck "status dot" (6f, the Codex title stays a source), "conversation"
  (6e), "review threads" (7b).
- What AiTerm writes: Operator artifacts named by the session's id and folder (1j), token handling
  folded (1g). Codex tab identity: owner `CodexThreads`, tag format unchanged (6e).
- UI and verification: "live workspace migration" becomes "live workspace setup" (1h removed
  migrations).

`docs/operators.md`
- The chat's window follows the closed view: closing it asks nothing, choosing the Operator row
  opens it (3a, 3b).
- Create a signal: Cancel on every step, Escape closes an open list, else cancels (8f). Agents step:
  readiness is advice for the signal's own rows, "Checking agents…" while it reads, Create never
  disabled for it; one wording for an unavailable model; a disabled Continue says why (8g). Check the
  80% fallback sentence against where the launch-time switch now lives (5g).
- One item keeps one task: Take Over makes an ordinary task that a later signal never continues
  (4e).
- Questions and the Oracle: a settings change during a check means it is asked again (5c). The
  shell gate paragraph matches the gate's refusals and Oracle prompt (1j, 5c).
- Publishing: workers may run `git merge` locally; the push guard still refuses the branches that
  matter (2g). Re-list exactly what the worker guard refuses.
- Pause, switch off and take over: Pause Operator and Resume Operator live on the Operator heading's
  context menu only, one wording; the heading's "+" holds only New Signal…; the row has no pair
  (8d). A switched-off signal's item reads "Switch On" (8e). A removed signal's heading shows no
  pause mark (8c). Take Over: an ordinary task, opened, restored, archived and removed like one; a
  running worker keeps its guard until it ends; stopped or finished signal tasks do not offer it
  (4e, 8a).
- The "needs you" paragraph: re-list the issue sources from `OperatorIssues.Source` (2f removed the
  Take Over repair and the activity write queue).
- Session recovery: no `stopped` tasks (5a); taken-over tasks are ordinary (4e). The last paragraph
  about broadcasts goes; one sentence points to the release procedure's Operator format section.

`docs/windows.md` (rewritten by 3e): verify each "What happens when…" against `RowWindows`,
`RowFocus`, `AppController.choose`, `TaskLauncher` and `TaskTeardown` as they are after phase 4:
Restore from the Archive restores, then focuses only when a person asked (4d); Remove asks
everything first (4b); a taken-over task is an ordinary row (4e); the developer section names the
current owners.

`docs/status-model.md`
- The hook table: delete the `PostModelSwitch` row (1g). The `Stop` row's `background` becomes the
  session's one work list whose items say whether they hold the turn (6a).
- Codex title and rollout paragraphs: one rollout cursor, an unparsable line skipped and logged once
  (2e); the title stays a spinner source (6f); identity from the tab's tag through `CodexThreads` (6e).
- The `displayWork` paragraph becomes the work list (6a); late readings dropped by one session key
  (6d).
- The subagent quiet window goes (2e); the `subagentsWrittenAt` paragraph goes (1g).
- The section "What a Claude worker runs, and what became of a slash command" goes, or keeps only
  what the code still does (1g).
- "No window open" (3e): verify.

`docs/daemon-protocol.md` (compare both tables with `DaemonProtocol.swift` and
`daemon/aitermd/protocol.py`, name by name)
- Commands: `session.prompt` and `session.dismissStartup` are gone (1g); keep the screen-recognition
  paragraph only as far as delivery still uses it. `operator.register` and `operator.revoke` carry
  `operatorId` (1j). `workspace.snapshot`: no adoption (6b), the connection's own call (6c); the
  line on `iterm.status`, `sessions.list`, `usage.get` matches who calls them now (6c).
- Events: banner text for `iterm.connected` and `iterm.disconnected` (3d). `window.closed` clears
  the row's window and nothing else (3a). `session.opened` and `.changed`: no `subagentsWrittenAt`,
  no `title` (1g); tagged-window adoption as 3b does it.
- The `displayWork` paragraph becomes the `work` list with `holdsTurn` (6a). "Older payloads that
  omit the field still decode" goes (1h). The supervisor paragraph matches 6b.

`docs/configuration.md`
- Intro: no Help with problems (1i, 8h). Agents: the New Task sheet has no command preview (1f).
  The Help with problems section is gone (1i).
- Jira, GitLab and GitHub table: AiTerm's only host write is a merge (1b): permissions say "merges",
  not "opens or merges".
- iTerm2: the banner's wording for each state (3d).
- Test runs: check "so the Operator does not flag a worker... as possibly stalled" against where
  the stall rule lives now (1d).

`docs/keyboard.md`
- Intro and Creation sheets: Escape closes an open list, else cancels; Cancel on every step;
  ⌘1…n; Rename, Add Divider and New Terminal commit on plain Return (8f).
- Application table: ⌘P's sheet shows the folder as a line with Choose… (8g).
- Row menus paragraph: Pause and Resume on the Operator heading (8d); Take Over only on a driven
  task still under the Operator (8a).
- Sidebar: Return on an empty heading runs its main command (New Task…, else New Terminal… for a
  project; Edit Signal… for a signal) (8c); moving the selection never opens a window, only raises
  one (3a); Return on a row without a window opens it (3b); ⌘Delete's Remove asks everything first
  (4b); the selection follows its row (8e).
- Pickers: name only the pickers that exist (1f).
- Settings and alerts: the close alert line (3e) and Remove's branch question with Delete and Keep
  (4b).

`docs/testing.md`
- The journey sentence (0b) and the builders sentence (0c) are present.
- Fixture table: no `operator-saved-format` row (1a), no `codex_reference.py` row (1g); the eval
  paragraph describes the current contract only (1a).
- Budgets: git-spawn counts are ceilings (2i); `OperatorWorkBudgetTests` named only if it exists.
- Joins: lifecycle operations are awaited (4a) beside Operator work's `settled()`.

`README.md`: no Find a Fix (1i); "Put work aside" matches restore (4d); the Develop paragraph on
`run-dev.sh` matches what the script and the app's helper ownership do now (6b).

`daemon/README.md`: App connection without adoption (6b); the eval fixture line (1a); Polling
matches the rollout cursor and per-agent telemetry (2e, 6f).

`scripts/README.md`: "Switch the running build" matches `scripts/run-dev.sh` now (6b).

`app/Sources/AiTermUI/README.md`, App composition inventory: `HeadingRow` with `HeadingValue` and
`SectionHeading` replace the project and signal heading types (8c); the Operator row as it is (3c);
`SteppedSheet` and `Step` replace the sheet frame rows (8f); row values `TaskRow` with `mark` and
`needsYou` from the projection (8b); no `RowMenuAnchor` (8c). Primitive inventory: only pickers
that exist (1f). Change names and responsibilities only, never a visual value.

`AGENTS.md`: "Preserve the current Signal contracts" without eval baselines (1a).

## Keep

- Visual values in the UI README; it is the design system's spec and this step only renames.
- `docs/release-notes/`: they describe their own release.
- The test-run record contract in `docs/configuration.md` (a public interface for other projects).
- Install, Backpack Mode and Interface sections nothing changed.

## Decisions already taken

- A step's in-step fix is wrong or missing: fix it here; mention it in your report.
- A doc names a behaviour no step touched and it is false: fix it if it is a line; otherwise report
  it and leave it.
- A sentence about history ("Signals replaced broadcasts") goes; only release notes narrate change.
- Counts in prose (tools, budgets, limits) are read from the code or schema, never from memory.
- No new document. `docs/windows.md` is not rewritten again; only false sentences change.

## Tests

None. `KeyboardSettingsTests` compares `KeyBindings.all` with the menus, not with `keyboard.md`.

## Proof

- The vocabulary sweep returns only hits you checked and kept, listed in your report with why.
- Plain `scripts/test.sh` reports a docs-only change and exits.

## Done when

- Every checklist item is fixed or confirmed true, and your report lists which.
- The sweep's remaining hits are each justified.
- Every relative link in an edited file resolves.

## Not in this step

- The release notes and the release procedure's Operator format section (9b).
- The final gate, bundle check, snapshot comparison, upgrade rehearsal and review (9c).
- Syncing `docs/design/design-system.html` (the design-system skill, on the maintainer's request).
