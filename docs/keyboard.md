# Keyboard

Two keys do most of the work in a sheet: ⌘↩ presses the primary button — the only key that does,
and the keycaps on it say so — and ⎋ backs out. A plain ↩ belongs to whatever has focus. A view
carries one keyboard shortcut, so a second one hangs on a hidden button in an overlay —
`.hidden()` keeps a view's space, which would hold a visible button away from the row's edge.

## Application

| Keys | Action | Notes |
|---|---|---|
| — | About AiTerm | First in the AiTerm menu, which runs in the HIG's order, four groups split by separators: About and Check for Updates…; Settings…; Hide AiTerm, Hide Others, Show All; Quit AiTerm. |
| — | Check for Updates… | Says "latest" or offers the newer version. |
| ⌘, | Settings… | Opens the Settings sheet on Integrations while iTerm2 is not connected or a saved service's last test failed, and on Agents otherwise — decided as it opens, never switched afterwards. Off while another sheet is up: it would replace that sheet, and a New Task draft with it. |
| ⌘H ⌥⌘H | Hide AiTerm, Hide Others | NSApplication's own. Show All has no key. |
| ⌘P | Add Project… | File menu, first, as the header's "+" has it. Off while a sheet is up or the workspace can't change. |
| ⌘D | Add Divider… | The same rules as Add Project…. |
| ⌘N | New Task… | File menu, after a separator. Acts on the target project: the selected project header, or the project of the selected task, review or terminal row. Off with no target, for a project with no provider (as its "+" menu has it), while a sheet is up and while the workspace can't change. |
| ⌘R | New Review… | The same target and the same rules as New Task…. |
| ⌘T | New Terminal… | The target project; any provider, a plain folder too. |
| ⌘+ ⌘− ⌘0 | Zoom In, Zoom Out, Actual Size | The sidebar only — sheets keep Apple's sizes. ⌘= is a hidden alias of ⌘+, as in Safari. Off while a sheet is up. |
| ⌘Q | Quit | Flushes a sidebar move made in the last 150 ms, then takes the daemon down — an orphan would block the next launch's socket. |
| ⌘Z | The standard Edit menu | Undo, Redo, Cut, Copy, Paste, Delete, Select All. Built by hand: without it no text field in any sheet could be edited normally. |

The five create keys are plain ⌘ and the item's initial, and the File menu, the header's "+", a
project's "+" and its context menu all list them in this order: Add Project…, Add Divider…, then
New Task…, New Review…, New Terminal…. None clashes with a sheet: ⌘P, ⌘D, ⌘R and ⌘T mean nothing
to a text field, and the File menu is off while a sheet is up anyway.

There is no Window menu, so no ⌘M or ⌘W (see Not bound). Row actions — Rename, Reopen, Open in…,
Pull, Remove — stay in the rows' context menus.

The Keyboard shortcuts section of Settings › Interface lists every key AiTerm answers to
(`KeyBindings.all`), a row that mirrors a menu item under that item's exact title, and
`KeyboardSettingsTests` checks the menu bar's titles, keys and modifiers against it. This page keeps
the reasoning.

## Sidebar

The arrows look, Return goes: moving through the list never takes the keyboard out of it. It is a
plain ↩; ⌘↩ is the sheets' commit key and does nothing here.

| Keys | Action | Notes |
|---|---|---|
| ↑ ↓ | Peek | Moves the selection through the project headers and every open project's rows, in list order, stepping over dividers and a task being removed, and shows the row's window beside the sidebar, raised in iTerm2. The keyboard stays in the sidebar, and a finished task stays blue. Arrowing past rows shows only the one the arrows stop on. A folded project's rows are stepped over; ⌘L opens them all. A selected header is drawn in the same pill as a row, shows no window and raises nothing. |
| ↩ | Go to the window | The selected row's window, with iTerm2 brought forward to type in. A click does the same, and so does creating a terminal; a new task or review is selected and its window opened, but the keyboard stays here — its agent is already at work. On a header, ↩ folds or opens the project. An empty project has nothing to fold, so ↩ opens its context menu instead, below the header with the first item highlighted: ↑ ↓ move, ↩ picks, ⎋ closes it (`RowMenuAnchor`). |
| ⌘⌫ | Remove the task, review or terminal | The row's own Remove, as its context menu has it: a task or a review asks first, a terminal just closes. Nothing on a header. On the list, not a menu command — a menu's key equivalent would beat a text field's own ⌘⌫. |
| ⌘F | Focus View | Opens the projects with a row that needs attention, folds the rest, and peeks at the first row waiting on you — its window shown even when it was already selected — with the keyboard left in the sidebar. The rows waiting on you are those needing input or done and unseen, terminals included; the Dock badge counts the same rows (`SidebarModel.needingAttention`). |
| ⌘L | List View | Opens every project that has rows. |

## In an AiTerm-opened iTerm2 window

