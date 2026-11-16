# The Operator row says "needs you" only while something needs the person

## Goal

On 16 Nov 2026 the Operator's sidebar row read "needs you" for at least ten minutes while
nothing needed the person. `SignalOperatorRowValue.make` shows "needs you" whenever
`SignalOperatorController.statusIssue` is set, and that returns one shared `lastError`, which seven
different failures set and only opening the Operator's window or reopening a worker clears. The
reason exists only in app memory, visible only as a tooltip.

After this change each error belongs to its source and clears when that source next succeeds.
A failure AiTerm retries by itself marks the row only after three failed attempts in a row. Every
error is written to the Operator's activity log with its time and source, and `run_status` reports
the current ones. A wake that could not be delivered is retried, never dropped.

## What the investigation found

- **Wakes are being lost (confirmed).** The daemon types only six wake events
  (`daemon/aitermd/delivery.py` `wake_text_problem`); the app also sends `settings_changed` (after a
  Settings save) and `session_recovered` (after a relaunch with an unread wake), and the daemon
  refuses both as "a wake line may not carry a digit". A refusal is not an error, so the wake stays
  pending forever, and `wake()` keeps only one pending wake: every later `task_blocked`,
  `worker_ended` or `agent_choice` wake is silently dropped until a global `run_status` clears it.
  Live on 16 Nov: AiTerm relaunched at 11:50 with `wakeAwaitingRead` saved as true; a ticket matched
  at 11:02 and stayed blocked, and the Operator made no call after 10:28.
- **The 08:48 "needs you" (not confirmable).** The activity log shows three matches at 08:48:38 and
  the first `run_status` at 08:49:27, after the person typed, which fits a lost wake. But a refused
  wake does not set `lastError`; only a thrown `deliverWake`, a failed reply, an activity write, a
  guard refresh or a journal write does, and that text lived only in memory. The daemon log was
  cleared by the 11:50 relaunch. Which source it was cannot be recovered; after this change it is
  always recorded.

## Approach

A pure `OperatorIssues` record in AiTermCore keeps at most one issue per source (text, first
failure, attempts) and decides which one, if any, needs the person. The controller reports
`fail(source)` and `succeed(source)` at each place that set or should clear `lastError`, logs each
issue as it starts, changes text or recovers, and hands the current issues to `run_status`.
The wake grammar becomes one list shared by app and daemon, checked by the wire contract.

Decided while planning:

- **Retried sources** (wake, reply to an Operator call, activity-log write, Operator session
  keeping): attention after **three consecutive failed attempts** of that source; any success of
  that source clears it.
- **Replies are retried by the Operator, not resent by AiTerm.** A reply that could not be sent
  leaves the Operator's call to time out; the Operator retries it, and a keyed call with the same
  key replays its saved result from the ledger without running its effect again (read-only calls
  simply run again). That retry's sent reply is the success that clears the reply issue. The
  count runs across all of the Operator's calls, not per call: the brief's "stop after two failures
  of one tool, then ask in chat" leaves a stranded call with the person through the Operator's own
  chat, and a reply path that keeps failing reaches three on the Operator's next calls.
- **Person-started sources** (opening the Operator's window, reopening a worker, Take Over's guard
  refresh and journal write): attention **at once**, cleared only by the next success of that same
  action. Take Over cannot be clicked again once the task is the person's, so its failed guard
  refresh or journal write is kept as a pending repair for that task and retried on each reconcile
  until it succeeds, which clears the issue. The repair lives in memory: a relaunch drops it with
  the issue, as today; the worker's next launch prepares its guard anyway.
- **A wake attempt fails** when delivery throws, is refused or is `partial` (pasted, Enter held
  back), except the "not now" refusals `typing`, `unsentInput` and `prompt` (the person is typing,
  or a prompt is open, which the session's own state already shows); those wait without counting.
  After a `partial` wake, `unsentInput` is the wake line's own leftover text, so it counts until a
  wake is delivered; its issue text tells the person to press Enter in the Operator's chat. A
  delivered wake succeeds, and so does the Operator's global `run_status`, which already
  acknowledges and clears the pending wake (after the person pressed Enter, say). The pending wake
  is kept on every failure, so it is retried at the next reconcile.
- **Wake events**: the app's `OperatorWakeEvent` enum (`worker_ended`, `task_blocked`,
  `agent_choice`, `question_waiting`, `reconnected`, `signal_failed`, `settings_changed`,
  `session_recovered`) and the daemon's grammar list are the same set: the daemon writes its list
  into the wire manifest and `WireContractTests` compares the enum to it.
- **Before attention** an issue is still logged and in `run_status`; the row stays as it would be
  without it. With several issues needing attention, the row shows the oldest, and its tooltip
  names the source and text.
