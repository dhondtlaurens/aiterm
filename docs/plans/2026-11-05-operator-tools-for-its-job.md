# The Operator has the tools its job needs: steer an open request, retry a pipeline, handle a thread

Plan G of the Operator snags (`2026-11-04-operator-snags.md`, area G). Branch
`feat/g-the-operator-lacks-tools-for-its-job`, built on the local main with B, C, A, D and E merged (41efd727).

## Goal

Three snags from broadcast "Aikido findings 2026-11" (AiTerm 0.39.0):

- **Steering an accepted task whose request is still open.** T1 was accepted, its merge end waiting on !65, which
  needed origin/main merged in. message_task answered "T1 is accepted and its commit is on origin: there is no worker
  to steer", and open_tab refused too. T3 earlier needed a separate check-only task.
- **Retrying a pipeline that failed on the environment.** Six request pipelines failed on runner network timeouts and
  image pulls. The shell gate refuses `POST …/pipelines/<id>/retry`, and no tool does it.
- **Review threads.** The broadcast's rule: a scanner's thread gets the Oracle's critique before any fix or pushback,
  then is resolved after a one-line reply. No tool asks the Oracle for a critique on demand, and no tool resolves a
  thread (!64).

Rule: what is the Operator's job has a tool, so it never needs a shell workaround or a throwaway task.

## Approach

Each new tool is built on B's host-edit path: the task's own recorded request (`publication.mergeRequestNumber`), its
host through `reviewHost(of:request:)` (refused when origin now resolves to another repository), and `writeCheck` read
fresh right before each write (no Pause, no End, no takeover, same ownership, same request), passed to the host as
`beforeWrite`.

### 1. message_task and open_tab steer an accepted task whose request is open

- `OperatedTransitions.isReopenable` gains one case: an `accepted` task whose accepted commit is pushed is reopenable
  while its request is recorded and not merged (no `merged`, no `mergedSHA`, not left for you). A pushed task with no
  request recorded, a `published` one and a merged one stay refused as now. The reopen itself is unchanged: back to
  `working`, the worker kept, `reopenedFrom` the accepted commit and the acceptance cleared. Accepting the same commit
  again (`mark_task accepted` on `reopenedFrom`) restores it; once the branch moves, accepting the new commit goes
  through `reacceptReopened`, which replaces what its dependents built on, exactly as for an unpushed reopen, and
  `changedAfterAcceptance` keeps catching a branch that moved while it was still accepted. The publication record is left
  as it is: the next `finish_task` pushes the new commit to the same request (the path an upstream replacement already
  takes) and, being the Operator's own call, restarts the merge wait and clears the old problem.
