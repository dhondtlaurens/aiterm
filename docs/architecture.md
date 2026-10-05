# Architecture & data flow

AiTerm does not embed a terminal. It drives the real iTerm2 over iTerm2's own Python API, from a
supervised Python daemon, and shows the result in a native sidebar window snapped to the left of
the screen. Everything the sidebar knows — which agent is in which tab, what it is doing, which
branch it is on, how much quota is left — comes back through that daemon.

## Outbound · the sidebar drives iTerm2

```
AiTerm.app  ──JSON-RPC over a Unix socket──>  aitermd  ──iTerm2 Python API (the official lib)──>  iTerm2
```

- **AiTerm.app** — Swift 6.4 in the Swift 6 language mode, SwiftUI + AppKit, macOS 26.
  `SidebarView` renders, `AppController` keeps the saved workspace and the workflows, and six
  owners hold the live state (below). `DaemonSupervisor` starts the daemon and restarts it with
  backoff — or *adopts* one an earlier run left behind.
- **aitermd** — Python ≥ 3.11, vendored into the bundle. One asyncio process: the RPC server, the
  iTerm2 bridge, the hook server and the status engine. It quits a minute after the last app
  detaches. The app locates a real `python3` through a login shell, falling back to the well-known
  Homebrew and python.org paths, and verifies each candidate by running that exact file — never
  its name through a shell.
- **iTerm2** — 3.7.x, Python API enabled. Raises its own permission dialog on first connect. The
  daemon pays for each connection with a single-use cookie the app asks iTerm2 for
  (`iterm.cookieRequested`), so no `osascript` runs under AiTerm. Each API call the daemon makes is
  bounded at 10 s. One window per task or terminal, framed by `async_set_frame` to the right of the
  sidebar on create, on select and when the screen changes.

## Inbound · the agents report back

```
Claude Code, Codex, Grok Build & PI  ──HTTP POST 127.0.0.1:47821──>  HookServer → StatusEngine  ──events broadcast to clients──>  the sidebar redraws
```

- **Claude Code & Codex** — running in those iTerm2 tabs. Lifecycle hooks are merged into
  `~/.claude/settings.json` and `~/.codex/config.toml` by the agent's Install action in
  Settings › Agents — merge-only, with a backup, because Emdash owns hook slots in the same files.
- **Grok Build** — command hooks, because Grok refuses `http://` hook URLs. AiTerm owns its whole
  hooks file, `~/.grok/hooks/aiterm.json`, rather than merging into one Emdash also touches; the
  status line is a merge into `~/.grok/config.toml`'s `[ui.status_line]` table, same as the others.
