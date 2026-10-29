# Daemon protocol

The Unix socket joins the Swift app and Python daemon. `DaemonProtocol.swift` and
`daemon/aitermd/protocol.py` define the names and framing; cross-language wire fixtures prove their
agreement. The following tables describe the current contract.

## Commands the app sends

| Command | What it does |
|---|---|
| `workspace.snapshot` | accepts the app-resolved `claudeConfigDirectory`, applies it before the tick, and echoes it as sent (also on adoption); the bootstrap: protocol version, whether iTerm2 is connected, `itermVersion`, `itermAuthError`, `itermCookieRequest` (a cookie request made before the app attached), every session, usage — written before any later event |
| `window.createTask` | new window in a worktree, launching the agent command; a retry returns the existing window. Once iTerm2 has made a window it is returned, even if tagging it, typing the command or the tick after fails — that is logged, since an error would make the app open a second one. The new window is found through the same locked refresh as every tick, never one that overlaps a tick's. Only a window whose shell ended at once is answered `iterm_unavailable`. A restored window passes the first remembered conversation's resume command, or none. With `background`, the window is placed and tagged but neither activated nor brought forward: a task the Operator starts opens behind your work |
| `window.createTerminal` | new window in the project folder, no agent. The optional `terminalId` tags it `aiterm_terminal`, which the app adopts the window by; the sessions carry it back as `terminalId` |
| `window.activate` | bring it forward when its row is clicked |
| `session.activate` | select one tab in its window and bring that window forward: an Operator's task with several worker tabs, its asking tab on a row's click, or the tab a board card's line names |
| `window.setFrame` | re-snap beside the sidebar |
| `window.close` | on remove, and before a worktree is deleted. The window is closed once iTerm2 has answered: a failed tick after it is logged, not answered |
| `tab.create` | a tab in an existing window, tagged like it: in `cwd` when given (a review opened in its task, a conversation resumed in a restored window), else where the active tab is. The optional `tabKey` tags that one tab `aiterm_tab` beside its task's tag, never inherited, and the sessions carry it back as `tabKey`: an Operator's extra worker tab (`open_tab`). A request with a `tabKey` already on a tab of its task returns that tab. With `background`, iTerm2 is asked not to select it: its window is not brought forward and keeps the tab you were on |
| `sessions.setTitles` | branch titles for AiTerm tabs, re-sent every couple of seconds; the daemon only applies changes |
| `sessions.markSeen` | clear a done mark when its row is opened |
| `interface.setMatchItermBackground` | paint AiTerm windows #1E1E1E |
| `iterm.provideCookie` | the answer to `iterm.cookieRequested`: a cookie and key, "not running", or why iTerm2 refused. An answer to a request that has timed out or been answered is not accepted |
| `session.deliver` | types a message into an agent's tab by the delivery adapter's rules: refused unless the CLI passed the delivery check (`delivery-policy.json`) for the major and minor version the tab runs (`verdict_covers`: a pass for 2.1.301 holds for every 2.1.x; Claude's session file, Codex's rollout), its screen reads and no prompt is open; a bracketed paste, 0.4 s, the same checks again, then Enter — anything changed in between, a takeover among it, holds the Enter back and answers `partial`. Over 2000 characters it is left in `<worktree>/.aiterm/messages/<n>.md`, everything checked again, and one fixed line typed. With `wake`, the Operator's wake line: no pass from the delivery check needed, every other check kept, never a message file, a text with a digit or a one-letter word refused; and refused while you typed in that tab in the last 10 s, or while its input may hold text not yet sent. The reply's `code` names a refusal's reason in one word (`delivery.RefusalCode`) |
| `session.prompt` | the prompt the tab's screen shows open: `permission`, `startup`, `menu` or none; a blank screen is an error. Recognition rules are below this table |
| `session.dismissStartup` | declines the CLI's update offer with Esc only while its tab is not working and its update options appear below any input arrow; other startup dialogs remain yours to answer: `{dismissed: false}` |
| `session.setOwnership` | a task's ownership generation, which a takeover increments: a send begun under an older one is refused, and a generation is never lowered. In memory only; the app sets each again after a daemon restart |
| `operator.register` / `operator.revoke` | open and close `/operator` to a broadcast's token. The app also writes each run's `operators/runs/<run-id>/token` (0600), which the daemon loads at start and rereads for a token it does not know, so a daemon restart costs the operator nothing; revoke also deletes that file |
| `operator.reply` | the app's answer to an `operator.request`: its result, or the error the operator is told. One the daemon no longer waits for is dropped |

`session.prompt` recognises Claude's last selection arrow on a numbered option next to its preceding
or following option, outside the ruled input frame, even without a known footer (including model
and effort confirmations). Indented wraps, descriptions and blank separators are allowed. A later
input arrow or the ctrl+o detailed-transcript view rules out a numbered menu. Codex uses its markers.
For tabs not in needs-input, markers above a later input arrow belong to the transcript.

`iterm.status`, `sessions.list` and `usage.get` are still served, for `python -m aitermd ctl`.
Malformed parameters are answered with `bad_params`, an iTerm2 call that fails or runs out of
time with `iterm_unavailable` — the tick a command runs before it changes anything included.

Requests are answered concurrently, each as soon as its handler returns, so a slow
`window.createTask` holds up nothing behind it. The `workspace.snapshot` reply is still written
before any later event. `sessions.setTitles`, `interface.setMatchItermBackground`,
`window.setFrame`, `window.activate` and `session.activate` each leave a state the next one replaces, so each takes
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
| `session.opened` / `.changed` | a new tab, a new agent, a new state, a new model, a new conversation (`conversationId`, which the task saves for its restore), a new write by a subagent it counts (`subagentsWrittenAt`, which tells the Operator a turn that ended on its subagents is still at work); a tab tagged with a row's id in a window the row lacks hands the row that window |
| `session.closed` | drops one avatar from the group |
| `usage.changed` | a status-line tick landed, or Codex wrote a new rate-limit record |
| `operator.request` | the Operator's tool call, for the app to answer with `operator.reply` within 30 s; past that the operator is told "AiTerm isn't answering", and with no app attached the daemon answers "AiTerm isn't open" without sending it |

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
