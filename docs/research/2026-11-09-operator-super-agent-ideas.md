# Three super-agent ideas for the Operator

## Question

Would any of three ideas from DeepSeek's super-agent design noticeably improve the Operator, and is
it worth what it costs?

1. **A "done means" list per task**: acceptance checks set at `create_task`, used by the worker, the
   review tab and the Oracle (the AI LABS video's `eval.md`).
2. **Answers straight to the worker**: the person's answer to a relayed worker question is typed
   into the worker, and the Operator is told afterwards (DeepSeek routes a thread's follow-ups to
   its worker directly).
3. **A loop detector**: a watchdog for a worker that is busy but making no progress, such as the
   same failing command or a long stretch without a commit.

The answer decides whether any of them gets a plan. Laurens confirmed the scope on 9 November 2026:
for each idea, check what the Operator already does, how often the gap shows up in real broadcasts,
and what it would cost, then give go or no-go. Code, docs and saved broadcast history are the
evidence; no prototype.

Sources for the ideas: the AI LABS video "Deepseek Just Released The Greatest Claude Code Workflow
Ever" (5 November 2026) and DeepSeek's research prototype
[deepseek-ai/dsh-superagent-prototype](https://github.com/deepseek-ai/dsh-superagent-prototype)
(MIT, created 31 October 2026; its README calls it "not an official DeepSeek product").

## Recommendation

None of the three, as proposed. The broadcasts show the Operator already does what idea 1 asks,
already does the useful part of idea 2, and has no recorded case of the behaviour idea 3 would
catch. Two small fixes came out of the research and are worth planning:

- **A. Give the task's brief to the review tab and to the Oracle's acceptance critique.** Right now
  neither one sees it. This is the useful part of idea 1, with no new field.
- **B. Stop counting time spent queued for the test lock toward the 90-minute no-commit cap.** All
  ten or more runtime-cap blocks found were false, and some of them came from this.

**Planning decision, 9 November 2026.** A is planned in
`docs/plans/2026-11-09-review-sees-the-task-brief.md`. Laurens dropped B. Its signal (`tests queued`)
comes only from AiTerm's own `scripts/test.sh`, through `daemon/aitermd/test_activity.py`, so it
would help only broadcasts on AiTerm itself, and the Operator should stay project-agnostic.

## What was tried

1. Read DeepSeek's prototype README and its `docs/000-philosophy.md` and `docs/003-execution.md`,
   along with the video's transcript and comments.
2. Searched for prior work: `docs/research/`, `docs/plans/`, `git log --grep` for stall, relay and
   acceptance. Nothing had covered these ideas. The questions-for-the-person plan neither weighs
   nor rejects direct delivery.
3. Mined the 13 saved Operator session transcripts (20 October to 4 November 2026,
   `~/.claude/projects/-Users-laurensdhondt-Library-Application-Support-AiTerm-operators-runs-*`):
   3,498 tool calls and 75 `create_task` briefs, plus 59 Claude worker sessions and 110 Codex
   worktree sessions. Three subagents did this, one per idea, read-only. Their throwaway scripts
   are in the session scratchpad, not the repository.
4. Re-checked the code claims the recommendation rests on: `TabOpener.swift`, `ChallengeLaunch.swift`,
   `RunStatus.swift`, `RunReconciler.swift` and `OperatedTransitions.swift`.

## Evidence

### 1. A "done means" list per task

**Coverage.** `create_task` has only `brief` (`daemon/aitermd/operator_mcp.py:315`). In practice the
Operator writes a bar into it. Of the 75 real briefs (median length 3.5k characters):

- 75 say what the worker's final message must contain (the checks' output and the commit SHA);
- 74 name test or gate commands;
- 34 name the tests to add;
- 11 have an explicit done or acceptance section.

The merge Oracle already sees the brief (`ChallengeLaunch.mergePrompt`,
`app/Sources/AiTermCore/Operators/ChallengeLaunch.swift:158-165`).

**Two places the brief doesn't reach**, both verified in the code:

- The review tab's first prompt is the shared review prompt plus the Operator's brief for that tab,
  `tab.brief` (`app/Sources/AiTerm/Operators/TabOpener.swift:82` and `:165`), not the task's brief.
  The Operator made up for this in 59 of 73 review briefs by restating the task's scope.
- The Oracle's critique of `mark_task accepted` gets the call's arguments and `run_status`
  (`ChallengeLaunch.prompt`, `:19`, called from `OperatorToolHandler+Challenge.swift:208`).
  `run_status` carries no task briefs (`RunStatus.swift`).

**How often the bar was missing.** 65 tasks were accepted and the Oracle critiqued an acceptance 201
times. The Operator went back to the worker 12 times, about 5 of them over proof or requirement
gaps, for example:

- 874EB7D2, 30 October 01:46, t8: "Accepting leaves a stated requirement incomplete".
- ABAA3E4F, 4 November 08:59, T6: "only a successful delayed refresh is demonstrated".

In each case the bar was already written, in the brief or in the person's prompt; what was missing
was evidence. About 27 merge refusals were again about evidence against a bar that was already
stated. Only one was a real disagreement over what "done" meant (874EB7D2, 30 October 03:08), and
the Oracle caught it because it anchors on the person's words. Two more applied the old setup v1's
broadcast-wide "Done" to a single task (E6F39529, 38407F31); setup v2 removed that. The person never
stepped in because a task wasn't done.

**Cost of a real field: medium.** About 12–15 files: the tool schemas and
`operator-current-tools.json`, the persisted `OperatedTask`, the brief goldens plus a live eval
(per `docs/testing.md`), the review, critique and merge prompts, the board card and its snapshots,
and the docs. There is also a risk: a list the Operator writes and edits lets it lower its own bar,
where today the Oracle measures against the person's words.

### 2. Answers straight to the worker

**Coverage.** A board answer only records `answeredHere` and wakes the Operator
(`OperatorController+Controls.swift:100-126`). The other way round already works: an answer typed in
the worker's window is recorded as `answeredInWindow` (commit 94e74249).

**How often, and how it went.** `relay_question` hadn't merged yet in any of these transcripts. On
the older path (the worker raises a point, the Operator asks with `ask_you`, then forwards with
`message_task`) there were about 26 answers across 5 broadcasts.

- **The Operator's hop is short.** The median from the person's answer to the forward was about
  10–15 s, and only 3 took longer, the longest 4m17s (1EBD91B1, 28 October 05:55). In that case the
  worker refused the message anyway ("a menu prompt is open"), and a direct delivery would have hit
  the same refusal.
- **The person's own answer time dominates**: minutes, sometimes overnight.
- **Almost no forward was verbatim, and the rewording helped.** The Operator:
  - expanded short answers: "c" became "don't pin it. Leave all seven include blocks unchanged…";
  - sent one answer to several workers;
  - bundled it with steering such as a rebase or test limits;
  - read a counter-question as a scope decision (ABAA3E4F, 3 November).
- **The opposite failure has happened twice: the Operator didn't know about an answer.** In
  88EDD20C (22 October) it asked again three times over about 25 minutes, until the person said they had
  already answered in the worker's window.

**Risks.**

- A raw answer reaches only one worker and loses the Operator's context.
- Typing during a Pause would restart a worker that was told to stop; `answer()` has no paused
  check.
- A worker that has moved on, or one the person took over, needs its own checks.
- The load saved is about one `message_task` per answer, nowhere near DeepSeek's ~30%.

**Cost.** The plumbing exists: AiTerm already types its own pause and carry-on notes
(`OperatorController+Controls.swift:241-305`). About one slice.

### 3. A loop detector

**Coverage.** Every check AiTerm has today times silence or elapsed time:

- **possibly stalled** after 20 minutes without any sign of life (`OperatorTiming.swift:19`,
  `StallWatch.swift:92`);
- **`working?`** after 2 minutes of transcript silence;
- **runtime caps**: blocked after 90 working minutes without a new commit, or 4 hours in total
  (`OperatedTransitions.swift:201-212`);
- **`nothing has moved for ten minutes`** for the whole broadcast (`OperatorWatchdog.swift:52-65`);
- **dependency cycles**, refused by `submit_plan` (`PlanRevision.swift:110`).

Nothing looks for repetition.

**How often workers looped.**

- **No identical failing command ran twice in any Claude worker; the most in Codex was 3.**
- **High repeat counts were waiting, not looping.** P1 (1EBD91B1) ran `tail` on its log 89 times
  in 74 minutes while queued for the test lock. A repeat detector would have fired on exactly that.
- **One real self-made wait (P7, 28 October).** The existing stall flag caught it at 00:37. The
  Operator misread it and acted at 00:56.
- **31 stall wakes, nearly all false**: usage limits, the test-lock queue, subagents, long suites.
- **At least 10 runtime-cap blocks across 4 broadcasts, all false.** In 1EBD91B1 the Operator ran
  its own 10-minute watchdog overnight and found missed wakes, a Codex menu and a test run starved
  behind the lock, but no loops.

**Test-lock time counts toward the cap (verified).** `RunReconciler.swift:174-178` adds runtime on
every tick while a worker reads `working`, with no exception for a worker queued behind the test
lock. `StallWatch` already counts a queued test run as a sign of life (b2ede3db); the runtime cap
does not.

## Open points

- **Idea 2 has no data for `relay_question` itself**, since every transcript predates it. A relayed
  question is in the worker's own words, so a raw answer might carry more of its meaning on its own.
  To settle it: after a few broadcasts on 0.39+, compare each `answeredHere` with the next
  `message_task` to that task. If those forwards are near-verbatim and slow, revisit an opt-in
  "Send to its worker too" for answers that pick one of the worker's own choices.
- **Idea 1:** whether an upfront list would have prevented the 5 premature acceptances is inferred,
  not observed. Revisit only if future snags show an acceptance whose bar was never written down.
  An optional, cheaper step: one clause in the Operator brief's rule 2, "end a brief with the checks
  that prove it done". It changes the brief goldens, so it needs the live eval.
- **Idea 3:** commits were detected by matching `git commit` in commands, so commits made by
  subagents or scripts were missed. PI workers weren't scanned, and 13 broadcasts is a small sample.
  Revisit if a real loop turns up as a snag. A passive repeat count in `read_task`, with no wake, is
  the cheap first step.
- **Fix B: how much of the false blocks it removes is unmeasured.** Two of the 10 or more came from
  the test-lock queue; the others came from commits to the wrong branch and from long reviews.
