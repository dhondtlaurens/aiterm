# Rows and windows

Every task, review and terminal in the sidebar has exactly one iTerm2 window, and the two are locked
together. You never see a row without its window, and you never have to think about whether a
window is "still there". This page explains how that works in plain words: what happens when you
close a window, when iTerm2 quits or crashes, and when AiTerm itself quits and comes back.
[architecture.md](architecture.md) has the same story with the type names; the last section here
maps one onto the other.

## The one rule

**The row is the truth; the window follows it.**

The sidebar holds what *should* be open: one window per row. iTerm2 holds what *is* open. AiTerm
keeps comparing the two, and whenever they differ it closes the gap: a row that has lost its window
gets it back, and a window that turns up for a row is taken by that row. It never works the other
way round. A window disappearing does not make a row disappear, unless you meant to remove it.

The row is never shown in a "Window closed" state. A row whose window is on its way back looks
exactly as it did. The only time a row says anything about its window is when AiTerm tried to bring
it back and could not (see [When it can't](#when-it-cant)).

## How AiTerm recognises its own windows

Each window AiTerm opens carries an invisible label: the id of the row it belongs to, stored as an
iTerm2 variable on every tab (`aiterm_task` for a task or review, `aiterm_terminal` for a terminal).
A tab you open with ⌘T inside one of those windows gets the same label.

That label is what lets AiTerm find a window again, however it got where it is:

- iTerm2 renumbered it after a restart.
- iTerm2 restored it itself, from its own saved windows. The label is saved with the window and
  comes back with it.
- You dragged the task's tab into another window, or used Window ▸ Merge All Windows.

In each case the row simply takes the window its label is in. Nothing is opened twice, and nothing
is asked.

## What happens when…

### You close a task's window

You close the whole window: its last tab with ⌘W, ⇧⌘W, or the red button. AiTerm reads that as
you choosing **Remove Task…** on the row, and offers **Shelve** beside it.

1. AiTerm waits one second (see [Why the one-second wait](#why-the-one-second-wait)).
2. It comes forward with the question Remove Task… asks, with a third answer: *Remove task "…"?
   Deletes its worktree and closes its iTerm2 window. Shelve does too, but keeps it to restore
   later.* For a review it adds that Remove also deletes its local branch, unless it has unpushed
   commits.
3. **Remove** removes the task: its worktree is deleted and, if you ticked it, its branch. The
   window is already gone.
4. **Shelve** shelves the task, exactly as its menu's Shelve Task does: its worktree is deleted, its
   branch is kept, and the row moves to the shelf (View › Show Shelf, ⌘S), its conversations
   remembered. The window is already gone. If the worktree has uncommitted changes, you are asked
   first: Keep leaves the task in the sidebar, and its window comes back.
5. **Cancel** means you want to keep it. The window comes straight back, in the worktree, with its
   conversations resumed, and it is brought to the front.

Questions come one at a time. If you close two task windows a few seconds apart, the second
question waits until you have answered the first.

### You restore a shelved task

Restore in the Shelf sheet (⌘↩, or a double-click) is you asking for the task back. Its worktree
is recreated at the same path, the row returns to its project, and the row is chosen as a click
chooses it: the window opens in the worktree with its conversations resumed, and it is brought to
the front. If the worktree cannot come back (its branch is gone, or something else is in its
folder), an alert says why and the task stays on the shelf. If the window then fails to open, the row
says **Couldn't reopen**, as any other row would.

### You close a terminal's window

A terminal has nothing on disk behind it, so there is nothing to ask. Its row goes, exactly as
**Remove Terminal** would do it.

### You close one tab

Tabs are yours. Closing one tab of a window that keeps other tabs changes nothing in the sidebar.
The conversation that tab was running is no longer remembered, so it is not resumed next time.

### You close several windows at once

Two or more windows closing within a second of each other (Close All, or a quick series of ⇧⌘W)
looks exactly like iTerm2 shutting down. AiTerm treats it that way: it asks nothing, and once
iTerm2 turns out to still be running, every one of those windows comes back on its own.

### iTerm2 quits or crashes

Nothing is asked and nothing is removed. AiTerm also does **not** start iTerm2 again on its own: a
deliberate quit and a crash look the same from the outside, and a quit should stay a quit.

When iTerm2 comes back, whoever starts it, AiTerm compares again:

- A window iTerm2 restored itself is recognised by its label and taken back.
- Every other row gets a new window, its conversations resumed. Terminals get a fresh shell.

These windows open quietly, one after another, each placed beside the sidebar. None of them is
brought to the front: you did not ask for any one of them.

### AiTerm quits, and starts again

Quitting AiTerm leaves your iTerm2 windows running, and your agents keep working. The sidebar is
saved.

When AiTerm starts again:

- If iTerm2 is not running, AiTerm starts it.
- Windows that are still open are recognised by their label and taken back.
- Any window that went missing while AiTerm was closed, even one you closed yourself, comes back
  quietly. AiTerm could not ask you about it at the time, so it keeps the task.

### You choose a row while iTerm2 is not running

Clicking a row, or pressing ↩, is you asking for its window. AiTerm starts iTerm2 and the window
comes back once iTerm2 is up.

## What "comes back" means

**A task or review** gets a new window in its worktree, and every agent conversation its tabs last
showed is resumed: the first in the window's own tab, each other in a tab of its own, in the order
they were. The agent you created the task with resumes on the model and reasoning you chose. An
agent you started by hand in a tab resumes on its defaults. The task's first prompt is never sent
again. With no conversation remembered, the window is a plain shell in the worktree.

A resumed conversation reopens where it stopped and then waits for you. If an agent was in the
middle of a turn when its window went, that turn is not continued.

**A terminal** gets a fresh shell in its project folder. Whatever was running there, a dev server
for example, is not started again.

## Why the one-second wait

iTerm2 cannot tell AiTerm *who* closed a window. When iTerm2 quits, it closes every window first
and drops its connection a moment later, so for that moment a quit looks like you closing windows.

So AiTerm holds each close for one second before deciding. If, within that second, another window
closes or iTerm2 disconnects, it was iTerm2 going away: nothing is asked and the windows come back
later. If nothing else happens, it was you, and you get the question.

The same second protects the way back. AiTerm only reopens windows once iTerm2 is connected and no
window has closed for a full second, so it never opens a window into an iTerm2 that is shutting
down.

## Closes AiTerm makes itself

Some windows close because AiTerm closed them. Those are never asked about:

- **Remove Task… / Remove Review…** closes the window before deleting the worktree.
- **Shelve Task** does the same, then moves the row to the shelf. A task with a window needs iTerm2
  connected to close it: without, it stops before closing anything, and the row says **Not
  shelved: iTerm2 isn’t connected**. A task with no window is shelved either way.
- **A worktree deleted outside AiTerm**: AiTerm notices, closes the window and removes the row. The
  branch is kept.
- **Remove Terminal** closes the terminal's window.

One exception: a removal or a shelving that closes the window and then stops (git refuses to
delete the worktree, you choose Keep when asked about unsaved work, the worktree was detached from
its branch while the window closed, or its place on the shelf could not be saved) leaves the task in the
sidebar. A task that stays gets its window back, like any other.

## When it can't

Sometimes a window cannot come back: iTerm2 refuses, or something goes wrong while opening it.
Then, and only then, the row says **Couldn't reopen** (in the same place a missing worktree is
shown) and the banner above the list says why. Click the row, or press ↩, to try again.

A failure caused by iTerm2 going away mid-way does not count: the window simply comes back once
iTerm2 is up again. A row whose worktree is missing is never reopened: it says **Worktree missing**,
and you restore the worktree or remove the task.

## Known limits

- A window with iTerm2's Window > Lock Location on is snapped back by iTerm2 when AiTerm places it beside the sidebar, so turn Lock Location off for task windows.
- **A window iTerm2 restores whose agent did not survive** (you quit iTerm2 with its window
  restoration turned on) is recognised and taken back as it is, a shell, without resuming the
  conversation. After a crash, iTerm2 usually keeps the agent running, so this is mostly about a
  deliberate quit.
- **Terminals don't re-run anything.** A terminal comes back as an empty shell in its folder.
- **Terminals created before this release** have no label yet. The first time iTerm2 restarts with
  window restoration on, you may see one duplicate shell per such terminal. After that they are
  labelled.
- **To check before a release:** with iTerm2's window restoration on, quit and relaunch iTerm2 with
  tasks and a terminal open. Nothing should open twice. (It also appears in
  [releasing.md](releasing.md).)

## Where it lives, for developers

| In plain words | In the code |
|---|---|
| The row is the truth; a row without a window is "owed" one | `TaskItem.windowId` / `TerminalItem.windowId == nil` |
| Comparing the sidebar with iTerm2 and deciding per row | `AppState.windowPlan` (Core, pure): adopt, restore, ask, drop |
| The one part of the app that acts on that decision | `WindowReconciler`, which runs a pass on every snapshot, close, choice and change of work |
| The invisible label | iTerm2 user variables `aiterm_task` / `aiterm_terminal`, read by the daemon (`sessions.py`, `windows.py`) |
| The one-second wait, and "iTerm2 has settled" | `ClosedWindowTriage` (`hold`, `isSynced`, `isQuiet(at:)`) |
| Bringing a window back | `WindowReconciler.restore`, through `TaskLauncher.openWindow` / `TerminalActions.openWindow` |
| Which conversations to resume | `TaskItem.conversations`, `TaskItem.resumeCommands` |
| Remove's question after a lone close | `TaskRemover.confirmRemove(task:archiveInstead:)`; Shelve goes to `TaskArchiver.archive`, Cancel through `RowFocus.select` |
| Shelve and restore | `TaskArchiver`: the row saved into `AppState.archive` before its worktree goes; a restore's row chosen through `RowFocus.select` |
| "Couldn't reopen" | `WindowReconciler.hasFailed`, `TaskRowCaption` |
| Never starting iTerm2 after it went away | `ItermSupervisor` launches only at the daemon's own start (`connection.py`); the app's `launchIterm` covers AiTerm starting and a row chosen while iTerm2 is down |