- The activity log records an issue when it starts, when its text changes and when it recovers,
  not on every retry. An entry that could not be written is kept, in order and with its original
  time, in a bounded in-memory queue (the latest 200) and written before the next entry; a
  successful write of the queue is the activity source's success. An activity-write failure is not
  written at once (that write would fail too); its own start entry joins the queue with its time and
  text, so the log shows it, and its recovery, once writing works again.

Not changed: the session's own "needs you" (its permission prompt), questions waiting on the
person, the "did not start in its window" and stopped-session issues.

Alongside `feat/fix` (another session: a driven task that waits draws a new `waiting` status). It
leaves the Operator row alone; the only shared file is `SignalSidebarSnapshots.swift`, where both
add poses to the same list, a one-line conflict for whichever merges second.

## Files

- `app/Sources/AiTermCore/Operators/OperatorIssues.swift` — create: sources, the per-source record,
  `fail`/`succeed` returning the transition to log, `attention` by the rules above; Encodable for
  `run_status`.
- `app/Sources/AiTermCore/Operators/OperatorWakeEvent.swift` — create: the wake events and the line.
- `app/Sources/AiTermCore/Operators/Signals/OperatorDigest.swift` — modify: `appIssues`.
- `app/Sources/AiTerm/Operators/SignalOperatorController.swift` — modify: replace `lastError` with
  `OperatorIssues`; report failures and successes per source; classify wake results; log
  transitions; `statusIssue` from `attention`; pass issues to the tool handler and keeper digests.
- `app/Sources/AiTerm/Operators/OperatorSessionKeeper.swift` — modify: report its failures and
  successes as the `session` source instead of its own `lastError`.
- `app/Sources/AiTerm/Operators/SignalOperatorToolHandler.swift`, `+Calls.swift` — modify: an
  `issues` port for `run_status`.
- `app/Sources/AiTerm/Snapshots/SignalSidebarSnapshots.swift` — modify: an `issue` pose drawing the
  Operator row's "needs you" from an app issue.
- `daemon/aitermd/delivery.py` — modify: `WAKE_EVENTS` as a named tuple the grammar uses, with
  `settings_changed` and `session_recovered`.
- `daemon/tests/test_wire_contract.py`, `daemon/tests/wire/manifest.json` — modify: the manifest
  carries `wakeEvents`.
- `daemon/tests/test_delivery.py` — modify: every wake event passes the grammar.
- `app/Tests/AiTermCoreTests/WireContractTests.swift` — modify: the enum equals `wakeEvents`.
- `docs/operators.md` — modify: when the Operator row shows "needs you".

## Proof

- New `AiTermCoreTests/Operators/OperatorIssuesTests`: a retried source needs three failures; a
  person-started one needs one; a success clears only its own source; two failing and one
  recovering keeps the other; transitions are reported once per start, text change and recovery.
- `SignalControllerTests`, with `RecordingDaemon`:
  - A wake whose delivery fails three times marks the row "needs you" with the wake source; the
    next delivered wake returns the row to "watching N tasks" without any window being activated.
  - A wake refused as `typing` never counts; one refused as `wakeText` counts; a `partial` wake
    followed by `unsentInput` refusals counts and its issue says to press Enter.
  - A reply that fails, then the Operator's retry of the same keyed call: the result is replayed
    from the ledger without a second effect, the reply is sent and the reply issue clears.
  - A partial wake, `unsentInput` refusals, then the Operator's global `run_status`: the wake issue
    clears without a delivered wake.
  - Two failed replies for one call, then a different call's reply is sent: cleared, never
    attention; three failed replies across calls: attention.
  - An activity write fails while a wake issue starts; the next write lands the kept entry first,
    with its original time, and clears the activity issue; the activity failure's own start and
    recovery entries are in the log afterwards.
  - Take Over whose guard refresh fails shows at once; the next reconcile's successful repair clears
    it without another Take Over.
  - Two sources failing (wake and reply), the wake recovering: the row keeps the reply issue.
  - `run_status` reports the current issue's source and text, and the activity log has its start
    and recovery entries.
  - A `settings_changed` wake is delivered, and a wake raised while another is pending is not lost
    once the pending one is delivered.
- `WireContractTests` and `daemon/tests/test_delivery.py`: the wake-event parity.
- `scripts/snapshots.sh` with the new pose, read against `app/Sources/AiTermUI/README.md`.
- The gate before the commit; `scripts/test.sh all` plain before merging.

## To-dos

- [ ] `OperatorWakeEvent`, the daemon's `WAKE_EVENTS` with the two missing events, the manifest and
      both parity tests.
- [ ] `OperatorIssues` with its core tests.
- [ ] The controller and keeper report per source; wake result classification; `statusIssue`,
      activity log and `run_status`; `SignalControllerTests`.
- [ ] Snapshot pose, docs; read the PNG.
