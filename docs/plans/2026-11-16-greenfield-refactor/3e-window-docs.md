# 3e. The window docs

Implementer: Opus 5.5, high. Depends on: 3a, 3b, 3c, 3d (it documents what they built). Audit findings:
WD F1 (its doc half). Docs only: no Swift, no test change.

## Why

`docs/windows.md` explains the old lock in plain words: every row has exactly one window, a lone close
asks Remove, Archive or Cancel a second later, two quick closes come back on their own, iTerm2's restart
reopens everything, a terminal's close removes its row, a failed restore says "Couldn't reopen". After
3a and 3b all of that is false. The person-facing rule is now the closed view: a row's window is a view
of it; closing it asks nothing; choosing the row opens it; nothing opens by itself. This step rewrites
`docs/windows.md` for that rule, from the code as it now is, and fixes the few lines elsewhere that
still describe the lock. A reader who knows nothing of the old lock must come away knowing what a click,
an arrow key, a close, an iTerm2 restart and an AiTerm restart each do, for every kind of row.

## Today

- `docs/windows.md` (198 lines): sections "The one rule", "How AiTerm recognises its own windows", "What
  happens when…" (you close a task's window; you restore an archived task; you close a terminal's
  window; you close one tab; you close several windows at once; iTerm2 quits or crashes; AiTerm quits and
  starts again; you choose a row while iTerm2 is not running), "What 'comes back' means", "Why the
  one-second wait", "Closes AiTerm makes itself", "When it can't", "Known limits", and "Where it lives,
  for developers" (a table naming `windowPlan`, `WindowReconciler`, `ClosedWindowTriage`,
  `TaskRemover.confirmRemove(task:archiveInstead:)`, `WindowReconciler.hasFailed`). It says its release
  check "also appears in release.md"; `grep -n "restoration" docs/workflow/release.md` finds nothing.
- `docs/keyboard.md`, "Settings and alerts" (about line 92): "A lone task-window close offers Remove,
  Archive and Cancel; Cancel brings the window back. iTerm2 quitting/crashing asks nothing." The Return
  row (about line 41) says "A closed worker resumes its conversation; the Operator row opens the one
  chat", which stays true.
- `docs/status-model.md`, "What the branch line can say", the bullet **No window open** (about line 349):
  "e.g. `main`. A task falls back to its own branch, a terminal to the project's checkout."
- `docs/daemon-protocol.md`, events table, the `window.closed` row (about line 56): Remove's question, a
  terminal's lone close taking its row, restore once quiet.
- `docs/architecture.md`, the paragraph that begins "`WindowReconciler` compares desired rows with
  tagged sessions" (about lines 74 to 82): triggers, `ClosedWindowTriage`, the question.

What the code now does, to read before writing (re-read it, do not trust this summary):
`app/Sources/AiTerm/RowWindows.swift`, `AiTermCore/Daemon/AppState+WindowPlan.swift`,
`AiTermCore/Daemon/AppState+Snapshot.swift`, `AppState.closeWindow` in `AiTermCore/Models.swift`,
`AiTerm/RowFocus.swift`, `AppController.choose(_:)` and `restoreFromArchive(_:)`,
`TaskLauncher.openWindow`, `TerminalActions.openWindow`, `SignalWorkerIO.reopen`,
`SignalOperatorController.openChat`, `OperatorSessionKeeper.ensure(allowPaused:reopen:)`,
`AppState.rememberingConversations`, `TaskItem.resumeCommands`, `ItermConnection.banner(waited:)`.

## Change

