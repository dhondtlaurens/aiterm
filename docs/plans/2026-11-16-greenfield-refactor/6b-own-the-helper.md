# 6b. The app owns its helper

Implementer: Opus 5.5, high. Depends on: phase 2 (1h removed the old-helper decoding forms). Findings: WD F4.

## Why

When AiTerm crashes or is force-quit, its helper (`aitermd`) keeps the socket for up to a minute.
The next launch's helper then refuses to start (exit 3), and the supervisor "adopts" the orphan:
it connects to old code, probes it every five seconds, and never ends it, so the orphan outlives
that app too and is adopted again at every launch. The maintainer works around this by hand, and
`scripts/run-dev.sh` `pkill`s it. Most of the "mismatch" handling in the app (a held status, a
log limiter) exists only because an adopted orphan can be another version. The end state: a child
that exits as "already running" means a stale helper holds this socket; the supervisor ends that
process, found by its exact command line, the way `stop()` ends its own child, and starts its own.
The app only ever talks to a helper it started from its own bundle.

## Today

- `app/Sources/AiTermCore/Daemon/DaemonSupervisor.swift`: `State.adopted`;
  `alreadyRunningExitStatus = 3` (mirrors `EXIT_ALREADY_RUNNING`); `exited(_:)` calls `adopt()` on
  that status; `adopt()` and `scheduleAdoptedProbe()` (a `SocketProbe` every
  `adoptedProbeInterval`, 5 s, then `launch()` when the socket is gone); the init parameter
  `adoptedProbeInterval`; comments about adoption in `Supervision.scheduled`, `truncateLog`,
  `openLog` and `exited`. `stop()` sends SIGTERM to `process` and `abandoned`, polls for
  `stopGracePeriod` (2 s), then SIGKILL with a 0.5 s wait. `arguments(socketPath:hookPort:)` is
  `-m aitermd run --socket <path> --hook-port <port> --cookies-from-app`.
- `app/Sources/AiTerm/HelperLink.swift`: `supervisorChanged` connects on `.listening, .adopted`,
  with a comment about adoption; `handle(_:)`'s comment names "adopted".
- `app/Sources/AiTerm/DaemonConnection.swift`: `HeldStatus` (holds a connection's statuses after a
  mismatch until it has lasted `steadyAfter`), the `mismatched` flag and the `steady` task inside
  `run()`. `steadyAfter` also resets the backoff for a connection that held: that use stays.
- `app/Sources/AiTermCore/Daemon/DaemonClient.swift`: `unreadableLogged` and `logUnreadable` rate
  limit the "unreadable line" log to once a minute per name, because an adopted helper sends the
  same unreadable shape on every reconnect. The `livenessCheck` doc mentions "an older helper"
  answering `unknown_method`.
- Daemon: `__main__.py` (`EXIT_ALREADY_RUNNING` and `IDLE_EXIT_SECONDS` comments say a supervisor
  adopts), `rpc_server.py` (`AlreadyRunning` docstring: "use that daemon"),
  `claude_sessions.py` (`configure` docstring: "including on helper adoption"). Exit 3 itself is
  how the supervisor learns the socket is held; it stays.
- `scripts/run-dev.sh`: the `SOCKET` variable and the `pkill -f "aitermd run --socket $SOCKET"`
  block with its comment. `scripts/README.md` line about stopping the orphaned helper.
