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
denials. The Operator reads the ended turn and uses `record_review` to attach the verdict to its
reviewed commit. Acceptance remains the Operator's decision.

When the review prompt's fix-round allowance runs out, the task asks you for **One More Round** or
**Accept As It Is**. The Oracle judges whether a merge satisfies the review prompt, verdicts and
your recorded answers. Accepted evidence belongs to a specific commit; a moved branch needs fresh
acceptance. Retrying publication resumes saved steps and discovers an existing request rather than
blindly creating another.

An ended worker turn is reported as changed after acceptance when its commit moved or its
uncommitted content differs from the content recorded at acceptance. An unchanged untracked
plan stays quiet, including after a local merge and restart. Older saved acceptances have no
content baseline, so only commit movement proves a later change for them.

On the board, **ends at** changes one task's end. It clears a previous wait/refusal, retains a push
or request already completed, and wakes the Operator. Changing to Commit after opening a request
leaves that request for you.

## Your controls

Pause/Resume and End are on the broadcast's menus. A paused broadcast starts no new publication;
resume reconciles tagged windows and saved work. Take Over removes the Operator's authority over a
task, and Hand Back restores it. Stop Task ends that task's participation. Questions remain on the
board for your answer; the Operator cannot answer permission prompts on your behalf.

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

## Tools

| Purpose | Tools |
| --- | --- |
| Observe | `run_status`, `read_task` |
| Plan | `create_task`, `update_task`, `submit_plan` |
| Steer | `message_task`, `open_tab`, `resume_task`, `retry_task` |
| Review | `record_review`, `find_user`, `request_review`, `reply_thread` |
| Finish | `mark_task`, `finish_task`, `check_goal` |
| Ask you | `ask_you`, `resolve_question` |
| Read Jira | `jira_search`, `jira_board` |
| Write Jira | `jira_create`, `jira_edit`, `jira_comment`, `jira_move`, `jira_link`, `jira_sprint` |
| Record | `report_find`, `report_snag`, `leave_for_you`, `log_decision`, `write_summary` |

`review_task` remains a served refusal directing the Operator to `open_tab`/`record_review`; it does
not run a headless reviewer. Current tool schemas and complete generated briefs are frozen by the
[contract tests](testing.md). The structured broadcast format is the supported persisted format;
there is no separate historical broadcast execution path.