1. **Rewrite `docs/windows.md`**, plain words first, type names only in the last section. Keep the
   title "Rows and windows" and the link to `architecture.md`. Sections, in order:
   1. *Intro.* Each task, review, terminal and the Operator's chat can have one iTerm2 window. The window
      is a view of the row: closing it is safe, and the row is where you get it back.
   2. *The one rule.* The row is the truth; its window is a view of it. Closing a window asks nothing
      and removes nothing. Choosing a row opens its window. Nothing opens by itself. A row without a
      window looks as it always did in that state: no agent marks, no status mark, its own branch on the
      branch line; a driven task's line says "window closed".
   3. *How AiTerm recognises its own windows.* The labels (`aiterm_task` on a task's or review's tabs
      and, with the session's id, on the Operator chat's; `aiterm_terminal` on a terminal's), a ⌘T tab
      inheriting it, and the cases where a row takes a window by its label: iTerm2 renumbered or restored
      it, AiTerm restarted, a tab was dragged to another window or windows were merged. Nothing is opened
      twice and nothing is asked.
   4. *What happens when…*, one short subsection each:
      - you close a row's window (any kind, by ⌘W, ⇧⌘W or the red button): the row stays without a
        window; its conversations stay remembered; Remove and Archive stay in its menu;
      - you choose a row without a window (a click, Return, a notification's Open, Restore in the
        Archive): its window opens beside the sidebar and comes forward;
      - you move with the arrow keys: a row with a window is shown without taking the keyboard; a row
        without one is only selected, nothing opens (Focus View and the attention counts move the same
        way);
      - you close one tab: nothing changes in the sidebar; that conversation is not remembered;
      - iTerm2 quits or crashes: nothing is asked; rows lose their windows; AiTerm does not start iTerm2
        again; when iTerm2 comes back, windows it restored itself are taken back by their label and every
        other row stays without a window until you choose it;
      - AiTerm quits and starts again: iTerm2 windows keep running; AiTerm starts iTerm2 if it is not
        running; open windows are taken back; a window that went missing meanwhile stays closed;
      - you choose a row while iTerm2 isn't connected: AiTerm starts iTerm2 and the banner says it isn't
        connected yet; choose the row again once it is (the sidebar's "iTerm2 isn’t running" banner has
        Open iTerm2);
      - you restore an archived task: worktree back at its path, row back in its project, then chosen
        as a click chooses it; a refusal leaves it archived with an alert saying why;
      - you add a project and import its worktrees: the rows come in without windows;
      - the Operator needs a window: it opens a worker's window when it launches or continues a stage,
        and reopens its own chat when it has something to tell it (a worker finished, a question waits,
        a task blocked); otherwise a closed chat stays closed until you click its row.
   5. *What opening means*, per kind: a task or review opens in its worktree with every remembered
      conversation resumed (the first in the window's own tab, each other in a tab of its own, in their
      order; its own agent on the model and reasoning you chose, an agent started by hand on its
      defaults; the first prompt never again; a plain shell when none is remembered; a turn cut off is
      not continued); a driven task resumes its worker's conversation under its branch guard, without
      repeating the stage prompt, and a driven task the Operator has not started yet has nothing to
      open; a task you took over opens as your task, making its worktree if the Operator never did; a
      terminal opens a fresh shell in its project folder and re-runs nothing; the Operator's chat
      resumes its conversation, or starts fresh if its workload had ended.
   6. *Closes AiTerm makes itself.* Remove, Archive (a window needs iTerm2 connected to close; without
      it Archive stops before closing anything and the row says "Not archived: iTerm2 isn’t
      connected"), a worktree deleted outside AiTerm (window closed, row removed, branch kept), Remove
      Terminal, and the Operator closing its chat when its workload ends or before a fresh chat. A
      Remove or Archive that stops after closing the window leaves the task without a window, like any
      other.
   7. *When opening fails.* The banner above the list says why, naming the row; nothing else marks the
      row; choose it again. A row whose worktree is missing opens nothing and says **Worktree
      missing**: restore the worktree or remove the task.
   8. *Known limits.* Lock Location snaps a window back when AiTerm places it; a window iTerm2 restored
      whose agent did not survive is taken back as a shell, not resumed; terminals re-run nothing; to
      check before a release: with iTerm2's window restoration on, quit and relaunch iTerm2 with tasks, a
      terminal and the Operator's chat open: each restored window is taken back once and nothing else
      opens. Drop the claim that this check is in `release.md`.
   9. *Where it lives, for developers*, a table: a row without a window (`TaskItem.windowId`,
      `TerminalItem.windowId`, `OperatorSession.window` is nil); taking windows by label
      (`AppState.windowPlan(sessions:)`, adoption only; the chat only outside a keeper handover); a
      window gone (`AppState.closeWindow`, `AppState.reconciled(with:)`); the one owner that applies both
      and opens a chosen row (`RowWindows`, its `open(_:)` choosing the opener per kind); what choosing a
      row does (`AppController.choose(_:)`, then `RowFocus.select(_:after:)`); selection, peek and
      raising (`RowFocus`); the labels (iTerm2 user variables `aiterm_task` and `aiterm_terminal`, read
      by the daemon's `sessions.py` and `windows.py`); the openers (`TaskLauncher.openWindow`,
      `TerminalActions.openWindow`, `SignalWorkerIO.reopen`, `TaskLauncher.openTakenOverWindow`,
      `SignalOperatorController.openChat` through `OperatorSessionKeeper.ensure`); which conversations
      resume (`AppState.rememberingConversations`, `TaskItem.resumeCommands`); starting iTerm2 (the
      daemon only at its own start, `connection.py`; the app's `launchIterm` at AiTerm's start, on a row
      chosen while iTerm2 isn't connected, and from the banner's Open iTerm2).
   Use only names that exist after 3a to 3d; grep each one before writing it.
2. **`docs/keyboard.md`**, "Settings and alerts": replace the two sentences about a lone task-window close
   and iTerm2 quitting with "Closing a row's iTerm2 window asks nothing; the row stays and Return opens
   it again." Leave the Return row as it is unless the code says otherwise.
3. **`docs/status-model.md`**, the **No window open** bullet: say it is the row whose window you closed,
   or that has not opened yet, and keep the fallback rule (a task shows its own branch, a terminal its
   project's checkout).
4. **`docs/daemon-protocol.md`**, the `window.closed` row: "the row whose window it was (a task, a
   terminal, or the Operator's chat outside a handover) has no window; nothing else follows."
5. **`docs/architecture.md`**, the window paragraph only: two or three sentences saying `RowWindows`
   clears a row's window when iTerm2 says it is gone, adopts tagged windows through the pure
   `AppState.windowPlan(sessions:)`, and opens a chosen row's window through the opener for its kind;
   `AppController.choose` decides what a choose does and `RowFocus` raises. Keep the sentences there
   about `TaskRemover`, `TaskArchiver` and `WorktreeTeardown` as they are. The rest of the file is 9a's.

## Keep

- The links into `docs/windows.md` from `README.md` and `docs/configuration.md` ("closing, restoration and
  reconnect behaviour"): the page still covers those.
- `docs/windows.md`'s style: short plain sentences for a person, the type names only in the last table,
  bold for the words the app shows (**Worktree missing**, **Not archived: iTerm2 isn’t connected**).
- `docs/keyboard.md`'s other alert sentences (Return and Escape defaults, unsaved changes, one-button
  alerts).

## Decisions already taken

- No mention of the old behaviour ("used to ask", "no longer reopens"): the page says what is true now.
  The release notes (9b) tell people what changed.
- The Operator's chat is a row like the others on this page; the workload and handover details stay in
  `docs/operators.md`.
- Taken-over tasks are described as they are after phase 3; 4e will change Take Over and update
  `docs/operators.md`, and 9a sweeps this page again.
- No em dashes; typographic apostrophes in quoted app strings, as the app shows them.

## Tests

None. This step changes only Markdown. `scripts/test.sh` on a docs-only change exits at once.

## Proof

- `grep -n "one-second\|one second\|Couldn't reopen\|Couldn’t reopen\|Cancel brings\|comes back on its own\|ClosedWindowTriage\|WindowReconciler\|archiveInstead\|hasFailed" docs/windows.md docs/keyboard.md docs/status-model.md docs/daemon-protocol.md docs/architecture.md`
  returns nothing.
- Every type or member named in `docs/windows.md`'s last section exists:
  `grep -rn "<name>" app/Sources daemon/aitermd` for each.
- Plain `scripts/test.sh` (it reports a docs-only branch and exits).

## Done when

- `docs/windows.md` has the nine sections above, in that order, and says nothing the code does not do.
- The four other files carry the replacements above and nothing else changed in them.
- The greps above return nothing.

## Not in this step

- The rest of `docs/architecture.md`, `docs/operators.md` beyond 3b's one line, and the READMEs: 9a.
- Release notes: 9b.
- Any Swift change: if the code turns out to differ from what 3a to 3d describe, report it rather than
  change code here.
