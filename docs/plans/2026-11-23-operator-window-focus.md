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
  retrying through `whenQuiet`; the retry prepares and registers again, as a retry after a failed open
  does today. Choosing the chat's row skips the check
  (the click is activity itself), and since no pass is held during a wait, it is never refused. There is no
  `release()`: nothing a click does lets a worker's wait through.
- **Not covered: windows other than the one you were in.** D orders only the previously key window back,
  so with windows A (key) and B open, a new C still lands above B. The iTerm2 API gives no stacking order
  and cannot order a window back; restoring the whole stack (option E) flickers and was not chosen. The full
  fix is iTerm2 itself opening an unselected new window behind (option A, upstream), left for later.
- **Tabs never wait.** iTerm2's source shows a background tab in an existing window is neither selected
  nor raised: `open_tab` and a launch into a task window that is still open go ahead at once.
- **Focus back when iTerm2 is inactive (D).** `_keep_behind` also activates the previously key window when
  iTerm2 was not the active app. `Window.async_activate` sends no `activate_app`, so iTerm2 is not
  activated; a live probe first checks it does not bring iTerm2's windows over the app in front. Should it,
  D stays limited to iTerm2 being active and that is reported.

## Files

- `app/Sources/AiTermCore/Operators/PauseGate.swift` (create): with idle seconds, the frontmost check and
  sleeping injected: `isQuiet`, an awaitable `quiet()` for launches, and `whenQuiet` for the chat's retry.
- `app/Sources/AiTermCore/Operators/OperatorTiming.swift` (modify): `pauseBeforeOpening = 5`.
- `app/Sources/AiTerm/Operators/` live idle source (create): the CGEventSource counters and
  `NSWorkspace.frontmostApplication` against iTerm2's and AiTerm's bundle ids.
- `app/Sources/AiTerm/Operators/OperatorPorts.swift` and the controllers that build `SignalWorkerIO` and
  `OperatorChat` (modify): one shared gate.
- `app/Sources/AiTerm/Operators/SignalWorkerIO.swift` (modify): the launch's two waits and the restamped
  `requestedAt`.
- `app/Sources/AiTerm/Operators/OperatorChat.swift`, `OperatorSessionKeeper.swift` (modify): a pass that
  would open the chat while you are active ends without waiting and is retried when you pause; choosing
  the row opens it at once.
- `daemon/aitermd/iterm_bridge.py` (modify): `_keep_behind` gives focus back with iTerm2 inactive.
- `docs/daemon-protocol.md`, `docs/operators.md` (modify): the wait and the focus rule.

## Proof

- `PauseGateTests` (new): quiet after 5 s without a key or click; always quiet with another app in front;
  a key or a click restarts the wait; `whenQuiet` fires once, after the pause.
- `SignalWorkerIOTests`: a window launch waits and a tab launch does not; nothing is closed during the first
  wait and nothing is saved during either; typing resumed during the launch's daemon calls holds the
  create; a task that changed hands meanwhile is not launched; `requestedAt` is restamped.
- `SignalSessionKeeperTests` and the controller's tests: while you are active the chat's pass ends at once,
  `reconcile` carries on with workers and stages, and the chat opens after the pause; typing resumed during
  the chat's preparation defers it without a failure or an issue, and it opens after the next pause; choosing the row opens
  it at once; a worker launch waiting meanwhile stays held.
- `daemon/tests/test_iterm_bridge.py`: the inactive-iTerm2 test (`:1511`) expects the focus given back.
- The gate, `scripts/test.sh`, green.
- Live probe for D, with the user's go-ahead before it runs (it opens and closes a test window): with
  another app in front, re-keying an iTerm2 window activates neither iTerm2 nor raises it over that app.

## To-dos

- [ ] `PauseGate`, its tests and the constant.
- [ ] Live idle source and port wiring.
- [ ] Worker launch waits; tests.
- [ ] Operator chat retries after your pause without holding reconcile; choosing its row opens it at once; tests.
- [ ] Probe D live, with the user's go-ahead.
- [ ] Daemon: focus back with iTerm2 inactive; flip the test.
- [ ] Docs.