- Docs: `docs/architecture.md` ("An adopted daemon is not killed as though it belonged to the
  current app."), `docs/daemon-protocol.md` (`workspace.snapshot` row: "also on adoption"),
  `daemon/README.md` ("including when adopted by a new app connection").
- Tests: `DaemonSupervisorTests.testSupervisorAdoptsARunningDaemonInsteadOfRestarting`,
  `testSupervisorTakesOverWhenTheAdoptedDaemonGoesAway`; `DaemonConnectionTests`
  `aMismatchedHelperIsNotShownConnectedAgainUntilAConnectionHolds`,
  `aConnectionThatHoldsAfterAMismatchIsShownOnceItHas` and the `retries(... until:)` helper.

Greps: `rg -n "adopted|adopt\(\)|adoptedProbe|HeldStatus|mismatched|unreadableLogged|logUnreadable" app scripts`
and `rg -n -i "adopt" daemon/aitermd daemon/README.md docs/architecture.md docs/daemon-protocol.md`
(window adoption by tag is a different thing and stays; only helper adoption goes).

## Change

1. `DaemonSupervisor`: add a pure static function that takes the text of a process listing (one
   process per line: its pid, then its full command line) and the socket path, and returns the
   pids whose command line runs `aitermd run --socket <this exact path>`: the words
   `aitermd run --socket ` followed by the path, followed by a space or the end of the line. Another
   socket path, or a path that merely starts with this one, does not match. No pid is excluded:
   the child that exited 3 is gone, and an abandoned child still holding the socket is meant to go.
2. `DaemonSupervisor.exited(_:)`: on `alreadyRunningExitStatus`, on `queue`, list processes with
   `ProcessRunner.run` of `/bin/ps` with `-axww -o pid=,command=` and a short timeout (one or two
   seconds), find the stale helpers with step 1, and end each as `stop()` ends a child: SIGTERM,
   wait up to `stopGracePeriod`, SIGKILL, wait up to half a second. Then `launch()` at once, with
   no backoff and no failure counted. If none was found, or the listing failed, count it as a
   failed launch through `recordFailure` with a message that says the socket is held by another
   process: the existing backoff and banner apply, so a loop cannot spin.
3. Delete `State.adopted`, `adopt()`, `scheduleAdoptedProbe()`, `adoptedProbeInterval` (init
   parameter and property) and every adoption comment; reword `alreadyRunningExitStatus`'s doc to
   say exit 3 means a stale helper holds the socket and is ended. Factor the SIGTERM, grace,
   SIGKILL sequence so `stop()` and step 2 share it, if that is simpler than repeating six lines.
4. `HelperLink.supervisorChanged`: connect on `.listening` only; drop the adoption comment and the
   word "adopted" from `handle(_:)`'s comment (a helper reached again after the socket dropped
   still sends no `iterm.connected`, so that branch stays).
5. `DaemonConnection`: delete `HeldStatus`, `mismatched` and the `steady` task; `ended(_:)` and
   every status report go straight to `onStatus`. Keep `steadyAfter` for the backoff reset only, and
   keep reporting a mismatch through the status that names it today (`.helperMismatch`, or the
   state 3d replaced it with if 3d has landed).
6. `DaemonClient`: delete `unreadableLogged` and its rate limit; `logUnreadable` logs every time
   (or inline the log line at its three callers). Delete the "older helper" sentence in the
   `livenessCheck` doc.
7. Daemon comments: `EXIT_ALREADY_RUNNING` (the app's supervisor ends the stale holder and starts
   again), `IDLE_EXIT_SECONDS` (it reaps a helper whose app died; no adoption), `AlreadyRunning`
   (the supervisor ends the holder), `ClaudeSessionFiles.configure` (drop "including on helper
   adoption").
8. `scripts/run-dev.sh`: delete the `pkill` block, its comment and the `SOCKET` variable with its
   comment. Do not run the script. Update the `scripts/README.md` sentence.
9. Docs: delete the adopted-daemon sentence in `docs/architecture.md`, "(also on adoption)" in
   `docs/daemon-protocol.md`, and "including when adopted by a new app connection" in
   `daemon/README.md`; where a sentence is needed, say the app ends a stale helper on its socket
   and starts its own.

## Keep

- The daemon's exit 3 and `RpcServer._is_live`: the supervisor learns from it that the socket is
  held. No request to quit and no wire change.
- `IdleWatchdog` and `IDLE_EXIT_SECONDS`: they reap an orphan when no app comes back at all.
- `stop()`'s synchronous SIGTERM, grace, SIGKILL: quit must leave no child (an orphan at quit was
  the original incident).
- The bind deadline and `abandon(_:)`: a child stuck before listening is a real case.
- `DaemonError.Code.incompatible` and the snapshot's version and Claude-directory checks: a plain
  error for a developer's mistake. `DaemonClient.Ending.unreadable` and the disconnect on an
  unreadable line stay; only the log limiter goes.