- **The request must really be open.** Before it delivers to such a task, message_task (and open_tab before it opens a
  tab) reads the host: the open request from the task's branch (`existingRequest(from:)`) must be the recorded number.
  None, or another one, is refused ("!65 is no longer open on the host: AiTerm steers a task only while its request is
  open"). A host that can't be read in `ports.hostTimeout` refuses with why: nothing is steered on a guess. Only this new
  case reads the host; the other states steer as now.
- **No publication while it is steered.** A task whose publication is in flight (`publishing`) is refused ("finish_task
  is publishing T1 now: call again once it answers"). Otherwise, in the same main-actor step as that check and before
  anything is awaited, an accepted task is put on hold in the finisher (`TaskFinisher.hold`): its merge watch stops, no
  watch starts for it, and a finish_task or a watch's poll of it refuses ("T1 is being steered now") until the hold is
  released. The hold is released when the call ends, whatever way: a task reopened is working and no longer watchable, so
  nothing is watched again; one left accepted (its message not delivered, its tab failed) is watched again as before. A
  merge can then never race the worker's new commits, also not during the delivery's await. The finisher's recheck before
  a merge (`PublicationGuard.recheck`, which needs the task `accepted` on the same commit) stays the last guard.
- **open_tab** uses the same rule as message_task (`working`, `inReview`, or reopenable): a tab added to an accepted task
  reopens it once the tab is asked for (its outcome not failed). A first-key reopen after a lost answer finds the task
  working already and answers the same. The served descriptions of both tools say so.

### 2. retry_pipeline

- New tool `retry_pipeline(task)`. It reruns the failed pipeline of the task's own open request. It changes no code, so it
  needs no slice and the Oracle isn't asked.
- New host call `retryPipeline(_ number:, beforeWrite:) -> PipelineRetry` on `MergeRequestPublishing`, each host reading
  the request and its pipeline, then writing only when it failed:
  - **GitLab:** reads the merge request with its `head_pipeline` (id, status). Failed: `POST
    /projects/:id/pipelines/:pipeline/retry`, which reruns its failed jobs. Any other status: `.notFailed(status)`.
  - **GitHub:** reads the pull request's head, then the Actions workflow runs for that head
    (`GET /repos/:repo/actions/runs?head_sha=…`), the latest run of each workflow. Each one that failed
    (`failure`, `timed_out`, `startup_failure`): `POST /repos/:repo/actions/runs/:id/rerun-failed-jobs`, `beforeWrite`
    before each. None failed: `.notFailed`. A failed check from another app than Actions can't be rerun through the
    API, and is said so.
- Refused (all before anything is written): a takeover, a Pause or an End (the fresh `writeCheck` without the Review
  condition, as update_request), a task with no request, a merged one, origin moved to another repository, a request on
  the host that is not open, whose source branch is not the task's branch or that comes from a fork ("isn't this task's
  request"), and a pipeline that didn't fail ("!69's pipeline is running, not failed: nothing to retry"). A second call
  while the first is writing is refused; a repeat after a retry finds the pipeline running and says so, so no key is
  needed.
- The shell gate keeps refusing API writes; `ShellGate.apiDenial` now names retry_pipeline for a failed pipeline, and
  resolve_thread and reply_thread for threads, beside update_request and finish_task.

### 3. Threads: resolve_thread and critique_thread

- **resolve_thread(task, thread)**, its own tool rather than a `resolve` option on reply_thread. Why: resolving is
  safe to repeat on its own (a resolved thread is left as it is), so it needs no key and no pending mark, while a reply
  that may have landed does; folded into reply_thread, a reply whose answer was lost would leave the resolve undone with
  no way to redo it under the same key. It also resolves a thread that a commit answered, with no reply. Under the Review
  slice, refused like reply_thread (no slice, no request, takeover, Pause, End, another repository, a thread not on this
  task's request). Host calls: GitLab `PUT …/merge_requests/:iid/discussions/:id` with `resolved=true`; GitHub's
  `resolveReviewThread` mutation. A thread the host shows resolved already is answered `resolved: false`, with nothing
  written.
- **critique_thread(task, thread)** asks the Oracle for a critique of one thread on demand: whether the reviewer's point
  is right for this change, and whether the worker should fix it or the Operator push back. It writes nothing to the
  host, so it needs no slice; it needs the Oracle on, and is refused after a takeover, a Pause or an End. The prompt
  carries the thread's last note fenced as data, with the task's key, brief, branch, worktree and accepted commit; the
  Oracle reads the code itself, read-only, as for any challenge.
  - **Recorded** on the task as `threadCritiques` (thread id, the signature of the note it critiqued as
    `ReviewWatcher.signature` makes it, the commit the task's worktree was on when the Oracle read it, the critique,
    when), saved before it is answered, and shown by `read_task` with what: review next to its thread, with the commit
    it judged. The same thread with the same last note on the same commit answers from the record and runs no Oracle; a
    new note, or a branch that moved since (the worker fixed it, or changed the code it was about), gets a new critique.
  - **Pending:** it waits `ports.challengeReplyBudget` as a challenge does; an Oracle not back by then answers
    `pending`, and the next call for that thread waits for the same run. A run lost with AiTerm's restart starts again.
    An Oracle that fails answers why and records nothing.
- **reply_thread stays unchallenged**: it is not in `isChallenged`, and a test pins that with the Oracle on.

### Frozen contract

The served tool schemas change on purpose: three new tools (`resolve_thread` and `critique_thread` after
`reply_thread`, `retry_pipeline` after `update_request`, so 36 schemas) and the descriptions of `message_task` and
`open_tab`. `daemon/tests/fixtures/operator-current-tools.json` is edited by hand for those five entries only, with the
snag log and this plan as the decision and evidence (docs/testing.md); `docs/testing.md`'s count follows. Briefs,
`contract.json` and `state.json` stay untouched: `threadCritiques` is optional and written only when not empty, so the
saved state of every existing broadcast reads and writes as before.

## Decided without the person

- **resolve_thread over a resolve option on reply_thread**, for the reasons above.
- **`published` tasks stay unsteerable.** The decision names an accepted task; a `published` draft is the end the person
  asked for, and steering it would reopen a finished task. Only `accepted` with an open request is added.
- **open_tab follows message_task's rule exactly**, so an accepted task whose commit is not pushed yet also takes a tab
  now (it could already be messaged); one predicate for both tools.
- **The host is read before steering a pushed task, and a host that can't be read refuses.** "Open and not merged" is
  the host's to say (the person merged !71 on GitLab without AiTerm knowing); steering on a guess would put a worker on
  merged work.
- **critique_thread needs no slice**: it only reads the host and asks the Oracle; the Review slice is about writing to
  people's review. It needs the Oracle on.
- **The critique sees the thread's last note**, which is what the host reads give today (GitHub's thread read is
  `comments(last: 1)`); widening every thread read to all notes would change the badge and watcher reads too. For the
  scanner's rule (critique before any fix or pushback) the last note is the finding.
- **GitHub "pipeline" means GitHub Actions workflow runs.** Other apps' checks have no rerun API AiTerm can call for
  them; the refusal says so.
- **The publication record is not touched by a reopen**: the Operator's next finish_task clears an old problem and
  restarts the merge wait, as for any task accepted again.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/OperatedTransitions.swift` | modify | `isReopenable`: a pushed accepted task with its request recorded and not merged |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Tasks.swift` | modify | message_task: host check for the new case, refused while publishing, the publication held while it steers; the refusal wording |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Tabs.swift` | modify | open_tab: the same rule and host check; reopen once the tab is asked for |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | `holdPublication`/`releasePublication`; dispatch the three tools; `mutating`; `WriteInFlight.Kind.pipelineRetry`; running critiques |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | wire the hold to the finisher |
| `app/Sources/AiTerm/Operators/TaskFinisher.swift` | modify | `hold`/`release`: no watch and no publication of a task while it is steered |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Request.swift` | modify | `retryPipeline` handler |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Review.swift` | modify | `resolveThread`, `critiqueThread`; read_task review shows recorded critiques |
| `app/Sources/AiTermCore/Operators/ChallengeLaunch.swift` | modify | `threadPrompt` for the Oracle |
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `ThreadCritique`, `OperatedTask.threadCritiques` (optional, written when not empty) |
| `app/Sources/AiTermCore/Operators/OperatorTool.swift` | modify | `retryPipeline`, `resolveThread`, `critiqueThread` |
| `app/Sources/AiTermCore/Operators/ActivityLine.swift` | modify | the Activity tab's words for the three tools |
| `app/Sources/AiTermCore/Operators/ShellGate+Denials.swift` | modify | `apiDenial` names retry_pipeline, resolve_thread and reply_thread |
| `app/Sources/AiTermCore/Tasks/MergeRequestPublisher.swift` | modify | `retryPipeline`, `resolveThread` on the protocol and both publishers; `PipelineRetry` |
| `app/Sources/AiTermCore/GitLab/GitLabClient.swift` | modify | read the head pipeline's id, retry it; resolve a discussion |
| `app/Sources/AiTermCore/GitHub/GitHubClient.swift` | modify | failed workflow runs of the head and their rerun; `resolveReviewThread` |
| `app/Tests/AiTermTestSupport/FakeMergeHost.swift` | modify | a pipeline status, `retry` and `resolve` logged |
| `daemon/aitermd/operator_mcp.py` | modify | the three tools; message_task and open_tab descriptions |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | the five entries above, and nothing else |
| `docs/operators.md`, `docs/testing.md` | modify | the tools table and the steering, pipeline and thread lines; 36 schemas |

## Proof

Tests first, each failing before its fix, with the snag log's cases as fixtures.

1. `OperatedTransitionsTests`: an accepted task pushed at its accepted commit with !65 recorded is reopenable; without a
   request, merged, left for you or `published`, it isn't.
2. `OperatorTaskToolsTests` (T1, merge end, pushed, !65 open on the fake host): message_task delivers, answers
   `reopened`, the task is working with `reopenedFrom` the accepted commit and the merge watch stopped; accepting a new
   commit then pushes it to !65 through finish_task. Refused when the host has no open request from the branch, when it
   can't be read, and while a publication is in flight. With the delivery held open, a merge watch poll and a
   finish_task of T1 merge nothing; a delivery that is refused leaves T1 accepted and watched again. Today it is refused
   with "there is no worker to steer".
3. `OperatorOpenTabTests`: open_tab on T1 opens the tab and reopens the task; the refused states keep their refusal.
4. `OperatorRequestTests` (retry_pipeline, !69 with a failed pipeline): it retries once and answers what it retried; a
   running pipeline, no request, a merged request, a request not open on the host, another branch's or a fork's request,
   a takeover, Pause and End are each refused with nothing written.
5. `GitLabPublishTests` / `GitHubPublishTests`: the reads and the retry calls (GitLab's pipeline retry; GitHub's
   rerun-failed-jobs for the failed latest run of each workflow, none for a green one); the thread resolve calls.
6. `OperatorReviewTests` (!64): resolve_thread resolves a thread of the task's request under the Review slice, a resolved
   one is left as it is, and it is refused without the slice, for another request's thread and after a takeover, Pause
   or End. critique_thread asks the Oracle once, records the critique, answers the same from the record, asks again on a
   new note and on a branch that moved, answers pending past the budget, is refused with the Oracle off; read_task review shows it. reply_thread
   with the Oracle on posts with no Oracle run.
7. `ShellGateTests`: `glab api -X POST projects/…/pipelines/123/retry` is refused and the refusal names retry_pipeline.
8. Daemon: `test_operator_mcp.py` against the hand-edited golden; `OperatorToolTests` catches the three new cases.
9. Gate: `scripts/test.sh` before the commit, `scripts/test.sh all` once at the end. Nothing is run against the installed
   AiTerm or a live broadcast.

## To-dos

- [ ] Steering T1: `isReopenable`, message_task and open_tab with the host check, the finisher's hold while steering (tests 1–3)
- [ ] retry_pipeline: protocol, GitLab, GitHub, fake host, handler, shell gate wording (tests 4, 5, 7)
- [ ] resolve_thread: protocol, both hosts, handler (tests 5, 6)
- [ ] critique_thread: prompt, record, pending, read_task review (test 6)
- [ ] Served schemas and golden by hand, activity lines, docs (test 8)

## Plan review

Codex, two rounds against 41efd727. Round 1: two Important findings, both fixed in this plan. Steering raced automatic
merging while the delivery or tab opening awaited (now the finisher's hold from the publishing check to the call's end),
and a critique was reused after the code it judged had changed (now keyed by the commit it read too). Round 2: none.
