# finish_task answers what is true, before the daemon gives up

Plan C of the Operator snags (`2026-11-04-operator-snags.md`, area C). Branch
`fix/c-finish-task-is-unreliable-and-its-answers-are`.

## Goal

Four snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- finish_task answered "AiTerm isn't answering" while its push and request still happened: T2 (pushed
  ddccfbb, opened !69), T7 (9bbc39e landed on !68), T8 (befb82c landed only on the third call).
- T7's retried fix-round push was judged as a merge, and the Oracle refused it for lacking approval.
- !71, which the person had merged on GitLab as 988ed6c, was treated as a new merge (the Oracle asked,
  then refused) until the Operator ran `git fetch`.

Rule: finish_task never answers "AiTerm isn't answering" while its work goes on. It answers what is
done and that the rest is still running, a later call joins the run or answers from the record, a
fix-round push is never judged as a merge, and a merge decision reads origin as it is now.

## Cause

The daemon waits `OPERATOR_REQUEST_TIMEOUT` (30 s, `daemon/aitermd/delivery.py`) for the app's answer
to a forwarded tool call, then tells the Operator `AiTerm isn't answering`. The app's `finish_task`
(`OperatorToolHandler.perform` → `OperatorController` bridge → `TaskFinisher.finish`) awaits the whole
publication: a push with a pre-push hook plus opening a request takes longer. The run goes on and
lands; the Operator only learns that the app didn't answer.

The retry is what turns T7 into a merge. A fix round is: task `inReview`, mark_task accepted again
(state `accepted`, review not ended), finish_task pushes the new commit and puts the task back in
`inReview`. A call while that push runs joins it (`TaskFinisher.run`) and is not challenged
(`mergeAwaitingOracle` skips an accepted task going into review). But once the run ended, the task is
`inReview`, and a finish_task on an `inReview` task means "end the review": for a merge end the
challenge gate asks the Oracle about a merge (`mergeAwaitingOracle`, `case .inReview`). The retry
that only meant to learn what the first call did was judged as a merge.

!71: whether the accepted commit is already merged is read from the local default branch and
`origin/<default>` as last fetched (`TaskFinisher.landing`, `Repository.landing`). Nothing fetches
before the challenge gate's `landed()` or the finisher's `finishLanded`, so a merge made on the host
looks new.

## Approach

- **A reply budget for finish_task.** The handler takes the moment the request arrived and answers
  within `OperatorTiming.finishReplyBudget` (24 s, inside the daemon's 30 s) of it. The Oracle's wait
  inside a finish_task is capped by the same deadline. `TaskFinisher.finish` starts the run (or joins
  the one in flight) and waits for it until the deadline; past it, the run goes on and the call
  answers the new result word **`running`**, with `pushedSHA`, `mergeRequest`, `merged` as recorded at
  that moment, and a reason saying what is done, that the rest still runs, and that AiTerm wakes the
  Operator when it ends. The merge watch's own polls are not budgeted, as now.
- **The run that outlived its call is answered later.** A call that answers `running` saves on the
  task's publication that an answer is owed for the accepted commit (`TaskPublication.unanswered`, an
  optional field: `state.json` loads unchanged). When that run ends and no call is waiting on it, the
  finisher keeps its result in memory, with the accepted commit it ran on, and wakes the Operator:
  `[AiTerm] <task>'s finish_task ended: call run_status`. The next finish_task of that task answers
  that kept result (the reason says it is the earlier call's) and clears it and the marker. A run
  joined by a call still waiting is answered to that call, which clears the marker; nothing is kept.
  A marker or kept result for another accepted commit is dropped. Only the end of the run whose call
  answered `running` is kept and wakes the Operator; a merge watch's later polls keep that answer up
  to date with their own result and wake nobody, and the next call has it first, even while a poll is
  in flight.
- **After a restart, the marker still holds.** The run in flight died with the app; its steps are
  saved. With the marker set and nothing kept: a task in `inReview` answers `inReview` from the record
  (the fix-round push landed before the quit; a call now must not end the review), and anything else
  clears the marker and resumes from the saved steps, which repeats nothing.
- **A call that joins or answers the record is never judged.** At the start of the challenge gate, a
  finish_task of a task with a run in flight, a kept result, or a marker for its accepted commit on a
  task in review (the only marker the record answers) skips the Oracle and the fetch: it decides nothing new. It is passed on join-only, so if nothing is
  pending by the time the finisher has it, the finisher refuses it ("call finish_task again") instead
  of starting a run the gate never judged. This is the T7 fix: the retry answers `inReview`.
- **Challenge replay.** A challenged finish_task whose acting call answered `running` has that answer
  saved as the challenge's result (`recordActed`). Replayed with its `challengeId`, it is not answered
  from that saved `running`: it goes to the finisher join-only, which joins the run, answers what it
  kept or the marker's record, or refuses with "nothing is running: call finish_task again without
  challengeId" (the Oracle's yes stays recorded on the task, so that call is not asked again).
- **Fetch before a merge decision.** A new `TaskFinisher.landingFetched` fetches origin's default
  branch (`Repository.fetchFromOrigin`, bounded by `OperatorTiming.landedFetchTimeout`, 8 s) and then
  reads `landing` as before; a project without origin reads only the local branch. It answers landed,
  not landed, or "couldn't tell" with git's reason. The challenge gate uses it before asking the Oracle
  about a merge; the finisher uses it on the Operator's own calls, before it ends a review or decides
  anything (`finishLanded` reads its result) (a watch poll reads
  the host, which says whether the request merged, and keeps the local read). A failed fetch is never
  read as "not merged": the gate refuses the call, and the finisher answers `failed`, each saying
  AiTerm couldn't fetch `<branch>` from origin and why, that nothing was done, and to call again. No
  problem is recorded for it, so a merge watch isn't stopped by one failed fetch.
- **Frozen contracts.** `finish_task`'s served description changes on purpose (the `running` word,
  the reply budget, the fetch), so `daemon/tests/fixtures/operator-current-tools.json` is edited by
  hand for that entry only, with this plan and the snag log as decision and evidence (docs/testing.md).
  Its input schema doesn't change. Briefs, `contract.json` and `state.json` stay untouched;
  `TaskFinisher.Result` keeps its fields and gains one `Kind`.