- `steadyAfter`'s backoff reset (`aConnectionThatHeldStartsTheBackoffOver`).

## Decisions already taken

- Matching is on the command line text, as `pkill -f` matched it, because `ps` prints the
  arguments joined by spaces and the socket path itself contains a space (`Application Support`).
  The `python` path in front does not matter, so a helper from the installed app or a dev build
  matches alike. Do not match on `--hook-port`.
- Two AiTerms running at once is not supported (`run-dev.sh`'s header). If it happens, each kills
  the other's helper and both back off through `recordFailure`; no handling.
- A helper started by hand with `python -m aitermd run --socket <the app's socket>` is ended too.
  That is intended: the app owns that socket.
- A process that is not the current user's cannot be signalled; it cannot hold this user's socket
  either. A kill that fails is treated as "none ended" (step 2's failure path).
- Ending the stale helper blocks the supervisor's queue for at most about 2.5 s. `stop()` waits on
  that queue; a quit during it waits that long. Accepted.
- The connection's statuses are no longer held after a mismatch, so a retry at a broken helper can
  show "Connected" between two mismatch reports. A helper of another version can no longer be
  reached, so this only shows a developer's broken build.

## Tests

- Delete `testSupervisorAdoptsARunningDaemonInsteadOfRestarting` and
  `testSupervisorTakesOverWhenTheAdoptedDaemonGoesAway`: the behaviour is deleted.
- Add pure tests of step 1: a listing with this socket's helper (path with a space), another
  socket's helper, a helper whose path starts with this one, and an unrelated `python` line picks
  only the first pid.
- Add a supervisor test: start a stand-in process that sleeps and whose arguments contain
  `aitermd run --socket <the test's socket path>` (for example `/usr/bin/python3 -c` a sleep, with
  those words as extra arguments); a supervisor whose child exits with `alreadyRunningExitStatus`
  ends the stand-in and reports `.starting` again without a `.failed` before it. Stop the
  supervisor and make sure the stand-in is gone even if the test fails.
- Add: an exit 3 with no matching process is a `.failed` launch and is retried through the backoff.
- `DaemonConnectionTests`: delete `aMismatchedHelperIsNotShownConnectedAgainUntilAConnectionHolds`
  and `aConnectionThatHoldsAfterAMismatchIsShownOnceItHas` (behaviour deleted); drop the `until`
  parameter of `retries` if nothing else uses it. `aHelperWhoseEventsCannotBeReadIsAMismatchAndItsRetriesBackOff`,
  `aSnapshotDecodingFailureIsAHelperMismatchNotAnUnreachableHelper` and
  `anOlderHelperCannotSilentlyIgnoreTheClaudeDirectory` stay as they are.
- `daemon/tests/test_main.py`'s exit-3 test stays.
- No fixtures change.

## Proof

- `scripts/test.sh swift -- --filter DaemonSupervisorTests`, `--filter DaemonConnectionTests`,
  `--filter DaemonClientTests`, `--filter ItermSettingsTests`; `daemon/.venv/bin/pytest -k main`
  from `daemon/`.
- Plain `scripts/test.sh`. Never run `scripts/run-dev.sh`.

## Done when

- `rg -n "adopted|adoptedProbe|scheduleAdoptedProbe|HeldStatus|unreadableLogged" app/Sources app/Tests`
  returns nothing.
- `rg -n -i "adopt" daemon/aitermd/__main__.py daemon/aitermd/rpc_server.py daemon/aitermd/claude_sessions.py daemon/README.md docs/daemon-protocol.md docs/architecture.md`
  shows only window adoption.
- `rg -n "pkill|SOCKET" scripts/run-dev.sh` returns nothing.
- The new supervisor tests and plain `scripts/test.sh` are green.

## Not in this step

- The banner's states and wording (3d). Which daemon commands exist (6c).
- The daemon launching iTerm2 at its own start beside the app's launch (WD F4's optional part):
  not planned.
