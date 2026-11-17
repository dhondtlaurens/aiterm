# Operator

The Operator watches signals and drives their tasks in real iTerm2 windows. A signal watches Jira,
GitLab or GitHub. When an item matches, AiTerm starts a task in an existing project and gives its
worker your prompt. Polling itself uses no model tokens.

The Operator keeps one Claude Code chat while it has unfinished tasks. Its row is first under
**Operator**; click it to open the chat. When the workload finishes, the chat closes and its row
disappears. Configured signals keep polling without a chat; the next match starts a fresh one. Each signal is a heading like a project, with the same task rows underneath.
Fold a signal to see its status counts, or hover its heading for its conditions, skipped items
and source failures.

The **Operator** and **Projects** sections fold into each other, one open at a time: click either
heading to switch. Projects are open by default, so the Operator stays one folded line until you
open it, and with no signal it is only its heading and **+**. A folded section shows an amber count
of what needs you; click it to open the section at that row. Creating a signal opens the Operator's
section, and a notification or Focus View opens whichever section holds the row it selects.

## Create a signal

Choose **File › New Signal…** (⌘S), or the Operator heading's +. Its five steps are:

1. **Signal:** name it and choose Jira, GitLab or GitHub.
2. **Starts when:** pick at least one condition. Jira offers labels, your open sprints, assignee, status and
   Jira projects, or JQL. Code hosts offer **I'm asked to review** or **My merge request needs me**;
   the latter watches unanswered threads, a request sent back to you, or both. Projects are optional
   filters. The preview lists what starts when you create the signal.
3. **Prompt:** say what each worker does, including its checks. For example, `/psg:plan, then
   /psg:implement and /psg:review`. Description checkboxes add only the ticket and/or merge request
   description, quoted as data beneath your prompt. `/` offers installed skills.
4. **Agents:** list the permitted Agent · Model · Reasoning rows. With one row every task uses it.
   With several, the Operator’s activity caption shows that it is choosing the task’s agent while it proposes
   a row with a one-line reason, weighing the item, your prompt, the project, weekly usage per
   agent, the installed agents and your standing instructions; an agent at 80% weekly usage is
   avoided when another permitted agent has room. The Oracle agrees or critiques, for up to three
   rounds. If the Oracle is off or unavailable the proposal applies; after three disagreeing rounds
   the first row in your list does, and only then may AiTerm still move to the other agent at 80%.
   The row and its reason go into the task's journal. The choice never comes to you. A later stage
   and another work tab are chosen the same way; an existing conversation keeps its agent.
5. **Done:** choose the source's done condition, whether to merge when ready where offered, and
   whether to keep, archive or remove the task. The closing box states what your choices do.

Creating, saving an edit or switching a signal on starts every currently matching item that never
started. An incomplete read starts nothing. An item that stops matching keeps running to its done
condition. There is no concurrency cap. Jira checks every minute and sweeps all matching keys every
ten minutes; source failures back off to five minutes.

AiTerm uses projects already in the sidebar; it never clones on pick-up. Link a project's Jira
projects in **Add Project…** or **Edit Project…**. A ticket linked to several projects waits for
the Operator to choose one: the Operator’s activity caption says it is choosing the project, and the Operator
decides it alone, or together with the agent row when there are several rows. Merge requests map
by repository remote. Items without a project are skipped with their reason in the signal's
tooltip and activity log. No acknowledgement is written
to a host or ticket when an item is picked up.

## One item keeps one task

A ticket key, merge request or matching branch identifies existing work. A later signal continues
that task with the same branch, worktree and conversation, moving its row under the new signal.
An archived task restores before continuing. This includes a task you made by hand: once its
worker ends its turn, the signal resumes its conversation with the new stage prompt. Unsent input,
background work and permission prompts hold that launch; it does not interrupt a turn. Use Take
Over to keep a task under your control.

Only one stage launches or works at once. Matches arriving during that stage wait, one per signal,
in arrival order. They start after the current work ends and never during a worker's turn.
Pending work takes precedence over archive/remove: only the last stage applies its final action.

## Questions and the Oracle

Workers end a question with a `Question:` paragraph. The Operator proposes an answer and the Oracle
critiques it, for up to three rounds per question. An agreed answer goes to the worker and its
journal. If they disagree, either calls it your decision, or the Oracle is off or unavailable,
the Operator asks you in its own chat. Its row says **waiting on you · n** and a notification opens
that chat. Type your answer there. A worker's permission, sign-in or folder-trust prompt stays in
that worker's window and marks its own row.

Settings › Operator explains both roles. Choose the Operator's model/reasoning, the Oracle's
agent/model/reasoning, and standing instructions under **Steer the Operator**. Saved instructions
reach the current chat and subsequent Oracle checks. You can also steer the Operator in its chat.

