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
  (`busy_queue`). Workers whose turn ended with nothing running get nothing. A first worker still launching
  counts as at work (the tabs read as of now); one whose window iTerm2 lists only after Pause gets its note
  when its agent appears (`pauseLateWorkers`, on every change of the tabs); a shell tab waits for its agent.
  A worker is tried once per pause, except when the refusal only means not ready yet (no input box, screen
  unread, iTerm2 away): it is tried again as its tabs change.
- **Resume = AiTerm types "carry on".** The workers that got the pause note are persisted on the run, so a
  restart keeps them. Resume, after the Operator is back and while the broadcast still reads paused (its news
  held, its tools refusing), delivers a carry-on
  note to each, marks each delivered one as messaged (`WorkerTurnReader.messaged`, the `message_task` path)
  so its paused turn never reads as "ready for the Operator", clears the set, then makes the state active and
  wakes the Operator with
  `resumed`; when a carry-on did not land, the one wake reason says paused workers missed it and to steer
  them with `message_task` (a wake line may carry no digit, so it cannot name a task key).
  Each recorded worker keeps the task's ownership generation at pause time. Resume revalidates before
  typing: the run has not ended, the task is still driven (`!takenOver`), still `.working`, its ownership
  unchanged and the tab still open; anything else is dropped from the set silently, since Take Over and
  Stop Task stay available while paused.
- **Ordering.** Every note Pause or Resume types runs on one queue per run, kept on the controller: each
  new signalling task awaits the one before it, so notes reach the workers in the order you pressed the
  controls. `pause(run:)` stays synchronous (no caller changes): it saves the pause, then queues its
  signalling. The workers it will signal are recorded and saved before any note is typed; each is checked
  again right before its note (a task stopped or taken over meanwhile gets none), and a refused delivery
  is removed afterwards. `resume(run:)` queues its carry-on behind any pause still typing; the broadcast
  reads paused until every carry-on is typed, so no Pause can come in between (a paused broadcast offers
  only Resume). Resume removes from the set only the workers it handled. `end(run:)` sets the handed
  tasks' ownership on the helper first, so a note mid-paste keeps its Enter back, then awaits the queue;
  both loops stop once the broadcast has ended.
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
- `app/Sources/AiTerm/Operators/OperatorController+Controls.swift` (modify): the pause and carry-on notes
  (`WorkerPrompts` reads prompts off screens; it holds no typed texts). `pause(run:)` saves as now, then
  queues the run's signalling: record and save the workers to signal (with their ownership), recheck each,
  deliver the pause note, drop the refused ones; `resume(run:)` queues behind it while still paused,
  revalidates each recorded worker, delivers carry-on, marks messaged, removes the workers it handled, then
  makes the state active and wakes (saying when a carry-on missed). `end(run:)` sets the new ownership,
  then awaits the queue; the set is cleared with the end.
- `app/Sources/AiTerm/Operators/OperatorController.swift` (modify): holds the per-run signalling queue.
- `app/Sources/AiTermCore/Operators/AppState+Operators.swift` (modify): `OperatorRun.isPausedByYou`, paused by
  you as against the Operator's window closing.
- `app/Sources/AiTermCore/Operators/WorkerTabs.swift` (modify): `WorkerTab.isStillAtWork`, shared by what a pause
  signals and what keeps a task `pausing`.
- `app/Sources/AiTermCore/Sidebar/OperatorLine.swift` (modify): `task(...)` says `pausing` / `paused` for a
  `.working` task of a broadcast you paused; `session(...)` says `pausing · n tasks` until none works.
- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift` (modify): `TaskRow` gains `paused`; `taskRow` sets it
  and does not hold a paused task's status at the spinner (`heldStatus`).
- `app/Sources/AiTermCore/Sidebar/BroadcastRow.swift` (modify): `OperatorRow` gains `paused`, set in
  `operatorRow(...)` when the broadcast is paused by you and no driven task has a working worker.
- `app/Sources/AiTerm/Views/SidebarRows.swift` (modify): `TaskRowMark` draws the pause sign for a paused
  row as for a queued one (one `pause.fill` case shared by both).
- `app/Sources/AiTerm/Views/Operators/OperatorRowView.swift` (modify): passes `paused` to the mark.
- `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift` (modify): a new `broadcast-paused.png`, the
  sidebar while one task is still pausing and once all stopped; the paused Operator row in
  `broadcast-row-states.png` shows its tasks stopped.
- `docs/operators.md` (modify): "Your controls" says Pause sends the note and Resume the carry-on.

## Proof

- `OperatorLineTests` / `SidebarModelTests` (core): pausing vs paused per worker state, needsYou wins,
  offline gets neither, queued unchanged, Operator row `pausing · n tasks` then `paused` with the sign.
- `RunControlsTests`: Pause delivers the note to working workers and to ended ones with background work,
  not to idle ones, and records them (saved before typing); a refused delivery is dropped; Resume delivers
  carry-on to the recorded ones, marks them messaged, clears the set and names the unreached in the wake;
  Resume skips a worker taken over, stopped or whose ownership moved; Resume and End called while the
  pause notes are still being delivered wait for them (a slow fake daemon), so no pause note follows a
  carry-on; the broadcast reads paused, no Operator wake goes and Pause is refused while the carry-ons are
  typed; a task stopped while the pause notes are typed gets none; End sets the new ownership before it
  waits for a note being typed; End clears the set; a saved file without the field loads.
- Core tests also cover a task whose worker ended its turn with background work: `pausing`, and the
  Operator row not yet `paused`.
- `OperatorSnapshotTests`: `broadcast-paused.png` joins the pinned list and renders; there are no checked-in
  goldens, so the images are opened and looked at (`scripts/snapshots.sh`).
- Run: debug snapshot of the paused scene; then a live broadcast with two tasks, Pause while one works:
  the note lands, its row goes `pausing` → `paused` with the sign, the Operator row follows; Resume types
  carry-on and the task works on.
- `scripts/test.sh` before each commit, `scripts/test.sh all` before merge.

## To-dos

- [x] Persist the paused workers on `OperatorRun` (decode-compatible), with a load test.
- [x] Pause's signalling task: record, save, deliver, drop refused; working and background workers; tests.
- [x] Resume and End await it; Resume revalidates, delivers carry-on, marks messaged, clears, names the
      unreached; End clears; ordering and eligibility tests.
- [x] Task line `pausing` / `paused` and the task row's pause sign; core tests.
- [x] Operator row `pausing · n tasks` / `paused` with the sign; core tests.
- [x] Snapshot scene and golden; `docs/operators.md`.
- [ ] Live run as in Proof (needs `scripts/run-dev.sh`, on the maintainer's go).
