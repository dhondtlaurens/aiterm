# 8a. One rule for "this task is under the Operator"

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 4e (Take Over removes the task's signal record),
5a (the `stopped` phase is gone), and every earlier step. Audit: SB F3.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- The plan's visible-change line says "a stopped or finished signal task no longer offers Take
  Over". After 5a no task can be `stopped`, so that half is already true. A finished task (phase
  `done`, for example after Then keep) still has its signal record, is drawn under its signal, and
  under the rule in the design notes ("under the Operator exactly when it has a `signalTask`")
  keeps offering Take Over. This brief follows the design notes: every task drawn under a signal
  offers Take Over, whatever its phase. If finished tasks must not offer it, that is a separate
  rule on the menu item, not a change to "under the Operator".
- The defects the audit found (Take Over on a row under its project, a project chevron that does
  nothing, a wrong count in Remove Project) came from copies that disagreed about `stopped`. With
  `stopped` gone they cannot happen any more; this step makes the agreement structural so a later
  phase or field cannot split the copies again.

## Why

Eight places in the app ask whether a task belongs to the Operator, each with its own spelling.
They were written while the record had a `takenOver` flag and a `stopped` phase, and they drifted:
some excluded stopped tasks, some did not, so one task was drawn under its project while its menu,
its project's fold and Remove Project treated it as the Operator's. Phase 4e removed the record on
Take Over and phase 5a removed `stopped`, so the true rule is now simple: a task is under the
Operator exactly when it has a signal record. The end state is one Core accessor that says so and
is the only way any code asks the question. A right change makes every place read that accessor
and changes no behaviour for any reachable state; a wrong change adds phase conditions, keeps a
private copy, or touches code that unwraps the record to read its fields.

## Today

As the code stands after phases 1 to 5:

