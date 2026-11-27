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
  explicit "needs input" notification, or Claude Code or PI asking whether to trust a folder. The one
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
| `Stop` | done | Deferred while a subagent is still alive — the last child finishes the change. A Claude `Stop` also drops each counted child its `background_tasks` does not list (below), and the session's `work` marks what still runs as holding the turn (`holdsTurn`): shells, monitors and other tasks, and the counted children by their description, each taken off as it ends. |
| `StopFailure` | done | Claude only, in place of `Stop` when an API error ended the turn. The session's `stoppedOn` names the error (`rate_limit` for a usage limit, `billing_error`, `authentication_failed`...), and for a limit when it resets, once the tick reads that in the transcript's own record of it within 30 s; it is never guessed. It clears once the session works again: a new prompt, a clean `Stop`, another conversation, its session file saying busy (Claude Code carrying on by itself once the limit reset), another process in the tab. |
| `PermissionRequest` | needsInput | Claude Code and Codex. |
| `Notification` | needsInput | Claude only: `permission_prompt`, `agent_needs_input`, `elicitation_dialog`, `elicitation_url_dialog`. |
| `Notification` | done | Claude only: `agent_completed`. |
| `SubagentStart` / `Stop` | working | Tracked per child id. A needs-input row is *not* overwritten — an input request must stay visible. A Claude child's `SubagentStop` ends it only once its transcript shows the run over, and a child that died without one is found there too (below). |
| `SessionStart` | metadata | Forgets the previous conversation's subagents and deferred completion — but not after a compaction (`source: "compact"`), and only in the tab the post provably came from. |

PI reports the same state machine through its public extension events:

| PI extension event | Signal | Notes |
|---|---|---|
| `session_start` | metadata | Resolves the PI session and updates context when present. With reason `startup`, `new`, `resume` or `fork` it is also Claude's `SessionStart`: the previous conversation's turn state is forgotten. `reload`, or no reason at all (an extension older than schema 3), is metadata only — PI's counterpart of a compaction. |
| `agent_start` | working | A PI turn started. |
| `ui_prompt_start` | needsInput | PI opened a prompt that needs the user. It remembers the state it interrupted — the first one, if prompts nest — and counts the prompts open. |
| `ui_prompt_end` | the interrupted state | Once the last open prompt closes, restores what the first interrupted: idle, done or working; an inner prompt closing leaves the row at needs input. A deferred completion is left alone. It changes nothing when no state is remembered: no prompt was opened, or a state hook since then took over. |
| `agent_settled` | done | The PI turn finished. |
| `rate_limits` | usage | Relayed from PI's `openai-codex` provider, which receives a `codex.rate_limits` stream event with each response: the ChatGPT account Codex spends, so it fills Codex's usage footer. Touches no row. |
| `thinking_level_select` | metadata | Refreshes the context percentage when present. |
| `turn_start` | working | Each model call of a run says the turn is at work again, so a run whose `agent_start` was lost still shows working from its next turn. No blocking prompt can be open then: it holds the tool that opened it. |
| `turn_end` | metadata | Refreshes the context percentage after each tool turn while the agent keeps running. Child sessions post nothing. |

PI has no subagents of its own, and AiTerm follows PI's own events only: a subagent package's
announcements are not relayed, so a child that outlives its parent's turn does not hold the row at
working. Extensions before schema 7 relayed @tintinweb/pi-subagents'; the daemon ignores those posts.

The extension sends its posts one at a time, in the order PI raised them, so a `turn_start` on a
slow connection never lands after its run's `agent_settled`.

Antigravity CLI reports through the command hooks AiTerm adds to `~/.gemini/config/hooks.json`, and
its status line:

