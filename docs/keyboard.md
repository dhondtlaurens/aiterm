# Keyboard

⌘Return presses a sheet's primary button. Plain Return belongs to the focused field or list; in
Rename, Add Divider and New Terminal it presses the primary button. Escape closes an open list,
then cancels.

## Application

| Keys | Action | Notes |
| --- | --- | --- |
| ⌘, | Settings… | Also View › Show Settings. Opens Integrations when setup needs attention, Agents otherwise. Disabled while another sheet is up. |
| ⌘P | Add Project… | Asks for the folder, then opens one sheet for its Jira links and worktree import; Choose… there picks another folder. |
| ⌘D | Add Divider… | One name field. |
| ⌘N | New Task… | Uses the selected project or the selected row's project. |
| ⌘R | New Review… | The same target project. |
| ⌘T | New Terminal… | Opens a shell in the target project, including a plain folder. |
| ⌘S | New Signal… | Also the Operator heading's +; no selected project needed. |
| ⌘+ / ⌘− / ⌘0 | Zoom In / Zoom Out / Actual Size | Sidebar only. ⌘= aliases ⌘+. Sheets retain native scale. |
| ⌘F | Focus View | Opens signals/projects with attention rows and peeks at the first. The Operator's chat questions count; ordinary unseen done rows still count. |
| ⌘L | List View | Opens signals and projects; they remain visible together. |
| ⌘A | Show Archive | Outside a text field. During text editing it stays Select All. |
| ⌘B | Backpack Mode | Opens setup at the desk, turns it off while on. |
| ⌘Q | Quit | Flushes state and stops the helper; agents keep running in iTerm2. |
| ⌘Z / ⇧⌘Z | Undo / Redo | Standard Edit menu, alongside Cut, Copy, Paste, Delete and Select All. |
| ⌘H / ⌥⌘H | Hide AiTerm / Hide Others | Native application menu. |

Creation keys are disabled while a sheet is open or the workspace cannot change. A task/review
needs a compatible project; a terminal also accepts a plain folder. Row menus keep Rename, Open in…,
Pull, Archive and Remove. The Operator heading's menu has Pause Operator and Resume Operator. Signal menus have Edit, Switch Off/On
and Remove. Take Over is a driven task action; there is no Hand Back or board.

`KeyBindings.all` feeds Settings › Interface; `KeyboardSettingsTests` compares it to the actual
menu titles, keys and modifiers. There is no Window menu, ⌘W/⌘M binding or ⌘I board shortcut.

## Sidebar

The arrows look; Return goes. Moving selection leaves the keyboard in the sidebar.
A row hidden by a fold hands the selection to its heading; a row that disappears, or is hidden with its heading, is deselected.

| Keys | Action |
| --- | --- |
| ↑ / ↓ | Select visible project/signal headers and rows, skipping dividers and removing rows. Peek at a row's window without taking the keyboard. Folded children are skipped. ↓ on the Operator's last row selects the first project, opening PROJECTS and folding OPERATOR; ↑ on the first project selects the Operator's last row, the other way round. |
| Return | Open the selected row's window for typing, or fold/open its header. A closed worker resumes its conversation; the Operator row opens the one chat. An empty project heading opens New Task, or New Terminal for a plain folder; an empty signal heading opens Edit Signal. |
| ⌘Delete | The selected task/review/terminal's Remove action. Task/review removal asks first. Nothing on a header. |

Worker permission prompts open in the worker window; the Operator's counted questions open its
chat. A task with no worker yet opens nothing. Clicking a folded heading's attention count reveals
its first attention row.

In an AiTerm-opened iTerm2 window, ⌘T creates a tab and the daemon changes it to that worktree's
directory. Starting another agent there adds its avatar to the task.

## Creation sheets

Task: Task (ticket, name, branch) → Prompt → Agent. Review: Review (merge request, ticket, name,
branch) → Prompt → Agent. Signal: Signal → Starts when → Prompt → Agents → Done. Add/Edit Project,
New Terminal and Add Divider have one confined step. A search field's results open when you click
it or type, not when the sheet focuses it.

| Keys | Action |
| --- | --- |
| ⌘Return | Continue, then Create Task/Create Review/Create Signal, Add or Save as the button says. A review of an existing task's branch offers Open in Task/Open in Review. |
| ⌘1…⌘4 | Return to a completed step when it is available. Future steps cannot be skipped. Clicking a completed check does the same. |
| Return | Pick a highlighted dropdown result; insert a newline in the prompt/JQL editor. No sheet-wide commit. In Rename, Add Divider and New Terminal, Return presses the primary button too. |
| Escape | Close the current popup first, then cancel. Back and the completed steps go back. |

## Picker and prompt completions

An open `ChipsPicker` list takes ↑/↓ (wrap), Return (pick) and Escape (close).
It hands keys back once closed. A selected item appears as a chip; multi-selection leaves the field
ready for another item.

`/` at a word start offers installed commands/skills. Codex skills insert their `$` invocation;
its slash commands keep `/`. `$` itself opens nothing. `@` at a word start offers files/folders
from the prepared project index or an explicit path. Arrows navigate, Return replaces the token,
Escape closes. Folder picks continue the path. The native prompt editor retains undo and caret
position. A price or email address does not open a popup.

## Archive

The search field keeps the keyboard. ↑/↓ moves the highlight with wrap. ⌘Return, double-click or
the accessible Restore action restores the selected task at its reserved path, selects it and
resumes its conversations. A refusal leaves the archive open. ⌘Delete removes the selected record
after confirmation; with no row, ordinary field editing applies. Escape clears search before closing.
Search covers title, branch, project, ticket and request number/title, ignoring case and accents.
There are no ended broadcasts to open.

## Settings and alerts

⌘1…⌘4 selects Agents, Operator, Integrations and Interface. Focused segmented controls and tabs
answer left/right. Settings stages every switch and field until Save; Install, Repair, Run check,
the Mac card's Allow… and Remove, and the sidebar size preview apply at once.

An alert's default button answers Return, Escape its safe choice. Destructive Remove/Delete Branch
is the default only when the alert says so. Closing a row's iTerm2 window asks nothing; the row stays
and Return opens it again. Unsaved changes default to Keep Task/Keep Review. Restore failures and
other one-button alerts use OK.

`AlertPrompt.escapeButton`/`ModalPrompter` preserve Escape even when the safe choice is also the
default. Alerts are awaited outside the SwiftUI key handler so native controls render correctly.
