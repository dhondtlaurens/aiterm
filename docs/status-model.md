# Status & branch model

The two things a sidebar row says that nothing else in the system can tell you: what the agent is
doing, and where it is doing it. Both are harder than they look, and both are wrong in the obvious
implementation.

## Four states, in urgency order

- **Idle** — Nothing is running, or the last turn has been seen. A hollow ring — the quietest
  shape in the app.
- **Working** — A turn is in flight. Entered on `UserPromptSubmit`, and held while any subagent is
  alive.
- **Needs input** — The agent is blocked on you — a permission prompt, an elicitation dialog, an
  explicit "needs input" notification, or Claude Code asking whether to trust a new folder. The one
  state worth amber.
- **Done** — The turn finished and you have not looked yet. Clicking the row calls
  `sessions.markSeen` and it falls back to idle.

A row with several tabs takes the most urgent of them: needs input > working > done > idle. A
collapsed project instead counts them, and draws its chips in task order rather than urgency
order — the chips sit still, so a stable reading order beats ranking.

## What moves a session

| Hook event | Signal | Notes |
|---|---|---|
| `UserPromptSubmit` | working | Claude Code and Codex. A new turn: it drops any completion the previous turn deferred. |
| `Stop` | done | Deferred while a subagent is still alive — the last child finishes the change. A Claude `Stop` also drops each counted child its `background_tasks` no longer lists (below), and the session's `background` lists what still runs: shells, monitors and other tasks, and the counted children by their description, each taken off as it ends. |
| `StopFailure` | done | Claude only, in place of `Stop` when an API error ended the turn. The session's `stoppedOn` names the error (`rate_limit` for a usage limit, `billing_error`, `authentication_failed`...), and for a limit when it resets, once the tick reads that in the transcript's own record of it within 30 s; it is never guessed. It clears once the session works again: a new prompt, a clean `Stop`, another conversation, its session file saying busy (Claude Code carrying on by itself once the limit reset), another process in the tab. |
| `PermissionRequest` | needsInput | Claude Code and Codex. |
| `Notification` | needsInput | Claude only: `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog`. |
| `Notification` | done | Claude only: `agent_completed`. |
| `SubagentStart` / `Stop` | working | Tracked per child id. A needs-input row is *not* overwritten — an input request must stay visible. A Claude child's `SubagentStop` ends it only once its transcript shows the run over, and a child that died without one is found there too (below). |
| `SessionStart` | model | Not a state: it updates the model, and forgets the previous conversation's subagents and deferred completion — but not after a compaction (`source: "compact"`), and only in the tab the post provably came from. |
| `PostModelSwitch` | model | Not a state: it updates which model the row reports, once Claude Code has switched. Like every Claude post from inside a subagent (`agent_id`), one there says nothing of the session's model. |

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
| `turn_end` | metadata | Refreshes the context percentage after each tool turn while the agent keeps running. Child sessions post nothing. |

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

Hooks are the primary source; two corroborating ones run on the daemon's tick so a missed post
cannot strand a row — Claude's own session file (`busy`/`thinking`/`running` → working, `waiting`
→ needs input, `idle`/`shell` → the turn ended; any other status is ignored rather than read as
the end of the turn) and the braille spinner glyph at the head of a Codex tab's iTerm2 title. Which
harness has which is its `corroboration` in the `HARNESSES` table; PI has neither.

