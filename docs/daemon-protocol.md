# Daemon protocol

The Unix socket joins the Swift app and Python daemon. `DaemonProtocol.swift` and
`daemon/aitermd/protocol.py` define the names and framing; cross-language wire fixtures prove their
agreement. The following tables describe the current contract.

## Commands the app sends

| Command | What it does |
|---|---|
| `workspace.snapshot` | the connection's own: asked when the app connects and when it reads iTerm2 afresh, never by code that only wants the tabs. Accepts the app-resolved `claudeConfigDirectory`, applies it before the tick, and echoes it as sent; the bootstrap: protocol version, whether iTerm2 is connected, `itermVersion`, `itermAuthError`, `itermCookieRequest` (a cookie request made before the app attached), every session, usage — written before any later event |
| `window.createTask` | new window in a worktree, launching the agent command; a retry returns the existing window. Once iTerm2 has made a window it is returned, even if tagging it, typing the command or the tick after fails — that is logged, since an error would make the app open a second one. The new window is found through the same locked refresh as every tick, never one that overlaps a tick's. Only a window whose shell ended at once is answered `iterm_unavailable`. A restored window passes the first remembered conversation's resume command, or none. With `background`, the window is placed and tagged but never activated: iTerm2 makes a brand-new window key and orders it front even unselected, so the window that had keyboard focus is activated again before the command is typed, also when iTerm2 is not the active app (activating a window does not activate iTerm2; switching back then finds your window key). Only that window goes back in front; others the new one covers stay covered. A task the Operator starts and the Operator's chat open behind your work, and the app asks for them only after you pause (`PauseGate`) |
| `window.createTerminal` | new window in the project folder, no agent. The optional `terminalId` tags it `aiterm_terminal`, which the app adopts the window by; the sessions carry it back as `terminalId` |
| `window.activate` | bring it forward when its row is clicked |
| `session.activate` | select one tab in its window and bring that window forward: an Operator's task with several worker tabs, its asking tab on a row's click, or a worker permission prompt's tab |
| `window.setFrame` | re-snap beside the sidebar |
| `window.close` | on remove, and before a worktree is deleted. The window is closed once iTerm2 has answered: a failed tick after it is logged, not answered |
| `tab.create` | a tab in an existing window, tagged like it: in `cwd` when given (a review opened in its task, a conversation resumed in a restored window), else where the active tab is. The optional `tabKey` tags that one tab `aiterm_tab` beside its task's tag, never inherited, and the sessions carry it back as `tabKey`: an Operator's extra worker tab (`open_tab`). A request with a `tabKey` already on a tab of its task returns that tab. With `background`, iTerm2 is asked not to select it: its window is not brought forward and keeps the tab you were on |
| `sessions.list` | the tabs now, after a tick, or the last known ones if the tick fails; no event. What the Operator's chat asks while it opens and closes |
| `sessions.setTitles` | branch titles for AiTerm tabs, re-sent every couple of seconds; the daemon only applies changes |
| `sessions.markSeen` | clear a done mark when its row is opened |
| `interface.setMatchItermBackground` | paint AiTerm windows #17181B, the sidebar's ground |
| `iterm.provideCookie` | the answer to `iterm.cookieRequested`: a cookie and key, "not running", or why iTerm2 refused. An answer to a request that has timed out or been answered is not accepted |
| `session.deliver` | types a message into an agent's tab by the delivery adapter's rules: refused unless the CLI passed the delivery check (`delivery-policy.json`) for the major and minor version the tab runs (`verdict_covers`: a pass for 2.1.301 holds for every 2.1.x; Claude's session file, Codex's rollout), its screen reads and no prompt is open; a bracketed paste, 0.4 s, the same checks again, then Enter — anything changed in between, a takeover among it, holds the Enter back and answers `partial`. Over 2000 characters it is left in `<worktree>/.aiterm/messages/<n>.md`, everything checked again, and one fixed line typed. With `wake`, the Operator's wake line: no pass from the delivery check needed, every other check kept, never a message file, a fixed Signal event plus task UUID is accepted without host text; all other text is refused; and refused while you typed in that tab in the last 10 s, or while its input may hold text not yet sent. With `guardInput`, any other text held to those same checks of you (typing in the last 10 s, input that may hold unsent text, no keystroke monitor), with the delivery check's pass still needed and no wake grammar: a project signal's prompt typed into a conversation that is also yours. The reply's `code` names a refusal's reason in one word (`delivery.RefusalCode`) |
| `session.closeIdle` | closes only the addressed ended CLI under the exact conversation/ownership and input checks, preserving sibling tabs. Used to resume a worker or replace the idle Operator without terminating somebody's active turn |
| `session.inputState` | what a session's input holds, read and never typed into nor noted: `input` is `unsent` while you typed there in the last 10 s, when its screen shows typed text, or, with no input to read on its screen, when keys were seen typed there and not sent; `empty` when the keys seen leave it empty, its screen shows it empty, or it has closed; `unknown` otherwise (an unread screen, or no input to read and its key history unknown). A project signal's Archive waits while a tab of the task may hold your unsent words |
| `session.setOwnership` | a task's ownership generation, which a takeover increments: a send begun under an older one is refused, and a generation is never lowered. In memory only; the app sets each again after a daemon restart |
| `operator.register` / `operator.revoke` | carry the session's `operatorId` and `generation` (and, to register, its token); one private `operators/operator/token` and `session.json` bind session identity, generation and token hash, which a restarted daemon reads. A revocation for another session or generation changes nothing, so it cannot revoke a successor. A failed deletion of the token file remains owed on retry |
| `operator.reply` | the app's answer to an `operator.request`: its result, or the error the operator is told. One nothing waits for any more is dropped |
| `delivery.policy` | each agent's delivery-check verdict and version as the daemon reads it for every delivery: what the app tells the Operator before it plans a task on that agent |

