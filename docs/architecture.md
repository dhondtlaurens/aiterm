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
  `SidebarView` renders; `AppController` builds the owners that hold the state and do the work
  (below) and forwards to them. `DaemonSupervisor` starts the daemon and restarts it with
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
  agent waits on the daemon — except a `/mcp` tool call (Codex's Stop hook), which is delivered
  before its result goes back. A Harness Test post carrying `_aiterm_test_id` is answered by the
  receiver itself, its proof that the route reaches the daemon, and never handed on, so it cannot
  change state on any route. The `SessionResolver`
  maps a post to a tab (by pid or the tab id the hook carries, then the tab that conversation was
  pinned to, then by directory); the status engine applies its state transition and its metadata
  separately, and keeps the per-session state machine — including subagents, so a row stays
  *working* while a background child runs.
- **The sidebar redraws** — status dot · avatars · branch · usage. A session change that moves a
  tab — its id, directory, window, tab index, task or project — also re-resolves every tab's
  branch, off the main actor. That is a `stat` of each directory's `HEAD` file — in a reftable
  repository, of its ref stack's `tables.list` — and git runs only the first time a directory is
  seen. A new context fill, state or model does not rescan, and a context fill, model or tab title
  does not redraw the rows either: they are derived from `LiveSessions.rowSessions`, which leaves
  those out — and so is the Dock badge. Nor does a sidebar move or a remembered agent and model,
  which the workspace saves but no row draws.

## Inside the app

`AppController` is the composition root that builds the owners and forwards to them. Each owner
is built after the owners it calls, which it is handed in its initializer, and is reached as a
property of the controller; views read the owners directly. The controller keeps only the Dock
badge, the order the workspace's change hooks run in, and ⌘B's choice — the Mac row's click — between
turning Backpack Mode off and asking `sheets` for its sheet.

| Owner | On the controller | What it holds |
|---|---|---|
| `WorkspaceStore` | `workspace` | the projects, dividers, tasks and terminals, and the one way they change, `mutate`, which runs the change hooks once and saves, coalesced and off the main actor |
| `WorkInFlight` (Core) | `work` | the work under way on each project, task and terminal: what one waits for before it starts, and what a project's removal waits for |
| `Notices` | `notices` | the banner above the list and the completion toast, and which report wins the banner |
| `FixSession` | `CreationModel.fixSession`, `Notices.fixSession` | one problem's Fix with AI — per failure, not one of the controller's: its state, the task running the pipeline and the clone it made, removed on every way out |
| `SheetCoordinator` | `sheets` | the one sheet slot, every way into it, the preparation on its way to it, and the creation sheets' models |
| `ProjectActions` | `projects` | every edit that is the workspace's alone — projects, dividers, names, Jira links — and the default branch's pull |
| `TaskLauncher` | `launcher` | tasks and reviews created, and their windows opened |
| `TerminalActions` | `terminals` | a project's terminals: a new one, and one closed |
| `TaskRemover` | `remover` | the person's Remove and its retries, the closing of a task whose worktree went, and what each left its row saying — a stopped shelving's note too, through the same channel; the unsaved-work question and the confirmed window close are `WorktreeTeardown`'s, which it shares with the archiver |
| `TaskArchiver` | `archiver` | tasks and reviews put away — “the Shelf” in the UI, “archive” in the code (`TaskArchiver`, `ArchiveSheet`, `AppState.archive`): shelve (the unsaved-work question, a detached head refused, the window closed and confirmed — refused without iTerm2 when the row has a window to close — the head read again and a detached one refused, the row saved onto the shelf on the branch its worktree is on now, then the worktree removed and the branch left), restore (the worktree back at its own path, the row back owed its window and chosen, so the window lock reopens it) and remove from the shelf (Remove's question, the record forgotten, the branch deleted only when ticked) |
| `WindowReconciler` | `windows` | each row locked to its window: `AppState.windowPlan` run on every report and acted on — a window adopted by tag, a window restored with its conversations, Remove's question — Shelve its third answer — after the person closes one task's window, a terminal's row taken with its window (`ClosedWindowTriage`); the failed restores rows read |
| `InterfacePreferences` | `preferences` | the Interface tab's settings, saved on every write |
| `AgentIntegrations` | `agents` | which agent CLIs the login shell finds, the Claude status-line shim, the Settings harness model |
| `SidebarTiling` | `tiling` | the sidebar window, its saved frame, and the terminal windows tiled beside it |
| `RowFocus` | `focus` | the selected row — a project header, a task or a terminal — and the request that brings its window forward — a click, Return, a peek — each returned as its `Task`; a click or Return on a row whose window is owed waits on its restore, or tries a failed one again; with no restore under way it only selects the row |
| `LiveSessions` | `live` | every tab the daemon reports, usage, and each row's last context fill |
| `CheckoutMonitor` | `checkouts` | branches, missing checkouts and diff badges; the pass on every session change a scan reads, and 2 s after the last pass ends |
| `ReviewThreadsWatcher` | `reviewThreads` | how many of each merge request's review threads are resolved — GitLab's resolvable discussions, GitHub's review threads — read every 60 s and when its row is selected, while started; each row's count in a `PerRow` cell, kept as last read when a read fails or the host is not connected (none before the first good one), and cleared only when its row goes or its task carries another merge request |
| `SidebarProjection` | `rows` | the sidebar's rows, derived from the workspace, `live.rowSessions` and the checkouts only when one of them changes what a row draws; the list, the Dock badge, Focus View and List View all read them |
| `HelperLink` | `helper` | the daemon process, the socket to it, how far the chain to iTerm2 reaches, and the tab titles it sends after each checkout pass |
| `BackpackController` | `backpack` | Backpack Mode: its state, setup and battery reading, its blocking work run on a thread of its own (`SerialThread`) |

A change to the workspace runs its hooks once, in this order: the owners' own, added as each was
built — `RowFocus`'s, which drops a selection whose row went, each `PerRow`'s, which drops only
cells no row reads, and `ReviewThreadsWatcher`'s, which drops a count whose row went or changed its
merge request — then `live.pruneContexts`, `notices.dropStale`, the rows derived again with the
Dock badge recounted, and last `remover.pruneRemovals`, so a task on its way out is not counted
between its row going and its removal entry going.

Saves wait for the next coalesced write, except where a step must be on disk before the next one:
a removal saves the row's going before it says "removed", and a shelving saves the row onto the
shelf before git removes its worktree — stopping there if that save fails. A new task is saved
before its window opens, a new project before its worktrees are offered, a restored row before it
is chosen, and the workspace at quit.

### Fix with AI

A failure an agent can fix — a diverged branch or a rebase's conflict, in New Review's footer and
Pull main's banner — offers Fix with the agent chosen in Settings › Agents (Claude Code or Codex;
Grok Build has no network-off on macOS, PI no unattended mode). `FixPipeline` runs it off the main
actor in four stages, each a closure the app's tests fake; `FixSession` owns one problem's run.

**The clone.** The agent never runs in the real repository. `FixClone` is a `git clone --shared
--no-checkout` of the project in the temp dir (`aiterm-fix-<uuid>`) with no remote, hooks off
(`core.hooksPath /dev/null`), the branch at the commit the fix started from and, for a rebase's
conflict, the stopped rebase recreated, so the agent reads the conflict itself. Signing is off in
the clone (`commit.gpgSign`, `tag.gpgSign`), so a fix's commits land unsigned. A pid file in `.git`
lets `FixClone.sweep` remove a crashed run's clone at launch and never a live one's; every way out
of a session removes its own.

**Look and Apply.** Look is read-only and has 180 s: the agent reads and runs read-only git, and
answers with a plan of one headline, a why and up to three steps. Apply resumes the same session
with 600 s to write the plan; AiTerm's checks and the plan's `verify` follow, which gets at least
30 s, so an Apply can run about 630 s. Nothing writes until the person presses Apply. Both runs go
through `AgentProcess` (dedicated drain threads, a stop that kills the process group), never
`ProcessRunner`. Claude runs with hooks off, `--setting-sources user` (the clone's own settings are
the repository's), no MCP servers, its Bash sandbox with the network off, no web tools, and Edit and
Write confined to the clone. Codex runs with `--ignore-user-config` and `--disable hooks`, a
`workspace-write` sandbox (read-only for Look) and the clone's `.git` as a writable root, which
`workspace-write` cannot write on its own.

**The checks.** The agent can write the clone, `.git` included, and a `core.fsmonitor` or
`filter.*.clean` that AiTerm's own git read would run unsandboxed, with the network on. So that git
(`CloneGit`) names the clone's `.git` and work tree itself, never discovering a repository the agent
laid out, with `safe.bareRepository=explicit`, no replace refs or grafts, and fsmonitor and hooks
off on its command line; FixGuard's `status` passes `--ignore-submodules=all` itself (a populated
submodule is a repository of the agent's, with filters of its own, and a `.gitmodules` entry
outranks any config). And `FixClone.make` keeps `.git/config` and `.git/shallow` as it left them:
after every run of an agent or `verify` both must be the same regular files byte for byte, `.git`
still a folder and no `commondir` in it, before AiTerm runs git in the clone again. Landing fetches
from the clone's `.git`, not its root.
`FixGuard` takes nobody's word that Apply worked: no operation left in progress,
no leftover conflict markers in the branch that will land, a clean tree, no branch moved that the
plan did not name, and no local commit lost — matched by patch id, or by a twin's author, date and
subject, which a rebase keeps — unless the plan dropped it. Then `verify` runs under `sandbox-exec`
(`VerifySandbox`): no network, unix sockets included; writes only in the clone and the per-user temp
dir; LaunchServices, AppleEvents and the pasteboard denied, so it cannot start an app that runs
unconfined. Without `sandbox-exec` there is no `verify`. It runs after the checks, so a test run
that touches tracked files is not taken for uncommitted changes; it can still write the clone, so
its settings and the branch's tip are read again after it, and a `verify` that moved the branch is
refused: only the tip `FixGuard` checked may land.

**Landing.** `TaskWorkflow.landFix` runs on the same serial queue as creation, removal and pull,
since it moves a branch. With hooks off in every command, the checked tip is fetched by its sha
under `refs/aiterm/fix/` (never the clone's branch by name), the old tip is kept as
`refs/aiterm/backup/<branch>`, and the branch moves only if it is still where the clone began:
`update-ref <ref> <new> <old>` where it is checked out nowhere, a fast-forward or `reset --keep`
in its clean checkout otherwise. A branch mid-rebase or
bisect, or a fix that would overwrite an ignored file, is refused; a refusal leaves everything as it
was. When a fix landed and its retry (the create, the pull) did not succeed, the person is told:
“The fix is in; your branch as it was is kept as aiterm/backup/<branch>.”

### Backpack Mode

`AiTermCore/Backpack/` decides; `BackpackController` drives it. Six ports, each faked in the
tests: lid sleep (`sudo -n /usr/bin/pmset -a disablesleep 0|1`, allowed by `/etc/sudoers.d/aiterm`,
which Settings › Integrations › Mac installs and removes through an `osascript` admin prompt after `visudo`
checks it), Wi-Fi (CoreWLAN, `networksetup` as the fallback and for the known-network list),
battery (IOKit), Location (CoreLocation: macOS hides Wi-Fi names without it), the installer and the
lid (`AppleClamshellState` on `IOPMrootDomain`, which `ioreg` shows unprivileged).
The hotspot's password lives in AiTerm's Keychain item: macOS will not hand another app an iPhone
hotspot's saved one. Every 5 s it checks the network and the battery; off the network it rejoins
at once, then after 5, 10, 20 and every 30 s. The check also takes whether any session in the
workspace is working: after 2 minutes without one the mode turns itself off, and a turn-on with
nothing working starts the same 2 minutes. On battery at or under 10 % it turns off too (a fixed
cutoff, `BackpackSettings.cutoff`). macOS sleeps on the lid's close, not its state, so an ending with the lid already shut runs
`pmset sleepnow` (no root needed) and leaves the Wi-Fi to rejoin on wake. After off, the Mac leaves the hotspot — or no network, which a failed join leaves — for the
first of its preferred networks that one scan finds, never the hotspot; if none is in range it
stays put. The Backpack sheet watches the lid and closes on an open → closed transition: with no
connect running — before Connect, or after a failure — that is a Cancel, which puts back a Wi-Fi a
failed join dropped; during one the attempt under way finishes, but no retry follows it.
`backpack.engaged` in UserDefaults is written before `disablesleep 1` and cleared only after
`disablesleep 0` succeeds: a failed restore is retried on every check, a launch that finds the
marker puts sleep back, and quit closes the mode first, so no turn-on can follow it.

Every request the app makes goes through `DaemonCommands`. `DaemonClient` sends it over the
socket; the app's tests record it in process instead.

## Inside the daemon

`Service` is the composition root: it builds the registry, the status engine and the usage store,
wires the three parts below to them, registers every RPC handler and runs the 2 s tick.

| Module | What it owns |
|---|---|
| `connection.py` · `ItermSupervisor` | connect, reconnect, auth backoff and cookie requests; every `iterm.*` event. It launches iTerm2 only in the loop the daemon's own start runs, never after iTerm2 has gone away |
| `windows.py` · `WindowManager` | task and terminal windows, their tabs, tagging a tab the user opens in one, titles and the background |
| `hook_router.py` · `HookRouter` | a hook post, placed on a tab and applied to status or usage |
| `publisher.py` · `Publisher` | `session.changed` and `usage.changed`, rendered when sent, for the router and the tick alike |
| `rpc_params.py` | reading parameters, and the errors every handler answers the same way |
| `delivery.py` · `Deliverer` | typing into an agent's tab (Operators spec §7.1): the prompt markers, the policy the delivery check wrote for each CLI version, paste · re-check · Enter |
| `keystrokes.py` · `TypingGuard` | when you last typed in each tab and whether its input may hold unsent text, from iTerm2's keystroke monitor: never the key itself |
| `operator_mcp.py` · `OperatorRoute` | the operator's MCP server on the hook port's `/operator`: a registered run's Bearer token or 401, the tools' schemas, every tool call forwarded to the app as `operator.request` |
| `iterm_bridge.py` | the only module that imports `iterm2` |
| `__main__.py` · `IdleWatchdog` | quitting once no app has been attached for a minute |

## Commands the app sends

| Command | What it does |
|---|---|
| `workspace.snapshot` | the bootstrap: protocol version, whether iTerm2 is connected, `itermVersion`, `itermAuthError`, `itermCookieRequest` (a cookie request made before the app attached), every session, usage — written before any later event |
| `window.createTask` | new window in a worktree, launching the agent command; a retry returns the existing window. Once iTerm2 has made a window it is returned, even if tagging it, typing the command or the tick after fails — that is logged, since an error would make the app open a second one. The new window is found through the same locked refresh as every tick, never one that overlaps a tick's. Only a window whose shell ended at once is answered `iterm_unavailable`. A restored window passes the first remembered conversation's resume command, or none. With `background`, the window is placed and tagged but neither activated nor brought forward: a task an operator starts opens behind your work |
| `window.createTerminal` | new window in the project folder, no agent. The optional `terminalId` tags it `aiterm_terminal`, which the app adopts the window by; the sessions carry it back as `terminalId` |
| `window.activate` | bring it forward when its row is clicked |
| `window.setFrame` | re-snap beside the sidebar |
| `window.close` | on remove, and before a worktree is deleted. The window is closed once iTerm2 has answered: a failed tick after it is logged, not answered |
| `tab.create` | a tab in an existing window, tagged like it: in `cwd` when given (a review opened in its task, a conversation resumed in a restored window), else where the active tab is |
| `sessions.setTitles` | branch titles for AiTerm tabs, re-sent every couple of seconds; the daemon only applies changes |
| `sessions.markSeen` | clear a done mark when its row is opened |
| `interface.setMatchItermBackground` | paint AiTerm windows #1E1E1E |
| `iterm.provideCookie` | the answer to `iterm.cookieRequested`: a cookie and key, "not running", or why iTerm2 refused. An answer to a request that has timed out or been answered is not accepted |
| `session.deliver` | types a message into an agent's tab by the delivery adapter's rules: refused unless the CLI passed the delivery check (`delivery-policy.json`) for the version the tab runs (Claude's session file, Codex's rollout), its screen reads and no prompt is open; a bracketed paste, 0.4 s, the same checks again, then Enter — anything changed in between, a takeover among it, holds the Enter back and answers `partial`. Over 2000 characters it is left in `<worktree>/.aiterm/messages/<n>.md`, everything checked again, and one fixed line typed. With `wake`, refused while you typed in that tab in the last 10 s, or while its input may hold text not yet sent |
| `session.prompt` | the prompt the tab's screen shows open: `permission`, `startup`, `menu` or none |
| `session.dismissStartup` | declines the CLI's update offer with Esc when the screen shows one — Codex's, by its own options; any other startup dialog, a folder's trust above all, is left for you: `{dismissed: false}` |
| `session.setOwnership` | a task's ownership generation, which a takeover increments: a send begun under an older one is refused, and a generation is never lowered. In memory only; the app sets each again after a daemon restart |
| `operator.register` / `operator.revoke` | open and close `/operator` to a run's token. The app also writes each run's `operators/runs/<run-id>/token` (0600), which the daemon loads at start and rereads for a token it does not know, so a daemon restart costs the operator nothing; revoke also deletes that file |
| `operator.reply` | the app's answer to an `operator.request`: its result, or the error the operator is told. One the daemon no longer waits for is dropped |

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
| `iterm.disconnected` | "Reconnecting to iTerm2…"; the daemon retries on its own, without launching iTerm2 again |
| `iterm.auth_failed` | iTerm2 is running but refused the API cookie; an amber banner gives the reason. Retries back off to once a minute, and the snapshot's `itermAuthError` carries the reason for an app that attaches later |
| `iterm.cookieRequested` | the daemon needs a cookie for its next connect; the app asks iTerm2 with an Apple event and answers with `iterm.provideCookie`. An attached app that stays silent for 120 s is asked again, under a new id; time with no app attached does not count |
| `window.activated` | aligns the sidebar selection when iTerm2 is raised from outside — e.g. by clicking an agent's notification |
| `window.closed` | the row owed that window is windowless at once, and the app decides what follows: a task window the person closed on its own is followed, a second later, by Remove's question, Shelve its third answer, a terminal's lone close takes its row, any other close is restored once iTerm2 is quiet; a close during a removal only clears its window |
| `session.opened` / `.changed` | a new tab, a new agent, a new state, a new model, a new conversation (`conversationId`, which the task saves for its restore); a tab tagged with a row's id in a window the row lacks hands the row that window |
| `session.closed` | drops one avatar from the group |
| `usage.changed` | a status-line tick landed, or Codex wrote a new rate-limit record |
| `operator.request` | an operator's tool call, for the app to answer with `operator.reply` within 30 s; past that the operator is told "AiTerm isn't answering", and with no app attached the daemon answers "AiTerm isn't open" without sending it |

An event the app does not know is a newer daemon's, and is ignored. One it knows but cannot read
is logged and drops the connection, so the app reconnects to a fresh snapshot rather than keep a
row the event would have changed.

Each side names every command, event and error code, the protocol version and the 1 MB frame
limit once: the daemon in `protocol.py` and its registered handlers, the app in
`DaemonProtocol.swift`. `daemon/tests/test_wire_contract.py` writes a frame of every event, reply
and error code, as a running daemon sends them, and a manifest of those names into
`daemon/tests/wire/`, and fails while the checked-in files differ from what the daemon sends. The
app's `WireContractTests` reads each frame with the client's own decoders and checks its names
against the manifest.

The socket is the only channel. If the daemon dies, the supervisor restarts it; from the second
failure the banner names the log at `~/Library/Application Support/AiTerm/aitermd.log`.

## Where the facts come from

| Fact | Source |
|---|---|
| status dot | agent hooks, plus Claude's own session file and the tab title's spinner glyph as corroboration |
| avatars | iTerm2's session list — one mark per tab, in tab order |
| branch | the *agent's* working directory, never iTerm2's: `session.path` is the shell's and never follows a Claude that entered a worktree |
| diff badge | `git diff --numstat` from the merge-base with the task's base, plus the untracked files' lines (at most 2,000 files and 20 MB; a file over 1 MB is skipped). Kept 5 s, inside the 2 s checkout pass; the merge-base is kept until a ref it joins moves. While the refs stand still an expiry costs two git processes per task — 40 at 20 tasks, where it was 100 |
| Claude usage | the `statusLine` shim — Claude Code hands rate limits to that command and to nothing else. It posts with `curl` to the hook port its driver recorded in `hook-port` and starts no `python3` |
| Codex usage | the `rate_limits` block Codex writes into every `token_count` record of its rollout file under `~/.codex/sessions` — the same file the context fill comes from, no subprocess |
| context fill | the same `statusLine` payload's `context_window`; the reporting session updates its task's last-known value, and the footer draws it only while that task is selected |
| provider icon | the git remote URL, or the repo itself |
| tickets | Jira Cloud REST, credentials in the Keychain |
| review threads | GitLab REST (`/merge_requests/:iid/discussions`, a discussion with a resolvable note, resolved when all of them are) on the configured GitLab host and port only, and GitHub GraphQL (`reviewThreads { isResolved }`), with the tokens Settings saved; read-only, 100 a page, at most 10 pages |
| models | each CLI's own catalogue cache, so the picker follows `/model` |
| conversation | each agent's own hooks — Claude's, Codex's and Grok's `session_id`/`sessionId`, PI's session id — kept only for a post placed on its tab by pid or by the tab id it carries, never by a pin or the directory; a subagent's start or stop and a Grok subagent's post name none, and it goes with the agent's process as the model does |
| skills & commands | discovered on disk per agent and per project, for the prompt step's completions |

**Token counts** are each tab's own, its subagents' included and nothing counted twice. Claude's are
summed from the transcript and every `subagents/**/agent-*.jsonl` beside it, one reply per
`message.id` across the tree, each field the most any of its lines said, so a fork's copy of a
parent's reply adds nothing. Codex's are the newest `total_token_usage` of the thread's rollout and
of every rollout descended from it, by the `session_meta` lineage. Grok's are the status line's
session totals, whose ledger already holds its subagents'. PI's extension posts its own: the
session's entries without a tool result's usage, where pi-subagents hangs a child's, plus a
process-wide ledger of what each subagent has spent.

## What AiTerm writes, and where

**Secrets** — one Keychain item, service `com.laurensdhondt.aiterm`, account `secrets`: a JSON
object holding the Jira, GitLab and GitHub tokens and the Backpack hotspot's password, read once per
launch (`Keychain.shared`), so macOS asks for access once. Tokens an earlier version kept in an item
each move into it the first time it is missing. Settings' Save still checks every card before it
writes and puts back what it wrote when the Keychain refuses one.

**Backpack Mode** — `/etc/sudoers.d/aiterm`, only once the Mac card's Allow… is pressed, and
removed by its Remove; the hotspot's name and the crash marker in UserDefaults
(`backpack.network`, `backpack.engaged`).

**Its own state** — `~/Library/Application Support/AiTerm/state.json` — projects, tasks,
terminals, the Shelf (`AppState.archive`: each shelved task or review with when it went, written
only when it is not empty), the sidebar frame, the last agent per project and the last model per
agent. A task id is in the sidebar or on the shelf, never both, and every shelved row's project
exists; a file that breaks either does not load. A build without the Shelf drops it on its next
save. The legacy `AIterm` folder is renamed on upgrade; if that fails, startup stops rather than
losing it.

**Worktrees** — One per task, under `<repo>/.worktrees/<slug>`. Removing a task removes the
worktree and optionally the branch. Shelving one removes the worktree and never the branch;
restoring recreates it at its own path, since an agent keeps its conversations by directory — on
its branch, or created from origin's when the local one has gone, a review's fetched and brought up
to origin's as creating one does. A new task's or review's worktree, and the sheets' preview of it,
skip the folders shelved rows come back to (`AppState.reservedWorktreeSlugs`). Removing a task
from the shelf deletes its branch when ticked and never touches its old folder: something else
may live there by now. Removing a *project* only forgets it — its tasks, terminals and shelved
rows — and says how many tasks and shelved rows go; it is refused while one of its shelved rows
is being shelved, restored or removed.
A new task's or review's worktree starts with the gitignored files the project's `.worktreeinclude`
selects (`WorktreeInclude`: untracked files its `.gitignore`-syntax patterns match that git also
ignores, listed in the project's checkout): right after `git worktree add`, before the window opens,
each is cloned to the same path, never over a file already there. What could not be copied is said
in the sidebar banner (three files by name, then how many more, or that the file could not be read),
and the task is created all the same.
Step 1's checkbox, ticked by default, turns it off for one task; there is no setting.

**Agent configuration** — Eight Claude events and six Codex events, plus the status-line command.
Merge-only, marked as AiTerm's, with `.aiterm-backup` beside each file. A file that already holds
the right hooks is not rewritten; a symlinked file stays a link and its target is merged; a link
to nothing is refused rather than replaced, as is a file that sets `hooks`, one of our events or
`statusLine` in a form the merge cannot extend (Claude), or that does not parse (Codex, Grok). A Claude
status line counts as current only when it names this bundle's shim or a copy that still runs. The agent's card in Settings › Agents re-runs the same installer — Install, Repair or Reinstall, by its state. Grok's
eight events go to a file AiTerm owns outright, `~/.grok/hooks/aiterm.json`, written atomically
rather than merged; only its status line merges into `~/.grok/config.toml`'s `[ui.status_line]`
table, saving a foreign command to `grok-statusline-original.cmd` first. The PI extension goes to
`~/.pi/agent/extensions/aiterm-status.ts`, schema 5, written with the hook port in place of its placeholder.
The two status-line shims run from the bundle and read the port from `hook-port` in the support folder,
which each of their drivers' Install writes (launch writes it too, for an upgrade); a shim with no port
posts nothing, and a card whose file does not hold the daemon's port is outdated.

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

[windows.md](windows.md) tells the following in plain words, scenario by scenario.

A row and its iTerm2 window are locked together: a task or terminal row is never shown without its
window, and a row with `windowId == nil` is owed one. Every reason a window has not come back yet is
an input to the decision, never a state the row is in. `AppState.windowPlan` (Core, pure) decides per
row what to do about the difference between the rows and what iTerm2 has: adopt a window a tab tagged
with the row is in (tasks `aiterm_task`, terminals `aiterm_terminal`), restore the window, ask about
it, or drop the row. `WindowReconciler` alone acts on it, on every connected snapshot, close, hold,
answer, choice and change of work, so there is one owner and one pass rather than a handler for each
way a window can go.

When the person closes one task's window while iTerm2 stays connected, the row is owed its window at
once and, a second later, AiTerm comes forward with Remove Task's own question and Shelve as a
third answer: Remove deletes the worktree as Remove Task… does, and Shelve shelves the task as its
menu's Shelve Task does, each with its window already gone; Cancel chooses the row, which restores its
window and raises it. A terminal's lone close takes its row, as Remove Terminal does.
The close is held a second first (`ClosedWindowTriage`, keyed by row), because iTerm2 quitting,
crashing or a restart closes windows too and must ask nothing. The hold is told the time by its
caller, and only what happens within the second after a close cancels it: iTerm2 disconnecting, or
another window closing (`ClosedWindowTriage.itermSynced(_:at:)` and `windowClosed(row:at:)` drop just
the closes still inside their hold, so one whose second was already over stays due when the caller
gets to it). A close is never held when another window closed within the second before it, or when
it arrives before the snapshot that follows a reconnect — the daemon keeps its sessions across a
disconnect, so its first tick back announces every window iTerm2 lost while it was away, and the
app's snapshot request on `iterm.connected` is answered only after that tick. Questions are asked
one at a time. A task whose tab lives on in another window — its only tab dragged there, or Merge
All Windows — is not asked about: its tag adopts that window, which the row takes. If iTerm2 keeps
the front and macOS refuses AiTerm's activation, AiTerm's Dock icon bounces until the person comes
(`AppController.bringAiTermForward`). Quit lets a held close go (`WindowReconciler.stop()`): nothing
is asked after it.

Everything else — a burst of closes, iTerm2 quitting or crashing, a reboot, AiTerm starting, a
daemon restart — is restored quietly, once iTerm2 is synced and no window has closed for a second
(`ClosedWindowTriage.isQuiet`), one window at a time, each tiled as a new one is, and each queued
restore looks again when its turn comes, so iTerm2 closing windows meanwhile skips it rather than
failing it. A task's window opens in its worktree and resumes each agent conversation its tabs last
showed (`TaskItem.conversations`, saved as the daemon reports each tab's `conversationId`): the
first in the window's tab, each other in a tab of its own. A window replaces the remembered list
only once every agent tab in it names its own conversation, so a restored window whose agents start
one by one never shrinks it; an id that is empty or starts with "-", which the CLI would read as a
flag, names none (`TaskConversation.isResumable`). The command is the harness's resume arguments
(`Harness.resumeArguments`) and, for the task's own agent, the launch arguments it was started with —
model and reasoning, and Codex's approval bypass; any other agent, started by hand, resumes without
them, and so does a task with no saved model, so no Codex bypass either. With none known the window
is a shell, and the first prompt is never replayed. A terminal comes back as a fresh shell in its
project's folder.

AiTerm never relaunches iTerm2 after it goes away: a quit must stay quit. The daemon launches it
only at its own start, which an AiTerm adopting a daemon a previous one left running never causes,
so the app starts it too: when AiTerm starts and iTerm2 is not running, and when a row is chosen
while iTerm2 is away, each without activating it; the windows come back with the snapshot that
follows. A restore that fails while iTerm2 is there leaves "Couldn’t reopen" on the row and the
reason on the banner; the pass leaves the row be, and choosing it — a click or ↩ — tries again. A
failure because iTerm2 went away meanwhile, or a reply saying it is unavailable, is not the row's:
the next connected snapshot restores it. A failed row that gets a window another way — adopted by
tag — is no longer failed. AiTerm quitting leaves the windows running; the next launch adopts them
by tag and restores the rest.

Closes AiTerm makes itself — Remove, Shelve, the checkout cleanup, Remove Terminal — are never asked about,
and are not restored while their work runs: a row busy with work, or whose removal awaits a retry,
is left out of the pass, and so is a row whose checkout is missing or whose worktree a restore found
gone, which is not looked for again until the checkout monitor reads that row
(`CheckoutMonitor.onMissingChanged`) or the person chooses it. A removal or a shelving that stops
after closing the window — git refuses the worktree, Keep at the late unsaved-work question, or its
place on the shelf could not be saved — leaves the row owed its window, and the window is restored. A
restore checks the worktree exists, off the main actor, before it opens. Nothing is restored while the workspace cannot change. Removing a task
explicitly also removes its worktree. A daemon disconnect alone does not close or forget tasks.

A created checkout is saved as a task before opening its window, and the new row is held busy
(`TaskOperation.opening`) from the moment it is appended until its create ends, so the pass never
restores a row whose window is still being created. If that window cannot be confirmed, the
existing task stays and says its window opens, or comes back, by itself rather than inviting
another creation attempt. Reconnection reconciles saved tasks with tagged windows, and repeated
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
iTerm2 sessions remains a separate setting. When the daemon launches iTerm2, it also includes
its single startup window and tabs opened in that window, without assigning a project or task.
This background-only ownership lasts for the daemon's lifetime; disabling the setting restores
the sessions' original backgrounds. An already-running iTerm2 is not adopted, and a launch
that restores several windows is left alone rather than guessing which one is the startup window.

Git, workspace writes, and iTerm2 still cannot share a transaction. A crash between checkout
creation and its first save can leave an unrecorded checkout; re-add the project to import it.
Shelving orders its two steps so a crash between them loses nothing: the shelved row is saved
before git removes the worktree, so a crash in between leaves a shelved row whose worktree still
exists, and restoring it adopts that worktree when it is on the row's branch — anything else in the
folder is refused and left as it is. A locked worktree whose folder was deleted is only git's record
of one, so restore prunes the record and makes the worktree again. Had git gone first, the crash would have left a task whose
checkout is gone, which the cleanup forgets. For the same reason a shelving whose save fails stops
before git, the row a task again, owed its window, saying "Not shelved".
A crash while iTerm2 creates an as-yet-untagged window can require closing that orphan manually.

On upgrade, AiTerm renames the legacy `AIterm` application-support folder before loading state.
Existing projects and integration data are retained. If migration fails or both folder
spellings exist as separate directories, startup stops with an error and preserves the data.
The bundle identifier and lowercase daemon/configuration identifiers remain stable.
