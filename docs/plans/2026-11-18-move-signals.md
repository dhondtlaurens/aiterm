# Move signal headings up and down

Status: planned on 2026-11-18.

## Goal

A signal heading's context menu gets Move Up and Move Down, in the same group position and wording
as on a project heading. Each moves the signal one place in `AppState.signals`, which is saved with
the workspace and survives a relaunch. That order is also the signals' priority: when several
signals match one item in a pass, the highest heading starts the task and the others wait as its
pending stages. No drag, and nothing else changes visually.

## Approach

`AppState.signals` is already the drawn order, already saved, and already append-on-create
(`SignalOperatorController` line ~318: an edit replaces in place, a new signal appends). So the
change is a pure swap of two adjacent signals plus the menu wiring, and no schema change or
migration: existing workspaces keep their current priority, because their array is in creation order.

- **Model.** Add `canMove(signalId:_:)` and `move(signalId:_:)` to `AppState` beside the project and
  task movers (`Models.swift`): swap with the adjacent element of `signals`. Removed signals are not
  in `signals` (their headings are rebuilt from task records in `SignalSidebar` and always drawn after
  the live ones), and the Operator row is not a signal, so neither can be a neighbour by construction.
  Switched-off signals are live signals: they move and count as neighbours.
- **Projection.** `SignalSection` gains `canMoveUp`/`canMoveDown`, set in `SignalSidebar.init` from the
  live signal's index in `state.signals` (false for removed sections). `HeadingValue.Kind.signal`
  carries them, as `.project` does, so the heading body does not read the workspace to build a menu.
- **Owner.** `AppController+Signals.swift` (which already owns toggleCollapsed / toggleEnabled /
  removeSignal) gains `moveSignal(_ id:, _ step:) -> Bool`: guard `canChangeWorkspace`, then
  `workspace.mutate { $0.move(signalId:step) }`. It rechecks the current neighbour, so a stale menu
  at a new edge does nothing.
- **Menu.** In `HeadingRow.commands()`, the `.signal` case becomes
  `[Edit Signal…, Switch Off/On]`, `[Move Up, Move Down]`, `[Remove Signal…]` — the move group sits
  directly before the Remove group, as on a project. Enabled = `canChangeWorkspace && canMoveUp/Down`.
  Each action resolves the signal by id at invocation (`controller.state.signal(id:)`), like its
  siblings. Removed headings keep no commands. `RowCommandActions` gives VoiceOver the same actions.
- **Priority.** `MatchDecision.decide` drops the `createdAt` sort and ranks runnable signals by their
  position in the `signals` argument; `ItemRouter` already passes `state.signals.filter`, which keeps
  heading order. Position is a total order (ids are unique), so no tie-break is needed and `createdAt`
  no longer plays any part in ranking. Reordering affects later passes only; stages already queued
  stay where they are.
- **Docs.** `docs/architecture.md` (ItemRouter row: "the oldest signal" → "the higher signal"; the
  oldest-signal wording lives here, not in `docs/operators.md`); `docs/operators.md` gains one
  sentence near "Only one stage launches…" that the higher heading takes an item several signals
  match and the others wait as pending stages, and that Move Up / Move Down set that order;
  `docs/keyboard.md` ("Signal menus have Edit, Switch Off/On, Move Up/Move Down and Remove");
  `docs/design/ui-patterns.md` gets a line on signal heading movement. The 2026-11-14 plan stays as is.

## Files

Modify:
- `app/Sources/AiTermCore/Models.swift` — `canMove(signalId:)` / `move(signalId:)`.
- `app/Sources/AiTermCore/Operators/Signals/MatchDecision.swift` — rank by argument position.
- `app/Sources/AiTerm/SignalSidebar.swift` — `SignalSection.canMoveUp/canMoveDown`.
- `app/Sources/AiTerm/HeadingValue.swift` — carry them on `.signal`.
- `app/Sources/AiTerm/Views/SidebarHeadings.swift` — the two commands; adjust the `.signal` pattern matches.
- `app/Sources/AiTerm/AppController+Signals.swift` — `moveSignal`.
- Tests:
  - `app/Tests/AiTermCoreTests/ModelsTests.swift` — up/down swap, first/last refused, missing id,
    other signals, tasks and items untouched.
  - `app/Tests/AiTermCoreTests/Operators/SignalDomainTests.swift` — rename
    `oldestSignalOwnsNewItemAndOtherSignalsQueue` to the higher-heading rule and prove it with the
    *newer* signal first in the array; fix `aMatchGivesEachStageItsSignalsConfiguration`, whose
    `[new, old]` fixture assumed creation order.
  - `app/Tests/AiTermTests/RowAccessibilityTests.swift` — extend
    `signalCommandsSwitchAndOmitRemovedSignals`: groups `[[Edit, Switch], [Move Up, Move Down], [Remove]]`,
    edge disabling for first/middle/last/singleton, all disabled while locked, removed heading still empty.
  - `app/Tests/AiTermTests/SignalSidebarTests.swift` — sections' move flags with a removed signal's
    heading after the last live one (last live has Move Down off) and a switched-off signal counted.
  - `app/Tests/AiTermTests/AppControllerTests.swift` — invoke the real heading command, check
    `rows.signalSections` order, a retained command at a new edge does nothing, locked workspace
    refuses, `savedWorkspace()` round-trips the order.
  - `app/Tests/AiTermTests/Operators/SignalEngineTests.swift` (ItemRouter) — after a
    move, a shared item starts under the higher heading with the other as a pending stage.
- Docs listed above.

## Proof

Write the model, MatchDecision and command tests first. Iterate with
`scripts/test.sh swift -- --filter` on ModelsTests, SignalDomainTests, SignalForwardCompatibilityTests,
RowAccessibilityTests, SignalSidebarTests, AppControllerTests and SignalEngineTests, started in
the background. Snapshots: `scripts/snapshots.sh build/signal-move-before` and `…-after`; the PNGs must
match byte for byte (menus are not drawn; the command tests are the evidence for the new items).
`operator-signals/state.json` golden must not change. Plain `scripts/test.sh` before the commit;
`scripts/test.sh all` before any merge. No `run-dev.sh` without the maintainer's go.

## To-dos

- [ ] `AppState.move(signalId:)` / `canMove(signalId:)` with ModelsTests.
- [ ] MatchDecision ranks by heading position; SignalDomainTests updated and an ItemRouter test proves the higher heading wins after a move.
- [ ] Projection flags, the two heading commands and `moveSignal`, with RowAccessibility, SignalSidebar and AppController (persistence) tests.
- [ ] Docs, before/after snapshots compared, plain gate green.
