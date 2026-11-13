# Configure AiTerm

Open **AiTerm › Settings…** (⌘,) to configure agents, the Operator, integrations and the interface.
For installation and a first task, start with the [README](../README.md#install).

**Save** applies settings edits. Agent installation/repair and **Help with problems** take effect
immediately; **Cancel** does not undo them. Sidebar size previews immediately, and Cancel restores
its previous size. The Mac card's **Allow…** and **Remove** permission actions also apply immediately.

## Agents

Claude Code and Codex support agent status, account usage and verified messaging. PI supports
manually started tasks and tabs, context reporting and use as the Oracle. Other providers, such
as Grok, run through PI. The Operator's workers use Claude Code or Codex.

Settings tests each agent when it opens. On the agent's card:

- **Install** adds a missing CLI using its vendor's installer, then installs AiTerm's driver.
- **Repair** repairs the integration; **Reinstall** lets you reinstall a driver that is already ready.
  Driver changes keep backups and preserve integration entries AiTerm does not own.
- Messaging's **Run check** opens isolated agent sessions in iTerm2 to verify that AiTerm can
  deliver messages to the installed version. It takes a few minutes. **Why it failed** expands the
  details of a failed check.
- A muted line says whether the installed version's major and minor is one this AiTerm was checked
  with ("2.1 verified with this AiTerm"), or not yet. Nothing waits on it: a newer version usually
  works, and Messaging stays what decides whether AiTerm types into the agent.
- Choose a default model and reasoning level from the available catalogue. Each new task can
  choose its own agent, model and reasoning.

Sign in through your chosen agent's CLI as needed. AiTerm uses that agent's account and access;
installing an agent does not supply a subscription or API credentials. PI lists models from its
signed-in providers; run `/login` in PI if none are available.

**Codex tasks run with `--dangerously-bypass-approvals-and-sandbox`.** The New Task sheet previews
the command before launch. An ordinary **New Review…** uses the normal agent launch command;
the Operator's review tabs use separate read-only launch restrictions. See the
[Operator guide](operators.md#workers-review-and-acceptance) for those restrictions.

### Help with problems

Enable **Help with problems** in Agents to offer **Find a Fix** for supported Git failures, such
as a diverged branch or a conflicted rebase. It requires Claude Code and uses the Operator's model
and reasoning settings.

Claude inspects an isolated clone and proposes a fix. **Apply** checks and lands the proposed fix
before retrying the failed action. Nothing in the project changes until you press Apply.

## Operator

Choose the Operator's Claude Code model and reasoning, its house instructions and the Oracle's
agent, model and reasoning. Optional Jira, Review and Merge capabilities, called slices, determine
which service actions it may take.

A **broadcast** is one brief across selected projects. Its setup chooses permitted workers and
review agents, review instructions, where tasks end and an optional goal. Only one broadcast runs
at a time. The Oracle can critique decisions and judge whether a goal has been met.

See [the Operator guide](operators.md) for setup, prerequisites, authority, review, pause/resume,
takeover and completion behaviour.

## Integrations

The Core group contains iTerm2 and Mac setup. Services contains optional Jira, GitLab and GitHub
connections. An ordinary local task can run without these service connections. Git operations
against remotes still use your normal Git authentication.

### iTerm2

Enable **iTerm2 › Settings › General › Magic › Enable Python API**. When iTerm2 asks whether AiTerm
may connect, allow it. Until then AiTerm shows “Waiting for iTerm2…”.

### Jira, GitLab and GitHub

Enter service credentials in their cards. Connection tests run when Settings opens and shortly
after you finish editing the fields. **Save** stores service tokens in the Keychain.

| Service | Configuration and permissions |
| --- | --- |
| Jira | Site URL, account email and API token. Optionally link Jira projects from a project's context menu; the New Task sheet can use a ticket to fill its name and branch. |
| GitLab | Host URL and access token. Reading needs `read_api`; an Operator that opens or merges requests needs `api`. |
| GitHub | Access token for the relevant repositories. Reading requests needs pull-request read access. An Operator that opens or merges them needs pull-request and contents write access, plus administration read access to inspect branch protection. |

### Mac and Unplugged

**Unplugged** (⌘U) connects to your phone's hotspot and keeps the Mac awake with the lid closed.
It needs **Lid sleep** permission and **Location** access for network discovery. Configure them in
**Settings › Integrations › Mac**, or follow the setup shown when enabling Unplugged.

**Allow…** asks for the missing permissions. The lid-sleep permission installs
`/etc/sudoers.d/aiterm`; **Remove** on the Mac card removes that rule. Choose the hotspot and enter
its password when setting up the connection; the password is stored in the Keychain.

Unplugged stops at 10% battery when running on battery power. With the option to stop when agents
stop, it turns off two minutes after the last working agent stops while the lid is closed. An open
lid keeps that countdown from expiring.

## Interface

Choose whether to match iTerm2's terminal background to AiTerm's dark appearance, set the sidebar
size and choose which badges appear. AiTerm is dark-only.

Sidebar zoom also uses ⌘+, ⌘− and ⌘0. Sheets keep native control sizes while the sidebar zooms.
**Focus View** (⌘F) opens projects with rows waiting on you; **List View** (⌘L) opens them all.
See the [keyboard reference](keyboard.md) for other shortcuts.

## Files in task worktrees

New tasks have a branch and a checkout under `<repo>/.worktrees/`. Tabs within one task share that
checkout. A plain folder can have terminals, but tasks require a Git repository.

To copy ignored local files into new worktrees, add a `.worktreeinclude` file at the repository's
root. It uses `.gitignore` patterns to select files that already exist in the project checkout
and that Git ignores, such as `.env` or local certificates. It does not make them tracked.
The Task step lets you turn off copying for that task. Existing destination files are kept.

Shelving keeps the task's branch and conversations while removing its worktree. Restoring brings
it back at its reserved path. Ended broadcasts remain readable on the Shelf. See
[rows and windows](windows.md) for close, shelve, restore and reconnect behaviour.

## Show your project's test runs

AiTerm can show a test run in a task's row, such as `tests queued · #2`, `running tests · unit` or
`last tests failed · exit 1`, when your project's test runner says so. This is opt-in: a runner that
writes nothing shows nothing. While a run is queued or running it also counts as the worker at
work, so the Operator does not flag a worker that waits on a long suite as possibly stalled, and a
pause waits for the run.

A runner reports a run through one record file in `/tmp/aiterm-test.lock.runs/`:

1. Pick a run id that is unique on this Mac, such as a UUID.
2. Open `<run id>.lock` in that folder and take an exclusive `flock` on it. Keep it open, and keep
   holding it, until the run is over. Pass it on to the test processes: a lock held by a child
   that outlives the runner still counts as the run being alive.
3. Write `<run id>.json`, and rewrite it whenever the state changes. Write to a temporary file in
   the same folder, then rename it over the record, so AiTerm never reads half a file.
4. When the run ends, write the `completed` state with its exit code and finish time, then close
   the lock.

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | no | `1`. A record with another version is ignored. |
| `run_id` | yes | The run id, as in the file names. |
| `root` | yes | The absolute path of the checkout the run tests, usually the task's worktree. |
| `suite` | yes | A short name for what runs, such as `unit`. |
| `state` | yes | `queued`, `running` or `completed`. |
| `exit_code` | with `completed` | The run's exit code. |
| `finished_at` | with `completed` | Unix time in seconds when the run ended. Without it, a finished record is dropped as soon as its lock is released. |
| `queued_at` | no | Unix time in seconds when the run was queued. |
| `ticket` | no | A number giving a queued run's place, lowest first. |

The record belongs to the agent tab whose folder is inside `root`. When several tabs share that
worktree, it belongs to the task's first tab. A `queued` or `running` record whose lock nobody holds
reads as interrupted. AiTerm picks up a finished record for five minutes after it ends, and the tab
keeps its last result until its agent restarts. The folder is shared by every
project on the Mac, so a queued run names the run that is holding the queue.

macOS has no `flock` command. A runner written in shell can take the lock with a few lines of Python
or Perl. AiTerm's own [`scripts/test-queue.py`](../scripts/test-queue.py) is a complete writer:
it runs one suite at a time across worktrees and reports each run this way.

## Local data

Workspace state and logs live under `~/Library/Application Support/AiTerm/`. Task worktrees live
under their repositories. Installing agent drivers writes integration files in the agents'
configuration directories with backups. Service credentials and the hotspot password live in the
Keychain.

The helper listens on `127.0.0.1:47821` for hook telemetry. The
[data ownership reference](architecture.md#what-aiterm-writes-and-where) lists the files and local
transports AiTerm uses. Agent requests use the selected provider's services and configuration.
