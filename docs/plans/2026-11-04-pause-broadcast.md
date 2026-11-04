# Pause a broadcast: signal the workers and show the pause sign

## Goal

Today Pause only holds back new work (no starts, no deliveries, Operator tools refused) and every worker
finishes its turn unaware. Pausing should tell each working task to wrap up and stop, show the pause sign
(the queued one, `pause.fill` in `Palette.idleRing`) on a task once its workers have stopped, and once every
task has stopped, on the Operator's row too. Resume gets those workers going again.

## Approach

Decided while grilling:
- **Signal = a typed note, not Esc.** On Pause, AiTerm delivers a short note to every worker tab of a driven
  `.working` task whose session is still working, or whose ended turn left background work running
  (`WorkerTab.background`, which wakes it again): finish the step you are on, end your turn, and when
  background work wakes you, do not go on; wait to be told to carry on. Delivery goes through the daemon's
  normal rules (`daemon.deliver`, the task's ownership), which the delivery check already covers mid-turn
  (`busy_queue`). Workers whose turn ended with nothing running get nothing.
- **Resume = AiTerm types "carry on".** The workers that got the pause note are persisted on the run, so a
  restart keeps them. Resume, after the Operator is back and the state is active again, delivers a carry-on
  note to each, marks each delivered one as messaged (`WorkerTurnReader.messaged`, the `message_task` path)
  so its paused turn never reads as "ready for the Operator", clears the set, then wakes the Operator with
  `resumed`, naming any worker the carry-on could not reach so it steers that one with `message_task`.
  Each recorded worker keeps the task's ownership generation at pause time. Resume revalidates before
  typing: the run has not ended, the task is still driven (`!takenOver`), still `.working`, its ownership
  unchanged and the tab still open; anything else is dropped from the set silently, since Take Over and
  Stop Task stay available while paused.
- **Ordering.** Every note Pause or Resume types runs on one queue per run, kept on the controller: each
  new signalling task awaits the one before it, so notes reach the workers in the order you pressed the
  controls. `pause(run:)` stays synchronous (no caller changes): it saves the pause, then queues its
  signalling. The workers it will signal are recorded and saved before any note is typed; a refused
  delivery is removed afterwards. `resume(run:)` queues its carry-on behind any pause still typing, and
  before each carry-on checks the run is still not paused: a Pause pressed meanwhile stops the rest, and
  those workers stay recorded for the next Resume. Resume removes from the set only the workers it
  handled, never the whole set. `end(run:)` awaits the queue, then clears the set.
- Only your Pause signals. An Operator window that closed (`operatorOffline`) keeps today's behaviour: no note,
  no task pause sign.

What the rows say while the broadcast is paused by you:
- Driven `.working` task, a worker still working or with background work running: line `pausing`
  (acting look, spinner stays).
- Driven `.working` task, no worker working and none with background work: line `paused`, mark the pause
  sign, status no longer the held spinner.
- A request, a prompt or a block still wins: `needsYou`, amber. Queued, in review, accepted, done keep their own
  line and mark.
- Operator row: `pausing · 2 tasks` while any driven task is still `pausing`; once none has, `paused`
  with the pause sign. The heading and board band already say `paused`.

The paused workers are kept on `OperatorRun`, not as an `OperatedFlag`: flags are on the frozen `run_status`
wire, the run's saved state is not.

## Files

- `app/Sources/AiTermCore/Operators/OperatorModels.swift` (modify): `OperatorRun` gains the persisted set
  of paused workers (task id + tab key), decoded as empty from older files.
- `app/Sources/AiTerm/Operators/WorkerPrompts.swift` (modify): the pause note and the carry-on note.
- `app/Sources/AiTerm/Operators/OperatorController+Controls.swift` (modify): `pause(run:)` saves as now, then
  queues the run's signalling: record and save the workers to signal (with their ownership), deliver the
  pause note, drop the refused ones; `resume(run:)` queues behind it, revalidates each recorded worker,
  stops if paused again, delivers carry-on, marks messaged, removes the workers it handled and names the
  unreached in the `resumed` wake. `end(run:)` awaits the queue and clears the set.
- `app/Sources/AiTerm/Operators/OperatorController.swift` (modify): holds the per-run signalling queue.
- `app/Sources/AiTermCore/Sidebar/OperatorLine.swift` (modify): `task(...)` says `pausing` / `paused` for a
  `.working` task of a broadcast you paused; `session(...)` says `pausing · n tasks` until none works.
- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift` (modify): `TaskRow` gains `paused`; `taskRow` sets it
  and does not hold a paused task's status at the spinner (`heldStatus`).
- `app/Sources/AiTermCore/Sidebar/BroadcastRow.swift` (modify): `OperatorRow` gains `paused`, set in
  `operatorRow(...)` when the broadcast is paused by you and no driven task has a working worker.
- `app/Sources/AiTerm/Views/SidebarRows.swift` (modify): `TaskRowMark` draws the pause sign for a paused
  row as for a queued one (one `pause.fill` case shared by both).
- `app/Sources/AiTerm/Views/Operators/OperatorRowView.swift` (modify): passes `paused` to the mark.
- `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift` (modify): the paused scene shows one task pausing,
  one paused and the Operator row's line.
- `docs/operators.md` (modify): "Your controls" says Pause sends the note and Resume the carry-on.

## Proof

- `OperatorLineTests` / `SidebarModelTests` (core): pausing vs paused per worker state, needsYou wins,
  offline gets neither, queued unchanged, Operator row `pausing · n tasks` then `paused` with the sign.
- `RunControlsTests`: Pause delivers the note to working workers and to ended ones with background work,
  not to idle ones, and records them (saved before typing); a refused delivery is dropped; Resume delivers
  carry-on to the recorded ones, marks them messaged, clears the set and names the unreached in the wake;
  Resume skips a worker taken over, stopped or whose ownership moved; Resume and End called while the
  pause notes are still being delivered wait for them (a slow fake daemon), so no pause note follows a
  carry-on; Pause pressed while Resume's carry-ons are being delivered to several workers stops the rest,
  its pause notes follow the carry-ons already typed, and the workers stay recorded; End clears the set; a saved file without the field loads.
- Core tests also cover a task whose worker ended its turn with background work: `pausing`, and the
  Operator row not yet `paused`.
- `OperatorSnapshotTests`: the paused scene's golden changes on purpose (new rows); nothing else moves.
- Run: debug snapshot of the paused scene; then a live broadcast with two tasks, Pause while one works:
  the note lands, its row goes `pausing` → `paused` with the sign, the Operator row follows; Resume types
  carry-on and the task works on.
- `scripts/test.sh` before each commit, `scripts/test.sh all` before merge.

## To-dos

- [ ] Persist the paused workers on `OperatorRun` (decode-compatible), with a load test.
- [ ] Pause's signalling task: record, save, deliver, drop refused; working and background workers; tests.
- [ ] Resume and End await it; Resume revalidates, delivers carry-on, marks messaged, clears, names the
      unreached; End clears; ordering and eligibility tests.
- [ ] Task line `pausing` / `paused` and the task row's pause sign; core tests.
- [ ] Operator row `pausing · n tasks` / `paused` with the sign; core tests.
- [ ] Snapshot scene and golden; `docs/operators.md`.
- [ ] Live run as in Proof.
