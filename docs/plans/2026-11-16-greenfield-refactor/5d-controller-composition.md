# 5d. The controller composes owners and runs one ordered reconcile

Implementer: Opus 5.5 high. Depends on: phases 1 to 4 (2f removed the activity write queue, the
Take Over repair loop and the mirrored source errors; 3b gave the Operator chat's window to
`RowWindows`; 4e moved Take Over to the task lifecycle), 5a, 5b and 5c (`OracleConsult` owns every
Oracle use and the in-flight count). Audit finding: RT F1.

## Why

`SignalOperatorController` is half composition root and half undeclared owners. Beside building the
Operator's owners it holds the wake policy (one pending slot, delivery, the result codes, the
acknowledgement by a global `run_status`), the Operator chat's window and session I/O (open, close
with its delivery-code classification, adopt, remember, the session part of the row's issue), the
activity log writer with the issue transitions it records, and the retention policy for seen items,
questions, Oracle rounds and source failures. Delete the controller and those decisions vanish,
because nothing else owns them. They were added one patch at a time. End state: the controller
constructs owners, wires them, routes daemon events and Operator requests, and runs one ordered
reconcile; the wake policy is `OperatorWaker`, the chat's window and session are `OperatorChat`
(which owns `OperatorSessionKeeper`), the activity log and the issues are `ActivityWriter`, and
retention is pure Core on `AppState`. This step only moves code: no behaviour, wording, order or
timing changes. A right change is a diff where every moved line can be found, unchanged in meaning,
in its new owner.

## Today

As the code stands after phases 1 to 4 and 5a to 5c. Read all of `SignalOperatorController.swift`
before moving anything; it is the only file with real content to move. Confirm the earlier steps:
`rg -n 'func takeOver|takeOverRepairs|unwrittenActivity|sourceErrors|normalizeEarlierChoiceBlocks|oracleJobs' app/Sources/AiTerm/Operators/SignalOperatorController.swift`
must be empty; if not, stop and report.

What the controller holds besides construction (by symbol):

- Wake: `wakePending` (event, task), `waking`, `wakeLeftUnsent`; `wake(_:id:)` (only while
  `operatorHasWork`, pulses the activity), `wakeIfWaiting(_:)` (blocked wakes `taskBlocked`,
  choosing wakes `agentChoice`), `deliverWake` and `sendWake` (set ownership, save
  `wakeAwaitingRead`, deliver the fixed line, classify delivered, partial and refused codes into
  `.wake` issues), the restore in `start()` when `wakeAwaitingRead` was saved (`sessionRecovered`,
  left unsent), the reconcile line that drops the pending wake when there is no work, and in
  `answer(_:using:)` the refusal of a task-scoped `run_status` while a wake is unread plus the
  acknowledgement after a global `run_status` (clear the slot and `wakeAwaitingRead`, save, clear
  `wakeLeftUnsent`, succeed `.wake`).
- Chat: `keeper` (lazy, built by `makeKeeper` with ports `canOpen`, `windowIsOpen`, `close`,
  `revoke`, `open`, `existingWindow`, sessions, instructions, usage, installed agents) and its
  callbacks (`failed`, `succeeded`, `finished`); `operatorTab()`, `rememberOperator()`,
  `open(_:digest:)` (prepare the launch, register the token, adopt a tagged tab or open the window),
  `closeOperator(_:)` (confirm absence or close idle, the `DeliveryCode` list that proves no close
  was attempted, `SignalOperatorCloseDeferred`), whatever 3b left of the open-in-flight record and
  of `openOperator()`, the window-closed event handling, `finishSessionIfIdle()`, the reconcile's
  finishing and fresh-start calls, and the session part of `statusIssue` (the tab's `stoppedOn`,
  "did not start in its window").
