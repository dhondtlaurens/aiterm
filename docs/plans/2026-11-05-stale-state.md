# AiTerm shows what is true now: thread counts, and no stale "blocked" on a card

Plan D of the Operator snags (`2026-11-04-operator-snags.md`, area D). Branch `fix/d-aiterm-shows-stale-state`,
built on a `main` that has areas B, C and A.

## Goal

Three snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- run_status said `unresolvedThreads 2 / resolvedThreads 0` on !63 (T3) and 2 of 3 unresolved on !64 (T9) after
  the reviewer had resolved every thread and approved; GitLab showed them all resolved.
- T1's card said `blocked · The Oracle hasn't s…` after the Oracle had answered (challenge 7A68F0F0, recorded
  08:09). run_status showed no flags and no mergeRefusal.
- T7's card said `blocked · The pre-push hook r…` while T7 was inReview and working, after a later push had
  landed (8eb4928 on !68).

Rule (the person's): the card and run_status come from the current state only. run_status's thread counts come
from the host as it is now; the Oracle's pending label clears once the challenge is answered; a push-hook label
clears once a later push succeeds; a task that is really blocked never looks like one with a stale label.

## Cause

**Thread counts.** `RunStatus.PeopleReviewLine` counts `OperatedTask.peopleReview.threads`, which only
`ReviewWatcher` writes, and it reads only tasks in `inReview`. A merge end whose review `finish_task` ended is
`accepted` while it waits for the Oracle or the merge (T3, T9 that evening): nothing reads its threads again, so
run_status repeats the last read, however old. Nothing in run_status says when the counts were read.

**T1.** mark_task accepted T1 again on the same commit to refresh its evidence (challenge 7A68F0F0). That path
(`OperatorToolHandler+Tasks.markTask`, "Refresh evidence for the same verified head") clears
`publication.conditionsHeld`: the Oracle's yes no longer covers the evidence. T1's merge was being watched. The
watch's next poll was refused by `PublicationGuard.oracleRefusal` ("The Oracle hasn't said that … hold for T1 …:
call finish_task again"), and the watch recorded that refusal as the task's `publication.problem`
(`TaskFinisher.watch`, `.refused` → `recordFailure`). A recorded problem makes a `.problem` request
(`OperatorRequests.open`), so the card says `blocked · <problem>` in the person's colour, and the person is
notified. But nothing waits on the person: the merge waits for the Operator's next finish_task, which the Oracle
judges. And run_status has no field for `publication.problem`, so the Operator, woken with "one task's merge watch
stopped", saw nothing there.

**T7.** A merge end's watch polls with `restart: false` (`TaskFinisher.watch` → `run(id, restart: false)`), and a
finish_task made while a watch exists also runs with `restart: false`. Only a run with `restart: true` clears a
recorded problem (`TaskPublisher.advancing`, "if restart, publication.problem != nil"). A watch that polls a task
accepted again for a fix round (a merge end in review, its request recorded: `isWatchable` holds) pushes the new
commit itself; a poll whose push the hook refused records the hook's problem (`publish`'s catch →
`recordFailure`) and the watch goes on (fewer than three failures); the next poll's push lands and the task goes
back in review, with the hook's problem still recorded. Its card then says `blocked · The pre-push hook r…` while
in review. The same happens to any failure a watch poll recorded and a later poll got past (a host read that failed
once, then answered `waiting`).

## Approach

1. **run_status reads each request's threads now.** Before it builds the snapshot, run_status reads the threads
   of every task with a request whose people review began (`peopleReview != nil`), in any state, from the host,
   asking the hosts together within `OperatorPorts.hostTimeout`, and never from a cache: a thread resolved on the
   host is counted resolved on the next run_status. `RunStatus.build` takes these fresh resolutions
   (`hostThreads`, by task) and uses them wherever the snapshot reads threads: the line's `unresolvedThreads` and
   `resolvedThreads`, and `obligations.reviewQuiet` (`isReviewQuiet`), so one answer never says a thread is open
   and the review quiet. A read that fails or times out leaves that task on the stored threads and sets the
   line's new optional `threadsNote` ("AiTerm couldn't read its threads on the host now: …; these counts are from
   its last read"), so stale counts never pass for current. The stored `peopleReview` is not written:
   `ReviewWatcher` keeps it, and its news are told against it. Every other caller of `currentStatus` (the waker's
   diff, the Oracle's and the gate's context) builds as now, without a host read. `read_task` with `what: review`
   already reads the threads from the host.
2. **What waits on the Operator is not a problem for the person.** The watch refused by the Oracle's yes no
   longer covering the evidence (the refusal is exactly `PublicationGuard.oracleRefusal` for the task now) records
   a fixed hold, `PublicationGuard.oracleYesNeeded` ("the Oracle's yes doesn't cover its evidence now; call
   finish_task to merge it"), instead of the refusal's sentence. Like `TaskEndChange.mergeWaitsForFinish`, a hold
   stops the watch from restarting, asks the person nothing (no request, no notification), and its card says
   `accepted · waiting on the Operator`. The Operator's next finish_task is judged as now: a yes reaches the
   finisher, whose restart clears the hold; a no never reaches it (`refuseVetoed` records `mergeRefusal` and
   throws), so the hold stays and the card, which checks the hold before `waitingSince` and `mergeRefusal`, reads
   `mergeRefusal` inside the hold: `waiting to merge · refused by the Oracle`, as for any refused merge. One set,
   `TaskPublication.operatorHolds`, names the holds; the card, the requests and run_status read it.
3. **A later run that goes through clears a failure's problem.** A run with `restart: false` that ends published,
   in review or waiting to merge clears a `publication.problem` that is not a hold: only a failed step of the same
   watch could have recorded it (a watch starts only with no problem, and its polls are the only `restart: false`
   runs), and a hold set meanwhile (`disarm`) is kept. This is the T7 fix: the push that lands clears the hook's
   label. `lastPushFailure` is already cleared by the push that lands.
4. **The card and run_status read the problem from the current state.** A publication problem is current only
   for an `accepted` task: one in review, published or back at work is past its publication's failure. One shared
   reading, `OperatedTask.currentPublicationProblem`, is used by `OperatorRequests.open`, `OperatorLine`
   (accepted, and the `.problem` request's detail) and run_status's new optional `publicationProblem` (the
   sentence the card says `blocked` for, or a hold's; nil otherwise). So a stale record from before this fix (T7's
   in state.json) no longer shows, and what the card says blocked for, run_status says too.

### Decided without the person

- Thread counts are read fresh on every run_status, not through the 30 s `hostReadCache` that the request's state
  uses: the person's rule is "on the next run_status". One host call per task with a people review per run_status
  is a few calls; they run together within the same timeout. Approvals stay in `mergeRequest.approvedBy`, cached
  as now.
- A failed thread read keeps the last counts with a `threadsNote`, rather than dropping the counts: the Operator
  still sees what was last known and that it is not current.
- run_status gains two optional per-task fields, `publicationProblem` and `peopleReview.threadsNote`; absent
  when nil. The served run_status tool description names no per-task fields, so the served schemas and
  `daemon/tests/fixtures/operator-current-tools.json` do not change; `contract.json` has no task with a request,
  a review or a problem, so its golden does not change either.
- The Oracle's hold is a fixed sentence without the task key, like `mergeWaitsForFinish`. The watch's wake line
  stays "one task's merge watch stopped"; run_status now says why.
- The watch pushing a fix-round commit on its own (seen while tracing T7) is out of scope: the label is fixed
  where it is recorded and where it is read. Written down as an open point.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/RunStatus.swift` | modify | `build(hostThreads:)` for the counts and `isReviewQuiet`; `PeopleReviewLine.threadsNote`; `TaskLine.publicationProblem` from `currentPublicationProblem` |
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `TaskPublication.operatorHolds`; `OperatedTask.currentPublicationProblem` |
| `app/Sources/AiTermCore/Operators/PublicationGuard.swift` | modify | `oracleYesNeeded`; `oracleRefusal` reachable from the finisher |
| `app/Sources/AiTermCore/Operators/OperatorRequests.swift` | modify | a `.problem` request only for a current problem that is not a hold |
| `app/Sources/AiTermCore/Sidebar/OperatorLine.swift` | modify | holds say `waiting on the Operator`; problems read through `currentPublicationProblem` |
| `app/Sources/AiTerm/Operators/TaskFinisher.swift` | modify | the watch records `oracleYesNeeded` for the Oracle's refusal; a `restart: false` run that goes through clears a failure's problem |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Host.swift` | modify | `readThreads`: each request's threads read from the host now, or why not |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | run_status reads the threads first and builds with them; `currentStatus(of:hostThreads:)` |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | `status(of:…)` passes `hostThreads` to `RunStatus.build` |
| `docs/operators.md` | modify | one line: run_status's thread counts are read now, and `publicationProblem` |
| tests (below) | create/modify | the snags' fixtures |

## Proof

Tests first; each fails before its fix, with the snag's case as fixture.

1. **!63 (T3).** `OperatorReviewTests`: a merge end `accepted` with its review ended, request !63, stored
   `peopleReview.threads` 2 unresolved; the fake host now has 3 threads, all resolved. run_status says
   `unresolvedThreads 0, resolvedThreads 3`. Today it says 2 / 0. A second run_status after one thread is reopened
   on the host says 1 / 2 (no cache). The host failing: the stored counts, with `threadsNote`. A task in review,
   quiet long enough, whose stored threads are all resolved but one is open on the host now: not in
   `obligations.reviewQuiet`, and its line counts the open thread.
2. **T1, challenge 7A68F0F0.** `TaskFinisherTests`: a merge end waiting to merge with the Oracle on and its yes
   recorded for the accepted commit and evidence; its evidence is refreshed as mark_task does
   (`conditionsHeld` cleared); the next watch poll is refused. The task's line is `accepted · waiting on the
   Operator`, `OperatorRequests.open` has no request for it, and run_status's `publicationProblem` is the hold.
   Today the line is `blocked · The Oracle hasn't s…` with a `.problem` request. The Operator's next finish_task
   clears the hold.
