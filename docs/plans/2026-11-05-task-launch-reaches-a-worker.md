# A task's launch reaches a worker, behind your work, or says why it didn't

Plan E of the Operator snags (`2026-11-04-operator-snags.md`, "E. Launching a task fails"). Branch
`fix/e-launching-a-task-fails`, built on the local `main` with C, A and D merged (f66095dc).

## Goal

Two snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- **T3, released by submit_plan:** its new window came to the front with keyboard focus. The person was
  typing in another window, the keys went into T3's new shell while AiTerm typed the agent command,
  and no agent started: no session, no claude process in the worktree.
- **The retry with the worktree at 41fa602:** after retry_task the task showed working, opening and
  uncertain, then read_task said "no open tab and no recorded conversation identity". The worktree was
  there; minutes later no worker had started.

The person's decisions, word for word:

- A task's new window opens behind the person's work without taking focus, as open_tab's tabs do.
- retry_task launches a worker, or answers plainly that the launch failed and why. It never leaves a
  task on working/opening/uncertain with no worker.

## What the code does today

- **Focus.** The app asks for every Operator window with `background: true` (`WorkerStarter.launch`,
  `reopen`), and the daemon then skips `win.async_activate()`. But `ItermBridge._new_window` creates the
  window with iTerm2's `select` left at its default, true: iTerm2 selects the new window and orders it
  front. open_tab's tabs pass `select=False` (`_new_tab`), which is why they stay behind. The agent
  command is typed into the new shell after the window is made (`WindowManager._set_up_created`), so
  keys the person types into a window that took focus mix with it.
- **Retry.** retry_task moves the task failed → queued and answers at once. The start pass then claims
  it and `WorkerStarter.launchClaimed` picks one of three paths: the first worker is idle in its tab
  (told to try again in place), busy (blocked), or absent (`launch`). When the failed worker left its
  window open with only a shell, there is no first worker, so `launch` asks for a window. The daemon's
  `window.createTask` finds a window already tagged with the task and returns it **without typing the
  agent command** (that dedupe exists for a lost reply). AiTerm records the window: working, opening for
  3 minutes, uncertain because the tagged tab runs no agent. Nothing starts the agent, and nothing ever
  says so. The reconciler only relaunches a launch that never showed a window.

T3's broken launch is that same state: a tagged window with a shell and no agent. Retrying T3 would
have hit the dead end of the second snag.

## Approach

**1. A background window doesn't take focus (daemon).**
- `ItermBridge.create_window(background=True)` asks iTerm2 not to select the new window (`select=False`
  through `_make`, as `_new_tab` does for open_tab).
- iterm2's own docs say a brand-new window may still be ordered front. So after making it, the bridge
  compares the focus before and after. "Before" is the last tick's focus: `create_task` ticks just before
  creating. "After" is the refresh `_make` does to find the window. If iTerm2 was the active app, another
  window had keyboard focus, and the new window has it now, the bridge gives focus back to that window
  (`async_activate`). It does this inside the set-up, so before the agent command is typed.
- Keys that still landed in the new shell before the agent command is typed (in the moment before focus
  went back) would garble the command, which is T3's failure. So for a background window the
  `WindowManager` asks the keystroke monitor (`TypingGuard`) whether any key was seen in the new session.
  If one was, it sends ⌃U (kill the line) ahead of the command. Without such keys, the bytes typed stay
  exactly as now.
- A window that isn't background (a task you create, a terminal) still comes to the front, as now.

**2. A launch into a window that holds only a shell starts the agent in a new tab there (app).**
- In `WorkerStarter.launch`, a claimed launch (not the reconciler's relaunch, which adopts its orphan as
  now) may find sessions tagged with the task but no first worker running an agent. Then it opens the
  worker as a new tab in that window, in the worktree, behind your work:
  `createTab(windowId:cwd:agentCommand:tabKey: nil, background: true)`. It doesn't ask for a window the
  daemon would hand back unused.
- The tab carries the window's task tag, so it becomes the first worker. The old shell tab is left alone:
  AiTerm never types into a shell the person may be using.