`iterm.status` is the client's liveness check, answered from what the helper holds without asking
iTerm2; it and `usage.get` also serve `python -m aitermd ctl`, and the app never sends `usage.get`.
Malformed parameters are answered with `bad_params`, an iTerm2 call that fails or runs out of
time with `iterm_unavailable` — the tick a command runs before it changes anything included.

Requests are answered concurrently, each as soon as its handler returns, so a slow
`window.createTask` holds up nothing behind it. The `workspace.snapshot` reply is still written
before any later event. `sessions.setTitles`, `interface.setMatchItermBackground`,
`window.setFrame`, `window.activate` and `session.activate` each leave a state the next one replaces, so each takes
effect in the order it was sent.

## Events the daemon sends

| Event | What it means |
|---|---|
| `iterm.connected` | ends the wait for iTerm2 and clears its banner |
| `iterm.disconnected` | the app waits; after a short grace its banner says **AiTerm isn’t connected to iTerm2.**, with Open Settings; the daemon retries on its own, without launching iTerm2 again; a cookie answer of not running shows **iTerm2 isn’t running.**, with Open iTerm2 |
| `iterm.auth_failed` | iTerm2 is running but refused the API cookie; the banner **iTerm2 refused AiTerm.** explains the Automation fix, with the reason in its tooltip. Retries back off to once a minute, and the snapshot's `itermAuthError` carries the reason for an app that attaches later |
| `iterm.cookieRequested` | the daemon needs a cookie for its next connect; the app asks iTerm2 with an Apple event and answers with `iterm.provideCookie`. An attached app that stays silent for 120 s is asked again, under a new id; time with no app attached does not count |
| `window.activated` | aligns the sidebar selection when iTerm2 is raised from outside — e.g. by clicking an agent's notification |
| `window.closed` | the row whose window it was (a task, a terminal, or the Operator's chat outside a handover) has no window; nothing else follows |
| `session.opened` / `.changed` | a new tab, a new agent, a new state, a new conversation (`conversationId`, which the task saves for its restore); a tab tagged with a row's id in a window the row lacks hands the row that window |
| `session.closed` | drops one avatar from the group |
| `usage.changed` | a status-line tick landed, or Codex wrote a new rate-limit record |
| `operator.request` | the Operator's tool call, for the app to answer with `operator.reply` within 30 s; past that the operator is told "AiTerm isn't answering", and with no app attached the daemon answers "AiTerm isn't open" without sending it |

Session payloads carry `work`, one ordered list of what runs beside the agent's turn, each item with
`kind`, `text`, `holdsTurn` and `idle`, plus an optional `displayLabel` containing a verified native short
description. The card uses that label when available; raw `text` remains the command or existing
task text consumed by status and the Operator. Missing labels preserve the existing fallback.
`holdsTurn` marks what the last Stop listed, which wakes the agent
again; the items after it are subagents and shells read live. `idle` marks a Claude Code teammate
that finished its turn and waits for a message: it never holds the turn, and the card lists it
apart (`docs/status-model.md`, Teammates). The app reads a missing `idle` as false. The sidebar's card draws the whole
list, the row's status and the Operator read only the `holdsTurn` items, and a change to the list
publishes `session.changed` even when the state stays the same.

Session payloads carry nullable `contextTokens`: this conversation's current input context,
including input, cache creation and cache read tokens, excluding output and lifetime billing totals.
A finite percentage and valid window size provide an estimate only when exact usage is unavailable.
Null is unknown. Counts are never promoted to sibling tabs and are cleared when the process changes.

The single Operator's `operator.request` carries the session's `operatorId` and the token's
`generation`; the app checks both before acting. The token serves thirteen Signal tools. Task
actions also carry stage/ownership; the shell gate is a separate private route. A missing/revoked
token always denies `/operator/gate`, including revocation while waiting for the app. The app also
returns a real gate denial for stale session/claim data. An unavailable Oracle follows the explicit
unchecked shell policy; it never counts as agreement to a worker answer or automatic merge.

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

The socket is the only channel, and the app talks only to a helper it started: a stale helper a
crash left holding the socket is ended, and the app starts its own. If the daemon dies, the
supervisor restarts it; from the second failure the banner names the log at
`~/Library/Application Support/AiTerm/aitermd.log`.