### Decided without the person

- The budget is 24 s from the request's arrival, a constant with the other Operator timings, and a
  port (`OperatorPorts.finishReplyBudget`) so tests can shorten it. The Oracle's 20 s budget stays,
  capped by that deadline only in finish_task, so a slow fetch plus a slow Oracle still answer in time.
- The exact kept result lives in memory; only the marker that an answer is owed is saved. After a
  restart the answer is rebuilt from the record only where repeating would change meaning (`inReview`);
  everywhere else resuming from the saved steps answers what is true and repeats nothing.
- A failed fetch refuses the merge decision rather than going on without it: origin that can't be
  fetched can't be pushed to either, and a refusal that says why costs one more call.
- The wake reason names the task and says the finish_task ended; the answer itself comes from
  finish_task, its state from run_status.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/OperatorTiming.swift` | modify | `finishReplyBudget` (24 s), `landedFetchTimeout` (8 s) |
| `app/Sources/AiTerm/Operators/TaskFinisher.swift` | modify | `Result.Kind.running`; `finish` with a budget and join-only; listeners, kept results, `finishedLate` callback; `landingFetched`; `finishLanded` fetches on the Operator's calls |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | the request's deadline; the `finish` closure takes one `FinishCall` (noVerify, content, budget, joinOnly); a `pendingFinish` closure |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Challenge.swift` | modify | pending finish skips the gate (join-only); an acted finish_task challenge whose answer was `running` replays join-only; `landed()` fetches and refuses when it can't tell; Oracle wait capped by the deadline |
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `TaskPublication.unanswered` (optional accepted SHA) |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | bridge passes the call; `pendingFinish`; `finishedLate` wakes the Operator and marks the run changed |
| `app/Sources/AiTerm/Operators/OperatorController.swift` (`OperatorPorts`) | modify | `finishReplyBudget` port |
| `daemon/aitermd/operator_mcp.py` | modify | finish_task's description: `running`, the budget, the fetch |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | that description, and nothing else |
| `docs/operators.md` | modify | one paragraph on finish_task's budget, `running`, and the fetch |
| `app/Tests/AiTermTests/Operators/OperatorFinishReplyTests.swift` | create | the snags' tests below |

## Proof

Tests first; each fails before its fix. Fixtures: a real repository with a bare origin
(`GitFixture.withOrigin`), the fake host, the reply budget shortened to a fraction of a second, and a
latch (a pre-push hook waiting on a file, or the fake host's `beforeCreate`) holding the publication
past the budget, as T2, T7 and T8's hooks and requests did.

1. **Cause (T2).** A draft-MR end whose request creation is held past the budget: finish_task answers
   before the latch opens, `result: running`, `pushedSHA` the accepted commit, no `mergeRequest` yet.
   Today the call doesn't answer until the latch opens (the test bounds its wait and fails). After the
   latch opens: one wake line `… finish_task ended: call run_status`, and the next finish_task answers
   `published` with the request, the host asked to create it once.
2. **T8.** While the push is held, a second and a third finish_task answer `running` too, and git and
   the host see one push and one create.
3. **T7.** A merge end in review with the Review and Merge slices and the Oracle on, accepted again for
   a fix round on !68: its push held past the budget, the call answers `running`; the run ends
   `inReview`; the retry answers `inReview` from the kept result; the Oracle was never asked, nothing
   merged. A later deliberate finish_task (nothing kept) still ends the review and is judged.
3b. **T7 across a restart.** The same, with a new controller over the saved workspace after the run
   ended and before the retry: the retry answers `inReview`, the Oracle is not asked.
3c. **Challenge replay.** A merge end with the Oracle on, its yes pending past the reply budget, then
   acted on with its `challengeId` while the push is held: that call answers `running`. The same
   call again joins the run (and after it ended, answers its kept result), never the saved `running`.
4. **!71.** A merge end with the Oracle on whose accepted commit origin's `main` already holds (moved
   in the bare origin, `origin/main` here stale): finish_task records it merged, says it is in `main`
   on origin, asks no Oracle, pushes nothing. Today the Oracle is asked.
5. **Failed fetch.** Origin unreachable: with the Oracle on the call is refused saying AiTerm couldn't
   fetch `main`; with it off finish_task answers `failed` with that reason; neither pushes nor asks the
   Oracle nor records a problem.
6. Daemon: `test_operator_mcp.py` against the hand-edited golden.
7. Existing suites (`TaskFinisherTests`, `OperatorMergeTests`, `OperatorReviewTests`,
   `OperatorChallengeTests`) stay green: the finisher without a budget behaves as now.
8. Gate: `scripts/test.sh` before the commit, `scripts/test.sh all` once. No live run: the broadcast
   runs inside the installed AiTerm.

## To-dos

- [x] Tests 1–5 written and failing for the snag's reason
- [x] Reply budget, `running`, kept result and late wake (tests 1, 2)
- [x] Pending finish skips the gate, join-only (test 3)
- [x] Fetch before a merge decision, failed fetch said (tests 4, 5)
- [x] finish_task description, golden entry by hand, docs/operators.md (test 6)
- [x] Gate green, `scripts/test.sh all` green
