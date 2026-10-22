# AiTerm

A native macOS sidebar that turns iTerm2 into a workspace for coding agents: **projects → tasks
(git worktrees) → agent tabs**, with each agent's status and usage at a glance. It drives the real
iTerm2 through its Python API — AiTerm does not embed a terminal.

<img src="docs/desktop.png" alt="AiTerm beside iTerm2: the sidebar lists a home folder and the aiterm (GitHub) and acme projects under Personal and Work dividers, with Claude Code, Codex and PI tasks and a merge-request review, and its footer the selected task's context and tokens, the Mac's load in backpack mode and the agents' usage; beside it, the selected task's iTerm2 window shows Claude Code mid-refactor">

> AiTerm is built for its maintainer's own workflow. Bug reports are welcome; feature requests and
> pull requests are not taken. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Features

- **Tasks from a Jira ticket or a prompt**: AiTerm creates the worktree and branch, copies the
  gitignored files `.worktreeinclude` names, opens an iTerm2 window and launches the agent.
- **Every agent's state at a glance**: working, needs input or done, from Claude Code, Codex
  and PI, with context and account usage in the footer. Claude Code and Codex are fully supported;
  other providers, such as Grok, work through PI.
- **Reviews**: a GitLab merge request or a GitHub pull request in its own worktree, its resolved
  review threads counted on the row.
- **Backpack Mode** (⌘B): keeps the Mac awake with the lid shut and on your iPhone's hotspot while
  agents work, and turns itself off when they stop.
- **The Shelf** (⌘S): puts a task away. Its worktree goes and its branch stays; restoring brings
  back the worktree and its conversations.
- **Windows that come back**: after a crash, a reboot or iTerm2 quitting, every task's window
  reopens with its conversations.
- **Focus View** (⌘F): only the projects with a row waiting on you, which the Dock badge counts.
- **Keyboard-first**: the arrows peek at each row's window without leaving the sidebar. Every key
  is in [docs/keyboard.md](docs/keyboard.md).

<details>
<summary>What each agent and project supports</summary>

What the sidebar knows depends on what each agent reports:

| | Claude Code | Codex | PI |
|---|:---:|:---:|:---:|
| Status: working, needs input, done | ✓ | ✓ | ✓ |
| Reported through | HTTP hooks | hooks, `Stop` over MCP | an extension |
| A second source, should a hook go missing | its session file | the tab title's spinner | — |
| Stays working while a subagent runs | ✓ | ✓ | ✓ (pi-subagents) |
| Context fill | ✓ | ✓ | ✓ |
| Account usage in the footer | ✓ | ✓ | — |
| Model and reasoning picked per task | ✓ | ✓ | ✓ |
| Skills and commands completed in the first prompt | `/` | `$` and `/prompts:` | `/skill:` |
| Conversations resumed when a window comes back | ✓ | ✓ | ✓ |
| Folder-trust dialog shown as needs input | ✓ | — | — |

What a project can do depends on where it lives:

| | GitLab | GitHub | Plain git | Folder |
|---|:---:|:---:|:---:|:---:|
| Tasks in their own worktree, from a Jira ticket or a prompt | ✓ | ✓ | ✓ | — |
| Branch and diff badge on each task | ✓ | ✓ | ✓ | — |
| Reviews of a merge or pull request | ✓ | ✓ | ✓¹ | — |
| Resolved review threads on a review's row | ✓ | ✓ | ✓¹ | — |
| Terminals | ✓ | ✓ | ✓ | ✓ |

GitLab means the one host set in *Settings › Integrations*. ¹ Only when the remote is on that host:
a self-hosted GitLab that AiTerm cannot tell from plain git.

</details>

## Requirements

- macOS 26 or newer
- iTerm2 with its Python API enabled (*Settings › General › Magic › Enable Python API*)
- `python3` 3.11 or newer (`brew install python`) — AiTerm runs its bundled helper with it

## Install