| Antigravity source | Signal | Notes |
|---|---|---|
| `SessionStart` hook | metadata | Fires with the first prompt, not at launch: until then a tab says nothing, and its folder-trust dialog is read from the screen, as PI's is. |
| `PreInvocation` hook | working | Before each model call of a turn. |
| `Stop` hook | done | However the turn ended: finished, cancelled or failed. `fullyIdle: false` says a background command or subagent still runs: the transcript then says which (below). |
| subagent's hooks | subagentStart / subagentStop | A subagent runs as a conversation of its own whose hooks fire from its parent's tab. A post with an empty `lastUserInput` is a subagent's, even in a tab whose conversation a restarted daemon does not know yet: every post of the tab's own conversation carries its prompt. Any other post naming a conversation other than the tab's is a subagent's too, except a `SessionStart` that carries a prompt: the tab's own new conversation, its first or one after `/clear`. Its `SessionStart` or a model call counts it, its `Stop` with `fullyIdle: true` ends it. It never takes the tab's conversation or moves its state. |
| status line `task_count` | work | How many background commands run (absent when none). A reading without it ends every command the daemon read in the transcript more than five seconds before it, a killed one included: had it still run, the count would include it. The count lags a command going to the background by about two seconds, so a command seen since stays. |
| status line `agent_state` | tick evidence | `working`, `tool_use` and `reviewing` say working, `idle` says done, and `tool_confirmation_pending` says needs input: the one sign Antigravity gives that a tool waits for approval. It moves working to needs input and back, ends a turn whose Stop was missed, and brings an idle row back to working or needs input, as a restarted daemon finds every tab idle. A working or done reading within a second of a hook is held, not believed: it may describe the moment before. A hook or a newer reading replaces it; otherwise the tick applies it once the second has passed, so a lost Stop cannot leave the row working. |

Antigravity names its background work only in the conversation's transcript (the hooks'
`transcriptPath`, read from where the last read stopped). A command that outlasts its
`WaitMsBeforeAsync` is a `RUNNING` record, "running as a background task with task id: X", with its
`Task Description`, and ends with a message from `sender=X` that says it finished. That message
starts a turn of its own. A subagent is an `invoke_subagent` call and the "Created the following
subagent" record that names its conversation. A Stop with `fullyIdle: false` lists the running
commands and the subagents as its work, as a Claude Stop's `background_tasks` does. A subagent
holds the turn while it is counted, so the parent stays working until its last subagent ends: agy
1.5.18 can end the parent's last turn just before the subagent's last Stop and send nothing after
it. The tick reads the same transcript for every Antigravity tab, working or ended: it lists the
commands still running among the shown shells, and takes one whose end it reads out of the Stop's
work, should the turn that end starts never report.

These extension events use the existing urgency and unread rules; PI does not introduce a fifth
state. In particular, `agent_settled` stays Done until the row is seen, just like Claude Code and
Codex completion, and a PI input prompt outranks Working.

An open PI prompt keeps the row at needs input, but what happens under it lands in the state the
prompt will restore, because PI has no tick to correct it afterwards. Opening the row under
the prompt turns a remembered done into idle, so closing the prompt does not bring back a
completion already seen. Claude's and Codex's input requests remember nothing; their tick signals
below do the correcting.

Hooks are the primary source; corroborating ones run on the daemon's tick so a missed post
cannot strand a row — Claude's own session file (`busy`/`thinking`/`running` → working, `waiting`
→ needs input, `idle`/`shell` → the turn ended; any other status is ignored rather than read as
the end of the turn), and for Codex the braille spinner glyph at the head of its tab's iTerm2 title
and the turn boundaries its rollout records (a turn started or completed, counted only when newer
than the last hook). Each agent's module under `daemon/aitermd/agents/` maps its own readings to the
engine's `Evidence`; PI has none.