- Its failures are handled like a window's: a timeout or disconnect is left for the 3-minute rule below,
  and any other error blocks the task with the reason.

**2b. A command that couldn't be typed is a launch that failed, with its reason (daemon and app).**
- Today `WindowManager._set_up_created` logs a failed send of the agent command and answers as if all went
  well. Now `_set_up_created` returns the send's failure. `window.createTask` and `tab.create` add an
  optional `commandError` to their reply when an agent command was given and its send failed; without
  one, the reply is unchanged.
- The app reads it only on the Operator's launch path. `DaemonCommands` gains `openWorkerWindow` and
  `openWorkerTab`, which send the same requests and return the id with `commandError`. Every other caller
  keeps `createTaskWindow` and `createTab` as they are.
- In `WorkerStarter.launch`, a `commandError` records the window, as the window is there, and blocks the
  task at once: "AiTerm couldn’t start it: its window opened, but AiTerm couldn’t type its agent command
  there: <error>. resume_task starts it again." That block resumes to queued. retry_task answers
  `failed` with that reason.
- The wire contract gains one fixture, `reply.window.createTask.commandError.json`, registered in
  `daemon/tests/wire/manifest.json` and read by Python's producers and Swift's `WireContractTests`.

**3. retry_task waits for its launch and says what happened.**
- After the retry, the handler asks the controller to start the task now: one start pass, then it waits
  for that task's launch within the call's reply budget. That budget is the same deadline `respond`
  already computes for finish_task (`OperatorPorts.finishReplyBudget`, 24 s, inside the daemon's 30 s).
- The answer is the task answer as now, plus `launch: {result, note}`:
  - `started`: its worker was idle in its tab and was told what failed and to try again;
  - `opened`: AiTerm opened its worker in a new window or in a new tab of its window, behind your work,
    and typed its agent command there (the daemon confirmed the send, rule 2b). If no agent starts there
    within 3 minutes, AiTerm blocks it and says why;
  - `opening`: the answer had to go before the window or tab was confirmed. AiTerm blocks it and says
    why if no worker starts;
  - `failed`: the launch blocked the task. The note is the block's reason, for example
    "AiTerm couldn’t start it: its worker is still busy; stop it or wait.";
  - `queued`: it wasn't started, and the note says why. Either AiTerm isn't connected to iTerm2, or the
    task waits on a task it depends on.
- A repeated retry_task of a task already working or queued answers the same shape, read from its state.
- `WorkerStarter.launchClaimed` returns how its launch ended (`Outcome`). The controller keeps each
  start's task by task id, so the hook can wait for the right one.

**4. A launch whose agent never starts is blocked plainly (the 3-minute rule).**
- A launch marks its attempt `LaunchAttempt.workerPending = true`, saved, once its claim is confirmed
  to hold and before it asks for a window or tab, or adopts an orphan window. The mark stays through
  whatever records the window afterwards: a reply, the reconciler adopting a tagged tab after a lost
  reply, or a relaunch adopting its orphan. So a window whose command never ran is judged too, even when
  its reply was lost. This is a new optional field: older records decode as nil and are never judged by
  this rule.
- The mark is cleared the first time a first-worker tab running an agent is listed for the task
  (`checkWorker`).
- On every listing (`tabsListed`), a working, not taken over task whose attempt is still pending, and
  whose window was seen `OperatorTiming.firstWorkerOpening` (180 s) ago or more, is blocked:
  "AiTerm couldn’t start it: its window opened, but no agent started in it within 3 minutes. resume_task
  starts it again." This applies whether its window is still there or was closed.
- That block records `blockedFrom = .queued`, so resume_task queues the task and the start pass launches
  it again. The launch goes through rule 2, a new tab in the shell's window, or a new window if the
  window is gone. The person is told as for every launch block (`onBlocked`), and the Operator is woken.
- This closes both snags' end state. T3's garbled launch and a retry that came to nothing end blocked
  with a reason, never working, opening or uncertain with no worker.

**5. A launch that never gets a window stops being retried forever.**
- A launch whose window request ended without an answer (a timeout, a disconnect, iTerm2 unavailable)
  is relaunched by the reconciler a minute on, as now. WorkerStarter counts such endings per task, in
  memory, and resets the count once a window or tab is recorded.
- After 3 of them in a row, the reconciler blocks the task instead of relaunching it: "AiTerm couldn’t
  start it: iTerm2 didn’t confirm its window in 3 tries (<last error>)." That block also resumes to
  queued.
- **While iTerm2 stays unreachable**, there is no fourth try to count, because the reconciler's tick
  returns while iTerm2's tabs are unknown. So the controller's tick, before that guard, also blocks a
  working task whose last launch ended unconfirmed in this run of AiTerm and is still unconfirmed
  `firstWorkerOpening` (180 s) later: "AiTerm couldn’t start it: it lost iTerm2 while opening its window,
  and iTerm2 hasn’t answered since (<last error>)."
- If the window turns out to have opened, the reconciler adopts its tagged tab as it does for any blocked
  task. When resume queues the task, the daemon hands that window back, never a second one.
- Only endings seen by this run of AiTerm count. A launch left over from before a restart is the
  reconciler's, as now.

**6. Frozen contracts.**
- retry_task's served description changes on purpose. It becomes "Queues a failed task again, if it has
  retries left, and starts its worker: the answer's launch says whether it started, or why it couldn't."
  `daemon/tests/fixtures/operator-current-tools.json` is edited by hand for that entry only, with this
  plan and the snag log as decision and evidence (docs/testing.md). Its input schema doesn't change.
- `contract.json` has no retry_task call. `state.json` loads unchanged, since `workerPending` is optional.
  Briefs stay untouched.

### Decided without the person

- **Not probed live.** Whether iTerm2 orders a brand-new window front despite `select=False` is not
  probed against the live iTerm2. Probing would open windows in the person's iTerm2 beside the running
  broadcast, and a first API connection can raise iTerm2's permission prompt with nobody there to
  answer. Rule 1 therefore does both: it asks for no selection, and it hands focus back when iTerm2 took
  it anyway.
- **Another app isn't given focus back.** iTerm2's API has no way to give focus back to another app. So
  when iTerm2 wasn't the active app and a new window still activated it, AiTerm can't undo that; this is
  written down as open. The snag's case is a window that took focus from another window, and rule 1
  covers it.
- **The answer doesn't wait for the agent.** retry_task answers once the window or tab is open and the
  command typed, not once the agent is listed. Waiting for a process to show would need a poll inside
  the call's budget. The 3-minute rule reports an agent that never starts, through the block and the
  Operator's wake.
- **The 3-minute bound.** It is `firstWorkerOpening` (180 s), the bound for how long a first worker
  counts as opening. No new constant.
- **Blocked, not failed.** Spec §8 lets AiTerm block a task but not fail one. Resuming that block queues
  the task again, so resume_task restarts its worker without using a retry.
- **A new tab, not typing.** The shell left in a task's window gets a new tab beside it. AiTerm doesn't
  type into that shell, which the person may be using.
- **A failed send gets an additive wire field.** It is an optional field in the reply plus two new
  methods for the Operator's launches, so no existing caller or signature changes.
- **Focus is not proven live here.** The decision names the mechanism, "as open_tab's tabs do", and
  open_tab's tabs stay behind because they are created with `select=False`. iTerm2's own proto field
  (pinned iterm2 2.30) says it creates without selecting and without bringing the window front. The
  focus hand-back and the ⌃U are fallbacks for the case where iTerm2 still raises a brand-new window.
  Whether it does can only be seen in a live iTerm2. That stays the person's check, written down under
  Open with how to run it.
- **The 3-try bound.** It is a fixed 3, in memory, not saved: after a restart a task gets at most
  3 more tries.
- **Same budget as finish_task.** The reply budget is reused from `respond`'s deadline
  (`finishReplyBudget`, 24 s). It is one budget for every tool call that waits on work.

## Files

| File | Change | Why |
|---|---|---|
| `daemon/aitermd/iterm_bridge.py` | modify | `create_window(background=True)`: `select=False`, focus handed back to the window that had it |
| `daemon/tests/test_iterm_bridge.py` | modify | `_CreatingApp` reports focus; T3's background window tests |
| `daemon/aitermd/windows.py`, `daemon/aitermd/keystrokes.py`, `daemon/aitermd/service.py` | modify | ⌃U ahead of a background window's command when keys landed in its new session (`TypingGuard.typed_in`) |
| `daemon/tests/test_service.py` (or the windows tests) | modify | the ⌃U guard |
| `daemon/aitermd/windows.py` | modify | `_set_up_created` returns the send's failure; `commandError` in the createTask/tab.create reply |
| `daemon/tests/wire/reply.window.createTask.commandError.json`, `manifest.json`, the Python producer | create/modify | the additive reply field, in the wire contract |
| `app/Sources/AiTermCore/Daemon/DaemonCommands.swift`, `DaemonClient.swift` | modify | `openWorkerWindow`/`openWorkerTab` returning the id and `commandError` |
| `app/Tests/AiTermTests/RecordingDaemon.swift` | modify | the two methods, with a scriptable `commandError` |
| `app/Tests/AiTermCoreTests/WireContractTests.swift` (or the decoding test that reads the fixtures) | modify | decodes `commandError` |
| `app/Sources/AiTerm/Operators/RunReconciler.swift` | modify | the 3-minute rule on every tick (events can go quiet); the 3-try bound instead of a fourth relaunch |
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `LaunchAttempt.workerPending: Bool?` |
| `app/Sources/AiTerm/Operators/WorkerStarter.swift` | modify | the shell window gets a new tab; `Outcome`; `workerPending` set and cleared; the 3-minute rule; a block that resumes to queued |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | each start's task by id; `launchNow(_:by:)` for retry_task; wire `tools.launchNow` |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | the `launchNow` closure; `.retryTask` dispatch passes the deadline |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Tasks.swift` | modify | `retryTask` awaits the launch and answers `launch` |
| `daemon/aitermd/operator_mcp.py` | modify | retry_task's description |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | that description, and nothing else |
| `docs/operators.md` | modify | one line: retry_task starts the worker and answers how its launch went; the 3-minute rule |
| `app/Tests/AiTermTests/Operators/WorkerStarterTests.swift` | modify | the 41fa602 retry, the 3-minute rule, resume after it |
| `app/Tests/AiTermTests/Operators/OperatorTaskToolsTests.swift` | modify | retry_task's `launch` answer (the existing retry test now reads `working`) |

## Proof

Tests first. Each reproduces its snag and fails before the fix.

1. **T3** (`test_iterm_bridge.py`, fixture: the person in window `w0`, iTerm2 active, T3's background
   window made by submit_plan's start):
   - the window is asked for with `select=False`;
   - when iTerm2 makes the new window key anyway, `w0` gets focus back and the new window is never
     activated;
   - when iTerm2 leaves focus where it was, nothing is activated;
   - a foreground window is still activated.

   The first two fail today.
2. **The retry with the worktree at 41fa602** (`WorkerStarterTests`): a task with a worktree holding a
   commit fails and is retried, and its window still shows the failed worker's shell (tagged, no agent).
   - The start opens a `tab.create` in that window: cwd the worktree, the retry's agent command,
     `background`, no tabKey.
   - No `window.createTask` is asked for. The window is recorded with `workerPending`.

   This fails today: `window.createTask` is asked for and nothing is typed.
3. **retry_task through the handler** (`OperatorTaskToolsTests`), same fixture. The answer has
   `launch.result == "opened"` and state `working`. Then:
   - with `tab.create` failing (`internal`): `failed` with the block's reason;
   - with no helper connected: `queued`, saying why;
   - with `tab.create` held past a short reply budget: `opening`.
4. **The 3-minute rule** (`WorkerStarterTests`):
   - a pending launch with only a shell, 180 s after its window was seen, is blocked with the plain
     reason, and the person is told;
   - at 179 s it isn't blocked;
   - one whose agent was listed once isn't blocked later;
   - a record without `workerPending` (state from before this change) is never blocked;
   - a lost reply (`window.createTask` times out), then the reconciler adopting a tagged shell with no
     agent: blocked 180 s after it was adopted;
   - resume_task queues the blocked task, and its start opens a tab again.

   The existing `aShellWindowStaysUncertainUntilAWorkerAppears` stays green.
4b. **Keys in the new shell** (daemon): a background createTask whose new session saw a key before the
   command is typed sends `\x15` and then the command; one with no key sends the command exactly as now.
   A foreground window is unchanged.
4d. **A command that couldn't be typed** (daemon: the reply carries `commandError` when `send_text`
   fails; app: `WorkerStarter` with RecordingDaemon answering `commandError`): the task is blocked at once
   with the reason, and retry_task answers `failed` with it.
4e. **Sustained disconnect** (`RunReconcilerTests`): a launch ends `disconnected`, iTerm2's tabs stay
   unknown, and the controller ticks. At 179 s the task is still working; at 180 s it is blocked with the
   reason. A launch ended by an earlier run of AiTerm is never blocked this way.
4c. **The 3-try bound** (`RunReconcilerTests`): `window.createTask` keeps timing out. The first launch
   and two relaunches are asked for; at the third ending, the task is blocked with the reason and no fourth
   is asked for.
5. Daemon: `test_operator_mcp.py` against the hand-edited golden.
6. Gate: `scripts/test.sh` before the commit, `scripts/test.sh all` once before merging. No live run:
   `scripts/run-dev.sh` and `delivery_check.py` are off limits while the broadcast runs in the
   installed AiTerm.

## To-dos

- [ ] Daemon: background window not selected, focus handed back before the command is typed (test 1)
- [ ] App: a claimed launch into a shell-only task window opens the worker as a new background tab (test 2)
- [ ] Daemon: ⌃U ahead of a background window's command when keys landed in it (test 4b)
- [ ] App: `workerPending`, the 3-minute block that resumes to queued, run on listings and on every tick (test 4)
- [ ] App: the 3-try bound on launches that never got a window, and the sustained-disconnect block (tests 4c, 4e)
- [ ] Daemon + app: `commandError` from a failed send, through the wire, to a plain block (test 4d)
- [ ] App: retry_task waits for its launch within the reply budget and answers `launch` (test 3)
- [ ] retry_task description in `operator_mcp.py` and the golden entry by hand; docs/operators.md (test 5)

## Open

- **Focus in a live iTerm2.** The person's check, once no broadcast needs the installed AiTerm
  undisturbed: start a one-task broadcast while typing in another iTerm2 window, and confirm that the
  task's window doesn't come forward and your typing stays where it was.

- If a background window still activates iTerm2 while the person works in another app, AiTerm can't
  hand focus back to that app through iTerm2's API.
- After an AiTerm restart, the 3-minute rule still holds, because `workerPending` is saved. A worker
  that started and then quit mid-work, leaving its window's shell, stays uncertain as today. That is
  outside the decision, which covers launches.

## Review of this plan

Adversarial plan review by Codex. Three rounds, each finding triaged as below. Nothing Critical or
Important is still open, apart from the live focus check, which only the person can do.

- Round 1:
  - Focus restored only after it was taken (Important): fixed. `select=False` stays first; the ⌃U
    guard was added.
  - A launch with no window has no bound (Important): fixed with the 3-try bound.
  - `opened` claims a command was typed when that isn't confirmed (Important): the wording was fixed.
- Round 2:
  - Focus not proven to stay (Important): pushed back. The decision names open_tab's mechanism, which
    the plan applies, and the live check is the person's (Open).
  - A sustained disconnect never reaches 3 tries (Important): fixed with the time-based block that
    doesn't need a listing.
  - A known send failure is hidden (Important): fixed with `commandError`, an additive wire field, and
    two Operator-only methods.
- Round 3:
  - An adopted orphan shell escapes the 3-minute rule (Important): fixed. `workerPending` is set before
    the window is asked for and kept through adoption.
