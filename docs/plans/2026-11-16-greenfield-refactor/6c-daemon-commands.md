# 6c. One method per daemon command

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 1g (dead requests gone), 1j (`operatorId`), 6a, 6b. Findings: WD F5.

## Why

`DaemonCommands`, the app's interface to its helper, mirrors the wire plus its history. Two wire
commands each have two methods that differ only in whether the reply's `commandError` is read:
`createTaskWindow` and `openWorkerWindow` both send `window.createTask`; `createTab` and
`openWorkerTab` both send `tab.create`. `background` is left out of a request when false "as every
window before operators". And `snapshot()` is used as a query although its reply is also pushed into
the event stream as `.snapshot`, so every caller who only wanted "the tabs now" makes every owner
re-run its snapshot handling (windows cleared and adopted, conversations rewritten, live sessions
replaced). The end state: one method per command, each returning its full reply; `workspace.snapshot`
is sent only by the connection (its bootstrap, iTerm2 reconnecting, and Settings' check); callers
that want the tabs use `sessions.list`, which has no effect in the app.

## Today

After 1g and 1j, `app/Sources/AiTermCore/Daemon/DaemonCommands.swift` declares: `snapshot()`,
`createTaskWindow(... background:)` returning a window id, `createTerminalWindow` returning a window
id, `createTab(windowId:cwd:agentCommand:tabKey:background:)` returning a session id,
`openWorkerWindow` and `openWorkerTab` returning `WorkerOpening(id, commandError)`, activation,
frame, close, titles, mark seen, background preference, `deliver`, `closeIdle`, `setOwnership`,
`deliveryPolicy`, `registerOperator(operatorId:...)`, `revokeOperator(operatorId:...)`,
`replyToOperator`. An extension adds `createTaskWindow(...frame:)` and
`createTab(windowId:cwd:agentCommand:)` with `background: false` and no tab key. `DaemonClient`
implements them; `CreateTaskParams.background` and `CreateTabParams.background` are `Bool?` sent as
`background ? true : nil`; the reply types are `WindowResult`, `SessionResult`,
`WorkerWindowResult` and `WorkerTabResult`. `DaemonClient.snapshot()` and
`snapshot(claudeConfigDirectory:)` yield their reply as `.snapshot` (`ordered:`).
`DaemonMethod.sessionsList` is documented "Not sent by the app: `aitermd ctl`'s".

Callers (re-run `rg -n "\.snapshot\(\)|openWorkerWindow|openWorkerTab|WorkerOpening|createTaskWindow\(|createTab\(" app/Sources app/Tests`):

- `snapshot()` as a query: `HelperLink.checkIterm` (Settings' iTerm2 check; it wants the status
  update the snapshot brings through the event stream, not the tabs); the Operator chat's
  `existingWindow`, `open` and `closeOperator` (in `SignalOperatorController` today, or the chat
  owner 5d made); `TaskLauncher.openTakenOver` if 4e has not deleted it yet (it also reads
  `snapshot.connected`).
- Worker opens: `SignalWorkerIO` (first worker window, worker tab), the Operator chat's window;
  each throws `ActionUnavailable` with `commandError`. The extra worker tab (`createTab` with a
  `tabKey`) and every manual open (`TaskLauncher.openWindow`, restored tabs, `MessagingChecks`)
  ignore `commandError` today.
- Fakes: `app/Tests/AiTermTests/RecordingDaemon.swift` (`snapshotValue`, `commandErrors`,
  `openWorker*`); `SignalSessionKeeperTests` passes its own `existingWindow`.
- Daemon: `Service._h_sessions_list` answers the registry as it is, without a tick;
  `_h_snapshot` ticks first.
- Tests reading `background` absence: `DaemonOperatorWireTests.aBackgroundTaskWindowSaysSoAndAForegroundOneSaysNothing`,
  `DaemonClientTests.testCreateTabSendsTheWindowCwdAndCommand`, `HarnessMessagingTests` (about
  line 130).

## Change

1. Rename `WorkerOpening` to `Opening` (an id and an optional `commandError`); it is now what both
   creation commands return.
2. `DaemonCommands`: `createTaskWindow(taskId:cwd:title:agentCommand:frame:background:)` and
   `createTab(windowId:cwd:agentCommand:tabKey:background:)` return `Opening`.
   `createTerminalWindow` keeps returning its window id (a terminal has no agent command). Delete
   `openWorkerWindow`, `openWorkerTab` and the two extension conveniences: every caller passes
   `background` (and `tabKey: nil`) itself. Remove `snapshot()` from the protocol. Add
   `sessions()` returning the session list (`sessions.list`).
3. `DaemonClient`: send `background` always as a plain `Bool`; one reply type per creation command
   carrying the id and the optional `commandError` (`WindowResult` keeps serving
   `createTerminalWindow`); delete `WorkerWindowResult`, `WorkerTabResult` and `SessionResult` if
   unused. Delete the no-argument `snapshot()`; keep `snapshot(claudeConfigDirectory:)` public for
   `DaemonConnection` only. Add `sessions()` as a plain request, never yielded as an event.
4. `DaemonConnection`: add `refresh()`, which sends its snapshot with its Claude directory exactly as
   the `iterm.connected` branch does (reply through the event stream; a failure disconnects the
   client). `HelperLink.checkIterm` calls it instead of `daemon.snapshot()`.
5. Callers: worker opens call `createTaskWindow`/`createTab` with `background: true` and keep their
   `commandError` check; manual opens read `.id` and keep ignoring `commandError`; the extra worker
   tab keeps ignoring it. The Operator chat's `existingWindow`, `open` and `closeOperator` read
   `daemon.sessions()`. If `openTakenOver` still exists, it reads `sessions()` and its
   `snapshot.connected` guard goes: the window request that follows answers `iterm_unavailable`,
   whose message is "iTerm2 isn’t connected.", and that is what the click reports.
6. Daemon: `Service._h_sessions_list` ticks first, logging a failed tick and answering the last
   known registry, as `_h_snapshot` does, so the app's listing is as fresh as the snapshot was.
7. `DaemonMethod.sessionsList` and `DaemonCommands`' doc comments say the app sends it; in
   `docs/daemon-protocol.md`, add `sessions.list` to the commands table ("the tabs now, after a
   tick; no event") and drop it from the "still served, for ctl" sentence.
8. `RecordingDaemon`: replace `snapshot()`/`snapshotValue` with `sessions()` and a settable
   `sessionsValue`, recorded as `sessions.list`; `createTaskWindow` and `createTab` record
   `background` as sent (a Bool) and return `Opening` with the scripted `commandErrors` entry.

## Keep

- `DaemonClient.snapshot(claudeConfigDirectory:)` with its version and Claude-directory checks and
  `ordered:` yield: the bootstrap barrier between earlier and later events.
- The `.snapshot` event handling in `HelperLink.handle`, `LiveSessions` and the window owner: a
  connection's own snapshots still arrive there.
- `DaemonCommands` as a protocol: it is the real I/O seam the recording fake uses.
- `closeWindowIfOpen` and the other helpers on `DaemonCommands`, unchanged.
- `iterm.status` and `usage.get`: still served for `aitermd ctl`.

## Decisions already taken

- A manual task's or the extra worker tab's `commandError` is not reported: each caller keeps
  today's behaviour; only the type now carries it.
- `sessions.list` ticks first. Callers relied on the snapshot's tick for a fresh read (the
  Operator's "is my window already open", the close confirmation); a 2 s stale list would make the
  close confirmation refuse more often. `aitermd ctl` gets the same fresh answer.
- A listing taken while iTerm2 is disconnected is the last known registry, as the snapshot was; no
  caller needs the `connected` flag after step 5.
- No change to the wire's shape: only the request's `background` is now always present, which the
  daemon already reads as an optional Bool. Request frames are not recorded.

## Tests

- `DaemonOperatorWireTests.aBackgroundTaskWindowSaysSoAndAForegroundOneSaysNothing`: rename to say
  a foreground window sends `background: false`; `DaemonClientTests.testCreateTabSendsTheWindowCwdAndCommand`
  and `HarnessMessagingTests` (about line 130) expect `false`, not absent.
- Add `DaemonClientTests`: `createTaskWindow` and `createTab` return the reply's `commandError`,
  nil when the reply has none; `sessions()` sends `sessions.list`, returns its sessions and yields
  no `.snapshot` event.
- Add a `DaemonConnectionTests` case: `refresh()` sends `workspace.snapshot` with the Claude
  directory and its reply arrives as `.snapshot`.
- Add a daemon test in `tests/test_service.py`: a tab iTerm2 opened since the last tick is in the
  `sessions.list` answer.
- Tests that set `snapshotValue` set `sessionsValue`. If
  `ItermFocusTests.aTakenOverTaskChecksForALiveWindowBeforeResuming` still exists, its
  disconnected case makes `window.createTask` fail with `iterm_unavailable` (the fake's `failing`)
  and expects the reported issue; its connected case is unchanged.
- `WireContractTests.everyReplyReadsAsTheTypeItsRequestAwaits`: read `window.createTask` and
  `tab.create` frames with the new reply types.
- Fixtures: if `reply.sessions.list.json` changes because the listing now ticks, re-record from
  `daemon/` with `AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py` and
  add to `daemon/tests/wire/PROVENANCE.md`: "6c of the greenfield refactor: `sessions.list` ticks
  before answering, as the app now reads it." If nothing changed, add nothing.

## Proof

- `scripts/test.sh swift -- --filter DaemonClientTests`, `--filter DaemonOperatorWireTests`,
  `--filter DaemonConnectionTests`, `--filter WireContractTests`, then the Operator and launcher
  suites the compiler points at; `daemon/.venv/bin/pytest -k "wire or service"` from `daemon/`.
- Plain `scripts/test.sh`.

## Done when

- `rg -n "openWorkerWindow|openWorkerTab|WorkerOpening|snapshotValue" app` returns nothing.
- `rg -n "\.snapshot\(\)" app/Sources` returns nothing, and `rg -n "snapshot\(claudeConfigDirectory" app/Sources`
  shows only `DaemonConnection`.
- `rg -n "background \? true : nil|before operators" app/Sources` returns nothing.
- Both contract suites and plain `scripts/test.sh` are green.

## Not in this step

- One window owner and who decides an Operator window is open (3b). Deleting the taken-over opener
  (4e). The Operator chat's owner (5d).
