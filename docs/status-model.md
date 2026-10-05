# Status & branch model

The two things a sidebar row says that nothing else in the system can tell you: what the agent is
doing, and where it is doing it. Both are harder than they look, and both are wrong in the obvious
implementation.

## Four states, in urgency order

- **Idle** — Nothing is running, or the last turn has been seen. A hollow ring — the quietest
  shape in the app.
- **Working** — A turn is in flight. Entered on `UserPromptSubmit`, and held while any subagent is
  alive.
- **Needs input** — The agent is blocked on you — a permission prompt, an elicitation dialog, or
  an explicit "needs input" notification. The one state worth amber.
- **Done** — The turn finished and you have not looked yet. Clicking the row calls
  `sessions.markSeen` and it falls back to idle.

A row with several tabs takes the most urgent of them: needs input > working > done > idle. A
collapsed project instead counts them, and draws its chips in task order rather than urgency
order — the chips sit still, so a stable reading order beats ranking.

## What moves a session

| Hook event | Signal | Notes |
|---|---|---|
| `UserPromptSubmit` | working | Claude Code, Codex and Grok Build. A new turn: it drops any completion the previous turn deferred. |
| `Stop` | done | Deferred while a subagent is still alive — the last child finishes the change. A Claude `Stop` also drops each counted child its `background_tasks` no longer lists (below). |
| `PermissionRequest` | needsInput | Claude Code and Codex. |
| `Notification` | needsInput | Claude only: `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog`. |
| `Notification` | done | Claude only: `agent_completed`. |
| `SubagentStart` / `Stop` | working | Tracked per child id. A needs-input row is *not* overwritten — an input request must stay visible. A Claude child that died without its `SubagentStop` is found from its transcript (below). |
| `SessionStart` | model | Not a state: it updates the model, and forgets the previous conversation's subagents and deferred completion — but not after a compaction (`source: "compact"`), and only in the tab the post provably came from. |
| `PostModelSwitch` | model | Not a state: it updates which model the row reports. |

PI reports the same state machine through its public extension events:

| PI extension event | Signal | Notes |
|---|---|---|
| `session_start` | metadata | Resolves the PI session and updates model, reasoning and context when present. With reason `startup`, `new`, `resume` or `fork` it is also Claude's `SessionStart`: the previous conversation's subagents and deferred completion are forgotten. `reload`, or no reason at all (an extension older than schema 3), is metadata only — PI's counterpart of a compaction. |
| `agent_start` | working | A PI turn started. |
| `ui_prompt_start` | needsInput | PI opened a prompt that needs the user. It remembers the state it interrupted — the first one, if prompts nest — and counts the prompts open. |
| `ui_prompt_end` | the interrupted state | Once the last open prompt closes, restores what the first interrupted: idle, done or working; an inner prompt closing leaves the row at needs input. A deferred completion is left alone. It changes nothing when no state is remembered: no prompt was opened, or a state hook since then took over. |
| `agent_settled` | done | The PI turn finished. |
| `subagent_start` / `subagent_stop` | working | Relayed from pi-subagents' `subagents:started`, `:completed` and `:failed`, and tracked per child id like Claude's. The extension keeps its last session past `session_shutdown`, so a child that ends after it is still reported. |
| `model_select` | model | Updates the full `provider/model` identifier. |
| `thinking_level_select` | reasoning | Updates PI's current thinking level. |

These extension events use the existing urgency and unread rules; PI does not introduce a fifth
state. In particular, `agent_settled` stays Done until the row is seen, just like Claude Code and
Codex completion, and a PI input prompt outranks Working.

An open PI prompt keeps the row at needs input, but what happens under it lands in the state the
prompt will restore, because PI has no tick to correct it afterwards. A child starting makes that
state working, and the last child finishing a deferred turn makes it done. A done that a running
child defers is not a state hook that takes over: the prompt keeps what it will restore, and the
last child's stop completes it, before or after the prompt closes. Opening the row under
the prompt turns a remembered done into idle, so closing the prompt does not bring back a
completion already seen. Claude's and Codex's input requests remember nothing; their tick signals
below do the correcting.

Grok Build reports through command hooks rather than an extension, in Claude's PascalCase event
names but Grok's own camelCase fields:

