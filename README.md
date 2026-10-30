# AiTerm

A native macOS sidebar for coding agents in real iTerm2 windows. Each task has its own Git
worktree; the Operator can plan a broadcast, start workers, review their work and carry it to the
end you choose.

<img src="docs/desktop.png" alt="AiTerm beside iTerm2, with the Operator, projects, tasks and reviews in the sidebar and the selected agent working in its own terminal window.">

AiTerm serves its maintainer's workflow. Bug reports are welcome; feature requests and pull
requests are not taken. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Install

Requires macOS 26+, iTerm2 and Python 3.11+. Enable **iTerm2 › Settings › General › Magic › Enable
Python API**.

1. Download the DMG from the [latest release](https://github.com/dhondtlaurens/aiterm/releases/latest)
   and drag AiTerm to Applications.
2. Open it. The release is self-signed; allow its first launch in **System Settings › Privacy &
   Security › Open Anyway** when macOS asks. If necessary, clear the download flag with
   `xattr -dr com.apple.quarantine /Applications/AiTerm.app`.
3. Allow AiTerm's API connection when iTerm2 asks. Until then the sidebar shows “Waiting for iTerm2…”.
4. Open **Settings › Agents** and press **Install** for each agent you use.

Use **AiTerm › Check for Updates…** for subsequent versions. To have a coding agent install it,
give it [the installation guide](docs/ai-install.md):

    Install AiTerm on this Mac by following
    https://raw.githubusercontent.com/dhondtlaurens/aiterm/main/docs/ai-install.md

## Work in the sidebar

| Item | What it does |
| --- | --- |
| Project | A GitHub, GitLab or local repository, or a plain folder. Group projects under named dividers and optionally link Jira projects. |
| Task · ⌘N | A branch and worktree under `<repo>/.worktrees/`, an agent and an iTerm2 window. `.worktreeinclude` selects ignored files to copy into new worktrees. |
| Review · ⌘R | A merge or pull request checked out in its own worktree. Its badge counts resolved review threads. |
| Terminal · ⌘T | A shell in the project folder, without a worktree. |
| Broadcast · ⌘B | One brief across selected projects, planned and steered by the Operator. One broadcast runs at a time. |
| Shelf · ⌘S | Put a task away while keeping its branch and conversations; restore its worktree later. Ended broadcasts remain here to read. |

A task can have several agent tabs sharing its worktree. Status marks distinguish working,
needs input, background work and done. Windows are tagged so reconnecting adopts them rather than
opening duplicates. Closing a task's window offers Remove or Shelve; Cancel reopens it. Quitting
AiTerm leaves iTerm2 windows and agents working. See [windows](docs/windows.md) and
[status](docs/status-model.md) for the exact behavior.

**Focus View** (⌘F) opens projects with rows waiting on you; **List View** (⌘L) opens them all.
The footer shows the selected tab's context, Mac readings and supported agents' account usage.
[Keyboard reference](docs/keyboard.md).

## Configure agents and services

Settings has four panes. Save applies edits, except agent installation and Help with problems,
which apply immediately; sidebar size previews immediately and Cancel restores it.

- **Agents:** Claude Code and Codex support status, usage and verified messaging. PI supports
  manually started tasks and tabs, context reporting and the Oracle. Other providers such as Grok
  run through PI. Install/Repair manages each driver with backups; Messaging's Run check uses
  isolated agent sessions to verify delivery for the installed version.
- **Operator:** choose its Claude Code model/reasoning, optional Jira/Review/Merge slices, house
  instructions and the Oracle agent/model/reasoning. See [the Operator guide](docs/operators.md).
- **Integrations:** iTerm2, Mac, Jira, GitLab and GitHub. Service tokens live in the Keychain.
  GitLab reads need `read_api`, writes `api`; GitHub needs permissions for the relevant repository
  operations and administration read access for branch protection.
- **Interface:** dark terminal background, sidebar size and badges. Sidebar zoom also uses
  ⌘+, ⌘− and ⌘0; sheets retain native control sizes.

**Codex tasks run with `--dangerously-bypass-approvals-and-sandbox`.** The command preview shows
this before launch. Review tabs use the separate read-only review command.

**Help with problems** offers Find a Fix for supported Git failures. Claude inspects an isolated
clone and proposes a fix; Apply checks and lands it before retrying the failed action.

**Unplugged** (⌘U) joins your phone's hotspot and keeps the Mac awake with its lid shut. It requires
Lid sleep permission and Location access for network discovery. It stops at 10% battery and, when
configured, two minutes after the last agent stops.

## Local data

AiTerm writes its workspace and logs under `~/Library/Application Support/AiTerm/`, task worktrees
under each repository, and agent integration files only when you install their drivers. The helper
listens on `127.0.0.1:47821` for hook telemetry. Allowing Lid sleep installs
`/etc/sudoers.d/aiterm`; the Mac card can remove it. See [data ownership](docs/architecture.md#what-aiterm-writes-and-where).

## Develop

Use a Git worktree and Swift 6.4 through [Swiftly](https://www.swift.org/install/macos/).

```sh
scripts/make-app.sh       # build and sign build/AiTerm.app, without launching
scripts/test.sh          # checks selected from this branch's changes
scripts/test.sh all      # complete automated gate before merging
scripts/run-dev.sh       # replace the running AiTerm with the development build
```

`run-dev.sh` quits the running app and replaces its helper. Development and installed builds share
state and connections; schedule that switch when existing work permits it. A DEV build does not
self-update. Never run a second live copy alongside the installed app.

Read [architecture](docs/architecture.md), [testing](docs/testing.md),
[script reference](scripts/README.md), [UI rules](app/Sources/AiTermUI/README.md) and
[release procedure](docs/workflow/release.md). [AGENTS.md](AGENTS.md) contains the repository's working rules.

## Licence

Copyright © 2026 Laurens D'Hondt. Licensed under [GNU GPL v3.0](LICENSE).
The app bundles `iterm2` (GPLv2 or later), `websockets` and `protobuf` (BSD-3-Clause).
Vendor names and logos identify their respective tools and belong to their owners.