| Keys | Action | Notes |
|---|---|---|
| ⌘T | New tab, in the right directory | iTerm2 does *not* inherit the worktree for a new tab — verified against both ephemeral and saved Dynamic Profiles. The daemon catches the new-session notification and `cd`s the tab itself (64 ms, then 8 ms). The new tab's agent appears as a second avatar on the row. |

## Not bound

| Keys | Action | Notes |
|---|---|---|
| ⌘W | Close a task window | Removal is ⌘⌫ on the list, which asks first because it deletes a worktree. A window-closing key would do it without a word. |
| ← → | Fold and open a project, Finder-style | Dropped: ↩ on a header folds or opens it, as a click on its label does. ⌘L opens every project. |

## New Task and New Review sheets

| Keys | Action | Notes |
|---|---|---|
| ⌘↩ | Whatever the primary button says | Continue on steps 1 and 2; on step 3 Create Task, Create Review, or Open in Task / Open in Review for a branch a task already has — the promise the keycaps on the button make. Before this it fired *create* from any step: a shortcut nothing on screen mentioned. |
| ↩ | Nothing sheet-wide | It picks the highlighted result in an open dropdown, and inserts a newline in the prompt editor. It does not press the primary button. |
| ⎋ | Close the open list, then go back | While a list is open, ⎋ belongs to it — in every other app that list is a window of its own, and closing the whole sheet is not what the key means there. New Review closes its merge-request list before its branch list. It sits on a hidden button rather than on Cancel, so *clicking* Cancel still cancels. |

## A picker's list

Every `SearchPicker` — the ticket, merge request, branch and Jira project fields — answers the
same keys while its list is open (`DropdownKeys`), and hands every key back once it is closed.

| Keys | Action | Notes |
|---|---|---|
| ↑ ↓ | Move | Wraps at both ends. |
| ↩ | Pick | The highlighted row. |
| ⎋ | Close | Only the list. |

## The prompt editor's completion popup

| Keys | Action | Notes |
|---|---|---|
| / | Open | At the start of a word, for every agent. The list is the commands and skills that agent actually has installed, for this project. `$` opens nothing, so a price or `$HOME` in a prompt stays plain text. |
| ↑ ↓ | Move | Wraps at both ends. |
| ↩ | Accept | Replaces the typed token with the item as its agent runs it: `/bra` → `/brainstorming`. Codex runs a skill as a `$` mention, so for Codex `/imag` → `$imagegen`; its commands, `/prompts:<name>` among them, keep the `/` (`SkillCatalog.invocation`). |
| ⎋ | Close | Only the popup. Every other key, and every key when it is closed, reaches the text view as usual. |

This is the whole reason the editor is a real `NSTextView` on TextKit 1: SwiftUI's `TextEditor`
exposes neither the caret's position nor the arrow keys, and a TextKit 2 view has no
`NSLayoutManager` to take a caret rectangle from.

## Every other sheet

New terminal, Add divider, Rename divider, Rename task, Rename terminal, Settings and Jira projects.
Add Project… has no sheet: the folder chooser adds the project at once.

| Keys | Action | Notes |
|---|---|---|
| ⌘↩ | Create Terminal · Add Divider · Rename · Save | The same `SheetPrimaryButton` and keycaps. A plain ↩ in a name field does nothing. |
| ⎋ | Cancel | Plain `.cancelAction` where there is no list. Jira projects has one, so ⎋ closes it first, on a hidden button as in New Task. |
| ← → | Move between segments | Any focused `SegmentedControl`: the Settings tabs, the agent picker, Sidebar size. |

## Settings

| Keys | Action | Notes |
|---|---|---|
| ⌘1 ⌘2 ⌘3 | Agents, Integrations, Interface | The tabs in the tab bar's order, from anywhere in the sheet. On hidden buttons, since a view carries one shortcut and the bar's segments are not buttons. |

## Alerts

Every alert has one default button, and only it answers ↩. It is blue, or red when it deletes files
or commits; every other button is the plain grey one, a destructive button that is not the default
included. ⎋ answers the safe choice on every alert (`AlertPrompt.escapeButton`).

| Alert | ↩ | ⎋ |
|---|---|---|
| Remove task / Remove review | Remove, red | Cancel |
| Delete branch | Delete Branch, red | Cancel |
| Uncommitted changes | Keep Task / Keep Review, blue | Keep Task / Keep Review — Delete Changes and Remove is the grey button |
| Remove project | Remove, blue: the files are kept | Cancel |
| Import worktrees | Import | Skip |
| An update is available | Update | Later |
| Unsaved workspace on quit | Cancel Quit | Cancel Quit |
| The workspace won't open, at launch | Retry | Quit — Restore Backup and Reveal in Finder are grey |
| One button only (OK) | OK | OK |

NSAlert gives ⎋ to a button titled Cancel by itself; any other safe button is handed it
(`keyEquivalent` ⎋). A safe button that is also the default keeps ↩ — a button holds one key — and
`ModalPrompter` answers ⎋ for it with a key monitor while the alert is up. An alert is never run
inside a SwiftUI key handler: ⌘⌫ defers its Remove alert a turn, or it comes up without its
checkbox.
