# What the "Broadcast fix" run found in the Operator

Fixes from broadcast "Broadcast fix" (run 36A37BF3-1DE4-4660-A2BB-145C719CB9CF, AiTerm 0.42.0, 4–5 Nov 2026), which
built areas C, A, D, E, G and F of `2026-11-04-operator-snags.md`. Branch `feat/broadcast-fix-v1`, fast-forwarded to
local `main` (416f3c26, which has abf4f363) before planning.

## Goal

Six snags. The rule stays the snags plan's: **AiTerm must show what was true, so the Operator doesn't have to work
around it.**

1. No wake came when C, A or D became ready for acceptance, or when A's worker stopped after the Mac slept. The
   Operator only kept the broadcast going by its own `sleep 600` loop. A's stall was found about 2 hours late.
2. In a local-merge broadcast, each successor branched from `origin/main` (4fb7de17) instead of local `main` (558cea0d,
   with C merged). A, D, E, G and F all needed `git merge --ff-only main`.
3. Wake lines named area-E as `area-letter-ee` and area-G as `area-letter-gee`, keys no tool accepts.
4. A false "one task is uncertain, no worker confirmed in its window" wake came about 2 minutes after G (and F) were
   released, while their workers were opening normally.
5. A local merge is refused when origin can't be fetched, though it pushes nothing.
6. A running merge watch can push a newly accepted fix-round commit without the Operator's `finish_task`.

## What the run's own records show

- **Item 1 on 0.42.0 was plan A's case 2.** The activity log and the Operator's transcript show its sleeps ran in the
  background: its turns ended, and it sat idle, e.g. 00:36–00:46 UTC while C became ready at 00:42. The person's
  screenshot at 08:39 shows the Notice "The Operator can't be woken … Text may wait unsent in its input". The first
  wake line typed came at 09:17 (`area-letter-ee needs acceptance`), after the person had typed into the Operator's tab
  at 08:40, which made its key history known. abf4f363 (on `main`) reads the screen for that case.
