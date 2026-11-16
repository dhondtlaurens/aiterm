# 5f. The chat's lifecycle is one saved state; a task's act is runtime-only

Implementer: Opus 5.5, high effort. Depends on: phases 1 to 4 and steps 5a to 5e. Audit findings:
operator-runtime F8 and F9, operator-core F2 (its session-lifecycle part)
(`docs/research/2026-11-16-greenfield-audit/`).

## Why

The Operator chat's lifetime grew by patches: `startingFresh` for renewal, a `handover` enum for
close, revoke and open, then `finishing` (kept optional "so existing saved sessions retain their
format") for retiring the chat when the workload ends, and `wakeAwaitingRead` for an unread wake.
Beside them sit four runtime flags: `opened` (when this run opened the window), the wake slot
`wakePending`, `waking`, and `wakeLeftUnsent`. The keeper's `transition` is a 95-line state machine
over the combinations, some of which no code produces, and "is the chat idle" is answered three
different ways in one tick. Separately, a task's current act (`SignalTask.currentAct`) is saved in
the workspace and copied into `run_status`, although `OperatorActivityTracker` already tracks the
same acts at runtime; a crash leaves "Operator starting its worker" on a row until its next stage.
The end state: one saved `OperatorSession.Lifecycle` beside the session's `generation`, one runtime
wake state in the waker, one idle rule, and task acts that live only in the tracker. Nothing a
person sees changes; `run_status` loses `tasks[].currentAct`; the saved `operatorSession` changes
shape and its fixture is re-recorded.

## Today

Described as after 5e. 5d split the controller: `OperatorChat` owns the chat's window and session
and wraps `OperatorSessionKeeper` (`app/Sources/AiTerm/Operators/OperatorSessionKeeper.swift`);
`OperatorWaker` owns the wake slot, delivery and its classification, and the acknowledgement;
`ActivityWriter` writes the activity log. 5e left the tick, `OperatorInFlight` and
`OperatorTiming.openingGrace` (today `firstWorkerOpening`). Re-read the code; anchors are today's.

Saved, in `OperatorSession` (`app/Sources/AiTermCore/Operators/Signals/OperatorSession.swift`):
`startingFresh: Bool`, `finishing: Bool?`, `handover: OperatorHandover?` (`OperatorHandover.swift`:
`closing`, `revoking`, `opening`, `unknown`), `wakeAwaitingRead: Bool?`, plus `window`,
`conversation`, `session` and `generation`, which stay. Combinations the code writes, and what each
means:

| Saved today | Meaning |
| --- | --- |
| all clear, no window, no conversation | no chat (a new or retired record) |
| `startingFresh`, `handover = opening` | generation N must be opened; open in flight or its reply lost |
| all clear, `window` set | chat open |
| `startingFresh`, `handover = closing` | closing the old chat to open a fresh one (renewal) |
| `startingFresh`, `finishing`, `handover = closing` | closing the chat because the workload ended |
| `handover = revoking` (with or without `finishing`) | window closed, token being revoked, then open or stop |
| `handover = unknown` | from a newer build: inert |
| `wakeAwaitingRead` | a wake was typed into the open chat and no global `run_status` read it yet |

Runtime: `OperatorChat`'s open record (today's `opened`: window, generation, time, or whatever 3b
left of it) feeds `sessionIssue`'s "did not start in its window" after the grace;
`OperatorWaker`'s `pending` (first event wins), `waking` and `leftUnsent` ("the unsent text in the
chat may be our wake line"); `waker.unread` is "pending, delivering or `wakeAwaitingRead`".
`waker.restore()` turns a saved unread wake into a pending `session_recovered` wake with
`leftUnsent` set; `waker.reset()` clears `leftUnsent` when the chat finishes.