2b. **T1 end to end.** `OperatorMergeTests` (Oracle on, the real tool handler): finish_task with a yes waits to
   merge; mark_task refreshes the evidence on the same commit through its challenge (7A68F0F0's path); the watch's
   next poll records the hold; the line is `accepted · waiting on the Operator`. The next finish_task with the
   Oracle answering no: the line is `waiting to merge · refused by the Oracle`, run_status shows the
   `mergeRefusal`, and no `.problem` request is open.
3. **T7, 8eb4928.** `TaskFinisherTests`: a merge end in review on its request, accepted again for a fix round and
   watched; a pre-push hook refuses the first poll's push (problem recorded, as today), the hook is removed, the
   next poll's push lands and the task is back in review. Its problem is nil, its line is `in review`, and no
   request is open for it. Today the problem stays and the line is `blocked · The pre-push hook r…`.
3b. Same suite: a host read that fails once during a merge wait, then answers waiting: the failure's problem goes.
   A hold set by `disarm` while a poll is in flight stays.
4. **Current state only.** `OperatorLineTests` / `OperatorRequestTests` (AiTermCore): a task in review with a
   stale publication problem in its record (T7's state.json) shows `in review` and makes no request; an accepted
   task with a hook problem for its accepted commit still says `blocked · The pre-push hook …` and makes one: a
   really blocked task still looks blocked.
5. Existing suites stay green: `TaskFinisherTests`, `OperatorMergeTests`, `OperatorReviewTests`,
   `OperatorRequestTests`, `OperatorFinishReplyTests`, `OperatorCurrentContractTests` (golden unchanged).
6. Visual: `scripts/snapshots.sh build/snapshots-d`; read the board and sidebar PNGs with a blocked task against
   `app/Sources/AiTermUI/README.md` (no new visual: existing lines, existing looks).
7. Gate: `scripts/test.sh` before the commit, `scripts/test.sh all` once. No live run: the broadcast runs inside
   the installed AiTerm.

## To-dos

- [ ] Tests 1–4 written and failing for the snag's reason
- [ ] run_status reads thread counts from the host, `threadsNote` (test 1)
- [ ] Oracle hold for the watch's Oracle refusal; holds on the card, requests, run_status (test 2)
- [ ] A `restart: false` run that goes through clears a failure's problem (tests 3, 3b)
- [ ] `currentPublicationProblem` read by the card, the requests and run_status (test 4)
- [ ] docs/operators.md; snapshots read; gate green; `scripts/test.sh all` green
