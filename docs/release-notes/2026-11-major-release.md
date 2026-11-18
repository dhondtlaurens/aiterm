# Major release

**Quit AiTerm, install this version and open it.**

This version saves the Operator's own records in a new shape and does not read the ones an earlier
version saved. On first launch AiTerm clears those records itself; the rest of your workspace stays
as it is.

## Upgrade

1. Let each task the Operator drives reach a point you are happy to pick up yourself. Quit AiTerm:
   the installed app and any development build. iTerm2 and its windows can stay open.
2. Install the new version and open it. On first launch AiTerm clears the Operator's saved records
   from the previous version and nothing else, keeps a dated copy (`state.json.before-reset-<date>`)
   beside `state.json`, and shows a note saying it did.
3. Open Settings › Agents. The agent cards need nothing for this upgrade; a card that shows
   **Repair** for another reason is fixed by pressing it. An install from before 0.54 may still have
   AiTerm's old `PreToolUse` entry (its hook carries `"_aiterm": true`) in Claude Code's
   `~/.claude/settings.json`; AiTerm no longer removes it, so delete that entry by hand.
4. What to expect: your projects, tasks, terminals, the Archive, conversations, signals and their
   seen items are all there. Tasks the Operator drove are now ordinary tasks of yours, and a task
   you had taken over stays yours: no signal continues it. A worker that is still working keeps
   its branch guard until it ends. The Operator starts a fresh chat at its next match; close the
   old chat's window in iTerm2 yourself. Items a signal already started are not started again.

## What changes

### Windows

- Closing a task's window asks nothing: the row stays, and choosing it opens the window again
  with its conversations resumed.
- Closing a terminal's window keeps its row; choosing the row opens a fresh shell.
- After iTerm2 restarts, nothing reopens by itself: a window opens when you choose its row.
- Moving the selection with the arrow keys never opens a window.
- When iTerm2 isn't running, the iTerm2 banner says so and offers Open iTerm2.

### Tasks

- Remove asks everything before it acts, including whether to delete a branch with commits that
  are not on its base.
- Without the helper, Remove refuses, as Archive does.
- Take Over makes a task fully yours: an ordinary task, restored and removed like any other, whose
  resumed conversations no longer carry the worker's branch guard.

### Sidebar

- Return on an empty heading runs its main command: New Task… for a project, Edit Signal… for a
  signal.
- "Pull <branch>" names the default branch git reports, read when the project's heading appears
  and after each pull.
- Pause and Resume are on the Operator heading's menu, worded the same everywhere.
- A switched-off signal offers Switch On.
- The selection follows its row: a row that disappears is deselected, and a row hidden by a fold
  hands the selection to its heading.

### Sheets and keys

- Every step of a sheet has Cancel; Escape closes an open list first, then cancels.
- Return commits Rename, Add Divider and New Terminal.
- Add Project shows the chosen folder as a line with Choose….
- New Task's Base branch is a filtered field, as in New Review.
- The "isn't installed" note shows once, and only when no agent can run.
- New Signal shows an agent's readiness as advice and never disables Create for it.
- A saved model that is no longer offered is described with one wording everywhere, and a disabled
  Continue says why.

### Operator

- An Oracle check whose settings changed part-way is discarded and asked again, wherever the
  Oracle is used.
- Workers may run `git merge` locally.
- The Operator's shell gate names only tools that exist.

### Removed

- Find a Fix is gone, with its Settings switch Help with problems.
- A failed rebase or a diverged pull still shows its banner with its own recovery.

## Going back

The dated copy (`state.json.before-reset-<date>` in `~/Library/Application Support/AiTerm/`) is for
the previous version only. To go back, quit AiTerm, copy the dated file over `state.json` and
install the previous version.
