# AiTerm

A native macOS sidebar that runs coding agents in real iTerm2 windows, one git worktree per task,
with an Operator that plans the work and steers the agents for you.

<img src="docs/desktop.png" alt="AiTerm beside iTerm2. The sidebar's Operator group shows the broadcast Ranking v2: the Operator working, one task with Operator watching and one waiting on you. Below it the projects: a home folder, aiterm under Personal with Claude Code and PI tasks, acme under Work with a PI task and a merge-request review. The footer shows the selected task's context, the Mac's load in Backpack Mode and the agents' usage. Beside it, the selected task's iTerm2 window shows Claude Code mid-refactor.">

> AiTerm is built for its maintainer's own workflow. Bug reports are welcome; feature requests and
> pull requests are not taken. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Install

Needs macOS 26 or newer, iTerm2 with its Python API on (*iTerm2 › Settings › General › Magic ›
Enable Python API*), and `python3` 3.11 or newer (`brew install python`).

1. Download the DMG from the [latest release](https://github.com/dhondtlaurens/aiterm/releases/latest)
   and drag **AiTerm** to Applications.
2. Open it. The release is self-signed, so allow the first launch once in *System Settings ›
   Privacy & Security › Open Anyway*. If you copied the app some other way, clear the download flag
   first (`xattr -dr com.apple.quarantine /Applications/AiTerm.app`): a quarantined app runs from a
   temporary copy and skips the Claude status line.
3. Allow AiTerm's API connection when iTerm2 asks. The sidebar says "Waiting for iTerm2…" until you
   do; if you declined, turn the Python API on again in iTerm2 and relaunch AiTerm.
4. In [*Settings › Agents*](#agents), press **Install** on each agent you use.

*AiTerm › Check for Updates…* installs newer versions in place.

### Install it with your AI

Paste this into Claude Code, Codex or another coding agent:

    Install AiTerm on this Mac for me by following
    https://raw.githubusercontent.com/dhondtlaurens/aiterm/main/docs/ai-install.md

The agent checks the requirements, downloads the latest release, verifies its checksum, copies the
app to Applications and switches on iTerm2's Python API. It asks before installing anything
missing, and stops for the clicks only you can make. The steps are in
[docs/ai-install.md](docs/ai-install.md).

### What AiTerm changes on your machine

- **Agent drivers**: only when you press **Install** on an agent's card; a backup is kept next to
  every file it edits.
- **A local port**: the helper listens on `127.0.0.1:47821` for the agents' hooks.
- **Backpack Mode**: the sudoers rule `/etc/sudoers.d/aiterm`, which lets AiTerm switch lid sleep
  with `pmset`, only once you allow it on the [Mac card](#integrations).
- **Worktrees**: one per task, under `<repo>/.worktrees/`.
- **Its own state and log**: `~/Library/Application Support/AiTerm/`.

The full list is in [docs/architecture.md](docs/architecture.md#what-aiterm-writes-and-where).

### Build from source

Needs Swift 6.4 through [Swiftly](https://www.swift.org/install/macos/) (`swiftly install --use 6.4`).

    scripts/run-dev.sh    # build build/AiTerm.app and open it in place of the installed one
    scripts/test.sh       # the suites this branch's changes can affect
    scripts/test.sh all   # every suite

A local build wears a DEV pill on its Dock icon and does not update itself. More in
[scripts/README.md](scripts/README.md), [docs/architecture.md](docs/architecture.md) and
[docs/status-model.md](docs/status-model.md).

## Concepts

The sidebar sits beside iTerm2 and keeps every task's window tiled next to it. AiTerm drives the
real iTerm2 through its Python API; it does not embed a terminal. You add projects, start a task
for each piece of work, and the agent works in its own worktree and window while the sidebar shows
where each one stands.

- **Project**: a GitLab, GitHub or plain git repository, or a plain folder, grouped under dividers
  you name. A Jira project can be linked to it.
- **Task**: one piece of work: its own git worktree and branch, its own iTerm2 window, started from
  a [Jira ticket](#integrations) or a prompt (⌘N). The gitignored files `.worktreeinclude` names
  are copied in. Its row shows the agents in its tabs, a [status mark](docs/status-model.md)
  (working, needs input, done) and the [badges](#interface) you keep. After a crash, a reboot or
  iTerm2 quitting, every task's window reopens with its conversations.
- **Tab**: an agent in a task's window. A task can hold several, each its own agent.
- **Terminal**: a plain shell in the project folder, with no worktree (⌘T).
- **Review**: a merge or pull request checked out in its own worktree, with an agent on it (⌘R).
  Its row counts the resolved review threads.
- **Broadcast**: one prompt to the [Operator](#operator) across one or more projects, carried
  through to the end you set. One runs at a time.
- **The Shelf** (⌘S): puts a task away. Its worktree goes and its branch stays; restoring brings
  back the worktree and its conversations. Ended broadcasts are kept here to read back.
- **Focus View** (⌘F): opens only the projects with a row waiting on you, which the Dock badge
  counts. **List View** (⌘L) opens them all again.
- **Footer**: SYSTEM shows the selected task's context fill, the Mac's CPU, memory and battery,
  and `backpack enabled` while [Backpack Mode](#integrations) is on. USAGE shows each agent's
  account usage.

## Settings

Four panes, ⌘1 to ⌘4. Everything waits for **Save**, except an agent's install and Help with
problems, which apply at once, and the sidebar size, which shows at once and Cancel puts back.

### Agents

The coding agents AiTerm launches and reads. Each card tests its agent when Settings opens and
shows three checks; one button installs or repairs what is missing. Claude Code and Codex are fully
supported; other providers, such as Grok, run through PI.

- **Help with problems**: when a git step fails (a diverged branch, a conflicted rebase), New
  Review's footer and Pull main's banner offer **Find a Fix**. Claude Code reads the problem in a
  clone and proposes a fix; nothing changes until you press **Apply**. Needs Claude Code; on by
  default.

Every agent card has the same parts:

- **CLI**: the agent's command is on your login shell's `PATH`.
- **Driver**: what reports the agent's status to AiTerm.
- **Messaging**: whether AiTerm can type into the agent's session safely on the installed version,
  proven by a delivery check. The Operator steers its workers this way, so only an agent with
  Messaging can be one.
- **Install / Repair / Reinstall**: installs a missing CLI with its vendor's installer, then
  AiTerm's driver. **Run check** appears when only Messaging is missing: it opens iTerm2 and runs
  the delivery check, which takes a few minutes.
- **Default model** and **Default reasoning**: what a new task starts on, and what a row added on
  New Broadcast's Agents step starts at.

#### Claude Code

Anthropic's agent.

- **CLI**: `claude`.
- **Driver**: HTTP hooks and a status-line bridge for usage, merged into `settings.json` under
  `$CLAUDE_CONFIG_DIR` (default `~/.claude`). The card shows that path.
- **Messaging**: checked per Claude Code version.
- **In the app**: task rows and tabs, context and account usage in the footer, the
  [Operator](#operator), a worker, a review tab, the Oracle and Find a Fix.

#### Codex

OpenAI's agent.

- **CLI**: `codex`.
- **Driver**: command hooks and an MCP server for `Stop`, merged into `~/.codex/config.toml`.
- **Messaging**: checked per Codex version.
- **In the app**: task rows and tabs, context and account usage in the footer, and for the
  [Operator](#operator) a worker, a review tab and the Oracle.

> **Codex runs without approvals.** Codex tasks launch with
> `--dangerously-bypass-approvals-and-sandbox`, which turns off Codex's approval prompts and
> sandbox. The New Task command preview shows the flag before anything runs.

#### PI

An open agent harness; its models come from the providers you signed in to with `/login` in PI.

- **CLI**: `pi`.
- **Driver**: an extension AiTerm owns in `~/.pi/agent/extensions/`.
- **Messaging**: not built for PI yet, so the Operator cannot start or steer a PI task, or give a
  task a PI tab.
- **In the app**: task rows and tabs you start yourself, with context fill (no account usage), and
  for the [Operator](#operator) the Oracle, which checks with read-only tools rather than a
  sandbox, and the headless reviewer of a broadcast started before the Agents step.

### Operator

The Operator works a [broadcast](#concepts) through to its end in its own iTerm2 window. In the
sidebar, the OPERATOR group holds the broadcast, the Operator's own row and the tasks it drives,
each saying what the Operator is doing (`Operator watching`, `waiting on you`). The **+** on its
heading starts a broadcast; a click on the broadcast opens its board (**Board**, **Activity**,
**Summary**).

- **Agent**: Claude Code, with its **Model** and **Reasoning**. Its workers run on an agent with
  [Messaging](#agents). In a broadcast set up with the [New Broadcast](#new-broadcast) steps, its
  workers, tabs and reviewers run only on the Agents list, and when a task's agent reaches 80 % of its
  weekly use the task starts on the list's first row for the other agent instead, while that one is
  under it, unless the Operator pinned its agent. A broadcast started before those steps keeps each
  agent's default model, unless the Operator picks another, and moves new tasks to the other agent at
  80 %.
- **Base** (always on): plans the tasks, starts their agents, answers them from the brief and the
  code, accepts or sends back their work, adds backlog tasks, commits, pushes the task's branch,
  opens a draft MR and runs review tabs.
- **Jira** slice: creates and updates tickets in the broadcast's Jira projects.
- **Review** slice: marks the MR ready, assigns reviewers, has the agent fix their feedback and
  replies in the threads. A task's MR goes into people's review only with this slice on and the
  Task step's review prompt written.
- **Merge** slice: merges, through the MR or locally without pushing. Only a commit it accepted,
  with the pipeline green and every thread resolved.
- **Never**: writes code, deploys, force-pushes, pushes to a default or protected branch, or answers
  an agent's permission prompt.
- **Oracle**: a second agent, with its model and reasoning. It critiques the plan and the
  Operator's verdicts, answers the [gated shell](#the-gated-shell)'s commands, and vetoes three calls,
  each refused on its no. On by default with Codex, when Codex is installed.
- **Instructions**: house rules for every broadcast; `/` lists the agents' skills.

The slices are off by default, and a broadcast keeps the settings it started with. A slice is
enforced by AiTerm, which does every Jira and code-host write itself and refuses one whose slice is
off; what that left undone shows under *Left for you* in the Summary.

The Oracle's no refuses a vetoed call. With no answer from it, missing, failed, too slow or lost
with a restart, each call does as the table says:

| The Oracle vetoes | With no answer from the Oracle, the call |
|---|---|
| `create_task` past the backlog limit: a quarter of the first plan | is refused |
| a `finish_task` that would merge, or push with `noVerify` | goes ahead |
| `check_goal` | acts as not checked by the Oracle |

#### New Broadcast

Five steps, **Broadcast · Prompt · Agents · Task · Done**:

1. **Broadcast**: an optional name, the Jira projects it reads, and the projects it may work in,
   at least one.
2. **Prompt**: what to work on, as you'd tell a colleague; `/` lists skills, `@` files.
3. **Agents**: the agent · model · reasoning rows the Operator may start workers, tabs and reviewers
   on, as many as you like. It starts as your last broadcast's list. Nothing else runs, a model your
   prompt names included: `create_task`, `update_task` and `open_tab` refuse a combination that is
   not a row.
4. **Task**: what every task follows. Its **review**, one prompt saying who reviews, what passes and
   how many fix rounds a task gets; left empty, a task is accepted without one. Its **end**: Commit,
   Draft MR, Merge or Local merge. Merge and Local merge need the Merge slice, and Draft MR and Merge a
   connected code host for every project; an end you picked that can't be had any more moves to
   Commit, and the help says so. Its **closing** when the broadcast ends: close finished tasks' tabs
   and remove their worktrees, and, once that is ticked, delete their local branches once merged.
5. **Done**: the broadcast's **goal**, what must be true once every task is done, and its **extra
   rounds** (2 by default). A goal is checked with the Oracle, so with the Oracle off both are
   disabled and the broadcast ends when its tasks do.

Start Broadcast waits until every agent the Operator may use is Ready, Messaging included,
iTerm2's checks have passed, and the chosen projects' code hosts have been checked.

#### Review tabs

In a broadcast set up with these steps, a task is reviewed in a tab of its own in the task's window, on an Agents row, so you can watch it:
the Operator opens it with `open_tab`, role `review`, and the tab is told to end with a verdict. It
starts read-only. Codex runs with `--sandbox read-only`. Claude Code is denied Edit, Write and
NotebookEdit and git's writing commands (`commit`, `checkout`, `switch`, `reset`, `rebase`, `merge`,
`stash`, `add`), on top of every worker's push, merge and MR denials. When its turn ends, the Operator
reads it and records the verdict with `record_review`, against the commit it reviewed. The Operator
decides when to accept. Once the fix rounds the prompt names are used up, it asks you on the task's
card: **One More Round** or **Accept As It Is**. With the Oracle on, a merge also needs the Oracle's
yes that the review prompt, the task's verdicts and your answers allow it.

#### The end is yours

In a broadcast set up with these steps, every task ends where the Task step says, and only you
change it: `create_task` and `update_task` take no end there (a broadcast started before still lets
the Operator set one). When an end can't be reached, because Merge is off or a project has no connected code
host, `create_task` is refused and tells the Operator to ask you with `ask_you`. While a task runs,
its card on the board shows `ends at` and its end as a menu. A pick changes that task alone. It
clears what was under way for the old end (a merge's wait, the Oracle's refusal), keeps what already
happened (the push, the MR), and wakes the Operator. With nothing else pending, that is `[AiTerm] You changed <key>’s end to
<end>, call run_status`, with `, and the broadcast is complete` before `, call run_status` when the change
completed the broadcast. Switching to Commit after an MR opened leaves that MR for you.

#### Closing at the end

With closing ticked on the Task step, AiTerm closes every task that reached its end when the broadcast ends, once
its summary is written (or AiTerm stopped waiting for it) or when you End it. Reached its end means
published, ended with no change, or accepted on a commit end. It records the task, closes its window
and removes its worktree and row. The card stays on the board, and `read_task` still reads its diff.
Stopped tasks and MRs left for you are never closed.

- **Waits** while a turn you prompted in one of its tabs is running, while any of its tabs' agents
  is mid-turn, and while AiTerm's helper is away.
- **Keeps the task**, saying why on its card, when its worktree has uncommitted or untracked changes,
  is off its branch, has a tab outside its window, or the removal fails.
- **Git-ignored files** such as `.env` are not kept: they go with the worktree, as plain
  `git worktree remove` takes them (never forced).
- **Branches**, with that box ticked, are deleted only for a task that ended in a merge, while the
  branch still points at its accepted commit, once that commit is in the default branch (local or on
  origin) or the host merged the MR at it (a squash merge included), and with no worktree on it.

#### The goal loop

Once every task of a broadcast with a goal is done, AiTerm wakes the Operator with `[AiTerm] every task is done: check the goal
with check_goal, call run_status`, and the band reads `checking the goal`. The Operator answers with
`check_goal`: met, with evidence from each task, or not met, with what is missing. A not-met answer
with rounds left plans only what is missing; once that is done, the goal is checked again, and the
band counts the extra rounds used, `round 1 of 2`. With no round left, or 0 extra rounds, it stops,
and what is missing goes to *Left for you*. The summary waits for the check, and the band and the
Summary say how the goal went: met, not met, or not checked by the Oracle.

#### The gated shell

The Operator has a shell, but every command passes a gate first. A plain read inside the broadcast's
checkouts runs at once; push, commit, reset, checkout, clean, merges and writing `gh`/`glab api`
calls are refused outright; everything else goes to the Oracle, which runs it, sends the Operator to
a worker, or asks you. When the Oracle cannot answer, the command runs and is logged.

#### Its tools

The Operator acts only through AiTerm's MCP tools:

| For | Tool | What it does |
|---|---|---|
| Status | `run_status` | The broadcast now: every task's state, branch, last commit and what is open; set up with the New Broadcast steps, also its Agents rows, task settings, goal, `goalCheckDue` and rounds used; each task's review verdicts; the tasks closed at the end. |
| Jira | `jira_search`, `jira_board` | Read tickets and boards of the broadcast's Jira projects. |
| | `jira_create`, `jira_edit`, `jira_comment` | Create, edit and comment on tickets (Jira slice). |
| | `jira_move`, `jira_link`, `jira_sprint` | Move status, link tickets, put them in a sprint (Jira slice). |
| Plan | `create_task`, `update_task` | Add an unstarted task, or change its brief, agent, model or dependencies. Set up with the New Broadcast steps, also its reasoning, on an Agents row only, and no end: the Task step's holds, and an end that can't be reached is refused with word to ask you. Before those steps, also its end. Additions past a quarter of the first plan need the Oracle's yes. |
| | `submit_plan` | Close a plan revision; its tasks are queued at once. |
| Steer | `message_task` | Type a message into a started task's worker. |
| | `open_tab` | Add another worker tab to a task, on the same worktree; set up with the New Broadcast steps, on an Agents row, and `role` review opens a read-only review tab. |
| | `read_task` | Read a worker's last message, diff, open prompt or review; a closed task's diff from its record. |
| | `resume_task`, `retry_task` | Put a blocked task back to work; queue a failed one again. |
| Review | `record_review` | Record a review tab's verdict once its turn ended: the commit it reviewed, whether it passed by the prompt's own words, its Critical, Important and Minor findings, its fix round and how many the prompt allows. It answers the task's verdicts; it never blocks an acceptance. |
| | `review_task` | A headless agent review, kept for broadcasts started before the Agents and Task steps; in a new one, refused: review in a tab. |
| | `find_user` | Find people on the code host who may review. |
| | `request_review`, `reply_thread` | Mark the MR ready and ask reviewers; reply in a thread (Review slice). |
| Finish | `mark_task` | Record a task's outcome: accepted, no change, blocked or failed. |
| | `finish_task` | Carry out an accepted task's end: a commit, a draft MR, or a merge (Merge slice); into people's review first when the Review slice is on and the review (the Task step's prompt, or before those steps the broadcast's Review) is written. |
| | `check_goal` | Answer the broadcast's goal once AiTerm wakes it for it: met, with evidence, or not met, with what is missing. It answers complete; planMore, with the rounds left, to plan only what is missing; or stopped, not met with no rounds left, what is missing going to *Left for you*. The Oracle's no refuses it: check the goal again. |
| You | `ask_you`, `resolve_question` | List a question under *Waiting on you* (`about` fixRounds for a task out of fix rounds, answered on its card); close it once answered, or withdraw the Operator's moot question or gate with a reason. |
| Record | `report_find`, `report_snag` | Note an off-brief find (filed in Jira with the slice on); note an AiTerm glitch. |
| | `leave_for_you`, `log_decision` | Note what a slice kept it from; log a decision it took. |
| | `write_summary` | Write the broadcast's summary once it is complete and its goal checked. |

### Integrations

The connections AiTerm needs (Core) and the services it reads and writes (Services). Each card
tests itself as you type; tokens are kept in the Keychain, and **Disconnect** removes them.

- **iTerm2**: the Python helper's connection, with numbered steps when it is not working.
- **Mac**: Backpack Mode (⌘B) keeps the Mac awake with the lid shut while agents work, joined to
  your iPhone's hotspot. It turns itself off two minutes after the last agent stops, or when the
  battery reaches 10 %. It needs two permissions: **Lid sleep** (the sudoers rule, one password
  prompt) and **Network discovery** (Location access, which macOS needs to show Wi-Fi names; AiTerm
  never reads where you are). **Allow…** grants them, **Remove** takes the rule out.
- **Jira** (site URL, email, API token): New Task picks a ticket, names the task and branch after
  it, and with *Include Jira ticket details* puts the ticket in the agent's first prompt. A
  broadcast's prompt brings in the tickets it names.
- **GitLab** (host URL, access token): [reviews](#concepts) of merge requests and the
  [Operator's](#operator) MRs. Reading needs `read_api`; opening or merging needs `api`.
- **GitHub** (access token, github.com only): the same for pull requests. Reading needs read access
  to pull requests; opening or merging needs write access to pull requests and contents, and read
  access to administration for branch protection.

### Interface

How the sidebar and AiTerm's terminal windows look.

- **Use dark terminal background**: paints AiTerm's terminal windows `#1E1E1E`; your iTerm2
  profiles stay unchanged.
- **Sidebar size**: Actual Size, Large or Extra Large; also ⌘+, ⌘− and ⌘0.
- **Sidebar badges**: show or hide the Jira project count on project headers, and the Jira ticket
  key, merge request number and lines changed on task rows. A hidden badge leaves its mark.
- **Keyboard shortcuts**: every shortcut, read-only. The full list is in
  [docs/keyboard.md](docs/keyboard.md).

## Screenshots worth adding

The README uses `docs/desktop.png` (above). The snapshot suite
(`scripts/snapshots.sh`) already draws most of these, so each could be added from there:

- **The board while a broadcast runs** (`board-running.png`): the four columns, a request waiting
  on you, the Operator answering an agent.
- **A broadcast's Summary** (`board-summary.png`): the Operator's prose summary and what was left
  for you.
- **New Broadcast** (`new-broadcast-1.png`): name, Jira projects and projects, before the prompt.
- **Settings › Agents** (`settings-agents.png`): the three cards with their checks.
- **Settings › Operator** (`settings-operator.png`): the slices, the never lines and the Oracle.
- **Find a Fix** (`banner-find-a-fix-proposal.png`): a proposed fix with Apply.
- **Backpack Mode** (`backpack-sheet-*.png`): the sheet that joins the hotspot.
- **The Shelf** (`archive.png`): shelved tasks and an ended broadcast.

## Licence

Copyright © 2026 Laurens D'Hondt. AiTerm is free software under the
[GNU General Public License v3.0](LICENSE).

The app bundles the [`iterm2`](https://pypi.org/project/iterm2/) Python package (GPLv2 or later),
[`websockets`](https://pypi.org/project/websockets/) and
[`protobuf`](https://pypi.org/project/protobuf/) (both BSD-3-Clause). Claude, Codex, PI, Jira,
GitLab and GitHub names and logos belong to their owners and are used only to identify those tools.
