# Operator

Signals watch Jira, GitLab or GitHub, or a schedule, and start tasks in real iTerm2 windows. A
signal has a Start and a Done trigger. It starts on an item a Jira, GitLab or GitHub query finds,
or on a schedule; it is done when a query matches that item, or when the Operator or you decide.
When an item starts to match the Start query, or a schedule's time comes, AiTerm starts a task in
an existing project and gives its agent your prompt. Polling and schedules use no model tokens.

## Two kinds of signal

A signal is one of two kinds, one per sidebar section, and where you create it decides which.

An **Operator signal** hands its tasks to the Operator. The Operator chooses the agent and the
project where there is a choice, answers its workers' questions with the Oracle, follows each stage
to its Done trigger and can merge. Its workers run under the worker guard and ask through the
Operator.

A **project signal** picks an item up and starts an ordinary task or review in its project with
your prompt and one agent, then leaves it to you. It keeps the Start trigger with its Write buttons
and preview, schedules, the prompt with its description checkboxes, a Done query AiTerm checks
itself, **Then** with **Delete its branch once merged**, switching off, source back-off and skipped
items. It drops several agent rows, **The Operator decides** (it has **You decide** instead), **Merge
it when it's ready**, the Operator's chat, the Oracle, journals and pending stages. Its task launches as
one you make: its agent asks you directly in its own window, and no branch guard applies, also on
the first turn, which runs with nobody watching. Operator signals never continue or adopt a task a
project signal started.

The Operator keeps one Claude Code chat while it has unfinished tasks. Its row is first under
**Operator**; click it to open the chat. The chat reads your project folders without adding them to
its session, so it opens without asking you to trust a folder, your home folder included. Closing
the chat's window asks nothing: choosing the row
opens it again, and a wake for the Operator reopens it. When the workload finishes, the chat closes
and its row disappears. Configured signals keep polling without a chat; the next match starts a
fresh one. Project signals never open the chat.

A window a signal opens on its own, the Operator's chat, a stage's worker window or a project
signal's task, waits until you have
paused: five seconds without a key or a click while iTerm2 or AiTerm is in front. iTerm2 makes a new
window key and puts it in front even when asked not to, so one opened while you type would take your
keys. The Operator's row says `waiting for your pause to open …` meanwhile, a project signal's task
says so on its signal card; there is no limit. A worker checks
again just before its window opens, after closing the worker it replaces, and the chat after it is
prepared. Choosing the chat's row, or a project signal's task still owing its first window, opens it
at once, and a tab in a window that is already
open never waits: iTerm2 keeps that tab behind. Once the window is open, the window you were in is
brought back in front; others it covered stay covered.

## The sidebar

Both sections group tasks by project. Under **Projects** every task sits under its project, a
project signal's among them. Under **Operator** the Operator's row comes first, then each project
holding a task the Operator runs, with only those tasks, under the divider the project has in
Projects; a project or divider with nothing of the Operator's is left out. An Operator project
heading has no **+** and no menu: click it or press Return to fold it in the Operator's section, apart
from its fold under Projects. A task you take over moves back under Projects.

The **Operator** and **Projects** sections fold into each other, one open at a time: click either
heading to switch. Projects are open by default, so the Operator stays one folded line until you
open it, and with nothing of the Operator's it is only its heading, its signals icon while it
has a signal, and its **+**.
Folded, **Projects** shows its rows' status
counts, as a folded project does; click a count to open the section at its first row in that status.
Folded, **Operator** shows one chip for the Operator: its most urgent state, as a row's mark draws it
(needs you, paused, working, waiting, idle, in that order, over its own row and the tasks it runs; a
worker in the background counts as working), and how many unfinished tasks it holds, the number its
row's title counts. A task waiting on its merge request is unfinished, so it counts, and the Operator's
row stays while one waits. A question with no task draws the amber mark alone, and so does a finished
task you continue: amber while its worker asks, the spinner while it runs. With no work and nothing
asking or running, there is no Operator chip. A green chip counts the finished tasks still listed in
the Operator's section, whose Done trigger fired and whose closeout is through, even once the
Operator's row has gone. Click a chip to open the section at the row it stands for. Creating an
Operator signal opens the Operator's section, and a notification or Focus View opens whichever
section holds the row it selects, unfolding its project.