Claude Code's folder-trust dialog ("Yes, I trust this folder") comes before all of these: Claude
loads no hooks and writes no session file until the folder is trusted, so the tab's screen is the
only sign of it. The tick reads the screen of a Claude tab that has a process but no session file,
while its row is idle, or while the dialog holds the row (`Service._apply_trust_prompts`; the text is
the harness's `trust_prompt` in `HARNESSES`). The dialog moves an idle row to needs input, and
nothing else: a row a hook has moved is left alone. When it closes, the row goes back to idle and not
to done, because no turn ran. It is closed by the screen no longer showing it, by the session file
appearing, by any hook (only a trusted folder loads them), or by Claude exiting. A screen that
cannot be read changes nothing. A tab past the dialog has its session file, so its screen is not
read again.

The Operator also reads worker screens through `session.prompt`. Discovery of unannounced prompts
on the reconcile tick is limited to working tasks in active broadcasts with no pause or stop intent.
It excludes planned, queued, in-review, blocked, failed, accepted, no-change, published and stopped
tasks, and planning, paused, operator-offline, complete and stopped broadcasts. Hook-announced
prompts (`needsInput`, including PermissionRequest) and post-delivery reads instead record questions
on working, blocked and in-review tasks in any broadcast that has not completed or stopped. This
includes paused and operator-offline broadcasts: a permission prompt there still notifies you.
A stop intent prevents new questions and notifications.
Resolution reads for existing questions run in every task and broadcast state, including with an intent.

Session events read tabs that need input or have an open question. The 60-second reconcile tick
also checks other eligible tabs for menus no hook announced. Event and reconcile reads have at
least ten seconds between reads of the same tab, including failed reads that recorded no question.
Entering needs-input bypasses that gap, as does leaving needs-input with an open question.
If either transition happens during a read, its completion starts a fresh read.
A delivered `message_task`, or a prompt/unrecognised-screen refusal, triggers a fresh read of the
addressed tab, then another 1.5 seconds after that read finishes so Claude has time to draw its dialog.
These delivery reads bypass the gap and wait for any earlier read of that tab to finish; they do not
delay the tool's delivery result or its replay. Newly stalled workers are also probed with the tick's rules.

For a tab that is not in needs-input, prompt markers above a later input arrow are transcript text,
not evidence of an open dialog. Codex's update offer is declined only while its tab is not working
and every update marker is below any input arrow. Quoted update options cannot interrupt a working turn.

Claude model and effort confirmations can open without a Notification or PermissionRequest hook.
Alongside the known markers, Claude's last `❯` line reads as a menu when it selects a numbered
option next to the preceding or following option, outside the ruled input frame. Blank separators
and indented wraps or descriptions between options are allowed. This avoids
mistaking sent numbered messages above a later input arrow, or multiline drafts inside the frame,
for menus. In Claude Code 2.1.310, both a short numbered paste and a typed multiline draft stay
inline between the rules. The frame is recognised even when its footer is empty, status-only or
absent. Claude's ctrl+o detailed-transcript view has no input box and its sent messages do not count
as menus. Codex keeps its marker rules.
An open prompt is recorded as a question waiting on you and listed under `promptsWaitingOnYou`;
a present tab with that question reads as needs input in `run_status`. The question suspends
runtime and stall accounting until a successful read shows it closed. A blank or unreadable screen
leaves it open; `read_task` with `what: prompt` returns an error on a blank screen, not a null prompt.
An extra tab's prompt does not hide a quiet first worker.

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
limits), so it is read on a worker thread, as the subagent checks are, and only the lines
that contain a `token_count` are parsed. A read that does not answer within a second costs that
tick its Codex numbers, not the daemon its hook acks.

