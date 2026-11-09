# Operator

A broadcast gives the Operator one brief across selected projects. It plans tasks, starts their
agents, reads their results and finishes accepted work. The sidebar's OPERATOR group contains its
own row and the tasks it drives. Open its board from the heading to see Board, Activity and Summary.

## Set up a broadcast

New Broadcast (⌘B) has five steps:

1. **Broadcast:** optional name, Jira projects and at least one project to work in.
2. **Prompt:** the brief. `/` offers installed skills; `@` offers files for a single selected project.
3. **Agents:** permitted agent/model/reasoning rows for workers and review tabs. It starts with the
   previous broadcast's list. A tool cannot start a combination outside these rows.
4. **Task:** a shared review prompt, end and closing choices. An empty review prompt requires no
   review. Ends are Commit, Draft MR, Merge and Local merge. Merge ends require the Merge slice;
   Draft MR and Merge require a connected code host for each project. An unavailable choice falls
   back to Commit and explains why. Only you change a task's end after creation.
5. **Done:** optional goal and extra rounds (two by default). Both require the Oracle. Without a
   goal the broadcast completes when its tasks do.

Start waits for iTerm2, required agents including Messaging, and code-host checks.

AiTerm records Claude's folder trust for the private Operator run folder it creates, using your
configured Claude profile, so a new broadcast starts without that folder's trust dialog.
If the profile cannot be updated safely, startup reports the error before opening its window.
Workers' project trust questions still wait for you.

Settings › Operator supplies the Operator's own Claude Code model/reasoning, house instructions and defaults.
The broadcast freezes its slices and task settings. Saved Oracle settings govern subsequent checks.
When an unpinned task's agent reaches 80% weekly usage, selection can switch to the first permitted
row for the other agent while that agent remains below the threshold.

## Capabilities and boundaries

| Capability | Behavior |
| --- | --- |
| Base | Plan and queue tasks, steer workers, run review tabs, accept or return work, commit, push a task branch and open a draft request. |
| Jira slice | Create and update tickets within the broadcast's Jira projects. |
| Review slice | Mark requests ready, ask human reviewers and reply to review threads. A task enters people's review only when its review prompt is also written. |
| Merge slice | Merge an accepted commit through its request or locally. Hosted merges require green checks and resolved threads. |
| Oracle | Critique plans/verdicts, judge gated shell commands and veto selected consequential decisions. |

AiTerm enforces slices at the write boundary. The Operator never writes code, deploys, force-pushes,
pushes to a default/protected branch or answers an agent's permission prompt. Work it cannot finish
is recorded under Left for you.

The Oracle's no refuses a vetoed call. If it cannot answer:

| Call | Outcome |
| --- | --- |
| Create beyond the backlog allowance (a quarter of the first plan) | Refused. |
| Finish a merge or bypass a failed push hook with `noVerify` | Proceeds under the remaining publication checks. |
| Check the goal | Recorded as not checked by the Oracle. |

The shell gate runs plain reads inside the broadcast's checkouts directly, refuses prohibited Git
and code-host writes, and asks the Oracle about other commands. If the Oracle cannot answer, the
command runs and the decision is logged. This policy is not a complete shell-language sandbox.

## Workers, review and acceptance

A task has its own worktree/window and may have multiple worker tabs. `open_tab` starts another
permitted Agents row in that worktree. A `review` tab starts read-only: Codex uses its read-only
sandbox; Claude denies editing tools and Git mutation commands, in addition to worker publication
denials. Its first prompt carries the review prompt, the task's brief (what its worker was asked to
do, fenced as data to judge the commit against) and the Operator's own brief for the tab. The
Operator reads the ended turn and uses `record_review` to attach the verdict to its reviewed commit.
Acceptance remains the Operator's decision; with the Oracle on, its critique of a verdict reads the
task's brief too, as a merge's judgment does.

When the review prompt's fix-round allowance runs out, the task asks you for **One More Round** or
**Accept As It Is**. The Oracle judges whether a merge satisfies the review prompt, verdicts and
your recorded answers. Accepted evidence belongs to a specific commit; a moved branch needs fresh
acceptance. Retrying publication resumes saved steps and discovers an existing request rather than
blindly creating another.

An ended worker turn is reported as changed after acceptance when its commit moved or its
uncommitted content differs from the content recorded at acceptance. An unchanged untracked
plan stays quiet, including after a local merge and restart. Older saved acceptances have no
content baseline, so only commit movement proves a later change for them.

A wake line names a task by its key as the tools take it: its letters as written and its digits
spelled (`T7` is `T-seven`, `area-E` stays `area-E`), which every tool resolves; it never carries a
digit or a one-letter word. A worker an API error stopped gets a line naming its task. A broadcast
with nobody at work and nothing moving for ten minutes wakes the Operator once, `nothing has moved
for ten minutes`, until something moves again: never during its own turn, while paused, or once the
broadcast is complete or ended.

On the board, **ends at** changes one task's end. It clears a previous wait/refusal, retains a push
or request already completed, and wakes the Operator. Changing to Commit after opening a request
leaves that request for you.