- Activity and issues: `issues` (`OperatorIssues`, `didSet` calls `changed()`), `fail`, `succeed`,
  `record(_ transition:)`, `recordActivity(...)`, `writeActivity(_:)` (one serial write per entry
  into the Operator folder's `activity.jsonl` after 2f, reporting `.activity`).
- Retention: `prune()` (seen items by live items, resolved worker questions of superseded or gone
  tasks, Oracle rounds of the three round tools whose binding's stage or ownership moved,
  `OperatorSession.prune(at:)`, source failures of removed signals) and `pruneQuestions()` (marks
  open questions that are no longer current as resolved, then flushes).
- Stays in the controller: construction and wiring, `start`, `stop`, `schedule` and `jobs`,
  `profile` and `loadProfile`, `configure`, `save`, `setPaused`, `daemonAttached`, `tabsKnown`,
  `handle(_:)`, `respond` and `answer` routing with `activeTools`, `reconcile`, `reconcileIfIdle`,
  `changed()` with the question notification, `onChange`, `connections()`, `statusIssue` as a
  composition, and the source poller glue (`onPass`, `onFailure`, saved `sourceFailures`) until 5e.

Readers outside: `AppController` (`signalController.statusIssue`, `activity.event`, `onChange`,
`setPaused`, `save`, `connections`, `handle`, `daemonAttached`, the `RowWindows` wiring for the chat
as 3b left it), `Views/Operators/SignalRows.swift`. Tests reach `root.keeper`
(`SignalOperatorLifetimeTests`), `root.issues`, `root.operatorTab()`, `root.openOperator()`
(`SignalOperatorIssueTests`), `root.statusIssue`, `root.native`, `root.tools`, `root.gate`,
`root.router`, `root.stages`, `root.tabsKnown`, `root.sourceRegistrations`:
`rg -n 'root\.[a-zA-Z]+' app/Tests/AiTermTests/Operators`.

## Change

1. **`ActivityWriter`** (app, `Operators/ActivityWriter.swift`). Holds the Operator folder, the
   serial write chain and `issues`. Offers `record(tool:task:arguments:outcome:result:line:)`,
   `fail(_:_:)` and `succeed(_:)` (each records its transition exactly as `record(_ transition:)`
   does today) and a `changed` callback for when `issues` changes. Moved unchanged:
   `recordActivity`, `writeActivity`, `fail`, `succeed`, `record(_:)`, `issues`.
2. **`OperatorChat`** (app, `Operators/OperatorChat.swift`). Holds `keeper` (still a settable
   property so a test can supply its own keeper), the open-in-flight record 3b left, and closures for
   the daemon, the frame, the profile, whether tabs are known and whether the Operator runs. Offers
   `operatorTab()`, `remember()`, `ensure(allowPaused:)`, `finishIfIdle(idle:wakePending:)`,
   `finishWhenNoWork(...)` (today's `finishSessionIfIdle` with its follow-up `ensure`),
   `freshIfDue(...)`, the opener the chat row uses (today's `openOperator`, as 3b left it),
   `windowClosed(_:)` and `sessionIssue` (the tab's stop reason, then "did not start in its
   window"). Moved unchanged: `makeKeeper` and its ports, `open`, `closeOperator`, `operatorTab`,
   `rememberOperator`, the keeper callbacks' bodies. It reports through `ActivityWriter` (`.session`,
   `.openWindow`) and, when the keeper finishes, calls a `finished` callback that the controller
   wires to the waker's reset and the three `succeed` calls of today's `keeper.finished`.
3. **`OperatorWaker`** (app, `Operators/OperatorWaker.swift`). Holds `pending`, `waking`,
   `leftUnsent`. Offers `wake(_:id:)`, `wakeIfWaiting(_:)`, `restore()` (the `start()` branch),
   `deliver()` (today's `deliverWake` and `sendWake`, reading the chat's `operatorTab()`),
   `dropWhenNoWork()` (the reconcile line), `unread` (the slot holds a wake, or `wakeAwaitingRead`
   is saved; exactly the condition `answer` tests today), `acknowledge()` (the global `run_status` branch) and `reset()` (clears
   `leftUnsent` when the chat finishes). It reports `.wake` through `ActivityWriter`. The
   controller's `answer` keeps its routing and asks the waker: refuse a task-scoped `run_status`
   while `unread`, acknowledge after a global one.
4. **Retention in Core.** Add `AppState.pruneOperator(at:)` with today's `prune()` body less its
   profile and configure calls, and `AppState.withdrawObsoleteQuestions(at:)` with today's
   `pruneQuestions()` body, returning whether it changed anything. Both are pure mutations; the
   controller calls them inside `workspace.mutate`, flushing as today.
5. **The controller** constructs, in this order, holding each as a property: `activity`
   (`OperatorActivityTracker`), `log` (`ActivityWriter`), `native` (`SignalWorkerIO`), `host`
   (`SignalHostIO`), `journal` (`SignalJournal`), `poller` (`SignalPoller`), `oracle`
   (`OracleConsult`), `chat` (`OperatorChat`, with `keeper`), `waker` (`OperatorWaker`), `pause`
   (`SignalPauseSignaller`), `router` (`ItemRouter`), `stages` (`StageRunner`), `then`
   (`ThenRunner`), `watch` (`RequestWatch`), `questions` (`QuestionRounds`), `choices`
   (`AgentChoiceRounds`), `tools` (the tool handler), `gate` (`SignalShellGate`). The final list is
   these eighteen and nothing else. Owners built lazily today stay lazy (`pause` to `gate`), so a
   test can still replace `stages` before `then`, `watch` and `tools` capture it; `chat.keeper` is
   settable for the same reason. Port closures keep their bodies; where a body
   called a moved function, it calls the owner. `statusIssue` becomes: nothing when stopped, else
   `log.issues.attention`'s sentence, else `chat.sessionIssue`.
6. **The one reconcile**, unchanged in order and conditions, now reads as a list of owner calls:
   1. Return unless running, not already reconciling, and the workspace can change; mark
      reconciling; on exit clear it and call `changed()`.
   2. When the minute's settings check is due: `pruneOperator(at:)`, `loadProfile()`, `configure()`.
   3. Return if stopped or the tabs are not known.
   4. `withdrawObsoleteQuestions(at:)`.
   5. When the session is finishing, or there is no work and a fresh start is pending:
      `chat.finishIfIdle` with idle meaning no tool call running and `oracle.isIdle`, and a wake
      pending meaning `waker.waking`.
   6. When there is work: `chat.ensure()`. Return if stopped.
   7. `chat.remember()`.
   8. `native.recoverLaunches()`, then `native.refreshTurns()`, then `pause.reconcile()`. Return if
      stopped.
   9. When paused: `chat.finishWhenNoWork(...)` and return.
   10. Schedule `stages.run` for every launching task and `.advancePending` for every continuable
       task with pending stages; schedule Then for every task whose Then is due.
   11. When the minute's host check is due: schedule `watch.pass()`.
   12. `waker.dropWhenNoWork()`, then `waker.deliver()`.
   13. `chat.finishWhenNoWork(...)` with today's idle inputs (the tab ended its turn and is not
       stopped, no tool call running, `oracle.isIdle`, no tracked activity; a wake pending meaning
       `waker.waking` or `waker.unread`).
   14. When there is work and the chat has a tab: `chat.freshIfDue(...)` with today's inputs.
7. **Docs.** In `docs/architecture.md`'s Operator ownership table, the controller's row says it
   composes owners and runs one ordered reconcile; add one row for `OperatorChat`, `OperatorWaker`
   and `ActivityWriter`, and say retention is `AppState.pruneOperator(at:)`.

## Keep

- Every port seam the tests use: `OperatorSessionKeeper.Ports`, the owners' `Ports` structs,
  `SignalOperatorController(workspace:live:work:ports:daemon:frame:automatic:)`.
- The two idle definitions in steps 5 and 13 exactly as they are; 5f makes them one rule.
- The question notification in `changed()`, `reconcileIfIdle`'s conditions, the poller glue and
  `sourceFailures` handling (5e moves polling into the tick).
- `OperatorWakeEvent` lines, the delivery-code list in the close, `SignalOperatorCloseDeferred`.
- `activeTools` in the controller (5g moves the acknowledgement into the handler).

## Decisions already taken

- Moves only. If a moved body reads a value that now lives in another owner (the chat reading the
  waker's state, the waker reading the chat's tab), pass a closure or a reference at construction;
  do not copy state.
- No owner holds a reference back to the controller. Cross-owner reactions (a finished chat resets
  the waker and succeeds three issue sources; a router change records activity and may wake) are
  closures wired in the controller's initializer.
- `ActivityWriter` writes nothing on its own schedule; it writes when called, as today.
- Retention keeps its minute cadence and its exact rules; do not merge `withdrawObsoleteQuestions`
  into `pruneOperator`: they run at different times today.
- If 3b left the chat's open path elsewhere (for example a `RowWindows` opener calling the
  controller), point it at `chat` and change nothing else about it.

## Tests

- No behaviour changes, so no test is deleted. Adjust paths: `root.keeper` becomes
  `root.chat.keeper`; `root.issues` becomes `root.log.issues`; `root.operatorTab()` becomes
  `root.chat.operatorTab()`; `root.openOperator()` follows where its opener moved. `statusIssue`
  stays on the controller.
- Add Core tests for the now pure retention: `pruneOperator(at:)` drops a resolved worker question
  and an Oracle round of a superseded stage, keeps the current stage's, drops a source failure of a
  removed signal and keeps one of a live signal; `withdrawObsoleteQuestions(at:)` resolves an open
  question of a finished stage, leaves a current one and a global one, and reports whether it
  changed anything.
- The behaviour is proven by the existing suites passing unchanged: `SignalOperatorIssueTests`
  (wake codes, acknowledgement, activity failures), `SignalOperatorLifetimeTests`,
  `SignalFreshSessionTests`, `SignalSessionKeeperTests`, `SignalControllerTests`,
  `SignalJourneyTests`.

## Proof

- While iterating: `scripts/test.sh swift -- --filter SignalOperatorIssueTests`, then
  `SignalOperatorLifetimeTests`, `SignalFreshSessionTests`, `SignalSessionKeeperTests`,
  `SignalControllerTests`, `SignalJourneyTests`, `OperatorActivityTests` and the new retention suite.
- Then plain `scripts/test.sh`, started in the background. No view, wire or saved-format change.

## Done when

- `rg -n 'wakePending|wakeLeftUnsent|sendWake|closeIdle|registerOperator|revokeOperator|ActivityLog\.append|SignalSeen\.pruned|oracleRounds\.removeAll' app/Sources/AiTerm/Operators/SignalOperatorController.swift`
  is empty.
- `rg -n 'func (prune|pruneQuestions|open|closeOperator|deliverWake|recordActivity|writeActivity|record)\b' app/Sources/AiTerm/Operators/SignalOperatorController.swift`
  is empty.
- The controller is construction, routing and the reconcile above; your report gives its line count
  before and after (the audit expected about 300 lines after).
- The suites above and plain `scripts/test.sh` are green; `docs/architecture.md` is updated.

## Not in this step

- One tick, polling and the host watch as due steps, one in-flight set per task, `busy` without a
  side effect: 5e.
- One saved chat lifecycle and one idle rule; `currentAct` leaving the saved record: 5f.
- The wake acknowledgement inside the tool handler; `answer_worker`'s second ledger: 5g.
- Regrouping `Signals/` and the task row's Operator wording in Core: 5h.