- **What `main` still lacks.** A `.stopped` news (A's worker after the sleep) is counted, but `actionReason` skips it,
  so the line is the generic `updates waiting` and doesn't name the task. Nothing wakes the Operator for a silence
  AiTerm doesn't recognise as news.
- **Item 4's cause.** A new worker's window is listed first as the shell its agent command is typed into.
  `WorkerStarter.checkWorker` flags it uncertain at once and `onUncertain` says the reason. The flag clears seconds
  later when the agent shows, but the said reason stays and is typed when the Operator's turn ends.
- **Item 2's cause.** `Repository.addTaskWorktree` always prefers `origin/<base>`. Also, `diffBaseSHA` is
  `merge-base(<default branch>, HEAD)`, which is older than the real start point when origin is ahead of the local
  branch.

## Approach

### 1. Quiet-time watchdog, and a stopped worker named

**Stopped worker.** `OperatorWaker.actionReason` names `.stopped(id, _)` as `<task>'s worker stopped on an error`, so
A's case gives `[AiTerm] area-A's worker stopped on an error, call run_status`. Rate limits are included, since the
news already covers them.

**Watchdog.** A new main-actor `OperatorWatchdog`, owned by `OperatorController`, keeps one entry per broadcast in
memory:
- `lastMoved`: the time of the last event;
- `armed`: whether it may fire.

Events reset `lastMoved`:
- `run_status` content changing, as the waker compares it (`OperatorWaker.content`, made internal). This covers a
  worker's turn ending, its live state, test runs starting and ending, task states and the lists.
- any Operator tool call (a new `tools.onCall` hook at the handler's entry);
- a wake line delivered;
- the Operator's tab leaving `working`.

A commit happens during a worker's turn, and its turn end is the event.

**Once per quiet spell (the person's pick).** Only a change in `run_status` content re-arms it. The Operator's own
reads and the watchdog's own wake reset the clock but don't re-arm it.

**When it fires.** It is checked on the controller's reconcile tick (every 60 s). It fires when all of these hold:
- the broadcast is `active`: not planning, paused, complete or ended;
- the Operator's tab is known and not `working`;
- no worker works, on any of a task's tabs:
  - no task line's first worker is live `working`/`workingQuiet` or `opening`;
  - no extra tab (`TaskLine.tabs`, review and `open_tab` tabs) counts as working (`TabLine.counted`, which reads an
    opening tab as working);
  - no task has background jobs (`TaskLine.background`, the `background` list);
  - no test activity is active (`TaskLine.testActivities`);
- it is armed;
- `now - lastMoved` is at least `OperatorTiming.quietWake`.

It then calls `waker.say("nothing has moved for ten minutes", …)` and disarms. The waker's hold while the Operator
works still applies.

**Other details.**
- `OperatorTiming.quietWake` is 600 s (10 min, the person's pick). A test pins the spelled words to the constant.
- After AiTerm starts, and after a resume, `lastMoved` starts then: the resume changes `run.state`, which is a content
  change.
- An ended or forgotten broadcast drops its entry.

### 2. A local-merge task branches from the local default branch

- `WorkerStarter.startPoint` also says whether origin is preferred: not when `operated.end == .mergeLocal`. A code
  parent's accepted commit is unchanged.
- `Repository.addTaskWorktree(slug:branch:base:fromOrigin:)` (default `true`). With `fromOrigin: false` it neither
  fetches nor prefers `origin/<base>`.
- `TaskCreator.checkOutWorker` and `TaskWorkflow.checkOutWorker` pass the flag through.
- **diffBaseSHA is the real start point.** For a newly made branch, `TaskCreator.Made` carries the commit its HEAD
  started at (`git rev-parse HEAD` right after the add). `TaskWorkflow.checkOutWorker` uses it as the baseline. A
  restored or adopted worktree keeps today's `merge-base`.
- Every other end keeps origin.

### 3. Wake lines name a task by a key the tools accept

- `taskReference` moves to AiTermCore as `TaskKeyReference.spoken(_:)`, so the resolver can use it:
  - letter runs are kept as written;
  - each digit is spelled;
  - separators are hyphens;
  - only a key that is itself one letter is spelled (`letter-ay`).

  So `area-E` → `area-E` and `T7` → `T-seven`. The daemon's rule is unchanged and still refuses any digit and any
  standalone one-letter word: the menu-safety reason holds, because a hyphenated key is one word of several letters.
- `AppState.task(inRun:named:)` tries the exact key and id first, then the one task whose spoken reference equals the
  ref. Two tasks with the same spoken form resolve neither: exact keys only.
- The shared table `daemon/tests/fixtures/wake-lines.json` gains these rows:
  - `[AiTerm] area-E needs acceptance, call run_status` (plain);
  - `[AiTerm] T-seven asks something, call run_status` (plain);
  - the stopped line (plain);
  - the watchdog line (plain).

  Swift and Python both read it.

### 4. No uncertain flag while a launch is still opening

- `WorkerStarter.checkWorker` doesn't flag uncertain (or say it) while the task's `launch.workerPending == true`.
- E's 3-minute rule in `checkLaunches` judges that launch:
  - an agent appears: the pending mark clears;
  - none within `firstWorkerOpening`: the task is blocked with `noAgentReason`. That changes its state, which wakes
    the Operator, so "no worker showed up" still reaches it, as a block with its reason.
- A tab that lost its agent after the launch confirmed (`workerPending` nil) is flagged as today.
- Not covered: a worker window you reopen by hand (`reopenWorker`). No 3-minute rule judges it, so its uncertainty
  stays as is.

### 5. A local merge goes ahead when origin can't be read (decision confirmed)

- In `TaskFinisher.publish`, `landingFetched` answering `.unknown(why)` still refuses every end but `.mergeLocal`.
- For `.mergeLocal`, the call goes on with `fetched = nil`. `finishLanded` then reads the local branch and origin as
  last fetched.
- The answer's `reason` says: "Merged locally. AiTerm couldn't fetch main from origin (<error>), so it read origin as
  last fetched."
- The answer's shape doesn't change.
- **The Oracle gate first.** With the Oracle on, `challengeGate` reads `landingFetched` before the finisher runs
  (`OperatorToolHandler+Challenge.swift`, `landed`), and refuses on `.unknown`. For `.mergeLocal` it falls back to
  `TaskFinisher.landing(of:in:git:)`, which reads the local branch and origin as last fetched:
  - landed: the Oracle isn't asked, as for a fetched landing;
  - not landed: the Oracle is asked as before, and its yes is still required.

  Every other end keeps the refusal.

### 6. Only finish_task pushes (decision confirmed)

- In `TaskFinisher.publish`, a call that isn't the Operator's (`operatorCall == false`, which is the merge watch) and
  finds the accepted commit still to push (`stillToPush`) pushes nothing. It answers refused with "<key>'s accepted
  commit <sha7> isn't pushed: only finish_task pushes it."
- The watch then does what it does on a refusal: it records the problem and calls `watchStopped`.
  - The problem makes `resumeWatching` leave the task alone until `finish_task`, which pushes the commit and watches
    again.
  - `mergeWatchStopped` says `<task> has an accepted commit to push` for that reason, and its usual line for any
    other.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTerm/Operators/OperatorWatchdog.swift` | create | the quiet-time watchdog |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | own and feed the watchdog (observeRuns, sessionsChanged, tick, the `delivered` hook); `mergeWatchStopped` names an unpushed commit |
| `app/Sources/AiTerm/Operators/OperatorWaker.swift` | modify | `.stopped` in `actionReason`; `content` internal; `delivered` hook; `taskReference` uses Core's |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | `onCall` hook at the entry of every tool call |
| `app/Sources/AiTermCore/Operators/OperatorTiming.swift` | modify | `quietWake` (600 s) |
| `app/Sources/AiTermCore/Operators/TaskKeyReference.swift` | create | the spoken key, shared by the waker and the resolver |
| `app/Sources/AiTermCore/Operators/AppState+Operators.swift` | modify | `task(inRun:named:)` resolves a unique spoken form |
| `app/Sources/AiTerm/Operators/WorkerStarter.swift` | modify | `startPoint` with `fromOrigin`; no uncertain while `workerPending` |
| `app/Sources/AiTermCore/Git/Repository+Worktrees.swift` | modify | `addTaskWorktree(…, fromOrigin:)` |
| `app/Sources/AiTermCore/Tasks/TaskCreator.swift`, `TaskWorkflow.swift` | modify | pass `fromOrigin`; the start commit as baseline |
| `app/Sources/AiTerm/Operators/TaskFinisher.swift` | modify | item 5's fall-through; item 6's no-push guard |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Challenge.swift` | modify | item 5: the Oracle gate's local-merge fallback when origin can't be fetched |
| `daemon/tests/fixtures/wake-lines.json` | modify | new rows (shared fixture, not a frozen golden) |
| Tests: `OperatorWakerTests`, a new `OperatorWatchdogTests`, `WorkerStarterTests`/`WorkerLaunchTests`, `WorktreesTests`, `TaskFinisherTests`/`OperatorMergeTests`, the resolver's tests, `daemon/tests/test_delivery.py` (reads the table already) | modify/create | tests that fail first, below |
| `scripts/test-routes.tsv` | modify if needed | route the new Swift files and test suites |
| `docs/operators.md` | modify | a line each on the watchdog and the stopped wake, the local-merge start point, and that only finish_task pushes |

No served tool schema, brief, `contract.json`, `state.json` or wire manifest changes. The watchdog lives in memory, and
the `finish_task` answer keeps its fields. Old test expectations of `letter-tee-seven` become `T-seven`: they encode
the bug, not a contract.

## Proof

Tests first, each failing before its fix (except the two noted as already passing), with the run's cases as
fixtures:

1. `OperatorWakerTests`:
   - **Already passes on `main`; it records the finding.** area-C turns `readyForAcceptance` while the Operator idles:
     one line naming it is typed. The same news arriving mid-turn is typed once when the turn ends.
   - A's worker gets `stoppedOn` ("it won't carry on by itself"): the line names area-A. On `main` it is the generic
     line.
2. `OperatorWatchdogTests`, with a fake clock, fake ticks and recorded `say`s:
   - quiet for 10 minutes with no worker working gives one `nothing has moved for ten minutes` wake;
   - each event resets the clock;
   - each of these gives none:
     - a first worker working or opening;
     - an idle first worker beside an extra tab (a reviewer) working;
     - a background job or an active test run;
     - the Operator's turn;
     - a paused broadcast and an ended broadcast;
   - after it fires, a `run_status` read and a delivered wake don't re-arm it, and a status change does;
   - a restart doesn't fire at once.
3. A real temp repository with a bare origin at 4fb7de17's role (X) and local `main` one merge ahead (Y, "merge
   c7174be9"):
   - a `mergeLocal` launch's branch has Y as an ancestor and `diffBaseSHA == Y`;
   - a `merge` launch still starts at `origin/main`;
   - with origin ahead of local (Z), `diffBaseSHA == Z`: today it is the older merge-base.
4. Key reference:
   - `area-E` → `area-E` and `T7` → `T-seven`, both plain by the shared table;
   - the resolver finds area-E by `area-E` and T7 by `T-seven`;
   - two tasks with the same spoken form resolve neither by it;
   - the run's `[AiTerm] area-letter-ee needs acceptance, call run_status` is the regression case.
5. `WorkerStarterTests`, area-G's release:
   - its window listed as a shell while `workerPending` gives no uncertain flag and no wake;
   - the agent tab listed later gives nothing;
   - still a shell after 180 s blocks it with `noAgentReason`;
   - a confirmed worker whose tab lost its agent is still flagged.
6. `TaskFinisherTests`, with origin unreachable:
   - a `mergeLocal` end merges, and its answer's reason says origin couldn't be read;
   - a `merge` end still answers failed with `unfetched`;
   - at the handler, with the Oracle on and origin unreachable, a `mergeLocal` `finish_task` is challenged, not
     refused. Without the Oracle's yes it doesn't merge; with it, it merges. A `merge` end is still refused with
     `unfetched`.
7. `OperatorMergeTests`:
   - a merge watch running on an open MR, with a new fix-round commit accepted, pushes nothing, records the problem
     and wakes with the task named;
   - the Operator's `finish_task` then pushes it and the watch resumes.
8. Gates:
   - `scripts/test.sh` before each commit;
   - `scripts/test.sh all` once at the end;
   - `/psg:review` before the last commit.

   No live run: broadcasts run inside the installed AiTerm (`run-dev.sh` only on the maintainer's go). No golden is
   regenerated.

## To-dos

One commit per item, in this order, each leaving `main`'s behaviour working:

- [ ] 3: `TaskKeyReference`, the resolver, the waker and the table (others use its output)
- [ ] 4: no uncertain flag while pending
- [ ] 2: local-merge start point and the real `diffBaseSHA`
- [ ] 5: local merge with origin unreadable
- [ ] 6: the watch never pushes
- [ ] 1: the stopped wake, then the watchdog
- [ ] `/psg:review`, fix rounds, `scripts/test.sh all` green, no push

## Decided without the person

- The 0.42.0 silences were plan A's false `unsentInput`, shown by the screenshot and the transcript's timeline. The
  watchdog is a safety net under the specific wakes, not their fix.
- "No worker working" includes background jobs and active test runs, so a long `scripts/test.sh all` isn't quiet.
- Item 4's "still fire after the window" is E's block with its reason, not a late uncertain line.
- Item 5's note goes in `reason`, so `finish_task`'s answer keeps its shape.
- Item 6 records the refusal as the publication's problem, so the watch doesn't restart until `finish_task`.