Download the DMG from the [latest release](https://github.com/dhondtlaurens/aiterm/releases/latest),
drag **AiTerm** to Applications and open it. The release is self-signed, so macOS refuses the first
launch: allow it once in *System Settings › Privacy & Security › Open Anyway*. If you copied the app
some other way, clear the download flag first — a quarantined app runs from a temporary copy, and
AiTerm then skips the Claude status line: `xattr -dr com.apple.quarantine /Applications/AiTerm.app`.
After that, *AiTerm › Check for Updates…* installs newer versions in place.

iTerm2 asks once to allow AiTerm's API connection; the sidebar shows "Waiting for iTerm2…" until
you do.

### Let your AI set it up

Paste this into Claude Code, Codex or another coding agent:

    Install AiTerm on this Mac for me by following
    https://raw.githubusercontent.com/dhondtlaurens/aiterm/main/docs/ai-install.md

The agent checks the requirements, then downloads the latest release and verifies its checksum. It
copies the app to Applications, clears the download flag so macOS doesn't ask you to *Open Anyway*,
and switches on iTerm2's Python API. It asks before installing a missing requirement, with or
without Homebrew. It stops
for the clicks only you can make, such as iTerm2's permission dialog and the agent hooks in
Settings. The steps it follows are in [docs/ai-install.md](docs/ai-install.md).

## What AiTerm changes on your machine

- **Agent hooks** — nothing until you press **Install** on an agent's card in *Settings › Agents*;
  until then that agent's status does not reach the sidebar. Install merges hooks into
  Claude's `settings.json` under the login shell's `$CLAUDE_CONFIG_DIR` (default `~/.claude`)
  or `~/.codex/config.toml`, or writes the PI extension, and adds a status-line bridge
  for Claude usage. A backup is kept next to every file it edits; the same card repairs or
  reinstalls them.
- **A local port** — the helper listens on `127.0.0.1:47821` for those hooks.
- **Backpack Mode** — nothing until you press **Allow…** on the Mac card in *Settings › Integrations*
  (or in the Backpack Mode sheet). That installs the sudoers rule `/etc/sudoers.d/aiterm`, which lets
  AiTerm turn lid sleep off and on with `pmset`, after an admin password prompt; **Remove** on the
  same card takes it out again.
- **Worktrees** — one per task, under `<repo>/.worktrees/`.
- **Its own state and log** — `~/Library/Application Support/AiTerm/`.

The full list is in [docs/architecture.md](docs/architecture.md#what-aiterm-writes-and-where).

> **Codex runs without approvals.** New Codex tasks launch with
> `--dangerously-bypass-approvals-and-sandbox`, which disables Codex's approval prompts and
> sandbox. The New Task command preview shows the flag before anything runs.

## Settings

**Agents** — each agent's CLI, default model and reasoning. **Integrations** — Core (the
iTerm2 connection, and the Mac: lid sleep and network discovery for Backpack Mode), then Jira, GitLab and
GitHub credentials (stored in the Keychain). **Interface** — terminal background, sidebar size,
badges and keyboard shortcuts.

## Known gaps

If you decline iTerm2's permission dialog, or revoke it later, the sidebar stays on "Waiting for
iTerm2…". AiTerm cannot ask again: re-enable the Python API in iTerm2's settings and relaunch
AiTerm.

## Build from source

Needs Swift 6.4 through [Swiftly](https://www.swift.org/install/macos/)
(`swiftly install --use 6.4`); the Command Line Tools compiler is not supported.

    scripts/run-dev.sh    # build build/AiTerm.app and open it in place of the installed one
    scripts/test.sh       # the daemon and Swift suites this branch's changes can affect
    scripts/test.sh all   # every suite

A local build is a dev build: a DEV pill on its Dock icon, and no self-update. More in
[scripts/README.md](scripts/README.md); how it works in [docs/architecture.md](docs/architecture.md)
and [docs/status-model.md](docs/status-model.md); the design system in
[app/Sources/AiTermUI/README.md](app/Sources/AiTermUI/README.md).

## Licence

Copyright © 2026 Laurens D'Hondt. AiTerm is free software under the
[GNU General Public License v3.0](LICENSE).

The app bundles the [`iterm2`](https://pypi.org/project/iterm2/) Python package (GPLv2 or later),
[`websockets`](https://pypi.org/project/websockets/) and
[`protobuf`](https://pypi.org/project/protobuf/) (both BSD-3-Clause). Claude, Codex, PI,
Jira, GitLab and GitHub names and logos belong to their owners and are used only to identify those
tools.