## Your controls

Pause/Resume and End are on the broadcast's menus. A paused broadcast starts no new publication;
resume reconciles tagged windows and saved work. Pause also types a note into each worker of a
working task that is still at work, still starting, or whose ended turn left background work
running: finish the current step, end the turn and wait. A worker whose window appears only after
Pause gets its note once iTerm2 lists its agent; one whose screen is not ready for it is tried again
as its tab changes, and one with a prompt open is not asked again. Such a task reads `pausing` until
its workers stop, then `paused` with the pause sign; the Operator's row reads `pausing · n tasks`
until every task stopped, then `paused` with the same sign. Resume types a carry-on note into each
worker that got the pause note and is still the broadcast's to steer (not taken over or stopped,
same ownership) while the broadcast still reads paused, so the Operator neither hears of nor accepts
a turn the pause cut short first; then it resumes and wakes the Operator. A carry-on that does not
land turns the wake line into `resumed; paused workers missed the carry-on note, steer them with
message_task` (a wake line names no task). Notes are typed in the order Pause and Resume were
pressed; End hands the tasks to you on the helper first, so a note being typed keeps its Enter back,
and types nothing more. Take Over removes the Operator's authority over a task, and Hand Back
restores it. Stop Task ends that task's participation. Questions remain on the board for your
answer; the Operator cannot answer permission prompts on your behalf.

A question the Operator asks about a task (`ask_you` with a task) shows on that task's card. It
holds the task, which then waits on you, isn't ready to accept and isn't watched for stalls, unless
the Operator asked it with `holds: false` because the task can go on without the answer. Then the
card keeps its own line, adds `question for you`, and the question still asks after the task
finishes, until the Operator resolves it. Fix rounds and AiTerm's own questions always hold.

Every open question for you is listed under Waiting on you, above the Board tab's columns, oldest
first: the Operator's, AiTerm's (a merge on the host, a command the Oracle stopped) and each worker
tab's permission prompt. The Operator asks with `ask_you` and leaves one line in its chat, "Asked
you in AiTerm: …". You answer in the question's block: a choice, or any answer and Send. AiTerm
records it once on the question (`answeredHere`, in `run_status`) and wakes the Operator with a
fixed line naming the task, never the answer; the Operator acts on it and resolves the question.
Answering in the Operator's chat still works. A prompt's block only opens its window, since AiTerm
never types a permission, and a stopped command's opens the Operator's chat, where it is allowed.
A question's notification, the Operator row's click while it waits on a question, and a card's
Answer… open the board at that block.

A worker's question is the Operator's first: its card shows it muted under `asking the Operator`
until the Operator answers it with `message_task` or relays it to you with `relay_question`. A relay
takes no text: AiTerm reads the worker's own words from its last message, so the question in Waiting
on you is the worker's, marked "relayed by the Operator", never a second one. The Oracle looks first,
as the Done step's Worker questions sets it for the broadcast: Straight to you, Challenged once (the
default: when the Oracle thinks the Operator can answer, the Operator answers the worker or replies
and relays it anyway), or Agreed first (rounds until the Oracle has no major or important point
left, at most three, then it reaches you with both sides). An Oracle that can't answer lets the
question through, and the block says why. A round judges only the question it read: once the worker
has moved on or asks something else, nothing is relayed, and a repeated call gets back the round
already asked rather than asking the Oracle again. With the Oracle off, every relay goes straight.
Workers are asked to end a question with a paragraph starting `Question:`, which AiTerm's scan reads.

## Goal and completion

With a goal, all tasks finishing wakes the Operator to call `check_goal`. A met goal completes the
broadcast. A missing goal with rounds left permits planning only the missing work; finishing that
round triggers another check. Exhausting the allowance, or finding nothing to plan and checking
again with the goal still unmet, stops the loop and records what remains under Left for you.
Summary distinguishes met, unmet and not checked by the Oracle.

With closing enabled, completed tasks close after the summary is written or its wait expires, or
when you End the broadcast. Their cards and recorded diffs remain readable. Stopped tasks and
requests left for you stay open. Closing waits for active turns and a connected helper. It retains a
task and says why if there are uncommitted/untracked changes, a different checked-out branch, tabs
outside its window or a removal failure. Ignored files go with the worktree. Optional branch deletion
requires a merged end, the branch still at its accepted commit, merge evidence and no worktree on it.

`run_status` reports cleanup separately from broadcast completion. With closing enabled, `run.cleanup`
is `awaitingSummary` until the summary is written or its wait expires, `pending` while AiTerm's cleanup
is due, and `settled` once that completion's cleanup pass finishes. Settled can include retained
worktrees: task lines expose `keptReason`, or `closingWait` while the pass waits for a turn or helper.
The same reasons appear on their board cards. Closed tasks appear in `finished`; each record's
`branchDeleted` says whether its local branch was deleted. Cleanup settling wakes the Operator to
read the outcome; expiry of the summary wait also wakes it when cleanup becomes pending. AiTerm handles automatic cleanup; an untracked plan
file is unsaved work and remains for you to preserve before removing its worktree. Ended broadcasts
keep their board records, and their Operator tools remain disabled.

