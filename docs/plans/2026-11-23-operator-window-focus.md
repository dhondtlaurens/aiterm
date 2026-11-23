# Operator windows wait for your pause

## Goal

A window the Operator opens on its own (its chat, or a stage's worker window) never lands on top of the
iTerm2 window you are working in and never catches the keys you are typing.

## Why it happens

iTerm2 (3.7.7, read in its source) honours `select_tab=false` only for a tab in an existing window. A
brand-new window always reaches `-[PseudoTerminal insertTab:atIndex:openInBackground:]` with one tab, which
calls `makeKeyAndOrderFront:`, synchronously during the create. Keys typed between that moment and the
daemon's `_keep_behind` land in the new window. `_keep_behind` orders only the previously key window back,
so the new one stays above every other iTerm2 window, and it does nothing when iTerm2 was not the active
app: the new window stays key and you type into it when you return. iTerm2 has an `openInBackground` path
(`orderWindow:NSWindowBelow`) but only tmux reaches it, not the API.

## Approach

- **Wait for a pause (C, extended).** Before the app asks the daemon for a new background window, it
  waits until no key and no click came for `OperatorTiming.pauseBeforeOpening` (5 s) while iTerm2 or AiTerm
  is the frontmost app. With another app in front nothing waits. There is no cap: the Operator's activity
  line says it is waiting for you to pause, so a held launch is never silent. Idle comes from
  `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` for key down and left, right and other
  mouse down: no permission is needed (probed from a shell; confirmed again in the app).
- **The wait happens in the app, not the daemon.** A daemon RPC times out after 15 s and a timeout makes
  the app retry, which can open a second window.
- **Where a launch waits.** `SignalWorkerIO.launch` waits only when it will open a window (no live session
  in the task's window besides the worker it replaces), and twice: first at its start, so a previous worker
  is not closed and then left without a successor for as long as you type; then again after every daemon
  RPC and the command build, immediately before its pending reply is saved, so typing resumed during those
  awaits holds the window too. Only the local pending save stands between the last wait and
  `createTaskWindow`. The pending reply is saved after the waits because one older than `openingGrace`
  blocks the task; the launch attempt's `requestedAt` is restamped in that same save, so the grace counts
  from the open. After each wait the task is required again (`require(task)`). Stage launches run as their
  own jobs, so a held one holds up nothing else.
- **The Operator chat never waits inside a pass.** `SignalOperatorController.reconcile()` awaits
  `chat.ensure()` while it holds `reconciling`, so a wait there would stall worker reads, stage scheduling
  and every later reconcile. Instead the keeper checks the gate without waiting: while you are active it
  leaves the chat `.opening` (or closed), ends its pass, and the gate calls `ensure` again once you have
  paused; the activity line says the chat waits for your pause. `OperatorChat.open` checks again,
  without waiting, immediately before `createTaskWindow`, after its preparation, `registerOperator` and
  `sessions`: typing resumed during those throws a deferral (as `SignalOperatorCloseDeferred` does for a
  close) that the keeper takes as "not yet", not as a failure, leaving the lifecycle as it was and
  retrying through the keeper's own retry task (`pausedRetry`, run through `OperatorWork`, awaiting
  `quiet()`); the retry prepares and registers again, as a retry after a failed open
  does today. Choosing the chat's row skips the check
  (the click is activity itself), and since no pass is held during a wait, it is never refused. There is no
  `release()`: nothing a click does lets a worker's wait through.
- **Not covered: windows other than the one you were in.** D orders only the previously key window back,
  so with windows A (key) and B open, a new C still lands above B. The iTerm2 API gives no stacking order
  and cannot order a window back; restoring the whole stack (option E) flickers and was not chosen. The full
  fix is iTerm2 itself opening an unselected new window behind (option A, upstream), left for later.
- **A held chat is still wanted, and says so.** The retry stops waiting, and does not open, once the chat's
  workload ended (`operatorHasWork`), so it never starts an empty chat and its wait does not hold off the
  retirement. A first chat held for your pause stays `.opening`; its row says it waits for your pause instead
  of "starting fresh", and choosing its row opens it even after Pause Operator.
- **A wait never outlives its reason, nor an Operator request.** A worker's wait ends as soon as its task is
  taken over or the Operator paused (`quiet(while:)` on the claim), so the launch lets go of the task. A
  stage that `resume_task`, `choose_agent` or `finish_stage` leaves launching starts as a job of its own
  (`StageRunner.launchSoon`, the controller's `schedule`), as a polled match does: the tool answers once the
  stage is saved, never after a wait longer than the Operator's 30 s request. The served descriptions promise
  nothing about the worker being open, so the tool contract stands. The chat's row reads whether its wait
  runs at all (`OperatorActivity.chatWaitsForPause`), not only whether it is the latest activity.
  A launch that waits saves its stage's `workerPending` as false before the wait, and true again in the save
  just before its window opens: while it waits no worker is opening, and recovery after a quit, a pause or a
  Take Over meanwhile would otherwise take the previous worker, still open after the first wait, for the new
  stage's and never send its prompt. A chat that opens ends a retry still waiting, and with it the row's line.
- **One window at a time (`WindowTurn`).** The daemon serialises creates behind a tick, so windows released by
  the same pause would open one after another, the later ones after you went back to typing. The app asks
  for a new Operator window only inside one shared turn, after a last look at your pause and at the task's
  claim there, with no await between them and the create; a worker that finds you typing leaves the turn and
  waits again, and the chat defers. No window waits for your pause while it holds the turn, so the chat's
  pass waits for it only as long as one create. Choosing the chat while a pass opens it, held for the turn,
  marks it chosen (`chosenMeanwhile`), so that open goes ahead without your pause, and the click waits for
  that pass instead of failing.
- **Tabs never wait.** iTerm2's source shows a background tab in an existing window is neither selected
  nor raised: `open_tab` and a launch into a task window that is still open go ahead at once.
- **Focus back when iTerm2 is inactive (D).** `_keep_behind` also activates the previously key window when
  iTerm2 was not the active app. `Window.async_activate` sends no `activate_app`, so iTerm2 is not
  activated; a live probe first checks it does not bring iTerm2's windows over the app in front. Should it,
  D stays limited to iTerm2 being active and that is reported.

## Files

- `app/Sources/AiTermCore/Operators/PauseGate.swift` (create): with idle seconds, the frontmost check and
  sleeping injected: `isQuiet`, and an awaitable `quiet(while:)` for launches and the chat's retry, which also
  ends once its caller no longer wants the window.
- `app/Sources/AiTermCore/Operators/OperatorTiming.swift` (modify): `pauseBeforeOpening = 5`.
- `app/Sources/AiTerm/Operators/LivePauseGate.swift` (create): the CGEventSource counters and
  `NSWorkspace.frontmostApplication` against iTerm2's and AiTerm's bundle ids.
- `app/Sources/AiTerm/Operators/OperatorPorts.swift` and the controllers that build `SignalWorkerIO` and
  `OperatorChat` (modify): one shared gate.
- `app/Sources/AiTerm/Operators/SignalWorkerIO.swift` (modify): the launch's two waits and the restamped
  `requestedAt`.
- `app/Sources/AiTerm/Operators/OperatorChat.swift`, `OperatorSessionKeeper.swift` (modify): a pass that
  would open the chat while you are active ends without waiting and is retried when you pause; choosing
  the row opens it at once.
- `app/Sources/AiTerm/SignalSidebar.swift` (modify): the Operator row of a first chat held for your pause.
- `app/Sources/AiTerm/Operators/StageRunner.swift`, `OperatorActivity.swift` (modify): `launchSoon`, `chatWaitsForPause`.
- `daemon/aitermd/iterm_bridge.py` (modify): `_keep_behind` gives focus back with iTerm2 inactive.
- `docs/daemon-protocol.md`, `docs/operators.md` (modify): the wait and the focus rule.

## Proof

- `PauseGateTests` (new): quiet after 5 s without a key or click; always quiet with another app in front;
  a key or a click restarts the wait; a wait no longer wanted ends after at most one pause.
- `OperatorPauseTests` (worker cases): a window launch waits and a tab launch does not; nothing is closed
  during the first wait, no pending reply is saved during either, and the only save before a wait marks the
  stage's worker not pending (read from the saved file); typing resumed during the launch's daemon calls holds the
  create; a task that changed hands meanwhile is not launched; `requestedAt` is restamped.
- `PauseGateTests` also: one window holds the turn at a time, and a throwing one passes it on.
- `OperatorPauseTests` also: typing resumed while a window waits for its turn holds it until the next pause;
  a launch whose claim was lost before its turn saves nothing; choosing a chat held for the turn opens it;
  during a wait the saved stage is not pending and recovery adopts nothing, and it
  is pending again once the window opens; a replacement paused during its wait is not adopted as launched; a chosen held
  chat ends its retry.
- `OperatorPauseTests` also: a task taken over while you keep typing ends the wait at once; a stage a tool
  resumes is handed to `launchSoon` instead of launching inside the call.
- `OperatorPauseTests` also: a held chat whose workload ended never opens; choosing a held chat opens it
  though the Operator is paused; the row of a held first chat says it waits for your pause.
- `OperatorPauseTests` (new, beside the worker cases): while you are active the keeper's `ensure`, which
  `reconcile` awaits, returns at once and the chat opens after the pause from its own retry, with no
  failure; typing resumed during the chat's preparation defers it, through the controller, without an
  issue, and it opens after the next pause; choosing the row opens it at once. No test holds a worker
  against a click: with no `release()` there is no path from the click to a worker's wait.
- `daemon/tests/test_iterm_bridge.py`: the inactive-iTerm2 test (`:1511`) expects the focus given back.
- The gate, `scripts/test.sh`, green.
- Live probe for D, with the user's go-ahead before it runs (it opens and closes a test window): with
  another app in front, re-keying an iTerm2 window activates neither iTerm2 nor raises it over that app.
  Ran 2026-11-23 with Calendar in front: the new background window stayed behind Calendar and became
  iTerm2's key window; re-focusing the previous window activated neither iTerm2 nor raised it. Switching back
  to iTerm2 found the new window key without the re-focus and the previous window key with it.

## To-dos

- [x] `PauseGate`, its tests and the constant.
- [x] Live idle source and port wiring.
- [x] Worker launch waits; tests.
- [x] Operator chat retries after your pause without holding reconcile; choosing its row opens it at once; tests.
- [x] Probe D live, with the user's go-ahead.
- [x] Daemon: focus back with iTerm2 inactive; flip the test.
- [x] Docs.
