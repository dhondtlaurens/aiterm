# Rows and windows

Each task, review, terminal and the Operator's chat in the sidebar can have one iTerm2 window. The
window is a view of the row: closing it is safe, and the row is where you get it back. This page
explains in plain words what a click, an arrow key, a close, an iTerm2 restart and an AiTerm
restart each do. [architecture.md](architecture.md) has the same story with the type names; the
last section here maps one onto the other.

## The one rule

**The row is the truth; its window is a view of it.**

- Closing a window asks nothing and removes nothing.
- Choosing a row opens its window.
- Nothing opens by itself: a window opens because you chose its row, or because the Operator needs
  it ([below](#the-operator-needs-a-window)).

A row without a window looks as it always does in that state: no agent marks, no status mark, and
its own branch on the branch line. A task the Operator drives says "window closed" on its line.

## How AiTerm recognises its own windows

Each window AiTerm opens carries an invisible label: the id of the row it belongs to, stored as an
iTerm2 variable on every tab. A task's or a review's tabs carry `aiterm_task`, and so do the
Operator chat's, with its session's id; a terminal's carry `aiterm_terminal`. A tab you open with
⌘T inside one of those windows gets the same label.

That label is what lets a row take a window that is already open, however it got where it is:

- iTerm2 renumbered it, or restored it itself from its own saved windows. The label is saved with
  the window and comes back with it.
- AiTerm quit and started again while the window stayed open.
- You dragged the row's tab into another window, or used Window ▸ Merge All Windows.

In each case the row simply takes the window its label is in. Nothing is opened twice, and nothing
is asked.

## What happens when…

### You close a row's window

Any kind of row, by ⌘W on its last tab, ⇧⌘W or the red button. The row stays in the sidebar,
without a window. Nothing is asked. A task's conversations stay remembered, so choosing the row
resumes them. Remove and Archive stay in the row's menu for when you do mean to let it go.

### You choose a row without a window

A click, ↩, a notification's Open, or Restore in the Archive. The row's window opens beside the
sidebar and comes forward, iTerm2 with it. A row that already has a window has it brought forward
instead. A task the Operator drives with a tab asking for something brings that tab forward.

### You move with the arrow keys

The arrows look; they do not open. A row with a window has it shown beside the sidebar without
taking the keyboard away from the list. A row without one is only selected: nothing opens. Focus
View and a heading's attention counts move the selection the same way. ↩ or a click then opens it.

### You close one tab

Tabs are yours. Closing one tab of a window that keeps other tabs changes nothing in the sidebar.
The conversation that tab was running is no longer remembered, so it is not resumed next time.

### iTerm2 quits or crashes

Nothing is asked and nothing is removed: the rows lose their windows. AiTerm does not start iTerm2
again on its own, since a deliberate quit and a crash look the same from the outside.

When iTerm2 comes back, whoever starts it, the windows iTerm2 restored itself are taken back by
their label. Every other row stays without a window until you choose it.

### AiTerm quits, and starts again

Quitting AiTerm leaves your iTerm2 windows running, and your agents keep working. The sidebar is
saved.

When AiTerm starts again, it starts iTerm2 if it is not running. Windows that are still open are
taken back by their label. A window that went missing while AiTerm was closed, even one you closed
yourself, stays closed: its row waits without a window until you choose it.

### You choose a row while iTerm2 isn't connected

AiTerm starts iTerm2 and remembers the row. Once iTerm2 connects, AiTerm opens that row's window
and brings it forward by itself, if the row is still the selected one. Only the last row chosen
is remembered; if you have moved on, nothing opens.

Meanwhile the banner above the list says what stands in the way: **iTerm2 isn’t running.**, with
**Open iTerm2**; after a short wait, **AiTerm isn’t connected to iTerm2.**, with **Open Settings**,
when iTerm2 runs but has not let AiTerm connect; or **iTerm2 refused AiTerm.** when iTerm2 says no.

### You restore an archived task

Restore in the Archive sheet (⌘↩, or a double-click). Its worktree is recreated at the same path,
the row returns to its project, and the row is chosen as a click chooses it: its window opens with
its conversations resumed and comes forward. If the worktree cannot come back (its branch is gone,
or something else is in its folder), an alert says why and the task stays archived.

### You add a project and import its worktrees

Each imported worktree becomes a task row without a window. Choosing one opens it.

### The Operator needs a window

The Operator opens a worker's window when it launches or continues a stage in a task. It opens its
own chat when a workload starts, and reopens a chat you closed when it has something to tell it:
a worker finished, a question waits, or a task is blocked or waits for its agent choice, for
example. Otherwise a closed chat stays closed until you choose its row.

## What opening means

**A task or review** opens in its worktree, and every conversation its tabs last showed is
resumed: the first in the window's own tab, each other in a tab of its own, in the order they
were. The agent you created the task with resumes on the model and reasoning you chose; an agent
you started by hand in a tab resumes on its defaults. The task's first prompt is never sent again.
With no conversation remembered, the window is a plain shell in the worktree. A resumed
conversation reopens where it stopped and then waits for you: a turn cut off when its window went
is not continued.

**A task the Operator drives** resumes its worker's conversation under its branch guard, without
sending the stage's prompt again. One the Operator has not started yet has nothing to open.

**A task you took over** is your task and opens like one. If the Operator never made its worktree,
Take Over made one.

**A terminal** opens a fresh shell in its project folder. Whatever was running there, a dev server
for example, is not started again.

**The Operator's chat** resumes its conversation, or starts a fresh one if its last workload had
ended.

## Closes AiTerm makes itself

Some windows close because AiTerm closed them:

- **Remove Task… / Remove Review…** asks all its questions first, then closes the window, and any
  other window one of the task's tabs was moved to, before deleting the worktree. A task with a
  window needs iTerm2 connected to close it: without, it stops before closing or deleting anything,
  and the row says **Not removed: iTerm2 isn’t connected**. A task with no window is removed either
  way. A window that would close holding other work (another row's tab in the task's window, or
  any tab not the task's in the window one of its tabs was moved to) stops it the same way, and
  the row says **Not removed**; move that tab to its own window or close it, then try again.
- **Archive Task** does the same, then moves the row to the Archive. Without iTerm2 connected, a
  task with a window says **Not archived: iTerm2 isn’t connected**, and a window shared with other
  work says **Not archived**.
- **A worktree deleted outside AiTerm**: AiTerm notices, closes the window, and any other window
  one of the task's tabs was moved to, and removes the row. The branch is kept. While one of those
  windows holds other work, as for Remove, nothing closes: the row stays, saying **Worktree
  missing**, until that tab has left.
- **Remove Terminal** closes the terminal's window and removes its row.
- **The Operator** closes its chat when its workload ends, and before it starts a fresh chat.

A Remove or an Archive that closes the window and then stops (git refuses to delete the worktree,
you choose Keep when asked about unsaved work, or the worktree was detached from its branch) leaves
the task in the sidebar without a window, like any other.

## When opening fails

The banner above the list says that the window could not open, and why. A terminal's names the
terminal; a task's names no row, and goes when that task opens or leaves the sidebar. Nothing else
marks the row. Choose it again to try again. A task's window that opens but whose agent or resume
command iTerm2 could not type stays open as a plain shell, and the banner says so, with why.

A row whose worktree is missing opens nothing and says **Worktree missing**: restore the worktree
or remove the task.

## Known limits

- **iTerm2's Window ▸ Lock Location** snaps a window back when AiTerm places it. Turn it off.
- **A window iTerm2 restores whose agent did not survive** (you quit iTerm2 with its window
  restoration turned on) is taken back as it is, a shell, without resuming the conversation. After
  a crash, iTerm2 usually keeps the agent running, so this is mostly about a deliberate quit.
- **Terminals don't re-run anything.** A terminal opens as an empty shell in its folder.
- **To check before a release:** with iTerm2's window restoration on, quit and relaunch iTerm2 with
  tasks, a terminal and the Operator's chat open. Each restored window is taken back once, and
  nothing else opens.

## Where it lives, for developers

| In plain words | In the code |
|---|---|
| A row without a window | `TaskItem.windowId`, `TerminalItem.windowId` or `OperatorSession.window` is nil |
| Taking windows by their label | `AppState.windowPlan(sessions:)` (Core, pure): adoption only; the Operator's chat only outside a keeper handover |
| A window gone | `AppState.closeWindow`, and `AppState.reconciled(with:)` for a connected snapshot |
| The one owner that applies both and opens a chosen row | `RowWindows`, whose `open(_:)` picks the opener for the row's kind; a row chosen while iTerm2 isn't synced comes back through `onPendingOpen` |
| What choosing a row does | `AppController.choose(_:)`, then `RowFocus.select(_:after:)` |
| Selection, peek and raising | `RowFocus` |
| The invisible label | iTerm2 user variables `aiterm_task` / `aiterm_terminal`, read by the daemon (`sessions.py`, `windows.py`) |
| The openers | `TaskLauncher.open` for a task, manual, driven or taken over (through `TaskLauncher.openWindow`), `TerminalActions.openWindow`, `OperatorChat.open` through `OperatorSessionKeeper.ensure` |
| Which conversations resume | `AppState.rememberingConversations`; `TaskLauncher.openCommands(for:)`: `TaskItem.resumeCommands` for your task, the first worker's under its guard for a driven one |
| Starting iTerm2 | The daemon only at its own start (`ItermSupervisor`, `connection.py`); the app's `launchIterm` at AiTerm's start, on a row chosen while iTerm2 isn't connected, and from the banner's Open iTerm2 |