Claude Code's folder-trust dialog ("Yes, I trust this folder") comes before all of these: Claude
loads no hooks and writes no session file until the folder is trusted, so the tab's screen is the
only sign of it. The tick reads the screen of a Claude tab that has a process but no session file,
while its row is idle, or while the dialog holds the row (`CorroboratingReaders.trust_prompts` in
`corroboration.py`; the text is
the harness's `trust_prompt` in `HARNESSES`). The dialog moves an idle row to needs input, and
nothing else: a row a hook has moved is left alone. When it closes, the row goes back to idle and not
to done, because no turn ran. It is closed by the screen not showing it any more, by the session file
appearing, by any hook (only a trusted folder loads them), or by Claude exiting. A screen that
cannot be read changes nothing. A tab past the dialog has its session file, so its screen is not
read again.

PI asks the same of a folder with project resources (`.pi/extensions`, `.agents/skills` and the
like) when no saved decision applies: "Trust project folder?", before its extension posts anything.
The tick reads the screen of a PI tab that has a process but has not yet posted its session, while
its row is idle, or while the dialog holds the row, and treats the dialog as Claude's. Its
`session_start` closes it, and from then on the tab's screen is not read.

Signal workers use the same daemon session states and permission prompts as ordinary tasks.
A worker's human permission/sign-in prompt remains in its own terminal; the Operator never answers
it. Automated worker questions end a turn with a `Question:` paragraph and are read by
`SignalWorkerIO` only for active tasks. Watching tasks do not poll transcripts.

A saved delivery intent includes the previous assistant-reply fingerprint. The old reply cannot
finish the new turn or reopen its question; only a new fingerprint clears that intent. A CLI that
never starts, an idle worker that never replies, or a `StopFailure` blocks for inspection. A live
working turn/background job still keeps its stage busy. Question bindings include conversation,
full-message fingerprint, tab, stage and ownership; stale answers cannot reach a replacement.

The Operator asks product questions in its own chat, separately recording their waiting count.
Notifications open that one row/window; worker permission notifications open the worker.
Pause/signal-off tells current workers to end their turn and wait. Source polling and new effects
stop; successful carry-on delivery precedes further work when resumed. See [Operator](operators.md).

Daemon prompt recognition distinguishes a live dialog from numbered transcript text above a
later input arrow, including Claude's framed multiline drafts and model/effort menus. Delivery
checks validate the current process, ownership, worktree and screen immediately before typing.
Blank/unreadable screens never prove safe delivery.

A hook can arrive before the tick has classified its tab: `window.createTask` sends the agent
command and ticks at once, while the tab still reads as a shell, so the agent's `SessionStart` and
first prompt find no tab running that agent. A hook that places nowhere therefore asks for one tick
and is placed again against it, once; if it still places nowhere it is dropped. A post that carries
the id of a tab the registry still reads as a shell keeps asking, tick after tick, for up to five
seconds: the agent provably runs there and only iTerm2's name for the job is behind, which can take
more than one poll -- and PI runs its launch prompt the moment it starts, so its `agent_start` would
otherwise be lost for the whole turn. A tab that runs another agent is not waited on. Posts from one
source -- the tab a post names, else its agent's conversation -- are applied in the order they
arrived: one waits behind an older post of its source that still waits for its tab, so a quick
Escape's `agent_settled`, or a prompt opened at once, cannot land before the launch's `agent_start`. The ack has already
gone out, so no agent waits on this. Hooks that arrive before that tick starts share it, and no more
than one runs and one waits, at least a second apart, so a flood from an agent outside iTerm2 costs
about one tick a second. Statusline posts are not retried: the next one carries the same data.

Until then such a post can still be placed by its directory, but only on a tab that runs no other
conversation. A Claude tab knows its conversation from its own hooks and, failing those, from its
session file, which the tick reads by the tab's pid: a tab adopted after a restart, idle since before
it and silent since, still names its conversation. A tab whose conversation a hook named keeps it; a
`/clear`'s file may name the previous one for a moment. Without the file's word, a new tab's first
prompt in the same worktree landed on such an idle sibling, which then read working for good: the
sibling's file, older than that hook, could not correct it.

The tab title is read for that spinner and for nothing else, so a title that changes while nothing
else does is not a change to announce: a working Codex tab turns its spinner glyph on almost every
tick. The daemon keeps the newest title in its registry, where the status engine reads it, and
leaves it out of a session's equality and of the wire.

Each tracked Codex rollout is followed by one cursor from where the last read stopped, the thread
found through the tab's binding (`CodexThreads`). On first sight only its first line and its last
8 MiB are read. Only lines naming a session start, a turn boundary or a token count are parsed; a
line that cannot be parsed is skipped and logged once. Rollouts and account rate limits are read
on a worker thread, as the subagent checks are. A read that does not answer within a second costs
that tick its Codex numbers, not the daemon its hook acks.

A tick publishes what it changed even if a step of it raises, and each corroborating step (a
session's file, the subagent transcripts) is guarded on its own: one that fails is
logged and costs only its own changes. A reading is applied only while the session key it was
captured with (agent, process, conversation) still stands; one that a replacement overtook is
dropped.

Both lag the hooks, so neither may override a newer one:

- **Claude's session file** counts only if it was written after the last hook that set the state
  (working, needs input or done). Claude rewrites the file after the hook fires; until then it
  describes the moment before — `busy` under a fresh permission prompt, the last turn's `idle`
  under a new prompt. The file's directory is applied either way. An answered prompt still resumes
  the row: Claude rewrites the file, which is then newer than the hook.
- **A Codex title without a spinner** ends a working turn only if a spinner has been seen since the
  last hook said working. Codex draws it a moment after `UserPromptSubmit`, and a tick in between
  would otherwise mark the row done. The cost: a `Stop` lost in a turn shorter than one tick (2 s)
  is not corrected by the title; the rollout's record of the turn's end corrects it.

The file rule compares two wall-clock times: the daemon's clock when the hook arrived, and the
file's mtime. If the clock steps backwards between them (an NTP correction), a newer file looks
older than the hook, and it is ignored until the next hook.

Subagent tracking cannot outlive its conversation: a new `SessionStart`, or a different process id
in the tab, forgets every child still counted. One lost `SubagentStop` would otherwise hold the row at working for good.

Each session carries one ordered `work` list (`work_items`). First comes what the last Claude or
Antigravity Stop listed and still stands, each item marked `holdsTurn`: a subagent always, a shell once the turn has
ended or while the background-shell reader lists it (with the reader's text), a monitor or task
once the turn has ended. Agent work that is no counted child (a `workflow`, a `cloud session`, a `dream`) goes out as
`agent` so the card can show it by its vendor, and holds the turn exactly as a task does. Then come the counted subagents of the tab's current conversation and the
reader's shells that the Stop did not list, holding nothing. The sidebar's work card draws the whole
list, also while the tab works or asks; the row's background status and the Operator read only
`holdsTurn`. Optional `displayLabel` metadata enriches the card without changing raw `text`,
membership, ordering or readiness. Claude's confirmed parent launch results supply shell/child
descriptions; Codex's native parent `SubAgentActivity` supplies a child ID and named task path.
Readers apply labels only to current counted children, under the same process/conversation guards;
resumed IDs whose assignment cannot be correlated use their existing fallback. Label caches are
bounded independently of shell evidence. PI retains its existing labels until its optional
background extension's payload is verified. Codex and PI send no Stop list, so their work is their
counted children.

The Claude reader follows the parent transcript from SessionStart. For an already-open conversation,
it uses the matching PID file’s process start when available. Its fallback is daemon startup for a
Claude process in the first iTerm snapshot, or the time the daemon first saw a later process. Learning
the transcript path and conversation ID in either order allows adoption. A directly placed Claude
status line can supply both together. When it names a different conversation than the one already
known, its transcript waits for a parent hook to identify the new conversation. A change of conversation
retires that boundary, and a genuine clear or resume establishes a fresh one. If iTerm reclassifies
a process to or from Claude on the same PID, the daemon resets its turn and counted children just
as it does when the tab’s foreground PID changes.

A Bash result must confirm `backgroundTaskId`. Native completion notices and verified TaskStop
results end a shell. While the reader catches up, encounters a partial write or fails to read, the
live inventory is unavailable. A Stop can list a shell launched before the fallback boundary. If the
reader cannot account for its ID, it withholds the whole live shell list until it reads the launch
or end, or a later valid Stop omits the ID. Test runs
are not in the list; the app appends the active ones of ended tabs to the card.

### Teammates: running, idle, ended

A named agent of Claude Code's agent team (the Agent tool with a `name`, `teammate_spawned`) stays
alive after it delivers its report, waiting for messages. Claude Code (2.1.332) lists it in every
Stop's `background_tasks` as `{"type": "teammate", "status": "running"}` for as long as it lives,
idle or not: its task record keeps an `isIdle` flag the hook does not send. On that list alone,
eight teammates that had all finished held a row at "Background work · 8 jobs", its mark spinning,
until each was stopped.

The same reader tells them apart from the parent transcript (`TranscriptWork`, on the session as
`transcript_work`), each teammate by the name Claude Code gave it:

- **running**: spawned (`toolUseResult.status: "teammate_spawned"`), or a successful SendMessage to
  it (or to `*`) since it went idle. It is also running while the status engine counts its agent:
  a teammate fires `SubagentStart` and `SubagentStop` under its `agent_id`, so one a peer's
  message woke, which the lead's transcript does not show, still counts.
- **idle**: a `<teammate-message>` from it of type `idle_notification`. A notification written
  (its own `timestamp`) before a message woke the teammate is stale: Claude Code delivers queued
  notifications late, up to minutes after they were written.
- **ended**: a `teammate_terminated` message ("NAME has shut down."), or a TaskStop whose result
  says `task_type: "in_process_teammate"`, by name, agent id or task id. The TaskStop's task id,
  and any task a terminal `<task-notification>` ended, go into `ended_tasks`.

A Stop's teammate entry carries only its task id (`t…`) and the description it was spawned with,
so it is matched to the transcript's teammates by that description. `work_items` then shows it, as
the `subagent` it is on the wire, as running (holding the turn once the turn ended, on one line with
its counted agent),
as `idle` (holding nothing), or not at all once it ended or its task id is in `ended_tasks`. Two
live teammates with one description are idle only once both are. Only teammate entries read it: a
shell the Stop listed still holds the turn once it completed, until the next hook, because Claude
Code hands the completion to the agent as its next prompt. The reading is positive evidence only. While the transcript is not read to its end or a gap leaves it unknown,
and for a teammate spawned before this daemon saw the conversation start, an entry stays as the
Stop listed it. Only items that hold the turn spin the mark. The card's heading counts every item
that is not idle, shown work that holds nothing included, and lists idle teammates after the running
work, muted, each avatar wearing a `zzz` corner.

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
  child on.

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
its parent's next `Stop` drops it.

`SubagentStart` carries only the session's `transcript_path`, `<dir>/<session>.jsonl`. The child's
transcript sits beside it at `<dir>/<session>/subagents/agent-<id>.jsonl`, or one directory further
down, where Claude Code files some agents, or two: a workflow's agents write theirs at
`subagents/workflows/<run>/agent-<id>.jsonl` (Claude Code 2.1.308). Only the last 64 KiB of each
transcript is read, on a worker thread with the one-second bound of the Codex rollout read above,
and again only once its mtime or size changes.

Claude's own session file cannot do this job. It stays `busy` while a background child runs past the
end of the turn, and it names no child. Only Claude children are checked. PI relays a crashed
child's `:failed`, and no Codex child has yet been
seen to die without its `SubagentStop`.

The same ambiguity applies after a parent `StopFailure`: a busy file and an alive child alone do
not clear `stoppedOn`. The daemon reads the parent's transcript tail while it is stopped, caching
unchanged files. A new parent prompt or successful assistant response, timestamped after the failure
and the latest hook, proves the parent carried on and clears the marker. Child records, system
notices, pure tool results, older reports and a later API error do not count as recovery.

What an agent reported belongs to its process, not the tab. A tab keeps its agent directory, context
fill and conversation id only while the same agent runs under the same process id, from one snapshot
to the next. A Claude that exits to the shell, or a new Claude in the same tab, starts blank: the
row stops showing the old worktree's branch, and Cmd+T opens where the shell is. The state is not
kept either: the tick that finds the tab back at its shell sets it idle at once
(`StatusEngine.agent_exited`), an exited agent's unseen done included. An agent that hands the
terminal to another program and gets it back under its own pid comes back blank too — Claude's
Ctrl+G opening `$EDITOR`. Claude's session file restores its directory and conversation in the tick
that sees it back; the context fill returns with the next hook or status-line post. Codex's
hook-proven thread is also kept on its iTerm tab with the foreground process ID, by `CodexThreads`.
When that same Codex process returns, or the helper restarts, the thread is recovered from the tag,
and its rollout supplies the CLI version for the usual delivery check. Another agent or another
process cannot inherit it. `SubagentStart` and `SubagentStop` never replace that binding; a
directory-based placement pin does not establish one.

## A turn that removes its own checkout

An agent that finishes by merging and deleting its own worktree deletes the directory its process
runs in. A hook that spawns a command in that directory then fails to fire. Codex's other hooks
are spawned commands and do fail, but its `Stop`, the end-of-turn signal, travels over MCP and still
arrives; Claude's hooks are HTTP posts and PI's extension runs inside PI. So no turn is stranded,
and the daemon has no rule for a vanished directory. A harness added later needs an end-of-turn
transport that survives one.

The app waits on the same fact before closing a removed task's window: `forgetRemovedCheckouts`
waits while any of the task's sessions is still `working` or `needsInput`. It closes the window
on the first pass after they have all settled, so
an agent whose worktree just vanished finishes its final message before the window disappears.
While that window holds another row's tab (`TaskTeardown.holdsOtherWork`), the app leaves the
window alone and keeps the row saying Worktree missing until the other row's tab leaves.

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
   can send several changes a second, and a new context fill moves nothing.

## What the branch line can say

- **One branch, no tooltip** — e.g. `feat/pay-214-apple-pay`. Nothing to explain, so the
  row carries no hover text.
- **The window has other branches open** — e.g. `feat/shop-2210-preview-tokens +2`. The tooltip
  lists every tab: `tab 2 · codex · main`. The chip keeps its intrinsic width however narrow the
  sidebar gets — only the name truncates, and from the middle.
- **Drift** — e.g. `main` shown in the drift state. The active tab is not on the branch the task
  is bound to. The tooltip names both: `task · feat/shop-2210-preview-tokens`. Amber, because this
  is the case where the next command lands somewhere you did not mean.
- **No window open** — e.g. `main`. The row whose window you closed, or that has not opened one
  yet. A task falls back to its own branch, a terminal to the project's checkout. The row still
  says something true rather than going blank.