A tick publishes what it changed even if a step of it raises, and each corroborating step (a
session's file, the subagent transcripts) is guarded on its own: one that fails is
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

**The tick.** The tick reads the end of every counted Claude child's transcript, its parent's turn
under way or ended (`StatusEngine.release_dead_subagents`), and counts the child as gone when:

- its last record is the interruption the watchdog, or Esc, leaves (`[Request interrupted by
  user]`), or the attachment of a `SubagentStop` hook, written — by the time the record gives —
  after the child's latest `SubagentStart`, unless the last message before that attachment is a
  prompt the child has yet to answer (the hand-back reminder below), since Claude then runs the
  child on; or
- its transcript has not changed for `SUBAGENT_QUIET_SECONDS` (45 minutes) since its parent's ended
  turn first waited on it or its `SubagentStop` came, timed on the monotonic clock from the later of
  that moment and the first tick that saw it unchanged: quiet while its parent still worked does not
  count, nor does a session file that says on every tick that the turn ended begin the window again.
  A child of a turn still under way is left to that turn's `Stop`, which says what still runs. That
  clock stops while the Mac sleeps. The window is long because live children have gone 28 minutes
  without writing, during a long generation or a stream retry. It only catches a child that died
  without writing anything: every watchdog kill observed left the interruption.

A transcript that does not exist yet proves nothing, so that child stays counted until its
`SubagentStop`. A gone child is dropped exactly as its `SubagentStop` would have dropped it, so the
last one lands the deferred done. A real `SubagentStop` that arrives later changes nothing. A child
that is resumed fires `SubagentStart` again under the same id, which counts it again: a stalled one,
or a finished one its parent sends a message (`SendMessage`; Claude Code 2.1.308 writes the message
to the child's transcript, then fires `SubagentStart`). Its transcript's old interruption or
`SubagentStop` is then ignored, because the time that record gives is before that start. Its time,
not the file's: Claude writes its transcripts in batches, and a resume can come 30 ms after a run
ends, so the end of the earlier run can reach the file after the new `SubagentStart`.

A `SubagentStop` is not always the end of a Claude child's run either. Claude Code fires it each
time the child's turn ends, and (2.1.283 to 2.1.308 at least) then runs on a background child that
ended its turn without handing back its report: it writes a reminder to the child's transcript
(`[handback-send-enforce] Your report has not been delivered. Call SubagentHandback(…)`), fires
`SubagentStop`, and the child answers the reminder, hands its report back and fires `SubagentStop`
again. On 22 Oct 2026 the two were 11 s apart, and the task read done, ready for acceptance, in
between. So a Claude child with a transcript stays counted through its `SubagentStop`, until the
tick finds its run over by the rules above. Claude writes its transcript in batches, a median 70 ms
after a record's time and up to 1.6 s, so a tick right after the hook may not find the stop's
attachment yet and waits for the next; and the reminder comes before the attachment, so the tick
never finds that attachment without it. A child of Codex or PI, which have no transcript to read,
ends at its `SubagentStop`; a Claude child ends with the first read begun after its stop that looked
for its transcript and did not find it. A read that did not answer in time says nothing of the
child, nor does one that began before the stop came and found no transcript: the child waits for the
next. The cost: a Claude child's end lands with the first tick that finds its stop's attachment,
usually the next poll, 2 s after the hook, sometimes the one after, rather than with the hook. It
relies on Claude Code writing each `SubagentStop` hook's attachment to the child's transcript, as
every version seen does (2.1.283 to 2.1.308); without it, a stopped child would stay counted until
its parent's next `Stop` drops it, or the quiet window does.

`SubagentStart` carries only the session's `transcript_path`, `<dir>/<session>.jsonl`. The child's
transcript sits beside it at `<dir>/<session>/subagents/agent-<id>.jsonl`, or one directory further
down, where Claude Code files some agents, or two: a workflow's agents write theirs at
`subagents/workflows/<run>/agent-<id>.jsonl` (Claude Code 2.1.308). Only the last 64 KiB of each
transcript is read, on a worker thread with the one-second bound of the Codex rollout read above,
and again only once its mtime or size changes. Each read also notes when the transcript was last
written, its mtime, and the session carries the newest of its counted children's as
`subagentsWrittenAt`. A parent whose turn ended on its children writes nothing while they work, so
the app's doubt of a worker whose transcript has stopped growing (`WorkerQuietWatch`, `working?` in
`run_status`) reads this beside the worker's own transcript. It moves as a child writes, so no
sidebar row redraws for it (`SessionInfo.rowRelevant`).

Claude's own session file cannot do this job. It stays `busy` while a background child runs past the
end of the turn, and it names no child. Only Claude children are checked. PI relays a crashed
child's `:failed`, and no Codex child has yet been
seen to die without its `SubagentStop`.

What an agent reported belongs to its process, not the tab. A tab keeps its model, reasoning,
agent directory, context fill and conversation id only while the same agent runs under the same process id, from
one snapshot to the next. A Claude that exits to the shell, or a new Claude in the same tab,
starts blank: the row no longer shows the old worktree's branch, and Cmd+T opens where the shell
is. The state is not kept either: the tick that finds the tab back at its shell sets it idle at
once (`StatusEngine.agent_exited`), an exited agent's unseen done included. An
agent that hands the terminal to another program and gets it back under its own pid comes back
blank too — Claude's Ctrl+G opening `$EDITOR`. Claude's session file restores its directory in the
tick that sees it back; the model and context return with the next hook or status-line post.

## What a Claude worker runs, and what became of a slash command

The model a Claude session reports is the session's own, as Claude Code holds it: `SessionStart`'s
`model` as it starts, `PostModelSwitch`'s `to_model` once a switch has happened, and the status line's
`model.id`, the one it runs now. A `/model` moves them only once it has run, never when it is typed, and
one that asks the person to confirm ("Switch model?") changes none of them until it is answered. A post
from inside a subagent, which carries `agent_id`, sets nothing, and neither does one placed by its
directory alone: another agent in the same worktree, a headless review there, is not the tab's. Its
effort comes from the status line's `effort.level` alone, which Claude Code redraws once an `/effort`
has run, and leaves out for a model that takes none: a status line that names a model and no effort
clears the last one's. Its hooks carry an `effort` too, but a Stop's is its turn's: an `/effort` typed
mid-turn takes effect at once, and that turn's Stop can still name the old level. `run_status` shows
both beside the model a task was planned on, for Claude workers only: a Codex hook may carry a child
thread's model.

What became of a slash command `message_task` delivered to a Claude tab is read from that tab's
transcript (`slash_commands.py`; `transcript_path` from its own hooks and status line), on every tick,
from where the transcript ended when the earliest command still looked for was typed, a few megabytes a
read: a read behind that place skips to it. Its command record (`<command-name>`, a local command's
`<local-command-stdout>` after it) says it ran; a `queue-operation` `enqueue` holding its text says it
is queued, until anything leaves the queue that names it or names nothing: a `dequeue`, a `remove`, a
`popAll` or `popOne` that takes it back into the input. Nothing seen for a minute, or no transcript to
read, is unknown, never that it did not run: `/model` and `/effort` run at once even mid-turn and then
write no record at all, and one waiting on a dialog writes its record only once answered. A command is
looked for for an hour, and only what its transcript records within that hour is its own: past it, one
that has not run is unknown. A tab keeps its last three, and the same text typed twice is two commands,
each record taken by the older that can. One queued runs in its turn, the same text queued twice first
in first out, unless a `remove`, `popAll` or `popOne` named it first: then no run is its own. One never
seen queued ran at once if at all, so only a run recorded before the next of its text was typed is its
own, and a run of its text before any enqueue of it is one it ran at once: that enqueue is a later
command's, such as the person's.

## A turn that removes its own checkout

An agent that finishes by merging and deleting its own worktree deletes the directory its process
runs in. A hook that spawns a command in that directory then fails to fire. Codex's other hooks
are spawned commands and do fail, but its `Stop`, the end-of-turn signal, travels over MCP and still
arrives; Claude's hooks are HTTP posts and PI's extension runs inside PI. So no turn is stranded,
and the daemon has no rule for a vanished directory. A harness added later needs an end-of-turn
transport that survives one.

The app waits on the same fact before closing a removed task's window: `forgetRemovedCheckouts`
keeps its confirmed-removal check, and also waits while any of the task's sessions is still
`working` or `needsInput`. It closes the window on the first pass after they have all settled, so
an agent whose worktree just vanished finishes its final message before the window disappears.

## Why the branch is not iTerm2's to tell

iTerm2's `session.path` is the *shell's* directory. Claude Code chdirs its own process when it
enters a worktree, so the shell underneath never moves. Probed live on 17 Sep: four Claude tabs
all reported the repository root while their processes were inside `.worktrees/*`.

1. The daemon reads the agent's real directory — Claude from its own session file, and Codex
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
running. Marking the row done there made it go quiet mid-work; the turn's deferred done holds the
change until the last child reports back.

**A child that ran on after its stop** — Claude Code fires a child's `SubagentStop` when its turn
ends, even one it then runs on to hand back its report. Taking that first stop as the child's end
landed the deferred done early: the Operator found the task ready for acceptance while its review
still ran. The child's transcript now says which stop ended it.