- `TaskItem.signalTask` (Core, `app/Sources/AiTermCore/Models.swift` with the signal extensions in
  `AiTermCore/Operators/Signals/`) is the Operator's per-task record. After 4e a taken-over task
  has none (it carries 4e's small mark instead); after 5a its phase has no `stopped` case.
- The places that ask the yes/no question, by symbol (line numbers are today's, before phases 3
  to 5 moved things):
  1. `SignalSidebar.init` (`app/Sources/AiTerm/SignalSidebar.swift`, about line 19): the `held`
     filter, which decides which tasks are drawn under a signal and leave their project.
  2. `AppController.reveal(_:)` (`AppController+Operators.swift`, about line 91): whether a task
     row lives in the OPERATOR section.
  3. The same function, about line 96: whether to open the task's signal fold.
  4. `TaskRowView`'s context menu (`Views/SidebarRows.swift`, about line 477): whether to lead
     with Take Over.
  5. `ProjectActions.hasRows(_:)` (`ProjectActions.swift`, about line 241): whether a project has
     rows of its own to fold. Read by `ProjectActions.toggleCollapsed` and
     `AppController.activateSelection`.
  6. `ProjectActions.confirmRemove(project:)` (about line 280): how many worktrees "are run by
     signals" in the Remove Project alert.
  7. `RowFocus.row(id:)` (`RowFocus.swift`, about line 170): whether an id that is not a live
     signal is still a signal heading because a task under the Operator names it.
  8. `PerRow.dropGone` (`PerRow.swift`, about line 67): the same question for keeping a cell.
- Other boolean askers of the same question: `AppController.choose(task:)` (after 3b, the
  ownership switch that picks the opener), `AppController.takeOver(_:)` in
  `AppController+Signals.swift` (its guard and its "is yours" check after 4e),
  `AppState.allSignalTasks` (Core, `AppState+Signals.swift`, two filters),
  `AppState+WindowPlan.swift` (`adoptOnly:` for driven tasks), and any `signalTask == nil` filter
  3b, 4c or 4d left in `RowWindows`, `TaskTeardown` or `TaskLauncher`.
- Find them all with:
  `grep -rn "signalTask != nil\|signalTask == nil\|signalTask\.map\|signalTask?\.signal ==" app/Sources`
  Code that unwraps the record to read it (`if let record = task.signalTask`, `guard let record`,
  or a `signalTask.map` that builds something from the record's fields, as in
  `SignalWorkerIO` and `SignalOperatorController`) is not a question and stays.
- If any of these still reads `takenOver` or `.stopped`
  (`grep -rn "takenOver\|\.stopped" app/Sources/AiTerm app/Sources/AiTermCore/Operators`, ignoring
  `TaskRemoval.stopped`, the teardown note, and `DaemonSupervisor`), 4e or 5a is not finished:
  stop and report.
- Tests: `SignalSidebarTests` (rows move between headings), `SignalSidebarPresentTests`,
  `SidebarModelTests`, `RowAccessibilityTests`, `ItermFocusTests`, `SidebarRowRedrawTests`.

## Change

1. Add `TaskItem.isUnderOperator` in Core, beside the other signal extensions on `TaskItem`: true
   exactly when the task has a signal record. Document it in one sentence: a task under the
   Operator is drawn under its signal, offers Take Over, and is not one of its project's own rows.
2. Make each place listed under **Today** read it. Where a place needs the signal id too (places
   1, 7 and 8), filter with the accessor and then read `signalTask?.signal`; do not fold the id
   into the accessor.
3. Make the other boolean askers read it as well, including `allSignalTasks` and the window plan's
   `adoptOnly:`. A boolean question about the record's presence anywhere in `app/Sources` uses the
   accessor; nothing else changes in those functions.
4. Rewrite the doc comments on the places you touched to say what the code does now (for example
   `ProjectActions.hasRows`: "the tasks under the Operator are drawn under their signal, not
   here").

## Keep

- Every `if let record = task.signalTask` or `guard let record` that reads fields: those are reads,
  not the question.
- 4e's mark that keeps later signals from continuing a taken-over task: it answers a different
  question ("may a signal continue this task") and has its own reader in `MatchDecision`.
- Phase checks that mean something else, such as "a launching task with no checkout opens nothing"
  in `AppController.choose`: it is a question about the phase of a task already under the
  Operator. It may read the accessor for its first half.

## Decisions already taken

- Phase does not matter. A `done`, `blocked`, `watching`, `choosing`, `launching`, `working`,
  `archived` or forward-compatible `unknown` phase is still under the Operator. See **Planner,
  check this** for `done`.
- An archived task with a record is under the Operator too; the accessor is on `TaskItem`, so it
  answers for archive entries as it does for rows.
- A task under a removed signal is under the Operator: it stays under its removed signal's heading.
- No accessor on `AppState` and no second spelling: one property on `TaskItem`.

## Tests

- Add a Core test for the accessor: a task without a record is not under the Operator; a task
  with a record is, in every phase case `TaskPhase` has.
- Add one app test that the places agree, built on `SignalWorld`: for one ordinary task, one driven
  task in `working` and one driven task in `done` in the same project, assert that
  `SignalSidebar` draws exactly the two driven tasks under their signal, `ProjectActions.hasRows`
  is true only because of the ordinary task (and false once it is removed), the Remove Project
  alert's detail (asked through a `ScriptedPrompter` that answers Cancel) counts as run by signals
  exactly the driven tasks that have a checkout, and `RowFocus.row(id:)` resolves the signal's id as a heading after the
  signal is removed while its tasks remain.
- No test is deleted. A test that built a `stopped` or taken-over record was already rewritten by
  5a or 4e.

## Proof

- `scripts/test.sh swift -- --filter SignalSidebarTests`, `--filter SignalSidebarPresentTests`,
  `--filter SidebarModelTests`, `--filter RowAccessibilityTests`, `--filter SidebarRowRedrawTests`,
  and the Core suite holding the new accessor test.
- Then plain `scripts/test.sh`, started in the background.
- No view's pixels change; no snapshot capture is needed.

## Done when

- `grep -rn "signalTask != nil\|signalTask == nil" app/Sources` returns only the accessor's own
  definition. `grep -rn "signalTask\.map" app/Sources` returns only maps that read the record's
  fields (for example the controller's map of records by task id), none that ends in `== true`.
- `grep -rn "signalTask?\.takenOver\|phase != \.stopped\|phase == \.stopped" app/Sources` returns nothing. (The task's own `takenOver` mark from 4e is a different thing and stays.)
- The new tests pass and plain `scripts/test.sh` is green.

## Not in this step

- Carrying "under the Operator" on the row value for the menu (8b), the menu as a command list
  (8d).
- Take Over itself, its mark and `MatchDecision` (4e).
- The `stopped` phase and the stage machine (5a).
