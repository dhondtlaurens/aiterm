# 6a. One ordered work list per session

Implementer: Opus 5.5, high. Depends on: phase 1 (1g, 1h, 1j) and phase 2 (2e). Findings: DM F2, SB F10.

## Why

A tab's background work (the shells, monitors, tasks and subagents its agent left running) is sent
to the app twice: `background`, the list the last Claude `Stop` gave, and `displayWork`, two
optional lists whose items point back into `background` by `legacyIndex`. The daemon computes those
positions and the app undoes them in `SidebarModel.displayJobs`. This grew in two steps: first the
Stop list drove status and the card, then live readers (counted children, the background-shell
reader) were added beside it "display only", without touching the old field. The end state: the
daemon builds one ordered `work` list per session and marks each item `holdsTurn` (the last Stop
listed it, so the agent will take the turn up again for it). The app's status and the Operator's
"background work keeps this stage busy" read `holdsTurn`; the card draws the whole list. A right
change leaves every row's status, every Operator obligation and every card the same, apart from the
one-tick case under Decisions.

## Today

Daemon (`daemon/aitermd/`):

- `models.py`: `BackgroundJob(kind, text, agent_id, task_id)`; `task_id` is `compare=False` ("never
  part of the legacy wire contract"). `DisplayWorkItem(job, legacy_index)` and `DisplayWork(subagents,
  shells)`, each source `None` when unavailable and an empty tuple when known empty.
  `SessionInfo.background` (the Stop's list) and `SessionInfo.display_work` are process fields;
  `to_json` sends `background` and `displayWork`.
- `sessions.py`: `SessionRegistry.set_background` (writes even when equal, to keep new native ids)
  and `set_display_work`.
- `status.py`: `StatusEngine._apply_event` sets `background` from a Stop (`ev.background_work`,
  filtered to children the engine counts) and clears it on a working hook; `_apply_state` clears it
  on a rollout `working`; `_show_children` filters `background` to counted children, copies the
  Stop's descriptions onto `_Child.label`, and builds `DisplayWork.subagents` with indices;
  `apply_shell_reading` builds `DisplayWork.shells` with indices from a `ShellReading`;
  `reset_turn` sets `display_work` to None; `agent_exited` clears both. `Turn.shell_snapshot*` and
  `work_since` gate when the shell reading is trusted.
- `hook_events.py`: `_claude_background_work` (the Stop list, each job with its native id) and
  `_claude_display_shells`. `claude_background.py`: `BackgroundTranscripts`, `ShellReading`,
  `ShellTask`. `corroboration.py`: `CorroboratingReaders.background` reads it.
- Tests: `tests/test_status.py` (the five `display` tests near its top and the `background`
  assertions around `test_a_stop_lists_the_children_the_turn_waits_on_beside_its_other_work`),
  `tests/test_service.py` (`test_background_shell_lifecycle_is_published_without_changing_state`,
  `test_background_read_cannot_attach_to_replaced_identity`, the Stop assertions about line 1523),
  `tests/test_sessions.py` (the `set_display_work` id test about line 55).

App:

- `app/Sources/AiTermCore/Daemon/DaemonTypes.swift`: `SessionInfo.background: [BackgroundJob]`,
  `SessionInfo.displayWork: DisplayWork?`, `DisplayWork`, `DisplayWorkItem` (with `legacyIndex`),
  `BackgroundJob(kind, text)` with a lenient `Kind`.
- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: `aggregate(tabs:)` (status `.background` when
  every tab ended its turn and `backgroundJobs(of:)` is not empty), `backgroundJobs(of:)` (turn-ended
  tabs' `background`, then active test runs), `displayJobs(of:)` (the index merge; read for
  `TaskRow.background` and `TerminalRow.background` in `taskRow` and the terminal rows).
- `app/Sources/AiTermCore/Operators/WorkerTabs.swift`: `WorkerTab.background` (all Stop jobs when
  the turn ended, else only subagents, plus an active test line), read by `isStillAtWork`.
- `OperatorDigest` (`WorkerLine.backgroundJobs = session.background.count`, part of `run_status`)
  and `SignalWorkerIO.isLiveWork` (`!session.background.isEmpty`). Phase 5 may have moved these;
  find them with the grep below.
- Tests: `SidebarModelTests` (`aTurnThatEndedWithWorkStillRunningIsInTheBackground`,
  `aBackgroundJobOfAKindNotKnownReadsAsATask`, `displaySourcesPreserveStopOrderAndNeverDecideStatus`,
  `displayTestsRequireEndedTurnsAndKeepTheirExistingSuffix`), `DaemonTypesTests`
  (`displayWorkDistinguishesUnavailableAndKnownEmptySources`), `SidebarProjectionTests`
  (`aDisplayOnlyJobInvalidatesItsRowWithoutChangingItsStatus`), `TestActivityTests`.

Greps that list every reader: `rg -n "displayWork|DisplayWork|legacyIndex|displayJobs|backgroundJobs" app daemon docs --glob '!docs/research/**' --glob '!docs/plans/**'`
and `rg -n "\.background\b" app/Sources | rg -v "\.background\(|Palette|TaskStatus"`
and in the daemon `rg -n "display_work|DisplayWork|legacy_index|\.background\b" daemon`.

## Change

1. `models.py`: rename `SessionInfo.background` to `stop_work` (what the last Stop listed, still
   standing). Replace `display_work` by two process fields, `shown_subagents` and `shown_shells`,
   each an optional tuple of `BackgroundJob` carrying its native id (`agent_id` or `task_id`), None
   while that source is unavailable. Drop `compare=False` from `BackgroundJob.task_id`: ids are
   compared now, so a changed id is a change to announce. Delete `DisplayWork` and
   `DisplayWorkItem`.
2. `models.py`: add a frozen `WorkItem(kind, text, holds_turn)` with `to_json` giving `kind`, `text`
   and `holdsTurn`, and one pure function `work_items(session)` returning the ordered tuple, built
   from the session's state, `stop_work`, `shown_subagents` and `shown_shells` (rule below).
   `SessionInfo.to_json` sends `work` (that list) and no longer sends `background` or `displayWork`.
   Computing it when the session is rendered means a state change alone re-renders it; every input
   already announces its own change.
3. The rule, in order. First every `stop_work` entry, in the Stop's order, each `holdsTurn` true: a
   subagent always; a shell when the turn has ended (state idle or done) or when `shown_shells`
   holds a shell with the same `task_id`, with that shell's text when it does; a monitor or task when
   the turn has ended. Then every entry of `shown_subagents` whose `agent_id` no `stop_work` entry
   has, `holdsTurn` false. Then every entry of `shown_shells` whose `task_id` no `stop_work` entry
   has (or that has none), `holdsTurn` false. Test activity is not in the list.
4. `sessions.py`: `set_background` becomes a plain `set_stop_work` through `_set`; replace
   `set_display_work` by setters for the two sources (or one setter taking both); each returns
   whether it changed.
5. `status.py`: `_show_children` keeps filtering `stop_work` to counted children and copying the
   Stop's descriptions onto labels, and publishes `shown_subagents` (the counted children of the
   tab's current conversation, by label, with `agent_id`), with no index. `apply_shell_reading`
   publishes `shown_shells` with the same availability rules as today, with no index. `reset_turn`,
   `apply_metadata`'s conversation branch and `agent_exited` set both sources to None as they set
   `display_work` today. Every other use of `background` becomes `stop_work`.
6. App, `DaemonTypes.swift`: `SessionInfo` loses `background` and `displayWork` and gains
   `work: [WorkItem]`, always sent. `WorkItem` has `kind` (`BackgroundJob.Kind`, still lenient),
   `text`, `holdsTurn`, and a `job` accessor giving `BackgroundJob(kind:text:)` for the card. Delete
   `DisplayWork` and `DisplayWorkItem`. `BackgroundJob` stays as the card's value type; drop its
   `Codable` conformance if nothing decodes it any more (the compiler says).
7. `SidebarModel`: `backgroundJobs(of:)` returns the turn-ended tabs' `holdsTurn` items in tab order,
   then active test runs, as today; `aggregate(tabs:)` is unchanged around it. `displayJobs(of:)`
   returns each tab's whole `work` list in tab order, then active test runs of turn-ended tabs (the
   existing final suffix). The index merge goes.
8. `WorkerTab.background`: the texts of its session's `holdsTurn` items, plus the active test line;
   the turn-ended filter goes (the daemon applied it). `isLiveWork`: any `holdsTurn` item or an
   active test, beside working and needs input. `WorkerLine.backgroundJobs`: the count of
   `holdsTurn` items.
9. Docs: in `docs/daemon-protocol.md`, replace the `displayWork` paragraph with two or three
   sentences on `work` (one ordered list; `holdsTurn` marks what the last Stop listed; the card
   draws all of it; status and the Operator read only `holdsTurn`) and fix the `session.changed` row
   if it still names the old fields. In `docs/status-model.md`, rewrite the paragraphs that describe
   `displayWork`, sources, legacy fallback and provider-ID merging (after the subagent-tracking
   paragraph) into one short paragraph stating the rule in step 3.

## Keep

- The background-shell reader (`BackgroundTranscripts`) and its availability rules
  (`work_since`, `shell_snapshot`, the `expected <= known` check): they decide when `shown_shells`
  is trustworthy, and a live shell during a working turn is a product feature.
- The filter of `stop_work` to children the engine counts, and the Stop dropping children it no
  longer lists: incident-driven (Claude's watchdog, the hand-back reminder).
- `testActivity` as its own field: `SignalWorkerIO`, `WorkerTab` and the card read it separately,
  and test runs stay the card's final suffix.
- `TaskStatus.background` and its label "In background", and `WorkerTab.background`'s name.
- `rowRelevant`: `work` is drawn, so it stays relevant.

## Decisions already taken

- A Stop-listed shell that the shell reader has seen end stays in the list, `holdsTurn` true, while
  the turn is ended, until the next hook replaces the Stop list. Today the card hides it while the
  status still counts it. Keeping the status and the Operator's "busy" exact matters more: Claude
  wakes the parent to report the ended shell, its session file turns busy within about one tick,
  and from then the tab is working and the rule hides it anyway. The card may show it for that tick.
- While a tab works or asks, Stop shells the reader does not list, monitors and tasks are left out
  of `work`, so `WorkerLine.backgroundJobs` counts fewer than today in that state. Accepted:
  `run_status` keeps the field and its meaning (work that will wake the worker).
- A Stop subagent whose child is counted but not shown (another conversation) is emitted from the
  Stop entry, as the fallback does today. It cannot really happen apart from that.
- Codex and PI never send a Stop list: their `work` is their counted children, `holdsTurn` false, as
  their card shows today.
- No decoding of `background` or `displayWork` is kept: the app and daemon ship together.

## Tests

Daemon:
- Rewrite the five display tests in `test_status.py` to assert `to_json()["work"]`: kind, text and
  `holdsTurn` per item, the Stop's order with known shells' texts, unanchored children and shells
  after, an unavailable shell source falling back to Stop shells only when the turn ended.
- Add: a Stop listing a subagent, a shell and a monitor, with the parent still working on its child,
  shows only the subagent; after the child ends and the turn is done, all three in the Stop's order,
  each `holdsTurn`; a reader shell started after the Stop follows with `holdsTurn` false.
- Add: a Stop-listed shell the reader saw end stays `holdsTurn` true while the turn is ended.
- Rename `background` to `stop_work` in the other `test_status.py` and `test_service.py`
  assertions; their expectations do not change. `test_background_shell_lifecycle_is_published_without_changing_state`
  asserts on `work` instead of `displayWork`.
- Delete the `set_display_work` id test in `test_sessions.py`: the behaviour is deleted (ids are
  compared now, so a new id is an ordinary change).

App:
- `SidebarModelTests`: `aTurnThatEndedWithWorkStillRunningIsInTheBackground` builds `work` with
  `holdsTurn` items; same expectations. Replace `displaySourcesPreserveStopOrderAndNeverDecideStatus`
  with: the card is the tabs' `work` in tab order whatever `holdsTurn` says, and a display-only item
  never makes a row `.background`. Keep `displayTestsRequireEndedTurnsAndKeepTheirExistingSuffix`
  with `work` items. `aBackgroundJobOfAKindNotKnownReadsAsATask` decodes `[WorkItem]` instead.
- `DaemonTypesTests.displayWorkDistinguishesUnavailableAndKnownEmptySources`: delete (behaviour
  deleted; availability is the daemon's now); add a decode test of `work` with `holdsTurn`.
- `SidebarProjectionTests.aDisplayOnlyJobInvalidatesItsRowWithoutChangingItsStatus`: build the event
  with a `work` item, `holdsTurn` false; same expectations.
- Add a `WorkerTabs` test: a working tab with only a `holdsTurn` subagent is still at work; an
  ended tab with a `holdsTurn` shell is still at work; one with only display items is not.

Fixtures: the session frames change. From `daemon/`, run
`AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py`, then the plain test
and the app's `WireContractTests`. Add to `daemon/tests/wire/PROVENANCE.md` a dated section: "6a of
the greenfield refactor replaced `background` and `displayWork` (with `legacyIndex`) by one ordered
`work` list whose items carry `holdsTurn`; re-captured with the same scripted run."

## Proof

- `daemon/.venv/bin/pytest -k "status or service or sessions or wire"` from `daemon/` while
  iterating; then `scripts/test.sh swift -- --filter SidebarModelTests`,
  `--filter WireContractTests`, `--filter SidebarProjectionTests`, `--filter TestActivityTests`.
- Contract suites: `tests/test_wire_contract.py` and `WireContractTests` both green on the
  re-recorded frames.
- Plain `scripts/test.sh`. No view changes, so no snapshot capture.

## Done when

- `rg -n "displayWork|DisplayWork|legacyIndex|display_work|legacy_index" app daemon docs --glob '!docs/research/**' --glob '!docs/plans/**'`
  returns nothing.
- `rg -n "session\.background|\.background\.isEmpty|\.background\.count" app/Sources` returns
  nothing.
- The wire frames carry `work` with `holdsTurn`, and `PROVENANCE.md` has the 6a line.
- Both contract suites and plain `scripts/test.sh` are green.

## Not in this step

- Per-reader identity checks and `Turn.generation` (6d). Moving the shell reader into
  `aitermd/agents/claude.py` (6f).
- Row marks and "needs you" decided in the projection (8b).