| Grok event | Signal | Notes |
|---|---|---|
| `SessionStart` | sessionStart | Forgets the previous conversation's subagents and deferred completion, same as Claude, except `source: "compact"` (metadata only). |
| `UserPromptSubmit` | working | A new turn. |
| `Notification` of type `permission_prompt` | needsInput | |
| `Notification` of type `idle_prompt` | settle | Grok's backstop for a turn that reports no end — a rewind, a cancel-and-send, a superseded turn, a stop gate at its continuation limit. It fires about a minute after the session settles, after any turn end, so it only ends a turn still working or needing input: a done stays as it is, seen or not. |
| `PostToolUse` / `PostToolUseFailure` | working | A tool ran, so an answered permission prompt is over — Grok's resume signal, where Claude has its session file and Codex its title spinner. Without it a Grok session would stay needs-input until the turn ended. A tool that fails to dispatch, or an MCP error, reports the second instead of the first. |
| `Stop` with `reason: "end_turn"` or no reason | done | |
| `Stop` with a session-end reason (`channel_closed`, `shutdown`) | ignored | Not a turn ending. |
| `Stop` whose `backgroundTasks` holds a running `subagent` | ignored | The turn works on through its child, as a Claude turn does; the child's completion wakes the session into a new turn, which ends with its own `Stop`. |
| `Stop` whose `backgroundTasks` holds only `shell` or `monitor` work | done | A dev server or a watcher can run for the rest of the session, so waiting on it would keep the row working for good. Whatever it wakes fires `UserPromptSubmit`, which puts the row back to working. |
| `StopFailure` / `StopCancelled` | done | |

Grok names each turn with a `promptId`, and its reports are not ordered: a cancelled turn's is
dispatched off the command loop, so it can arrive after the next turn's `UserPromptSubmit`. The
engine keeps the turn each `UserPromptSubmit` starts, and ignores a done, needs input or working
that names another one. A done for a turn never seen to start does not turn an idle row done — an
interrupted bash-mode (`!`) command reports one with no `UserPromptSubmit` — though a working row,
say after a daemon restart, takes it. An event with no `promptId` (the `idle_prompt` backstop) always
applies, and a new session forgets the turn.

Any payload carrying a non-empty `subagentType` is a nested agent's own event and is dropped: a
foreground Grok subagent runs inside the parent's turn, and background work is already visible on
`Stop` as `backgroundTasks`, so it needs no separate tracking. The one exception is a child's
`permission_prompt`: Grok waits on the user for it as for the session's own, so it is needs input. `/hook/claude` drops any payload carrying
`hookEventName` — a key Claude itself never sends — so a future Grok config that allows loopback
HTTP on the Claude route can never be counted as Claude.

Hooks are the primary source; two corroborating ones run on the daemon's tick so a missed post
cannot strand a row — Claude's own session file (`busy`/`thinking`/`running` → working, `waiting`
→ needs input, `idle`/`shell` → the turn ended; any other status is ignored rather than read as
the end of the turn) and the braille spinner glyph at the head of an iTerm2 tab title.

A hook can arrive before the tick has classified its tab: `window.createTask` sends the agent
command and ticks at once, while the tab still reads as a shell, so the agent's `SessionStart` and
first prompt find no tab running that agent. A hook that places nowhere therefore asks for one tick
and is placed again against it, once; if it still places nowhere it is dropped. The ack has already
gone out, so no agent waits on this. Hooks that arrive before that tick starts share it, and no more
than one runs and one waits, at least a second apart, so a flood from an agent outside iTerm2 costs
about one tick a second. Statusline posts are not retried: the next one carries the same data.

The tab title is read for that spinner and for nothing else, so a title that changes while nothing
else does is not a change to announce: a working Codex tab turns its spinner glyph on almost every
tick, and each of those would have been a `session.changed` that the app decodes and discards. The
daemon keeps the newest title in its registry, where the status engine reads it, and every
`session.changed` and snapshot still carries it, so an older app that decodes the field keeps working.

A Codex rollout grows without bound and is read on every tick it changes (context fill, rate
limits), so it is read on a worker thread, as the orphan and subagent checks are, and only the lines
that contain a `token_count` are parsed. A read that does not answer within a second costs that
tick its Codex numbers, not the daemon its hook acks.

