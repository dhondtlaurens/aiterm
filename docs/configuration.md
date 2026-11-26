# Configure AiTerm

Open **AiTerm › Settings…** (⌘,) to configure agents, the Operator, integrations and the interface.
For installation and a first task, start with the [README](../README.md#install).

**Save** applies every switch and field in Settings. Installing, repairing and **Run check** take
effect immediately; **Cancel** does not undo them. Sidebar size previews immediately, and Cancel
restores its previous size. The Mac card's **Allow…** and **Remove** permission actions also apply
immediately.

## Agents

AiTerm supports each agent at one of two levels:

| | Basic | Full |
|---|---|---|
| Start and resume tasks and tabs, with a model, reasoning and skills | ✓ | ✓ |
| Status from the agent's own hooks, and the context ring | ✓ | ✓ |
| The Oracle | ✓ | ✓ |
| Install, repair and test from Settings, and the compatibility check | ✓ | ✓ |
| Status checked against a regular reading, including "needs input" | | ✓ |
| Verified messaging: AiTerm types into the agent | | ✓ |
| Operator workers: the Operator gives it tasks, guards its branch and reads its replies | | ✓ |

Claude Code, Codex and Antigravity CLI have full support; PI has basic support. Other providers,
such as Grok, run through PI. Account usage and background work show for the agents that report
them: Claude Code and Codex.

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
signed-in providers; run `/login` in PI if none are available. Antigravity lists the models its
signed-in account offers (`agy models`), each with its effort in its name, so it offers no separate
reasoning level; run `agy` once to sign in.

**Codex tasks run with `--dangerously-bypass-approvals-and-sandbox`, and Antigravity tasks with
`--dangerously-skip-permissions`.** Antigravity's driver adds a named hook, `aiterm`, to
`~/.gemini/config/hooks.json` and sets its status line in `~/.gemini/antigravity-cli/settings.json`,
keeping your own status line running beneath it. As the Oracle, Antigravity runs with rules that deny
commands, file writes, MCP servers and fetches; it can still search the web. The New Task sheet summarises
the destination before launch. An ordinary **New Review…** uses the normal agent launch command;
signal workers also use the task-branch publishing guard. See the
[Operator guide](operators.md#publishing-done-and-merging) for publishing and merge boundaries.

## Operator

Choose the Operator's Claude Code model and reasoning, the Oracle's agent/model/reasoning, and
standing instructions under **Steer the Operator**. The page explains what each role does and
when it asks you. Saved instructions reach the current chat and subsequent Oracle checks.

A **signal** watches Jira, GitLab or GitHub, starts a task per item matching its Start query and
follows your prompt until the item matches its Done query. Permitted workers and automatic merging are chosen per signal.
The Operator and Oracle answer worker questions together; questions needing you arrive in the
Operator's own chat. With the Oracle off, those answers reach you and automatic merging waits.

See [the Operator guide](operators.md) for setup, publishing guards, pause/resume, Take Over and
completion behaviour.

## Integrations

The Core group contains iTerm2 and Mac setup. Services contains optional Jira, GitLab and GitHub
connections. An ordinary local task can run without these service connections. Git operations
against remotes still use your normal Git authentication.

### iTerm2

Enable **iTerm2 › Settings › General › Magic › Enable Python API**. When iTerm2 asks whether AiTerm
may connect, allow it. Until then the sidebar's banner says **AiTerm isn’t connected to iTerm2.**,
with **Open Settings**, and Settings › Integrations › iTerm2 shows what is missing. With iTerm2 not
running it says **iTerm2 isn’t running.**, with **Open iTerm2**; when iTerm2 refuses the connection
it says **iTerm2 refused AiTerm.** and names the Automation switch to turn on.

### Jira, GitLab and GitHub

Enter service credentials in their cards. Connection tests run when Settings opens and shortly
after you finish editing the fields. **Save** stores service tokens in the Keychain.

| Service | Configuration and permissions |
| --- | --- |
| Jira | Site URL, account email and API token. Optionally link Jira projects from a project's context menu; the New Task sheet can use a ticket to fill its name and branch. |
| GitLab | Host URL and access token. Reading needs `read_api`; an Operator that merges requests needs `api`. |
| GitHub | Access token for the relevant repositories. Reading requests needs pull-request read access. An Operator that merges them needs pull-request and contents write access, plus administration read access to inspect branch protection. |

### Mac and Backpack Mode

**Backpack Mode** (⌘B) connects to your phone's hotspot and keeps the Mac awake with the lid closed.
It needs **Lid sleep** permission and **Location** access for network discovery. Configure them in
**Settings › Integrations › Mac**, or follow the setup shown when enabling Backpack Mode.

**Allow…** asks for the missing permissions. The lid-sleep permission installs
`/etc/sudoers.d/aiterm`; **Remove** on the Mac card removes that rule. Choose the hotspot and enter
its password when setting up the connection; the password is stored in the Keychain.

Backpack Mode stops at 10% battery when running on battery power. With the option to stop when agents
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

Archiving keeps the task's branch and conversations while removing its worktree. Restoring brings
it back at its reserved path. See
[rows and windows](windows.md) for close, archive, restore and reconnect behaviour.

## Show your project's test runs

AiTerm can show a test run in a task's row, such as `tests queued · #2`, `running tests · unit` or
`last tests failed · exit 1`, when your project's test runner says so. This is opt-in: a runner that
writes nothing shows nothing. While a run is queued or running it also counts as the worker at
work: its stage does not move on and the Operator is not woken as if its turn had ended, and a
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

While signals can start work, Backpack Mode cannot stop merely because agent turns ended. Pause the
Operator before choosing “until agents are done”; pending workers still
finish their current turn. This keeps source polling from starting new work after automatic sleep.