Idle, three ways (5d kept them verbatim): retirement in `chat.finishWhenNoWork` (tab turn ended and
not stopped, no tool call, `OracleConsult.isIdle`, no tracked activity, `waker.unread` false); the
"renewal in progress but no work" call of `chat.finishIfIdle` (no tool call and `oracle.isIdle`,
not `waker.waking`); renewal in `chat.freshIfDue` (tab ended and not stopped, `oracle.isIdle`, no
tool call, no wake, exactly one tab in the chat's window). The controller's `activeTools` and
`OracleConsult`'s in-flight count exist only for these checks: verify with
`rg -n 'activeTools|isIdle' app/Sources/AiTerm`.

Readers of the saved flags outside the keeper: `RequestWatch` (no merge while `startingFresh`),
the worker-answer round and the agent-choice round (refuse unless `startingFresh == false`),
`SignalOperatorToolHandler.requireSession` (refuse while `startingFresh`), `FreshStartPolicy`,
`SignalOperatorRowValue.make` in `app/Sources/AiTerm/SignalSidebar.swift` ("finishing its session",
"starting fresh · n tasks carried over", `shown`, `completedActivity`), the snapshot pose `fresh`
in `Snapshots/SignalSidebarSnapshots.swift`. Find all with
`rg -n 'startingFresh|finishing|handover|wakeAwaitingRead|OperatorHandover' app/Sources app/Tests`.

`currentAct` is written by `StageRunner`, `ThenRunner`, `RequestWatch`, the worker-answer and
agent-choice rounds, the tool handler (from `OperatorTool.act`), `SignalWorkerIO`, and cleared in
`SignalTransitions`; it is read by `SignalSidebar.present`, `SignalOperatorRowValue.make` (fallback
when no tracker line), `SidebarProjection.refresh` (copied into the drawn record) and
`OperatorDigest.TaskLine`. `rg -n 'currentAct' app/Sources app/Tests`.

Tests: `SignalSessionKeeperTests`, `SignalFreshSessionTests`, `SignalOperatorLifetimeTests`,
`SignalOperatorIssueTests`, `SignalDomainTests` (`FreshStartPolicy`), `SignalSidebarTests`,
`SignalSidebarPresentTests`, `SignalWatchTests`, `OperatorActivityTests`, `SignalSavedFormatTests`.

## Change

1. **Add `OperatorSession.Lifecycle`** (Core, in `OperatorSession.swift`), saved under the key
   `lifecycle`, default `idle`:
   - `idle`: no chat.
   - `opening`: generation N is to be opened; covers an open in flight and one whose reply was lost.
   - `open(since:wake:)`: the chat is open; `since` is when AiTerm opened it in its current window;
     `wake` is nil, `sent` (typed and sent, not yet read by a global `run_status`) or `maybeUnsent`
     (a wake line may sit unsent in the chat).
   - `closing(then:)` and `revoking(then:)`, with `then` either `renew` or `retire`. The window being
     closed is the session's `window`.
   - `unknown(JSONValue)`: inert, as every saved enum here.
   Encode it in the same `{"kind": …, "value": …}` shape as `TaskPhase`, by hand like it (5h
   converts them together). A value that does not decode becomes `unknown`.
   Give it three predicates and use them everywhere instead of the flags: `isOpen`; `isChanging`
   (opening, closing, revoking or unknown: today's `startingFresh == true`); `isRetiring` (closing or
   revoking with `retire`: today's `finishing == true`).
2. **Delete** `startingFresh`, `finishing`, `handover`, `wakeAwaitingRead` and `OperatorHandover`
   (`OperatorHandover.swift`). `generation`, `window`, `conversation` and `session` stay.
3. **Rewrite `OperatorSessionKeeper.transition`** as one switch over the lifecycle, keeping every
   effect and its order (close before revoke; revoke before generation increments; adopt an
   unrecorded opening's window before retiring it):
   - `ensure` with work: `idle` saves `opening` (with `createdAt`) before calling the daemon;
     `opening` opens and saves `open(since: now, wake: nil)` with the window; `open` does what 5d
     and 3b left for an open chat; `closing(renew)` and `revoking(renew)` continue the renewal.
     `ensure` does nothing while `isRetiring` (today's `finishing` guard) or `unknown`.
   - `finishIfIdle` with no work and the chat idle: `opening` adopts an existing window, then
     `closing(retire)`; `open` saves `closing(retire)`; `closing(renew)` and `revoking(renew)` become
     the `retire` cases. A retirement already saved continues whatever the idle rule says, as today.
   - `freshIfDue` saves `closing(renew)`, then runs `ensure`.
   - A close that is safely deferred (`SignalOperatorCloseDeferred`) puts back `open(since: now,
     wake: nil)`; a close or revoke that fails otherwise leaves the saved case for the next pass.
   - After revoke, for both `retire` and `renew`, exactly as today: increment `generation`, set
     `createdAt`, clear `conversation` and `session`, prune. Then `retire` saves `idle` and `renew`
     saves `opening`. The increment on retirement matters: the daemon has revoked that generation's
     token and refuses to register it again, so the next workload's chat must open as the next
     generation. Do not make the increment a renewal-only step.
4. **One idle rule.** Add a pure Core function beside the lifecycle,
   `OperatorSession.chatIsIdle(tab:tabsInWindow:actsRunning:wakeUnread:)`: true when no tracked act
   is running, no wake is unread, the chat's window holds at most its own tab, and the chat's live
   tab, if any, ended its turn and is not stopped on an error. `OperatorChat` computes its inputs
   (the tab from the session's window, the tracker's `isRunning`, `waker.unread`) and the
   controller's three call sites (`finishIfIdle`, `finishWhenNoWork`, `freshIfDue`) all pass it. The
   keeper's `idle`/`wakePending` parameters become this one Bool. `FreshStartPolicy.shouldStart`
   reads `isOpen` and the idle Bool; its `wakePending` parameter goes.
5. **`activeTools` and `OracleConsult.isIdle` go.** Every tool answer runs inside the tracker
   (`respond` wraps it in `activity.during`) and every Oracle use does too (`OracleConsult` runs
   inside "consulting the Oracle"). The tracker's `isRunning` covers both. Delete the controller's
   `activeTools` and `OracleConsult`'s in-flight count once nothing reads them; move
   `OracleConsultTests`' "not idle while a held run is in flight" assertion to the tracker's
   `isRunning`.
6. **One runtime wake state.** In `OperatorWaker`, replace `pending` and `waking` with one value:
   none, pending (event, id) or delivering (event, id); the first event still wins while one is
   pending or delivering. `leftUnsent` becomes the saved `open.wake`, and `unread` reads the new
   state:
   - Before typing, save `sent` unless it is already `maybeUnsent` (today: `wakeAwaitingRead =
     true` before `deliver`).
   - Delivered: `sent`; the pending event clears. Partial, or the reply lost: `maybeUnsent`.
   - Refused while `sent` (nothing earlier was pasted): clear to nil (today's "clear
     `wakeAwaitingRead` unless `wakeLeftUnsent`"); refused with `unsentInput` while `maybeUnsent`:
     today's "Text waits unsent" failure.
   - `waker.acknowledge()` (after a global `run_status`) clears the waker state and saves
     `wake = nil`.
   - `waker.restore()`: an `open` with any unread wake is saved as `maybeUnsent` and queues
     `session_recovered`, as today. `waker.reset()` has nothing left to clear and goes; the chat's
     `finished` wiring keeps its three `succeed` calls.
   - Delivery requires `isOpen` and not paused (today `!startingFresh && !paused`).
     `dropWhenNoWork()` stays, reading the new state.
   `waker.unread` (used by the idle rule and by the scoped `run_status` refusal) means: the waker
   state is not none, or `open.wake` is not nil.
7. **The chat's runtime open record goes.** `chat.sessionIssue`'s "The Operator did not start in
   its window. Open the chat to inspect it." holds when the lifecycle is `open(since:)`,
   `openingGrace` has passed since `since`, and the chat's window holds the session's tagged tab only
   as a shell. If 3b left a "window open or opening" check on that record, it reads `opening`
   instead. `chat.windowClosed(_:)` no longer touches the chat's lifecycle.
8. **Map every reader** (`isChanging` replaces `startingFresh == true`; `!isChanging` with a session
   present replaces `startingFresh == false`; `isRetiring` replaces `finishing == true`):
   `RequestWatch` merges only when not `isChanging`; both rounds and `requireSession` refuse while
   `isChanging`; `SignalOperatorRowValue.make` shows "finishing its session" for `isRetiring`, then
   "starting fresh · n tasks carried over" for `isChanging`, `shown` includes `isRetiring`, and
   `completedActivity` requires not `isChanging`; the tick's "renewal in progress but no work"
   branch reads `isChanging && !isRetiring`; `reconcileIfIdle` reads "the chat is `open` or
   `closing`" where it read `window != nil`.
9. **Acts become runtime.** Extend `OperatorActivityTracker` (`OperatorActivity.swift`) with
   per-task acts: `acting(task:act:body)` keeps a stack per task while the body runs (the latest
   running act shows); `act(for:)` answers a task's current act; `latestAct` answers the most recent
   (task, act) pair for the Operator row; synchronous begin and end calls underlie both so a
   snapshot pose can hold an act. Begin and end pulse `changed`. Each owner that wrote
   `currentAct` runs its body inside `acting` with the same words ("starting its worker",
   "archiving it", "removing it", "consulting the Oracle", "merging it", "answering its worker",
   "checking its result", "choosing its agent"); the owners take the tracker at construction,
   defaulting to a fresh one. The controller's `respond` passes `OperatorTool.act` and the request's
   task. Delete `SignalTask.currentAct` and every write and clear, including those in
   `SignalTransitions` (the actions 5a added among them) and `SignalWorkerIO`.
10. **Rows draw the tracker.** `SignalSidebar` takes the tracker's acts by task; `present` shows
    "Operator " + act where it showed `currentAct`. `SignalOperatorRowValue.make`'s fallback reads
    `latestAct` with today's name substitution instead of a saved record. `SidebarProjection` adds
    the acts to its `Inputs` (so a change redraws) and stops copying `currentAct`. The `acting`
    snapshot pose begins the act on the controller's tracker with the same words.
11. **`run_status`.** Delete `OperatorDigest.TaskLine.currentAct`. No other digest field changes;
    the lifecycle is not in the digest.

## Keep

- `generation`, `window`, `conversation`, `session`: identities, not lifecycle flags. The renewal
  and retirement paths read and clear them exactly as today.
- Close before revoke, and confirming a missing window by snapshot rather than closing "an old
  number" (`closeOperator`): real incidents behind both.
- `SignalOperatorCloseDeferred` and the `DeliveryCode` list that proves no close was attempted.
- The keeper's `pass` single flight and `holds(...)` rechecks after each await.
- Today's first-event-wins wake coalescing and the one fixed wake line per event
  (`OperatorWakeEvent`): the daemon checks the list.
- `OperatorActivityTracker.during(_:)` and the Operator row's words: unchanged.

## Decisions already taken

- **No compatibility.** A saved `operatorSession` from an earlier build (no `lifecycle`) does not
  decode; the release notes' reset command clears it. Add no default, fallback or reader for the
  old keys.
- **A renewal-in-progress whose work ended** retires under the one idle rule. Its tab may already
  be gone; no tab counts as idle.
- **The window-holds-one-tab condition now also gates retirement.** Today a retirement against a
  window holding a person's extra tab tried a close that was deferred every tick; now it waits.
- **Renewal now also waits for running acts** (a stage launch, a Then, a host read). It is checked
  every tick; a delay of a minute at 150k tokens is harmless.
- **An open chat whose agent exited** (only a shell left in its tagged tab) now shows "did not start
  in its window" after a relaunch too, since `since` is saved. It is the same fact and wording;
  today the check only covered windows opened by the current run.
- **An unknown lifecycle** is inert: the keeper does nothing, tools refuse as changing, the row
  says "starting fresh". Only a newer build writes one.
- **Take Over during an act**: the act ends when its owner's body returns; the task is ordinary by
  then (4e) and its row is no longer drawn from the signal section.
- **Nested acts on one task** show the innermost while it runs, then the outer one again. Today a
  nested owner's `defer` cleared the act to nothing.

## Tests

- Keep, or add if no test covers it after the rewrite: a workload that retires and is followed by
  another workload opens a chat whose generation is one higher than the retired one, and that
  generation is the one registered with the helper (`SignalOperatorLifetimeTests`,
  `SignalSessionKeeperTests`). This is the test that fails if retirement stops incrementing.

- Rewrite assertions on the old flags to the lifecycle in `SignalSessionKeeperTests`,
  `SignalFreshSessionTests`, `SignalOperatorLifetimeTests`, `SignalOperatorIssueTests`
  (`aRelaunchWithAnUnreadWakeCountsTheTextLeftInTheChat` saves `open(wake: sent)`) and
  `SignalAgentChoiceTests` (its rig sets an open lifecycle instead of `startingFresh = false`). Every
  test that builds an open chat by setting `window` must also set `open`; add a builder for an open
  session in `app/Tests/AiTermTestSupport/Builders.swift` and use it.
- `SignalDomainTests`' `FreshStartPolicy` cases: same cases on the new signature.
- Replace `currentAct` setup in `SignalSidebarTests`, `SignalSidebarPresentTests` and the assertion
  in `SignalWatchTests` (about line 165) with tracker acts; the expected lines stay identical.
- Add, test first: a table test of `chatIsIdle`; the lifecycle's encode and decode for every case
  including `unknown`; each saved transition across a restart (open, renew, retire, deferred close
  rolling back); an act shown on its row disappears when its owner's body ends, and a relaunch
  shows no act.
- Re-record `operator-signals/state.json`: build its session with `open(since:wake: nil)`, then
  `AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests`, and add a
  line to `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/PROVENANCE.md`: "Step 5f
  replaced `startingFresh`, `finishing`, `handover` and `wakeAwaitingRead` with one `lifecycle`
  and removed the saved `currentAct`; re-recorded by the command above."

## Proof

- Iterate: `scripts/test.sh swift -- --filter 'SignalSessionKeeperTests|SignalFreshSessionTests|SignalOperatorLifetimeTests|SignalOperatorIssueTests|SignalDomainTests|SignalSidebarTests|SignalSidebarPresentTests|SignalWatchTests|OperatorActivityTests|SignalSavedFormatTests|SignalJourneyTests'`.
- Snapshots: `scripts/snapshots.sh build/5f-after`, then read the Operator section poses (`acting`,
  `fresh`, `questions`, `issue`, `watching`, `paused`) against `build/refactor-before`: equal pixels.
- Then plain `scripts/test.sh`, started in the background.

## Done when

- `rg -n 'startingFresh|finishing|OperatorHandover|wakeAwaitingRead|leftUnsent|activeTools|currentAct' app/Sources app/Tests`
  returns nothing outside the PROVENANCE line; `OperatorWaker` has one state value instead of
  `pending` and `waking`; `OperatorChat` has no runtime open record; `OracleConsult` has no
  in-flight count.
- `rg -n 'handover' app/Sources` finds only prose about handing work over, not a type or field.
- The suites above, the snapshot comparison and plain `scripts/test.sh` are green.
- `docs/architecture.md`'s `OperatorSessionKeeper` row still reads true; `docs/testing.md`'s
  `operator-signals/state.json` row says it includes the chat lifecycle.

## Not in this step

- Moving the wake acknowledgement into the tool handler: 5g.
- Converting `Lifecycle` and the other saved enums to the shared kind-tagged helper, and moving
  `FreshStartPolicy` into `OperatorSession.swift`: 5h.
- The Operator row's line moving into Core: not planned; 5h moves the task row's wording only.