`run_status` and the cards say what is true now. A task's `peopleReview` thread counts are read from
the host on every call, in any state, and `reviewQuiet` follows that read; a host that can't be read
leaves the last counts with `threadsNote`. `publicationProblem` is what keeps an accepted task's
publication from going on, the sentence its card says `blocked` for. A problem left from a failed push
or host read goes once a later run gets past it, and a task back in review shows none. What waits for
the Operator's next `finish_task` (a merge whose Oracle yes no longer covers refreshed evidence, an
end changed to Merge) is a hold: its card says `accepted · waiting on the Operator` and asks you nothing.

## Tools

| Purpose | Tools |
| --- | --- |
| Observe | `run_status`, `read_task` |
| Plan | `create_task`, `update_task`, `submit_plan` |
| Steer | `message_task`, `open_tab`, `resume_task`, `retry_task` |
| Review | `record_review`, `find_user`, `request_review`, `reply_thread`, `resolve_thread`, `critique_thread` |
| Finish | `mark_task`, `finish_task`, `update_request`, `retry_pipeline`, `check_goal` |
| Ask you | `ask_you`, `relay_question`, `resolve_question` |
| Read Jira | `jira_search`, `jira_board` |
| Write Jira | `jira_create`, `jira_edit`, `jira_comment`, `jira_move`, `jira_link`, `jira_sprint` |
| Record | `report_find`, `report_snag`, `leave_for_you`, `log_decision`, `write_summary` |

A request `finish_task` opens takes the Operator's title, description and assignee. Without them its
title is the ticket key, a colon and the task's title. Its description is the checks the worker ran,
never the worker's brief. It is assigned to the user AiTerm acts as on the host. `update_request`
changes an open request's title, description or assignee; the Operator's shell stays refused
`glab mr update`, `gh pr edit` and API writes, and the refusal names the tool to use instead.

An accepted task is steered (`message_task`, `open_tab`) while its commit is not pushed yet, or while
its request is still open on the host and not merged, such as a merge waiting on a conflict; AiTerm
reads the host first, and a host that can't say steers nothing. The task goes back to working, its
accepted commit kept as `reopenedFrom`, and its next `finish_task` pushes the new commit to the same
request. No publication of it runs while it is steered: its merge watch stops, and `finish_task`
refuses until the call ends. `retry_pipeline` reruns the failed pipeline of a task's own open request
(GitLab's head pipeline, GitHub's failed Actions runs of the head), with no slice and no Oracle; a
pipeline that didn't fail, a request not from the task's branch, a takeover, Pause and End are
refused. `resolve_thread` resolves a review thread under the Review slice. `critique_thread` asks the
Oracle for a critique of one thread on demand, needs the Oracle on and no slice, and records it on the
task, per thread, note and commit; `read_task` with what: review shows it. `reply_thread` is never
challenged.

`finish_task` answers within about 20 seconds of the call, inside the daemon's 30-second wait for the
app. A publication that takes longer (a pre-push hook, a slow host) answers `running` with what is
done so far and goes on. The next `finish_task` joins it, or once it ended answers what it did, and
AiTerm wakes the Operator when it ends; that an answer is owed is saved, so a retry after a restart
is still not read as ending a review. Such a call is never judged by the Oracle. Before a merge
decision (the commit already merged, or a merge the Oracle judges), AiTerm fetches the default
branch from origin; a fetch that fails is said, and nothing is done. A local merge pushes nothing, so
origin out of reach doesn't stop it: whether its commit is merged already is read from the checkout
and origin as last fetched, the Oracle still judges a new merge, and the answer says origin couldn't
be read. Only `finish_task` pushes: a merge watch that finds the task accepted again on a commit not
pushed yet pushes nothing, stops with that reason, and wakes the Operator naming the task.

A task's branch starts at origin's default branch, fetched first; in a local-merge broadcast, at the
local default branch, where the tasks before it merged. Its diff base is the commit it started at.
While its launch is pending, the shell its new window shows first is its opening, not an uncertain
task. A task's worker opens behind your work: its window is asked for unselected, as `open_tab`'s tabs are.
If iTerm2 raises it anyway, keyboard focus goes back to the window you were in before its agent
command is typed, and keys that landed in its new shell are cleared first. `retry_task` starts the
worker at once and answers how its launch went (`launch`: `started`, `opened`, `opening`, `failed`
or `queued`, with a note). A window left holding only a shell gets the worker as a new tab. A launch
that reaches no worker is blocked with why:
- its agent command couldn't be typed;
- no agent started in its window within 3 minutes;
- iTerm2 didn't confirm its window in 3 tries;
- iTerm2 stayed unreachable for 3 minutes.

`resume_task` then queues it to start again.

`review_task` remains a served refusal directing the Operator to `open_tab`/`record_review`; it does
not run a headless reviewer. Current tool schemas and complete generated briefs are frozen by the
[contract tests](testing.md). The structured broadcast format is the supported persisted format;
there is no separate historical broadcast execution path.
