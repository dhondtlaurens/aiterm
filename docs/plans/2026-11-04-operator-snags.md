# Operator snags from a GitLab broadcast, 2026-11-03/04

The snag log of one broadcast on AiTerm 0.39.0: 19 snags in 7 areas, B through G. Every one ends
with the same rule: **AiTerm must show what was true, so the Operator doesn't have to work around
it.** Task keys (T1–T10) and request numbers (!62–!71) are that broadcast's; use them as fixtures.

Each area gets its own plan in `docs/plans/`, in this order: B, C, A, D, E, G, F. B is done
(`2026-11-04-finish-task-mr-content.md`: finish_task's title, description and assignee, and
`update_request`). G reuses B's host-edit path (`MergeRequestPublishing.updateRequest`, the write
check in `OperatorToolHandler+Review.swift`).

Constraints for every area:

- Keep the frozen Operator contracts (`docs/operators.md`, `docs/architecture.md`). Don't regenerate
  contract goldens to fit a change (`docs/testing.md`); a deliberate change to a served tool schema
  is edited by hand for that entry only, and the plan says why.
- For each fix, first write a test that reproduces the snag, using the case below as the fixture
  where possible.

## C. finish_task is unreliable and its answers are wrong (4 snags)

- It answers "AiTerm isn't answering" while the push and the MR still happen:
  - T2: pushed at ddccfbb and opened !69;
  - T7: 9bbc39e landed on !68;
  - T8: befb82c only landed on the third call.
  run_status answered normally the whole time. So the call times out while the work carries on,
  and a retry has no idea what already happened. Lead: the daemon gives an Operator request
  `OPERATOR_REQUEST_TIMEOUT` (30 s, `daemon/aitermd/delivery.py`), shorter than a push with a
  pre-push hook plus opening a request.
- A retried fix-round push (T7) was judged as a merge, and the Oracle refused it for lacking
  approval. A fix-round push must never be judged as a merge.
- A request the person had already merged on GitLab (!71, merged as 988ed6c) was treated as a new
  merge (the Oracle asked, then refused) until the Operator ran `git fetch`. finish_task should fetch
  origin before it decides.
- Code: `OperatorToolHandler.swift`, `OperatorToolHandler+Tasks.swift`, `daemon/aitermd/operator_mcp.py`,
  `TaskFinisher.swift`.

## A. The Operator wake line doesn't get through (2 snags)

- Case 1: the notice said "AiTerm couldn't type the wake line" (T7 workerAsks, T6/T10
  finishedWithoutCommit). The Operator was in a turn answering the person. The wake should have
  been queued and sent after the turn, not dropped.
- Case 2: the notice said "Text may wait unsent in its input: send it there, or clear it with ^U"
  (T8/T10 finished, T5 reviewQuiet). The Operator was idle between turns with an empty input, so the
  warning was false and the wake should have been typed.
- Each time the person had to tell the Operator; it then called run_status and handled the tasks by hand.
- Code: `AiTermCore/Operators/OperatorWakeNotice.swift`, `AiTerm/Operators/OperatorWaker.swift` and
  the code that types the wake line.

## D. AiTerm shows stale state (3 snags)

- run_status kept unresolvedThreads 2 / resolvedThreads 0 on !63 (and 2 of 3 unresolved on !64)
  after a reviewer resolved them all and approved; GitLab showed 3 of 3 resolved.
- T1's card kept "blocked · The Oracle hasn't s…" after the Oracle had answered (challenge
  7A68F0F0, recorded 08:09). run_status showed no flags and no mergeRefusal.
- T7's card kept "blocked · The pre-push hook r…" while T7 was inReview and working, after a later
  push succeeded (8eb4928 on !68). A label from a failed push must clear once a later push succeeds.
- Rule: the card and run_status come from the current state, so a really blocked task never looks
  the same as a stale label.
- Code: `AiTermCore/Operators/RunStatus.swift`, `TaskFinisher.swift` (the hook-refusal label).

## E. Launching a task fails (2 snags)

- When submit_plan released T3, AiTerm brought the new window to the front with focus. The person
  was typing in another window and the typing broke the launch: no session, no claude process in
  the worktree. New task windows must open behind the person's work without taking focus, as
  open_tab's docs say tabs do.
- After retry_task, the task showed working/opening/uncertain, then "no open worker and no recorded
  conversation identity". The worktree existed at 41fa602, but no worker had started minutes later.
  A retry has to really launch the worker, or say plainly that the launch failed.
- Code: `app/Sources/AiTerm/TaskLauncher.swift`, `RowFocus.swift`.

## G. The Operator lacks tools for things that are its job (3 snags)

- Steering an accepted task whose request is still open. message_task is refused ("T1 is accepted
  and its commit is on origin: there is no worker to steer") and so is open_tab. T1's !65 still
  needed origin/main merged in. T3 earlier needed a separate check-only task.
- Retrying a pipeline that failed on the environment: six request pipelines failed on runner network
  timeouts and image pulls. The shell gate refuses `POST .../pipelines/<id>/retry`, and no tool does it.
- Review threads: the broadcast's rule said a scanner's thread gets the Oracle's critique before any
  fix or pushback, then is resolved after a one-line reply. No tool asks the Oracle for a critique
  on demand, reply_thread is not challenged, and no tool resolves a thread (!64).
- Code: `ShellGate+Denials.swift`, `OperatorTool.swift`, `ReviewWatcher.swift`.

## F. Questions for the person pile up in the Operator chat (3 snags)

- Several ask_you questions were open at once, mixed in with status reports. They scroll out of
  sight and answers got mixed up.
- Questions about a task's scope (T2's access gate, T6's confirmation scope and copy, T7's chat
  reset, T4's token) all went into the chat. ask_you with a task also holds that task (not ready,
  not watched), so the Operator avoids it.
- The Operator has no AskUserQuestion-style dialog. The person didn't experience ask_you's
  "Waiting on you" as a dialog in the chat.
- To decide: should a question be attachable to a task's card without holding the task? Should a
  worker's own question show on its card? How does the person see the list of open questions and
  which one they're answering? It fits the 2026-10-22 decision: Operator questions sit on its row
  as "waiting on you".
- Code: `AiTermCore/Operators/OperatorRequests.swift`, `OperatorModels.swift`, `OperatorTool.swift`.
