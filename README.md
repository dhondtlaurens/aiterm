# AiTerm

Keep your coding agents organised across projects. AiTerm is a native macOS sidebar for
**Claude Code and Codex** in real iTerm2 windows. Run tasks in separate Git worktrees, see which
agents need your attention, and coordinate changes across repositories.

[Download the latest release](https://github.com/dhondtlaurens/aiterm/releases/latest)
· [Install](#install) · [Try your first task](#try-your-first-task) · [Configuration](docs/configuration.md)

<img src="docs/desktop.png" alt="AiTerm beside iTerm2, with the Operator, projects, tasks and reviews in the sidebar and the selected agent working in its own terminal window.">

*Projects and tasks stay in the sidebar; the selected task opens in its own iTerm2 window.*

## What you can do

### Give each task its own workspace

Work on a fix and a feature at the same time, each on its own branch and checkout. AiTerm creates
the task's Git worktree under `<repo>/.worktrees/` and opens its agent in iTerm2.

### Use several agents on one task

In a task's iTerm2 window, press ⌘T and start another agent, such as `claude` or `codex`.
Tabs share the task's worktree, so they work with the same files. Quitting AiTerm leaves your
iTerm2 windows and agents running.

### See what needs your attention

Status marks show working agents, requests for input, background work and unread completed turns.
**Focus View** (⌘F) opens projects with rows waiting on you; **List View** (⌘L) opens them all.
The footer shows the selected tab's context, Mac readings and supported agents' account usage.

### Start and steer work from signals

Create a **Signal** (⌘S) for matching Jira tickets, reviews asked of you, or your merge requests
that need a reply. The **Operator** starts a task for each item in its existing project, gives the
worker your prompt and follows its done condition. The Oracle helps answer worker questions;
questions for you arrive in the Operator's chat. Choose the permitted agents and what happens
when work finishes. See [the Operator guide](docs/operators.md).

### Bring reviews into your workspace

Open a branch or merge/pull request with **New Review…** (⌘R). It gets a review worktree, or opens
in the existing task when that branch is already checked out there. Review badges count resolved
threads. Signals can also start reviews when a host asks you to review.

### Put work aside and pick it up later

**Archive** a task to keep its branch and conversations while removing its worktree. Open the
**Archive** (⌘A outside a text field) to restore it later. See
[rows and windows](docs/windows.md) for closing, restoration and reconnect behaviour.

## Install

Requires **macOS 26+**, **iTerm2** and **Python 3.11+**. Enable
**iTerm2 › Settings › General › Magic › Enable Python API**.

1. Download the DMG from the [latest release](https://github.com/dhondtlaurens/aiterm/releases/latest)
   and drag AiTerm to Applications.
2. Open it. The release is self-signed; allow its first launch in **System Settings › Privacy &
   Security › Open Anyway** when macOS asks. If necessary, clear the download flag with
   `xattr -dr com.apple.quarantine /Applications/AiTerm.app`.
3. Allow AiTerm's API connection when iTerm2 asks. Until then the sidebar says AiTerm isn’t connected to iTerm2, and Settings › Integrations › iTerm2 shows what is missing.
4. Open **Settings › Agents** and press **Install** for each agent you use. This installs a missing
   CLI and AiTerm's driver. Sign in through the chosen agent's CLI as needed; you use your own agent
   account or API access.

**Codex tasks run with `--dangerously-bypass-approvals-and-sandbox`.** The task sheet summarises the
destination before launch. Ordinary **New Review…** uses the normal agent command. Signal workers also run with publishing
guards on their own task branch. [Agent configuration](docs/configuration.md#agents).

Use **AiTerm › Check for Updates…** for subsequent versions. To have a coding agent install it,
give it [the installation guide](docs/ai-install.md):

    Install AiTerm on this Mac by following
    https://raw.githubusercontent.com/dhondtlaurens/aiterm/main/docs/ai-install.md

## Try your first task

Start with an existing Git repository that has a committed base branch, and an installed agent.
Jira, GitHub and GitLab service connections are optional for this task.

1. Choose **File › Add Project…** (⌘P) and select your repository folder.
2. Select its project in the sidebar, then choose **File › New Task…** (⌘N).
3. In **Ticket**, pick a ticket or continue without one.
4. In **Name and branch**, enter “Explain the test setup”, check the branch and choose a base branch.
5. In **Prompt**, write: “Find the test commands for this project and explain how to run them.”
6. In **Agent**, choose the agent, model and reasoning. Check the destination and closing box, then
   press **Create Task**.

Your task appears in the sidebar with its own branch, worktree and iTerm2 agent window. Select it
to return to that window, and answer any agent sign-in or folder-trust prompt there.
To start work automatically from Jira or a code host, [create a signal](docs/operators.md#create-a-signal) (⌘S).

## More ways to work

- **Organise your projects:** add GitHub, GitLab or local repositories and plain folders. Group
  them under named dividers and optionally link Jira projects.
- **Open a shell:** **New Terminal…** (⌘T) starts in the project folder without creating a worktree.
- **Bring local files along:** `.worktreeinclude` selects ignored files, such as `.env`, to copy
  into new task worktrees. [Worktree files](docs/configuration.md#files-in-task-worktrees).
- **Use other providers:** PI supports manually started tasks and tabs, context reporting and the
  Oracle; providers such as Grok run through PI. [Agents](docs/configuration.md#agents).
- **Keep work running with the lid closed:** **Backpack Mode** (⌘B) joins your phone's hotspot and needs
  Lid sleep permission and Location access for network discovery. It stops at 10% battery and can
  stop after your agents finish. [Backpack Mode setup](docs/configuration.md#mac-and-backpack-mode).

See [configuration](docs/configuration.md) for settings, integration permissions and agent checks;
the [keyboard reference](docs/keyboard.md), [window guide](docs/windows.md) and
[status guide](docs/status-model.md) cover everyday controls and behaviour.

## Local data

AiTerm keeps workspace state and logs under `~/Library/Application Support/AiTerm/`, task worktrees
under each repository, and service tokens in the Keychain. Installing agent drivers writes their
integration files with backups. Agent requests use your chosen provider's services and configuration.
See [data ownership](docs/architecture.md#what-aiterm-writes-and-where) for exact files, local
transports and the optional lid-sleep rule.

## Help and project scope

Found a problem? [Report a bug](https://github.com/dhondtlaurens/aiterm/issues/new?template=bug_report.yml).
For a security issue, use [private vulnerability reporting](https://github.com/dhondtlaurens/aiterm/security/advisories/new).

AiTerm is built for its maintainer's workflow. Bug reports are welcome; feature requests and pull
requests are not taken. [CONTRIBUTING.md](CONTRIBUTING.md) explains what to include in a report
and how to change the app yourself.

## Develop

Use a Git worktree and Swift 6.4 through [Swiftly](https://www.swift.org/install/macos/).

```sh
scripts/make-app.sh       # build and sign build/AiTerm.app, without launching
scripts/test.sh          # checks selected from this branch's changes
scripts/test.sh all      # complete automated gate before merging
scripts/run-dev.sh       # replace the running AiTerm with the development build
```

`run-dev.sh` quits the running app, which stops its helper, and opens the development build, which
starts its own and ends one a crash left behind. Development and installed builds share
state and connections; schedule that switch when existing work permits it. A DEV build does not
self-update. Never run a second live copy alongside the installed app.

Read [architecture](docs/architecture.md), [testing](docs/testing.md),
[script reference](scripts/README.md), [UI rules](app/Sources/AiTermUI/README.md) and
[release procedure](docs/workflow/release.md). [AGENTS.md](AGENTS.md) contains the repository's working rules.

## Licence

Copyright © 2026 Laurens D'Hondt. Licensed under [GNU GPL v3.0](LICENSE).
The app bundles `iterm2` (GPLv2 or later), `websockets` and `protobuf` (BSD-3-Clause).
Vendor names and logos identify their respective tools and belong to their owners.