The Oracle gives read-only second opinions, critiques answers and review threads, judges shell
commands and vetoes automatic merges. Its settings are read for each check. Switching it off
routes worker answers to you and prevents automatic merges. For the Operator's shell gate,
ordinary reads are allowed, prohibited writes are refused, and other commands are consulted;
when that consultation is unavailable or off, they run unchecked and the result records why.
A missing or revoked Operator token always refuses the gated call.

## Publishing, done conditions and merging

Workers run the requested skills, including their own adversarial review and publication. They
may commit, push their own task branch, open a draft request and perform host actions authorised
through Operator/Oracle judgment. AiTerm's worker guard refuses force pushes, `--no-verify`, another
branch, the default/protected branch and worker-initiated merges, for Claude and Codex. It preserves
the project's own pre-push hook. These are cooperative CLI guards, not an operating-system sandbox.

AiTerm finds the request from the branch and adds its ordinary clickable badge. Done conditions
fit the source: Operator judgment, a reviewer, approval, resolved threads, merged, a Jira status,
your review posted since this stage began, or merged/closed where applicable. An unreadable host is
unknown and never counts as done.

**Merged** as a done condition only watches for a merge. Automatic merging requires the separate
**Merge it when it's ready** choice. Review requests asked of you never offer it. An opted-in stage
waits for approvals, green checks and resolved threads, the Oracle's explicit yes, an unchanged
local/host head and the host's confirmation that it merged. An Operator judgment does not bypass
those checks. Skills do not merge it themselves.

**Keep** leaves the task. **Archive** closes its window and removes the worktree while keeping the
branch and conversations. **Remove** removes the task; its optional branch deletion requires proof
that the branch's exact tip merged and that it is not the default branch or another task's branch.
Unsaved work keeps the worktree. Open the **Archive** with ⌘A outside a text field; text fields keep
Select All.

## Pause, switch off and take over

Use **Pause Operator** in the Operator heading’s **+** menu to pause all signals, and **Resume Operator**
there to resume even when its chat row is absent. The heading reads **Operator · paused** while paused. The row’s context menu offers the same control.
Unfinished tasks retain the chat while
paused. A configured signal alone does not show the chat row; its heading remains available,
and with no signal configured only the OPERATOR heading and its + remain. Existing workers receive a note to finish
their current turn and wait. **Resume** carries them on before stages advance. A signal's menu
has **Switch Off** and **Switch On (starts n)**; switching it off pauses only its workers and source
polling. Removing a signal leaves its existing tasks running with their saved instructions under
a heading explaining that the source was removed.

**Take Over** on a driven task moves it to its project and withdraws the Operator's authority and
questions for it. Its worktree, branch and conversations stay. There is no Hand Back.
Clicking it opens its window. If its worker never started, AiTerm creates or adopts its worktree
and opens a shell; a merge-request task checks out the request's source branch. Saved conversations
resume with their branch guards, without repeating the Signal's work instruction.

The Operator row says **needs you** only while something needs you: its own chat waits on you (a
permission prompt, or **waiting on you · n** for questions), or AiTerm cannot reach it. AiTerm
tracks each of its own failures by source (waking the Operator, answering its calls, its activity
log, its session, opening its window, reopening a worker, Take Over) and clears each when that same
source next succeeds. A failure AiTerm retries by itself shows only after three failed attempts in
a row; one from something you clicked shows at once until that action succeeds. Hover the row for
the source and reason. Every failure and recovery is written to the Operator's activity log with
its time and source, and `run_status` lists the current ones under `appIssues`, so you can ask the
Operator why. A wake held because you are typing in its chat waits without counting; one pasted
but not sent, or text left unsent in its chat, asks you to send or clear it there.

Only the Operator row’s activity caption decodes. Each event retriggers it, even when the words
repeat, and the words settle after half a second. Its title stays steady. Tasks keep their normal
two-line layout and badges under projects and signals. Reduce Motion uses a plain swap.

## Session recovery and local records

AiTerm keeps task journals, stages, questions, pending replies and source failures locally. The
Operator reads status rather than relying on chat memory. Choosing, launching, working, watching
for a done condition and blocked tasks keep the same chat, as do pending stages and outstanding
closeout. Completed, archived, stopped or taken-over tasks do not keep it after their remaining work
finishes. Questions from completed or superseded stages no longer ask for attention.

Once no work remains, AiTerm waits for tools, deliveries and Oracle jobs, then closes the chat before
revoking its token. A refused close leaves the current chat and its tools usable. A new match during
closure survives and starts in a fresh generation. While work remains, about 150,000 current context
tokens trigger renewal at a safe boundary, carrying current status and recent journals. Age alone
does not restart the chat. A wake can combine updates
for several tasks, so read status without a task first before narrowing it.
Reopening a worker resumes its saved conversation without repeating its stage prompt. Uncertain
launches and deliveries require inspection rather than a blind duplicate.

Before installing this format over a build with broadcasts, end any running broadcast using that
installed build. The new format retires broadcast records without migration; their tasks become
ordinary tasks. See [release notes](workflow/release.md#operator-format).