### Signals sheets

Each section heading has a signals icon, the signals glyph and a count, left of its **+** while the
section has a signal. It opens that section's signals sheet, **Operator signals** or **Project
signals**, listing them in priority order: each row has its source's mark, its name, its Starts and
Done lines, a schedule's next run, and in the warning ink anything that needs you: a source that
cannot be read, with when AiTerm tries again, each skipped item with its reason, and a signal this
version cannot run. A switched-off signal is faded with the pause mark. A row's menu, as a context
menu and behind its trailing button, has **Edit Signal…**, **Switch Off** or **Switch On**, **Move
Up** and **Move Down**, and **Remove Signal…**; a double-click edits. There is no switch per row:
switching on starts every item that matches. The footer has **New Signal…** and **Done**.

A skipped item or a failing source turns the icon and its count amber, and hovering names the first
one. A source that fails three reads in a row also raises the sidebar's banner: `“Reviews for me”
can’t read GitLab.`, the error and when AiTerm tries again, with **Open Signals** and **Settings…**.
It is raised once for that streak, waits behind a question you are answering, and goes by itself at
the next good read; dismissed, it returns only after the source has recovered and failed three times
again.

### The signals disc

A task a signal started wears a small disc with the signals glyph on its avatar's corner, under
either section; a task you made has none, and its row keeps its two lines. Rest the pointer on the
disc for its card, in the background-work card's chrome and with its timing: each signal that ran
the task, oldest first, with when (a removed one says so), a rule, and last the work going on now
beside the row's own mark. On a task the Operator runs that is the Operator's act (`Operator answering its
worker`) or its line; on a project signal's task it is `Waiting for your pause to open its window`,
`Waiting for its worker to be idle` (hover it for why), its status, or `Done · kept` or `Done ·
archived`. VoiceOver reads the row as started by its signal.

### The status line

A line runs down the status column from the Operator's mark through the mark of each task it runs,
in the idle ring's grey, and ends at the last of them. It passes dividers and project headings, and
goes round a finished task's mark. While a project of the Operator's is folded, its heading stands
in for its tasks with a 5 pt stop on the line, in the line's ink; unfolding it removes the stop.

An exchange turns the stretch between the Operator's mark and its task's dotted, in the text ink. It
marches down for as long as the Operator acts on the task, and up once, for a second, when the task
wakes the Operator. A question for you holds its stretch amber and still. Where they overlap, the
moving exchange shows while it lasts and the stretch is amber again after. An exchange with a task
inside a folded project runs to the stop, which takes the stretch's ink. Status marks stay exactly
as they are. With Reduce Motion the dots stand still.

## Create a signal

Choose **File › New Signal…** (⌘S), which makes the open section's kind: a project signal with
Projects open, the default, and an Operator signal with Operator open. Each heading's **+** and its
signals sheet's **New Signal…** make their section's kind. The sheet's title says **New Operator
signal** or **New project signal**, and editing keeps the kind. Its five steps are:

1. **Signal:** name it. The name is what the signals sheet, its tasks' cards and its notifications
   show.
2. **Starts when:** the Start trigger. **Starts on** picks **An item** or **A schedule** (see
   [Schedules](#schedules)). For an item, **Reads** picks Jira, GitLab or GitHub; that source decides
   whether a task is about a ticket or a merge request. **Describe it** takes what you want in your
   own words, and its **Write JQL** (**Write GitLab query**, **Write GitHub query**) button has
   Claude write the query from it (see [Write a query](#write-a-query)). The query field below it
   is what runs: edit what Claude wrote, or type your own. A query AiTerm refuses says why under
   the field. The preview lists up to four matching items with their projects, warns about an item
   no project matches, and counts what starts when you create the signal. For a schedule,
   **Describe it** and **Write cron** write the **Cron** field, **Project** is where each run starts,
   and **Next runs** lists the next four times in place of the preview.
3. **Agents** (**Agent** on a project signal): a project signal has one Agent · Model · Reasoning
   row, which every task uses. An Operator signal lists the permitted rows. With one row every task
   uses it.
   With several, the Operator’s activity caption shows that it is choosing the task’s agent while it proposes
   a row with a one-line reason, weighing the item, your prompt, the project, weekly usage per
   agent, the installed agents and your standing instructions; an agent at 80% weekly usage is
   avoided when another permitted agent has room. The Oracle agrees or critiques, for up to three
   rounds. If the Oracle is off or unavailable the proposal applies; after three disagreeing rounds
   the first row in your list does, and only then may AiTerm switch between permitted Claude and Codex rows at 80% weekly usage.
   The row and its reason go into the task's journal. The choice never comes to you. A later stage
   and another work tab are chosen the same way; an existing conversation keeps its agent.
4. **Prompt:** say what each task's agent does, including its checks. For example, `/psg:plan, then
   /psg:implement and /psg:review`. Name workflow choices such as reviewers in the signal prompt because a
   worker has no question dialog and a skill that would ask uses its default. Description checkboxes
   add only the ticket and/or merge request
   description, quoted as data beneath your prompt; a scheduled signal has none, since a run has no
   ticket or merge request. `/` offers installed skills, following the agents the step before chose.
5. **Done when:** the Done trigger. **Done when** picks **A query matches**, with its own **Reads**,
   **Describe it**, Write button and query; or, on an Operator signal, **The Operator decides**, with
   an optional **What done looks like** (see [The Operator decides](#the-operator-decides)); or, on a
   project signal, **You decide** (see [Project signals](#project-signals)). A new scheduled signal
   opens on The Operator decides or You decide, an item signal on A query matches. On a scheduled
   signal a Done query reads
   GitLab or GitHub against the merge request its run opens; Jira is off, since a run has no ticket.
   On an Operator signal, **Merge it when it's ready** is offered where the Start trigger reads Jira,
   names you as author or assignee, or is a schedule. **Then** keeps, archives or removes the task;
   with remove, **Delete its branch once merged** is offered.
   The closing box states what your choices do; a project signal's says that its agent asks you
   directly and no branch guard applies.

Every step has **Cancel**; Escape closes an open list, otherwise it cancels. A disabled **Continue**
on the Agents step says why: an agent that isn't installed, or a model marked Unavailable.

While an agent the signal may use isn't ready, a note above the buttons says what to fix, and
**Checking agents…** shows while AiTerm reads them. The note is advice for the signal's own agents:
you can still create or save the signal.

Creating, saving an edit or switching a signal on starts every currently matching item that never
started; the closing box counts them. An incomplete read starts nothing. An item that stops matching
keeps running until its Done trigger. There is no concurrency cap. AiTerm reads each Start query
every minute, and Jira sweeps all matching keys every ten minutes; source failures back off to five
minutes, or until the network comes back.

AiTerm uses projects already in the sidebar; it never clones on pick-up. Link a project's Jira
projects in **Add Project…** or **Edit Project…**. A ticket linked to several projects waits for
the Operator to choose one: the Operator’s activity caption says it is choosing the project, and the Operator
decides it alone, or together with the agent row when there are several rows. A project signal has
no one to choose and skips such an item, naming the projects. Merge requests map
by repository remote. Items without a project are skipped with their reason in the signals sheet,
and an Operator signal's in its activity log too. No acknowledgement is written
to a host or ticket when an item is picked up.

### Write a query

The Write button runs the Operator's Claude once, headless and read-only, with the Operator's model
and reasoning, in an empty scratch folder. No Operator chat is needed or woken. Claude gets your
description, quoted as data, with the source's syntax, worked examples and what AiTerm knows of
your accounts: who you are on that source, the Jira projects linked to your projects with Jira's
statuses and labels, and your projects' repositories. It answers with one query on one line.

AiTerm checks the answer: Jira checks JQL, AiTerm checks a GitLab query, and GitHub checks a GitHub
query by running it. A query that fails goes back to Claude once, with the error. If it still
fails, or the check cannot run (the account is not connected, say), the query lands in the field
with the reason under it, for you to fix. A query that passed says Claude wrote it and who checked
it. Your description is saved with the trigger; a waiting task's line shows the Done trigger's.

### Query syntax

**Jira** runs JQL as written, in the Jira projects you can see.

**GitLab** uses GitLab's merge request search syntax, which AiTerm reads into GitLab's GraphQL
filters. Tokens are `key:value`, separated by spaces; a value may be quoted
(`label:"needs review"`) and a leading `-` negates a token. The keys are `author:`, `assignee:` and `reviewer:`
(`@me`, a username, `none` or `any`), `review-state:` (`unreviewed`, `review_started`, `reviewed`,
`requested_changes`, `approved` or `unapproved`; commas mean or), `approved-by:`, `draft:` (`yes`
or `no`), `label:` (repeat it for and), `target-branch:`, `source-branch:`, `milestone:`,
`project:` (a full path such as `shop/webshop`; commas mean or) and `state:` (`opened`, `merged`,
`closed` or `all`). `draft:`, `project:` and `state:` cannot be negated. A Start query lists open
merge requests unless it names a `state:`; a Done query reads any state. An unknown key or a bad
value is refused with the token named.

**The role rule.** A GitLab Start query names you in exactly one role: `author:@me`, `assignee:@me`
or `reviewer:@me`. The role picks the list AiTerm reads, as on GitLab's own merge request homepage,
and with it what `review-state:` means: your own review under `reviewer:@me`, any reviewer's under
the other two. A negated `@me` (`-reviewer:@me`) is a filter, not a role. A Start query with no role,
or with two, is refused, since it would read every merge request on the server. A Done query names
one role or none; with none, `review-state:` is any reviewer's.

**Threads.** AiTerm adds two tokens it decides from a merge request's review threads, never sent to
the host: `threads:waiting-on-me` (an unresolved thread whose last note is someone else's) and
`threads:resolved` (no unresolved thread). Either may be negated, in a GitLab or a GitHub query.

**GitHub** uses GitHub's own search syntax: AiTerm adds `is:pr` when it is missing, and `is:open`
to a Start query that names no state.

A Done query is checked against the task's own item: Jira against its ticket (`key = SHOP-412 AND
(your query)`), for a merge request task the key in its branch or title; GitLab or GitHub against
its merge request, the same query confined to that one request. A task without that ticket or merge
request does not match.

Some review conventions as queries:

| Situation | Starts when | Done when |
| --- | --- | --- |
| Review requested, and asked again | GitLab `reviewer:@me review-state:unreviewed draft:no` | GitLab `reviewer:@me review-state:approved` |
| Returned to you | GitLab `assignee:@me review-state:requested_changes,reviewed` | GitLab `-review-state:requested_changes,reviewed` |
| Waiting on your reply | GitLab `assignee:@me threads:waiting-on-me` | |
| Approved by others | GitLab `assignee:@me review-state:approved draft:no threads:resolved` | GitLab `state:merged`, or Merge it when it's ready |
| Assigned to you, reviewed by another | GitLab `assignee:@me reviewer:any -reviewer:@me` | |
| Assigned to another, reviewed by you | GitLab `reviewer:@me -assignee:@me` | |
| Sprint tickets | Jira `assignee = currentUser() AND sprint in openSprints() AND statusCategory = "To Do"` | GitLab `reviewer:any` |
| Handed to you in review | Jira `assignee = currentUser() AND status = "In Review"` | Jira `assignee != currentUser()` |
| Review requested on GitHub | GitHub `is:pr is:open user-review-requested:@me draft:false` | GitHub `-user-review-requested:@me` |

## Schedules

**A schedule** starts a signal at the times its cron names, with no item: each firing is a new task
in the signal's project, titled with its scheduled time (`Weekly dependency update · 23 Nov 2026
09:00`), on a branch of its own. The branch is the signal name's slug cut short, then the first six
characters of the signal's id and the time in UTC (`feat/weekly-dependency-update-1a2b3c-20261123-0800`), so
two runs, or two signals of one name, never share a branch or worktree. A run never continues another
task, though a later Operator signal may continue an Operator run's task, its merge request
matching, say. A project signal's run is an ordinary task in its project.

**One run at a time.** A time that comes while the signal's last run is unfinished is skipped, with
its reason in the signals sheet (and an Operator signal's activity log); an Operator run stays the
signal's, whichever signal's stage it runs now. A project signal's run is unfinished until its Done
is reached or its task is archived or removed: with **You decide**, each later time is skipped until
you archive the task. A run still waiting to be made (iTerm2 away, say) counts too, so two times
make one task. A run's task that cannot be made is tried three more times, then that time is skipped
with the reason. **Missed times run once.** With AiTerm closed, the Mac asleep or, for an Operator
signal, the Operator paused at the time, the most recent missed time starts when it is back and
older ones are dropped. Pausing the Operator does not hold a project signal's schedule. Times before
the signal was created, switched on or its cron changed never start, so
nothing starts when you create it. Each signal keeps the last time it fired or skipped, saved with
the task it starts, so a restart never starts one time twice.

The cron has five fields: minute, hour, day of month, month and weekday, each `*`, a value, a range
(`1-5`), a list (`1,15`) or a step (`*/15`), with month and weekday names (`JAN`, `MON`); Sunday is
`0` or `7`. When both day fields are restricted, a day matching either one runs. There are no
seconds, `@` names or `L`, `W` and `#`. Times are your Mac's time zone: a time a daylight-saving
change skips runs at the change, and a time it repeats runs once. **Write cron** works as the other
Write buttons do (see [Write a query](#write-a-query)), with the current date, time and time zone;
AiTerm checks the answer with its own parser.

## Project signals

**Pick-up.** A project signal's new match makes the task as **New Task…** or **New Review…** would:
a merge request you review becomes a review, one you authored or are assigned to a task on its own
branch, a ticket a task on a new branch from the project's default branch. The row appears in its
project without being selected, its window opens behind in your pause, and its agent starts with
your prompt. Matches for one project start one after another; a create you have under way in that
project goes first. AiTerm skips, with the reason in the signals sheet, a merge request from a fork
(`From a fork: AiTerm checks out only branches of the project’s own repository.`), a review whose
branch another row has checked out (naming that row), and an item whose task the Operator runs
(`The Operator runs this item’s task.`). A create that fails is skipped with its reason and tried
again after five minutes.

**Its first turn.** When the turn your prompt started ends, one notification says so: its title is
the signal's name and its body, say, `!12 Fix rounding in cart totals is ready for you, in shop.`,
or `… asks you something, in shop.` when its agent asks you. Clicking it selects the row and opens
its window; choosing the row takes the notification back. A prompt an agent only pasted notifies
once you have sent it and it has worked.

**Asked again.** When the item matches again and its task exists (a review asked again, say), the
signal's prompt is typed into the same conversation once its agent is idle with nothing unsent: it
waits while you type, while input is unsent and while the agent works or asks, with no limit. An
archived task is restored first, and a closed window opens behind in your pause, resuming its
conversation with the prompt. A newer match replaces a prompt still waiting. There is no
notification for the match itself; the turn the prompt starts notifies when it ends, as the first
does. A task you made by hand is marked with the signal the first time it matches, and gets the
prompt the same way. A task another project signal started stays that signal's.

**Done and Then.** With **A query matches**, AiTerm reads the Done query for the task before its
window opens, and before a prompt is typed again, and stores whether it matches; a read that fails
holds the prompt, with the reason in the signals sheet, and is tried again after five minutes. From
then on it reads the query each minute, skipping an agent at work or asking, and the task is done
when its item starts to match. With **You decide** there is no query: you archive the task when you are
done with it. Either way a merge request that is merged or closed ends it. **Keep** leaves the task;
**Archive** archives it, and **Remove** removes it, once none of its agents works, asks or holds a turn,
and no tab's input may hold words you have not sent (an agent's input AiTerm cannot read counts as holding
them). Unsaved work keeps it, and its card says `Done · kept` with why. With **Delete its branch once
merged**, a removed task's branch goes under the same proof as an Operator signal's, also while the
Operator is paused; a review's branch never does. A removed task's item does not start again while it
still matches. Editing the Done query makes the next read a new baseline. A later match makes a kept
or archived task the signal's again, and Done and Then run again.

## One item keeps one task

A ticket key, merge request or matching branch identifies existing work. A later Operator signal
continues that task with the same branch, worktree and conversation, and its row moves into the
Operator's section under its project.
An archived task restores before continuing. This includes a task you made by hand: once its
worker ends its turn, the signal resumes its conversation with the new stage prompt. Unsent input,
background work and permission prompts hold that launch; it does not interrupt a turn. A task you
took over is yours: a later signal never continues it. An Operator signal never continues a task a
project signal started (see [Project signals](#project-signals) for what a project signal does
with an existing task).

An item that stops matching and matches again continues the same task as a new stage, or, for a
project signal, runs its prompt again in the same task. On GitLab,
a review asked again sets your review state back to unreviewed, so
`reviewer:@me review-state:unreviewed` starts each re-review in the same task and conversation.
Use `review-state:` there rather than `approved-by:@me`: an approval survives a review asked again.

Each signals sheet's order is its signals' priority. Project signals come first: when a project
signal and an Operator signal match the same new item in one pass, the project signal starts its
task and the Operator signal gets nothing. Of two project signals the higher starts and the other
yields. When several Operator signals match the same item in one pass, the higher starts its task
and the others wait as pending stages. Move a signal with **Move Up** and **Move Down** in its menu
in the sheet; a new signal is added at the bottom.

Only one stage launches or works at once. Matches arriving during that stage wait, one per signal,
in arrival order. They start after the current work ends and never during a worker's turn.
Pending work takes precedence over archive/remove: only the last stage applies its final action.
A waiting stage is checked once more just before its worker launches: when the latest full read of
its signal no longer lists the item (a merged request, a ticket that moved on), the stage is dropped,
its journal says so, and the next waiting stage starts. With none left, the task is the earlier
stage's again, with its agent: still waiting for its Done trigger, or done and applying its Then. A
read that only fetched changes since the last one is no such evidence.

## Questions and the Oracle

Workers end a question with a `Question:` paragraph. The Operator proposes an answer and the Oracle
critiques it, for up to three rounds per question. An agreed answer goes to the worker and its
journal. If they disagree, either calls it your decision, or the Oracle is off or unavailable,
the Operator asks you in its own chat. Its row says **waiting on you · n** and a notification opens
that chat. Type your answer there. A worker's permission, sign-in or folder-trust prompt stays in
that worker's window and marks its own row. A project signal's agent asks you in its own window.

Settings › Operator explains both roles. Choose the Operator's model/reasoning, the Oracle's
agent/model/reasoning, and standing instructions under **Steer the Operator**. Saved instructions
reach the current chat and subsequent Oracle checks. You can also steer the Operator in its chat.

The Oracle gives read-only second opinions, critiques answers and review threads, judges shell
commands and vetoes automatic merges. Its settings are read for each check. A check whose Oracle
settings or standing instructions changed while it ran is discarded and asked again. Switching it off
routes worker answers to you and prevents automatic merges. For the Operator's shell gate, plain
reads run at once; pushes, merges, changes to a request on the host, commits, hard resets, checkouts
and cleans are refused; every other command goes to the Oracle. Its yes runs the command, a critique
sends it to a worker, and a call for you becomes a question in the Operator's chat whose answer
allows it once. When the Oracle is off or cannot answer, the command runs unchecked and the result
says why.
A missing or revoked Operator token always refuses the gated call.

## Publishing, done and merging

The signal prompt can ask a worker to run a skill, obtain a review or publish its work. They
may commit, push their own task branch, open a draft request and perform host actions authorised
through Operator/Oracle judgment. AiTerm's worker guard, for Claude, Codex and Antigravity, refuses a push that
forces or replaces remote history, skips the push hook (`--no-verify`, a `core.hooksPath` override),
pushes all branches, tags or a deletion, or pushes anything but its own task branch at its current
commit; and a push to another repository, the default branch or a branch the host protects, or one it
cannot check against the host. It refuses every merge of a request on the host, through `gh`, `glab`
or their APIs. A worker may run `git merge` locally. The guard preserves the project's own pre-push
hook. These are cooperative CLI guards, not an operating-system sandbox. A project signal's tasks
have none of them.

**Review task or own task** is decided per merge request. A merge request is a review task, which
checks out its branch and never pushes, unless your account authored it or is one of its assignees.
A ticket's task is always your own, also once it has a merge request.

AiTerm finds the request from the branch and adds its ordinary clickable badge. **Done is an edge,
as Start is.** Before a stage's worker launches, AiTerm reads the Done query for the task's item and
stores whether it matches; the worker launches only after that read. A Done trigger that cannot be
read holds the launch, with the reason on the task, and is read again after five minutes. From then
on, every complete read compares with the last one, and the stage is done when its item starts to
match the Done query during the stage. A Done query that already matched when the stage began waits
for a fresh match, so evidence from an earlier round never ends a new one. Reads skip a worker at
work: a review posted during its turn ends the stage at the first read after it. A merge request
that is closed, or merged by anyone but AiTerm, is always done. An unreadable host is unknown and
never counts as done.
`finish_stage` records a stage's outcome for the Operator; only the Done trigger, or a merge or
close, ends the stage, except where the Operator decides the Done. While a stage waits, its row's line is the Done trigger's description, or
its query when it has none.

### The Operator decides

A Done of **The Operator decides** has no query. When the worker ends its turn, the Operator judges
whether the prompt's work is done, guided by **What done looks like** (empty means the prompt's work
is complete), and its `finish_stage` done goes to the Oracle with its evidence and the worker's last
turn, for up to three rounds per stage, as a worker answer does. The Oracle's yes finishes the stage
and its Then runs; a critique goes back to the Operator. If they still disagree after three rounds,
either calls it your decision, or the Oracle is off or unavailable, the Operator asks you in its chat,
and your yes finishes it. A merge request that is closed, or merged by anyone but AiTerm, still ends
the stage. With **Merge it when it's ready** and an open merge request AiTerm has not merged, an
agreed done waits for the merge: AiTerm merges, hands the stage back to its worker, and the next
agreed done ends it. With no merge request, an agreed done finishes.

Automatic merging requires **Merge it when it's ready**, offered on an Operator signal where the
Start trigger reads Jira,
names you as author or assignee, or is a schedule. Workers never merge, so this is the only way a signal merges,
and it never applies to a review task. An opted-in stage merges once the host says the request can
be merged, with approvals, green checks, resolved threads and the local head pushed, then the
Oracle's explicit yes, an unchanged local/host head and the host's confirmation that it merged.
It does not wait for the Done query, and the Done query does not end the stage before the merge.
While it waits, its line names what the merge lacks (`waiting to merge · checks`). Skills do not
merge it themselves.

AiTerm's own merge does not end the stage either: it hands the stage back to its worker, so one
signal can merge and then follow the release. The worker gets one line, as the Operator's answers
are delivered: `AiTerm merged !12 at 1a2b3c4; carry on.` (`#12` on GitHub, with the merge commit).
The stage then ends on its Done query alone, at the first read after that turn where it matches,
even if it already matched before the merge; a Done query of `state:merged` therefore ends it
after the worker's one follow-up turn. AiTerm saves its merge just before asking the host, so a
lost answer or a restart still counts as AiTerm's, while a refused merge does not. When the worker's
window is gone, the stage blocks with `AiTerm merged !12 at 1a2b3c4; its worker is gone.`, and
Resume reopens its conversation with the carry-on line instead of the stage prompt.

**Keep** leaves the task. **Archive** closes its window and removes the worktree while keeping the
branch and conversations. **Remove** removes the task; its optional branch deletion requires proof
that the branch's exact tip merged and that it is not the default branch or another task's branch.
Unsaved work keeps the worktree. Open the **Archive** with ⌘A outside a text field; text fields keep
Select All.

## Pause, switch off and take over

Use **Pause Operator** in the Operator heading's context menu to pause the Operator's signals, and
**Resume Operator** there to resume, even when its chat row is absent. Project signals carry on
while the Operator is paused. The heading reads **Operator · paused** while paused.
Unfinished tasks retain the chat while
paused. A configured signal alone does not show the chat row, and with no task the Operator runs
the section is its heading, its signals icon while it has a signal, and its **+**. Existing workers receive a note to finish
their current turn and wait. **Resume Operator** carries them on before stages advance. A signal's
menu in its signals sheet has **Switch Off** and **Switch On**; switching it off pauses only its
workers and source polling, and the sheet draws it faded with a pause mark. Switching a project
signal off stops its reads, pick-ups and prompts; its tasks stay yours. Removing a signal leaves its
existing tasks running with their saved instructions under their project, and their card names the
signal as removed.

**Take Over**, on the menu of a task still under the Operator, makes it an ordinary task in its
project. The Operator lets go of it and of its questions, and later signals never continue it. Its
worktree, branch and conversations stay; a worker still running finishes its turn under its branch
guard. If its worker never started, Take Over makes its worktree first; a merge-request task checks
out the request's source branch. From then on it opens, archives, restores and removes like any
task, and its conversations resume without a branch guard. It keeps its signals disc and card.
There is no Hand Back.

The Operator row says **needs you** only while something needs you: its own chat waits on you (a
permission prompt, or **waiting on you · n** for questions), or AiTerm cannot reach it. AiTerm
tracks each of its own failures by source (waking the Operator, answering its calls, its activity
log, its session) and clears each when that same source next succeeds. AiTerm retries each by
itself, so a failure shows only after three failed attempts in a row. Hover the row for the source
and reason. Every failure
and recovery is written to the Operator's activity log with its time and source, except a failure
to write the log itself: only its recovery is written.
`run_status` lists the current ones under `appIssues`, so you can ask the Operator why. A wake held
because you are typing in its chat waits without counting; one pasted but not sent, or text left
unsent in its chat, asks you to send or clear it there. A project signal's failed reads are not the
Operator's: they show on the signals icon, in the sheet and, after three, in the banner.

Only the Operator row’s activity caption decodes, and only when its words change: the words
standing morph into the new ones, settling from the left in half a second, so the caption is never
empty. A new event with the same words moves nothing. Every word is in one muted ink; only “needs
you” stands out, in the attention chip. Unfolding the section shows the current words without a
decode. Its title counts the tasks the Operator runs, **Running 3 tasks**, **Running 1 task** or
**No tasks**, and never decodes; at rest the caption says **watching**. Tasks keep their normal
two-line layout and badges in both sections. Reduce Motion uses a plain swap.

A row's trailing mark is a ring while its state can still move and a filled disc once it holds: a
finished task wears the green disc with a white check (also used on a done ticket's badge),
and a paused one the grey pause disc. A finished task is past pausing: it stays done when you pause
the Operator or switch its signal off. A done task whose closeout is still running is paused with
the rest. The blue done ring stays what it is under projects: a chat ended its turn and wants reading.

## Session recovery and local records

AiTerm keeps task journals, stages, questions, pending replies and source failures locally. The
Operator reads status rather than relying on chat memory. Choosing, launching, working, watching
for a Done trigger and blocked tasks keep the same chat, as do pending stages and outstanding
closeout. Completed or archived tasks do not keep it after their remaining work finishes, and
tasks you took over are ordinary tasks, not the Operator's. Questions from completed or superseded
stages stop asking for attention.

Once no work remains, AiTerm waits for tools, deliveries and Oracle jobs, then closes the chat before
revoking its token. A refused close leaves the current chat and its tools usable. A new match during
closure survives and starts in a fresh generation. While work remains, about 150,000 current context
tokens trigger renewal at a safe boundary, carrying current status and recent journals. Age alone
does not restart the chat. A wake can combine updates
for several tasks, so read status without a task first before narrowing it.
Reopening a worker resumes its saved conversation without repeating its stage prompt. Uncertain
launches and deliveries require inspection rather than a blind duplicate.

A project signal's task saves what it owes and where it stands: a prompt still to reach its agent,
its Done baseline, whether Then ran, and its latest turn. A quit while its window waits for your
pause opens it at the next start; a launch whose agent is already running is not prompted twice.
Queued pick-ups are not saved: the first full read after a start decides them again. A failed read's
count is kept in memory, so a restart counts three again before the banner.

A change to any of these records is a change to the saved workspace, brought forward by an update
script ([Workspace format and update scripts](workflow/release.md#workspace-format-and-update-scripts)).