- **HookServer → StatusEngine** — `/hook/claude` · `/hook/codex` · `/hook/grok` · `/hook/pi` ·
  `/mcp` · `/statusline` · `/statusline/grok`. A post is acknowledged before it is handled, so no
  agent waits on the daemon — with two exceptions. A Harness Test post carrying `_aiterm_test_id`
  is answered once handled, which is its proof of delivery, and never changes state. A `/mcp`
  tool call (Codex's Stop hook) is delivered before its result goes back. The `SessionResolver`
  maps a post to a tab (by pid or the tab id the hook carries, then the tab that conversation was
  pinned to, then by directory); the status engine applies its state transition and its metadata
  separately, and keeps the per-session state machine — including subagents, so a row stays
  *working* while a background child runs.
- **The sidebar redraws** — status dot · avatars · branch · usage. A session change that moves a
  tab — its id, directory, window, tab index, task or project — also re-resolves every tab's
  branch, off the main actor. That is a `stat` of each directory's `HEAD` file — in a reftable
  repository, of its ref stack's `tables.list` — and git runs only the first time a directory is
  seen. A new context fill, state or model does not rescan, and a context fill, model or tab title
  does not redraw the rows either: they read `LiveSessions.rowSessions`, which leaves those out.

## Inside the app

`AppController` keeps what is saved and what the person is doing: the workspace, the sheets,
toasts, and every project, task, terminal and review workflow. The live state has one
owner each, reached as a property of the controller. Views read the owners directly.

| Owner | On the controller | What it holds |
|---|---|---|
| `InterfacePreferences` | `preferences` | the Interface tab's settings, saved on every write |
| `AgentIntegrations` | `agents` | which agent CLIs the login shell finds, the Claude status-line shim, the Settings harness model |
| `SidebarTiling` | `tiling` | the sidebar window, its saved frame, and the terminal windows tiled beside it |
| `RowFocus` | `focus` | the selected row — a project header, a task or a terminal — and the request that brings its window forward — a click, Return, a peek — each returned as its `Task` |
| `LiveSessions` | `live` | every tab the daemon reports, usage, and each row's last context fill |
| `CheckoutMonitor` | `checkouts` | branches, missing checkouts and diff badges; the pass on every session change a scan reads, and 2 s after the last pass ends |
| `HelperLink` | `helper` | the daemon process, the socket to it, how far the chain to iTerm2 reaches, and the titles already sent |

Every request the app makes goes through `DaemonCommands`. `DaemonClient` sends it over the
socket; the app's tests record it in process instead.

## Inside the daemon

`Service` is the composition root: it builds the registry, the status engine and the usage store,
wires the three parts below to them, registers every RPC handler and runs the 2 s tick.

| Module | What it owns |
|---|---|
| `connection.py` · `ItermSupervisor` | connect, reconnect, auth backoff and cookie requests; every `iterm.*` event |
| `windows.py` · `WindowManager` | task and terminal windows, their tabs, tagging a tab the user opens in one, titles and the background |
| `hook_router.py` · `HookRouter` | a hook post, placed on a tab and applied to status or usage |
| `publisher.py` · `Publisher` | `session.changed` and `usage.changed`, rendered when sent, for the router and the tick alike |
| `rpc_params.py` | reading parameters, and the errors every handler answers the same way |
| `iterm_bridge.py` | the only module that imports `iterm2` |
| `__main__.py` · `IdleWatchdog` | quitting once no app has been attached for a minute |

## Commands the app sends

| Command | What it does |
|---|---|
| `workspace.snapshot` | the bootstrap: protocol version, whether iTerm2 is connected, `itermVersion`, `itermAuthError`, `itermCookieRequest` (a cookie request made before the app attached), every session, usage — written before any later event |
| `window.createTask` | new window in a worktree, launching the agent command; a retry returns the existing window. Once iTerm2 has made a window it is returned, even if tagging it, typing the command or the tick after fails — that is logged, since an error would make the app open a second one. The new window is found through the same locked refresh as every tick, never one that overlaps a tick's. Only a window whose shell ended at once is answered `iterm_unavailable` |
| `window.createTerminal` | new window in the project folder, no agent |
| `window.activate` | bring it forward when its row is clicked |
| `window.setFrame` | re-snap beside the sidebar |
| `window.close` | on remove, and before a worktree is deleted. The window is closed once iTerm2 has answered: a failed tick after it is logged, not answered |
| `tab.create` | a tab in an existing window, tagged like it: in `cwd` when given (a review opened in its task), else where the active tab is |
| `sessions.setTitles` | branch titles for AiTerm tabs, re-sent every couple of seconds; the daemon only applies changes |
| `sessions.markSeen` | clear a done mark when its row is opened |
| `interface.setMatchItermBackground` | paint AiTerm windows #1E1E1E |
| `iterm.provideCookie` | the answer to `iterm.cookieRequested`: a cookie and key, "not running", or why iTerm2 refused. An answer to a request that has timed out or been answered is not accepted |

`iterm.status`, `sessions.list` and `usage.get` are still served, for `python -m aitermd ctl`.
Malformed parameters are answered with `bad_params`, an iTerm2 call that fails or runs out of
time with `iterm_unavailable` — the tick a command runs before it changes anything included.

Requests are answered concurrently, each as soon as its handler returns, so a slow
`window.createTask` holds up nothing behind it. The `workspace.snapshot` reply is still written
before any later event. `sessions.setTitles`, `interface.setMatchItermBackground`,
`window.setFrame` and `window.activate` each leave a state the next one replaces, so each takes
effect in the order it was sent.

## Events the daemon broadcasts

| Event | What it means |
|---|---|
| `iterm.connected` | clears the "Waiting for iTerm2…" or "Reconnecting to iTerm2…" banner |
| `iterm.disconnected` | "Reconnecting to iTerm2…"; the daemon retries on its own |
| `iterm.auth_failed` | iTerm2 is running but refused the API cookie; an amber banner gives the reason. Retries back off to once a minute, and the snapshot's `itermAuthError` carries the reason for an app that attaches later |
| `iterm.cookieRequested` | the daemon needs a cookie for its next connect; the app asks iTerm2 with an Apple event and answers with `iterm.provideCookie`. An attached app that stays silent for 120 s is asked again, under a new id; time with no app attached does not count |
| `window.activated` | aligns the sidebar selection when iTerm2 is raised from outside — e.g. by clicking an agent's notification |
| `window.closed` | forgets the row, or clears its window during a removal |
| `session.opened` / `.changed` | a new tab, a new agent, a new state, a new model |
| `session.closed` | drops one avatar from the group |
| `usage.changed` | a status-line tick landed, or Codex wrote a new rate-limit record |

The socket is the only channel. If the daemon dies, the supervisor restarts it; from the second
failure the banner names the log at `~/Library/Application Support/AiTerm/aitermd.log`.

## Where the facts come from

| Fact | Source |
|---|---|
| status dot | agent hooks, plus Claude's own session file and the tab title's spinner glyph as corroboration |
| avatars | iTerm2's session list — one mark per tab, in tab order |
| branch | the *agent's* working directory, never iTerm2's: `session.path` is the shell's and never follows a Claude that entered a worktree |
| diff badge | `git diff --numstat` from the merge-base with the task's base, plus the untracked files' lines (at most 2,000 files and 20 MB; a file over 1 MB is skipped). Kept 5 s, inside the 2 s checkout pass; the merge-base is kept until a ref it joins moves. While the refs stand still an expiry costs two git processes per task — 40 at 20 tasks, where it was 100 |
| Claude usage | the `statusLine` shim — Claude Code hands rate limits to that command and to nothing else. It posts with `curl` to the fixed hook port and starts no `python3` |
| Codex usage | the `rate_limits` block Codex writes into every `token_count` record of its rollout file under `~/.codex/sessions` — the same file the context fill comes from, no subprocess |
| context fill | the same `statusLine` payload's `context_window`; the reporting session updates its task's last-known value, and the footer draws it only while that task is selected |
| provider icon | the git remote URL, or the repo itself |
| tickets | Jira Cloud REST, credentials in the Keychain |
| models | each CLI's own catalogue cache, so the picker follows `/model` |
| skills & commands | discovered on disk per agent and per project, for the prompt step's completions |

## What AiTerm writes, and where

**Its own state** — `~/Library/Application Support/AiTerm/state.json` — projects, tasks,
terminals, the sidebar frame, the last agent per project and the last model per agent. The legacy
`AIterm` folder is renamed on upgrade; if that fails, startup stops rather than losing it.

**Worktrees** — One per task, under `<repo>/.worktrees/<slug>`. Removing a task removes the
worktree and optionally the branch; removing a *project* only forgets it and lists the worktrees
it is leaving behind.

**Agent configuration** — Eight Claude events and six Codex events, plus the status-line command.
Merge-only, marked as AiTerm's, with `.aiterm-backup` beside each file. A file that already holds
the right hooks is not rewritten; a symlinked file stays a link and its target is merged; a link
to nothing is refused rather than replaced. The agent's card in Settings › Agents re-runs the same installer — Install, Repair or Reinstall, by its state. Grok's
eight events go to a file AiTerm owns outright, `~/.grok/hooks/aiterm.json`, written atomically
rather than merged; only its status line merges into `~/.grok/config.toml`'s `[ui.status_line]`
table, saving a foreign command to `grok-statusline-original.cmd` first. The PI extension goes to
`~/.pi/agent/extensions/aiterm-status.ts`, schema 3.

**A long first prompt** — When the typed command would pass 1000 bytes, or the prompt holds a
control character, the prompt goes to `<worktree>/.aiterm/first-prompt.md` and the command becomes
`"$(cat …)"`; `.aiterm/` is added to the repository's exclude file, best-effort. The command is
typed before the shell's line editor may be up, and a terminal in canonical mode keeps only 1024
bytes of input (`MAX_CANON`).

## Recovery, removal and appearance

AiTerm saves projects, tasks, terminal references, and sidebar placement in
`~/Library/Application Support/AiTerm/state.json`. Each save keeps the previous valid file as
`state.json.backup` before atomically replacing the primary. The backup is one previous save,
not a history. Keep only one AiTerm instance writing to this folder; concurrent writers are
unsupported.

If the workspace cannot be read, startup offers **Retry**, **Restore Backup** (when valid),
**Show in Finder**, or **Quit** before starting integrations. It never silently starts with an
empty workspace. Restoring may omit recent changes and preserves the readable original as
`state.json.recovered-<UUID>`. An unreadable original must become readable before restoration
can preserve and replace it.

A failed save leaves current changes in memory and shows **Retry Saving** in the sidebar.
New workspace changes are blocked until saving succeeds; selecting and activating existing
windows remains available. Retry saves the latest state without repeating Git or terminal
commands. Normal quit retries saving and offers **Cancel Quit** or **Quit Without Saving** if
it still fails. Choosing to quit without saving loses changes since the last successful save.

Closing a task's iTerm2 window removes its sidebar row while keeping the branch and checkout
on disk. **Reopen Window** is available for saved tasks whose window was never opened; it starts
a shell without replaying the initial agent prompt. Closing a plain terminal removes its row.
Removing a task explicitly also removes its worktree. A daemon disconnect alone does not
close or forget tasks.

A created checkout is saved as a task before opening its window.
If that window cannot be confirmed, the existing task offers recovery rather than another
creation attempt. Reconnection reconciles saved tasks with tagged windows, and repeated
window requests reuse an existing task window without replaying its prompt.

Removal leaves the terminal open when Git refuses or the user cancels. If the checkout was
removed but its branch remains, the task explains the partial result and supports retrying
the remaining step. Force-removing checkout changes does not force-delete unmerged commits.
Agent Stop hooks and shell-command text never authorize cleanup. Use **Remove Task…** only
when all work is finished; legacy cleanup events also leave the task and its window intact.

AiTerm checks saved checkout paths two seconds after the previous check ends, independently of
agent hooks and session changes. When a checkout has been deleted externally, its task row is removed and
its window is closed through the connected daemon; any remaining Git branch is preserved.
If closing the window fails or the daemon is unavailable, the task stays until closure can
be confirmed, and AiTerm retries automatically.
Missing or unreadable projects and checkout parent directories retain the task for recovery.
An explicit removal that needs a branch or window retry retains its row during that app session.

The sidebar uses native list selection: arrows browse; Return or a click activates. A missing
checkout is distinct from a closed window or an unavailable connection. Creation and settings
content scroll independently of their actions.

AiTerm supports dark mode only. The application sets `.darkAqua` before startup recovery,
window creation, or snapshots, so windows, sheets, alerts, and native controls share one
appearance regardless of macOS settings. Appearance is not a preference; the retired saved
value is removed at launch. Semantic colors retain increased-contrast support, alongside
reduced-motion and reduced-transparency behavior. The optional dark background for managed
iTerm2 sessions remains a separate setting.

Git, workspace writes, and iTerm2 still cannot share a transaction. A crash between checkout
creation and its first save can leave an unrecorded checkout; re-add the project to import it.
A crash while iTerm2 creates an as-yet-untagged window can require closing that orphan manually.
Plain terminal creation does not yet have the stable task identity used for task-window retries.

On upgrade, AiTerm renames the legacy `AIterm` application-support folder before loading state.
Existing projects and integration data are retained. If migration fails or both folder
spellings exist as separate directories, startup stops with an error and preserves the data.
The bundle identifier and lowercase daemon/configuration identifiers remain stable.