A tick publishes what it changed even if a step of it raises, and each corroborating step (a
session's file, the orphan check, the subagent transcripts) is guarded on its own: one that fails is
logged and costs only its own changes.

Both lag the hooks, so neither may override a newer one:

- **Claude's session file** counts only if it was written after the last hook that set the state
  (working, needs input or done). Claude rewrites the file after the hook fires; until then it
  describes the moment before — `busy` under a fresh permission prompt, the last turn's `idle`
  under a new prompt. The file's directory is applied either way. An answered prompt still resumes
  the row: Claude rewrites the file, which is then newer than the hook.
- **A Codex title without a spinner** ends a working turn only if a spinner has been seen since the
  last hook said working. Codex draws it a moment after `UserPromptSubmit`, and a tick in between
  used to mark the row done. The cost: a `Stop` lost in a turn shorter than one tick (2 s) is no
  longer corrected by the title, and the row stays working until the next hook.

The file rule compares two wall-clock times: the daemon's clock when the hook arrived, and the
file's mtime. If the clock steps backwards between them (an NTP correction), a newer file looks
older than the hook, and it is ignored until the next hook.

Subagent tracking cannot outlive its conversation: a new `SessionStart` (for PI, a `session_start`
that begins a conversation), or a different process id in the tab, forgets every child still
counted. One lost `SubagentStop` would otherwise hold the row at working for good.

Within a conversation, a Claude child can also die without a `SubagentStop`. Claude Code's stream
watchdog kills a background child that has made no progress for 600 s ("Agent stalled"), and sends
no `SubagentStop` for it. Two signals find such a child.

**The next `Stop`.** Claude wakes the parent with a `failed` task notification when a child dies, so a
`Stop` follows. Its `background_tasks` lists the work still in flight (`running` or `pending`, and
not foreground), and a subagent's task id is its `agent_id`. Every counted child the list leaves out
is dropped. If the last one goes, a completion an earlier turn deferred lands first, then the `Stop`
lands its own. The list proves nothing, and nothing is dropped, when:

- it is absent: an older Claude Code, or a task registry it could not reach;
- it is malformed;
- it holds work whose agents it does not name by their `agent_id`. A `teammate`'s task id is
  generated separately from its agent id, and a `workflow`'s agents sit behind the workflow's own id.
  Only `subagent`, `shell`, `monitor` and `MCP task` entries are understood.

**The tick.** While a deferred done waits on Claude children, the tick reads the end of each child's
transcript (`StatusEngine.release_dead_subagents`) and counts the child as gone when:

- its last record is the interruption the watchdog, or Esc, leaves (`[Request interrupted by
  user]`), or the attachment of a `SubagentStop` hook the daemon never received, written after the
  child's latest `SubagentStart`; or
- its transcript has not changed for `SUBAGENT_QUIET_SECONDS` (45 minutes), timed on the monotonic
  clock from the first tick that saw it unchanged. That clock stops while the Mac sleeps. The
  window is long because live children have gone 28 minutes without writing, during a long
  generation or a stream retry. It only catches a child that died without writing anything: every
  watchdog kill observed left the interruption.

A transcript that does not exist yet proves nothing, so that child stays counted. A gone child is
dropped exactly as its `SubagentStop` would have dropped it, so the last one lands the deferred
done. A real `SubagentStop` that arrives later changes nothing. A stalled child that is resumed
fires `SubagentStart` again under the same id, which counts it again. Its transcript's old
interruption is then ignored, because it was written before that start.

`SubagentStart` carries only the session's `transcript_path`, `<dir>/<session>.jsonl`. The child's
transcript sits beside it at `<dir>/<session>/subagents/agent-<id>.jsonl`, or one directory
further down, where Claude Code files some agents. Only the last 64 KiB of each transcript is read,
on a worker thread with the one-second bound of the orphan check below, and again only once its
mtime or size changes. A turn with nothing deferred reads none.

Claude's own session file cannot do this job. It stays `busy` while a background child runs past the
end of the turn, and it names no child. Only Claude children are checked. PI relays a crashed
child's `:failed`, Grok tracks no children (its `Stop` lists them), and no Codex child has yet been
seen to die without its `SubagentStop`.

What an agent reported belongs to its process, not the tab. A tab keeps its model, reasoning,
agent directory and context fill only while the same agent runs under the same process id, from
one snapshot to the next. A Claude that exits to the shell, or a new Claude in the same tab,
starts blank: the row no longer shows the old worktree's branch, and Cmd+T opens where the shell
is. The state is not kept either: the tick that finds the tab back at its shell sets it idle at
once (`StatusEngine.agent_exited`), an exited agent's unseen done included. That is also how a Grok
session's end shows, since its session-end `Stop` is ignored. An
agent that hands the terminal to another program and gets it back under its own pid comes back
blank too — Claude's Ctrl+G opening `$EDITOR`. Claude's session file restores its directory in the
tick that sees it back; the model and context return with the next hook or status-line post.

## A turn that removes its own checkout

An agent that finishes by merging and deleting its own worktree deletes the directory its process
runs in. Every hook transport that spawns a command in that directory then fails to fire — Grok
Build's command hooks always do this; Codex's `Stop` does not, because it travels over MCP instead.
Left alone, a session like that would sit `working` or `needsInput` forever: no further hook can
arrive to end its turn.

The daemon's tick settles it instead (`StatusEngine.settle_orphans`). On each tick it checks every
agent session in `working` or `needsInput`: if `agentCwd` (falling back to the shell's `cwd`) no
longer exists, it records when the directory was first found missing, and once that has been true
for `ORPHAN_SETTLE_SECONDS` (10 s) it forces the session to `done` — past any deferred subagent
completion, since no subagent hook can arrive either. If the directory reappears, or the session
leaves `working`/`needsInput` on its own first, the record is cleared instead, and any hook for the
session restarts the 10 seconds: it was spawned in a directory that exists.

"No longer exists" means a `stat` failed with `ENOENT` or `ENOTDIR`. Any other failure — `EACCES` on
a TCC-protected folder, `EIO`, a stale or unreachable network mount — proves nothing, so the
directory counts as present. The stats run on a worker thread, and a tick waits a second for them:
a check that takes longer, or one still stuck from an earlier tick, finds nothing missing, so a
hung mount stalls neither the daemon nor the hook acks Grok's gates wait on. The 10 seconds are
timed on the monotonic clock, which an NTP step does not move. A check that raises answers the
same as one that cannot answer, and its thread is a daemon thread, so one stuck on a dead mount
cannot hold the daemon open after it quits.

The rule is skipped for harnesses whose real end-of-turn signal survives a removed cwd —
`END_OF_TURN_SURVIVES_CWD_LOSS = {claude, codex, pi}`, derived from the `HARNESSES` table in
`aitermd/models.py`, where every per-harness fact the daemon keeps lives: Claude's session file
would flip a settled tab back to working moments later, and Codex's MCP `Stop` already arrives
regardless, so for them the rule never runs and there is no pending settle to race. Grok Build gets
the rule by default, and so does any harness added later, until its driver finds a transport that
does not spawn into the session's cwd. For one of those unlisted harnesses, a real transition —
arriving before the 10 seconds are up — always wins and cancels the pending settle; that is what
the 10 seconds are for.

The app waits on the same fact before closing a removed task's window: `forgetRemovedCheckouts`
keeps its confirmed-removal check, and also waits while any of the task's sessions is still
`working` or `needsInput`. It closes the window on the first pass after they have all settled, so
`settle_orphans` — not a fixed poll — is what lets a Grok task whose worktree just vanished finish
its final message before the window disappears.

## Why the branch is not iTerm2's to tell

iTerm2's `session.path` is the *shell's* directory. Claude Code chdirs its own process when it
enters a worktree, so the shell underneath never moves. Probed live on 17 Sep: four Claude tabs
all reported the repository root while their processes were inside `.worktrees/*`.

1. The daemon reads the agent's real directory — Claude from its own session file, Codex, Grok
   and PI from their hook posts — and publishes it as `agentCwd` beside iTerm2's `cwd`.
2. A row resolves the branch from `agentCwd ?? cwd`, and only for the tab that was *active* in its
   window — that is the tab the keyboard is talking to.
3. Tabs whose directory is not a checkout at all — a shell sitting in `$HOME` — are ignored
   entirely rather than showing a blank.
4. Resolution is a `stat` of each directory's `HEAD` file, not a git call: git runs only the
   first time a directory is seen, to find that file, and for a `HEAD` too unusual to read. It
   runs off the main actor, coalesced, and only for a session change that moves a tab: the daemon
   can broadcast several changes a second, and a new context fill or model moves nothing.

## What the branch line can say

- **One branch, no tooltip** — e.g. `feat/pay-214-apple-pay`. Nothing to explain, so the
  row carries no hover text.
- **The window has other branches open** — e.g. `feat/shop-2210-preview-tokens +2`. The tooltip
  lists every tab: `tab 2 · codex · main`. The chip keeps its intrinsic width however narrow the
  sidebar gets — only the name truncates, and from the middle.
- **Drift** — e.g. `main` shown in the drift state. The active tab is not on the branch the task
  is bound to. The tooltip names both: `task · feat/shop-2210-preview-tokens`. Amber, because this
  is the case where the next command lands somewhere you did not mean.
- **No window open** — e.g. `main`. A task falls back to its own branch, a terminal to the
  project's checkout. The row still says something true rather than going blank.

## What this shape fixed

**The frozen spinner** — SwiftUI installs a `.animation(_:value:)` only when the value changes,
and the spin flag outlives the branch of the switch that owns it. It latched true the first time a
row worked, so every later working spell rendered a static arc at 360°. Measured with an
interpolation probe: 172 on first appearance, 0 on the second, 181 with the reset on disappear.

**Every row on the same branch** — Before `agentCwd`, every task in a repository reported the
repository's own branch, because that is where the shells were. The rows looked plausible and were
uniformly wrong — the worst kind of bug in a status display.

**A turn that ended too early** — A foreground `Stop` arrives while background subagents are still
running. Marking the row done there made it go quiet mid-work; the deferred-done set holds the
change until the last child reports back.
