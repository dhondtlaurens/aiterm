# Fix the FE Sprint 84 broadcast snags

## Goal

Three snags from broadcast "FE Sprint 84" (task fe-1801, AiTerm 0.44.0):

1. A review tab whose turn ended on 2026-11-09 read live `working` the next morning, so the task was never
   ready for acceptance and no wake came when the newest review tab ended its turn.
2. After `finish_task` pushed a fix commit and answered `inReview`, the task read `accepted` with the hold
   "the Oracle's yes doesn't cover its evidence now", and AiTerm said its merge watch stopped, while the
   request still waited on its reviewer.
3. The same stale `working` tab held the completed broadcast's cleanup at `closingWait: agentTurn`.

AiTerm should say what was true: the tab idle, the task in people review, cleanup free to go on. Also, by
the person's choice, a worker tab other than the first that really hangs at work is flagged as it is for
the first worker.

## Approach

**Stale working (snags 1 and 3, one cause).** The daemon learns a tab's conversation only from hooks placed
on it by evidence. AiTerm restarted at 00:13 on 2026-11-10, so the new daemon knew review-3 (idle since
15:13 the day before, its Stop delivered) only from its session file, with no conversation. When the
Operator opened `fe-1801-fix-nathan` (08:16) and `fe-1801-review-4` (08:22) in the same worktree, each new
Claude's first hooks arrived before the tick had classified its tab. Its pid matched no tab, so
`SessionResolver._by_cwd` placed the post on the most recent Claude tab in that worktree that runs no other
conversation: review-3. `UserPromptSubmit` set it working; the later `Stop` was placed by pid on the new
tab's own row. review-3's session file, older than that hook, can no longer correct it
(`StatusEngine._apply_state`'s freshness rule). Its transcript ends with `end_turn`, the Stop hook's 200 and
`turn_duration` at 15:13:11; no headless Claude ran in that worktree afterwards.

The fix: each tick, a Claude tab whose own session file is read by its pid takes that file's `sessionId` as
its conversation while it has none. The existing rule (`_may_run`: a post placed by inference goes only to a
tab running no other conversation, or this one) then keeps a sibling's post off it; the post waits for the
tick (`HookRouter._tick_for_unplaced`) and lands on its own tab. A conversation a hook set is never replaced
by the file, so a `/clear` whose file is not rewritten yet cannot flip the tab back.

**Review ended by a merge watch (snag 2).** From the run's activity log: fe-1801 was `inReview` at 0b1ce73
(the Oracle's refusal on 11-09 was the challenge gate's, before `TaskFinisher` ran, so the review never
ended). `mark_task` accepted a1b0323 at 08:35:05; `UpstreamReplacement.reaccept` set it `accepted`, and
`OperatorController.runChanged` → `TaskFinisher.resumeWatching` armed a merge watch (`isWatchable`: merge end,
accepted, request open, no problem). `finish_task` at 08:35:18 pushed a1b0323 and, the review not ended, put
the task back `inReview`. The watch's poll then ran `publish`, whose `state == .inReview` branch calls
`endReview` for any caller: the review ended, the task went `accepted`, the merge hit
`PublicationGuard.oracleRefusal`, and the watch recorded `oracleYesNeeded` and stopped.

The fix, in two places: `isWatchable` refuses a task whose next publication enters people review
(`TaskPublisher.Context.entersReview`), and a watch's poll never ends a review: `publish` takes the
`endReview` branch only for the Operator's call, and a poll that finds the task in review changes nothing and
ends the watch without a wake (the review watcher wakes the Operator on the review's news).

**Quiet extra tabs (the person's choice).** `WorkerQuietWatch` already reads every working tab's transcript
and feeds signs to `StallWatch`, but its quiet set judges only each task's first worker. It will judge each
tab on its own clock: a quiet working extra tab reads `working?` on its `run_status` tab line and lists its
task under `uncertain`, in any task state but taken over or not started, as the first worker does now.
Closing still waits on a `working?` tab (`TaskRemover.turnInFlight` reads the session state): AiTerm never
closes a window under a turn it only doubts.

## Files

- **modify** `daemon/aitermd/service.py` (`_corroborate`): pass the read file's `sessionId` as the tab's
  conversation while the tab has none.
- **modify** `daemon/aitermd/status.py` (`apply_metadata` or a small sibling): fill a conversation only when
  none is known, keeping its existing reset of display work when the conversation changes.
- **modify** `app/Sources/AiTerm/Operators/TaskFinisher.swift`: `isWatchable` excludes `entersReview`;
  `publish` ends a review only on `operatorCall`; the watch loop ends quietly on an in-review answer.
- **modify** `app/Sources/AiTerm/Operators/WorkerQuietWatch.swift`: the quiet set per tab (first worker and
  each extra tab), each on its own working-since and transcript clock.
- **modify** `app/Sources/AiTerm/Operators/OperatorController.swift`: `liveFacts` and `status(of:…)` take the
  quiet set per tab (task and tab key, nil for the first worker) and set an extra tab's quiet flag; the
  `tools.quietTasks` wiring and the waker's own status build pass the same set.
- **modify** `app/Sources/AiTerm/Operators/OperatorToolHandler.swift`: `quietTasks` returns the per-tab set,
  which `currentStatus` hands on, so `run_status` can tell a quiet extra tab from a busy first worker.
- **modify** `app/Sources/AiTermCore/Operators/RunStatus.swift`: `TaskLiveFacts.Tab.quiet`, the tab line's
  `LiveState(status, quiet:)`, and `uncertain` including a quiet working tab.
- **modify** `docs/status-model.md`: the conversation also comes from Claude's session file; why a sibling's
  early post no longer lands on a tab adopted after a restart.
- **modify** `docs/operators.md`: a merge watch never ends a review and doesn't watch a task re-accepted while
  its review goes on; extra tabs read `working?` and make their task uncertain.

## Proof

- Daemon, `daemon/tests/test_service.py`: the restart reproduced through the fake iTerm2. An idle Claude tab
  known only by its session file (conversation A, no hooks); a new tab in the same worktree, still a shell,
  posts `UserPromptSubmit` then `Stop` for conversation B. Before the fix the idle tab goes working and
  stays; after it, it stays idle and B's posts land on the new tab once ticked. Also: a conversation a hook
  set is not replaced by an older file's. The existing `_may_run` tests in `test_hook_router.py` keep passing.
- Swift, `TaskFinisherTests`: an in-review task accepted again on a new commit is not watched after
  `resumeWatching`; the Operator's `finish_task` then leaves it `inReview` with no problem; a poll reaching a
  task in review leaves its state, `peopleReview.ended` and problem as they were, and wakes nobody.
- Swift, `WorkerQuietTests` and a RunStatus test: a working extra tab whose transcript went quiet gives
  `working?` on its line and the task under `uncertain`; a busy first worker doesn't hide it, and a quiet
  first worker still reads as before. One test goes through the tool handler's `run_status` path
  (`quietTasks` → `currentStatus`), not only `RunStatus.build`.
- `scripts/test.sh` before each commit; `scripts/test.sh all` once before merging. A live run through
  `scripts/run-dev.sh` only on the maintainer's go.

## To-dos

- [ ] Daemon: a Claude tab's conversation from its session file while it has none, with the restart test
- [ ] TaskFinisher: no merge watch for a task re-entering review, and no review ended by a poll, with tests
- [ ] WorkerQuietWatch per tab, through `liveFacts` and RunStatus, with tests
- [ ] Docs: status-model.md, operators.md
- [ ] Full gate (`scripts/test.sh all`)
