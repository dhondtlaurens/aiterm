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
| ⌘, | Settings… | Opens the Settings sheet on Integrations while iTerm2 is not connected or a saved service's last test failed, and on Agents otherwise — decided as it opens, never switched afterwards. Off while another sheet is up: it would replace that sheet, and a New Task draft with it. Also under View › Show Settings, the same item with the same rule; the AiTerm menu comes first and owns the key. |
| ⌘H ⌥⌘H | Hide AiTerm, Hide Others | NSApplication's own. Show All has no key. |
| ⌘P | Add Project… | File menu, first, as the header's "+" has it. Off while a sheet is up or the workspace can't change. |
| ⌘D | Add Divider… | The same rules as Add Project…. |
| ⌘N | New Task… | File menu, after a separator. Acts on the target project: the selected project header, or the project of the selected task, review or terminal row. Off with no target, for a project with no provider (as its "+" menu has it), while a sheet is up and while the workspace can't change. |
| ⌘R | New Review… | The same target and the same rules as New Task…. |
| ⌘T | New Terminal… | The target project; any provider, a plain folder too. |
| ⌘+ ⌘− ⌘0 | Zoom In, Zoom Out, Actual Size | The sidebar only — sheets keep Apple's sizes. ⌘= is a hidden alias of ⌘+, as in Safari. Off while a sheet is up. |
| ⌘F | Focus View | View menu; off while a sheet is up. Opens the projects with a row that needs attention, folds the rest, and peeks at the first row waiting on you, showing its window even when it was already selected and leaving the keyboard in the sidebar. The rows waiting on you are those needing input or done and unseen, terminals included, and in the broadcast's group only what is amber, the Operator's row first; the group is opened while one of those is in it and folded otherwise. The Dock badge counts the same rows (`SidebarModel.needingAttention`). |
| ⌘L | List View | View menu; off while a sheet is up. Opens every project that has rows, and the broadcast's group. |
| ⌘S | Show Shelf | View menu, after the views, in a group of its own with Show Settings. Off while a sheet is up and while the workspace can't change. |
| ⌘B | Backpack Mode | View menu, after the views. Backpack Mode: opens its sheet at the desk, turns it off in the backpack. Checked while on. |
| ⌘Q | Quit | Flushes a sidebar move made in the last 150 ms, then takes the daemon down — an orphan would block the next launch's socket. |
| ⌘Z | The standard Edit menu | Undo, Redo, Cut, Copy, Paste, Delete, Select All. Built by hand: without it no text field in any sheet could be edited normally. |

The five create keys are plain ⌘ and the item's initial, and the File menu, the header's "+", a
project's "+" and its context menu all list them in this order: Add Project…, Add Divider…, then
New Task…, New Review…, New Terminal…. None clashes with a sheet: ⌘P, ⌘D, ⌘R and ⌘T mean nothing
to a text field, and the File menu is off while a sheet is up anyway.

There is no Window menu, so no ⌘M or ⌘W (see Not bound). Row actions — Rename, Open in…, Pull, Shelve Task, Remove — stay in the rows' context menus; a row's window comes back by itself. So do the broadcast header's — Open Board, Rename…, Pause Broadcast (Resume Broadcast while paused) and End Broadcast… — and a driven task's Take Over or Hand Back and Stop Task…; the OPERATOR heading's "+" (New Broadcast…) has no key, and there is no File menu item for it.

The Keyboard shortcuts section of Settings › Interface lists every key AiTerm answers to
(`KeyBindings.all`), a row that mirrors a menu item under that item's exact title, and
`KeyboardSettingsTests` checks the menu bar's titles, keys and modifiers against it. This page keeps
the reasoning.

## Sidebar

The arrows look, Return goes: moving through the list never takes the keyboard out of it. It is a
plain ↩; ⌘↩ is the sheets' commit key and does nothing here.

| Keys | Action | Notes |
|---|---|---|
| ↑ ↓ | Peek | Moves the selection through the project headers and every open project's rows, in list order, stepping over dividers and a task being removed, and shows the row's window beside the sidebar, raised in iTerm2. The keyboard stays in the sidebar, and a finished task stays blue. Arrowing past rows shows only the one the arrows stop on. A folded project's rows are stepped over; ⌘L opens them all. A selected header is drawn in the same pill as a row, shows no window and raises nothing. A row whose window is still coming back is only selected. The broadcast's header is a header: it shows no window, and a folded group's rows are stepped over. The Operator's row, first under it, peeks at the Operator's window, as a task row peeks at its own; a queued task's row is stopped on and shows nothing, having no window yet. The OPERATOR heading is stepped over, as a divider is. |
| ↩ | Go to the window | The selected row's window, with iTerm2 brought forward to type in — a row whose window is still coming back waits for it, and one that could not be reopened is tried again. On the Operator's row, ↩ — or a click — brings the Operator's window to front, or reopens it in front when it is closed, resuming its conversation and the broadcast. On a queued task's row they open nothing: no window, no board, no error. On the broadcast's header, ↩ — or a click on its label — folds or opens its group, as on a project's; the board opens from the header's board button or Open Board in its menu. Folded, its amber count is a button: it opens the group and selects the first row that needs you, as a project's broadcast badge opens it at that project's first task. On a task the Operator drives, ↩ or a click brings its window with the worker tab that asks in front, else the tab last in front; one whose window you closed comes back with its conversation resumed — never a second agent. A click does the same, and so does creating a terminal; a new task or review is selected and its window opened, but the keyboard stays here — its agent is already at work. On a header, ↩ folds or opens the project. An empty project has nothing to fold, so ↩ opens its context menu instead, below the header with the first item highlighted: ↑ ↓ move, ↩ picks, ⎋ closes it (`RowMenuAnchor`). |
| ⌘⌫ | Remove the task, review or terminal | The row's own Remove, as its context menu has it: a task or a review asks first, a terminal just closes. Nothing on a header. On the list, not a menu command — a menu's key equivalent would beat a text field's own ⌘⌫. |

## In an AiTerm-opened iTerm2 window

| Keys | Action | Notes |
|---|---|---|
| ⌘T | New tab, in the right directory | iTerm2 does *not* inherit the worktree for a new tab — verified against both ephemeral and saved Dynamic Profiles. The daemon catches the new-session notification and `cd`s the tab itself (64 ms, then 8 ms). The new tab's agent appears as a second avatar on the row. |

## Not bound

| Keys | Action | Notes |
|---|---|---|
| ⌘W | Close a task window | Removal is ⌘⌫ on the list, which asks first because it deletes a worktree. A window-closing key in iTerm2 closes the window first; AiTerm then asks Remove's question a second later, Shelve puts the task away instead, and Cancel brings the window back. |
| ← → | Fold and open a project, Finder-style | Dropped: ↩ on a header folds or opens it, as a click on its label does. ⌘L opens every project. |
| ⌘A | — | Edit › Select All claims it even on the list, where it is disabled, so Show Shelf took ⌘S. |
| ⌘I | Open the broadcast's board | Dropped: the header's board button opens it, and so does Open Board in its menu. |
| — | Shelve a task | Shelve Task is in the row's menu and Shelve is in the window-close question. |

## New Task, New Review and New Broadcast sheets

| Keys | Action | Notes |
|---|---|---|
| ⌘↩ | Whatever the primary button says | Continue on steps 1 and 2; on step 3 Create Task, Create Review, or Open in Task / Open in Review for a branch a task already has — the promise the keycaps on the button make. Before this it fired *create* from any step: a shortcut nothing on screen mentioned. New Broadcast has four steps: Continue on Broadcast (once it has a project), Prompt (once it says something) and Review, Start Broadcast on Done. |
| ↩ | Nothing sheet-wide | It picks the highlighted result in an open dropdown, and inserts a newline in the prompt editor. It does not press the primary button. |
| ⎋ | Close the open list, then go back | While a list is open, ⎋ belongs to it — in every other app that list is a window of its own, and closing the whole sheet is not what the key means there. New Review closes its merge-request list before its branch list; New Broadcast its Jira projects list before its projects list; on a prompt step (New Broadcast's Prompt, Review and Done), the completion popup is the list. It sits on a hidden button rather than on Cancel, so *clicking* Cancel still cancels. |

## A picker's list

Every `SearchPicker` — the ticket, merge request, branch and Jira project fields — and New Broadcast's
two `ChipsPicker`s, whose list opens as the field takes the keyboard, answer the same keys while the list is
open (`DropdownKeys`), and hand every key back once it is closed. A pick in a `ChipsPicker` joins its chips,
and the field stays for the next.

| Keys | Action | Notes |
|---|---|---|
| ↑ ↓ | Move | Wraps at both ends. |
| ↩ | Pick | The highlighted row. |
| ⎋ | Close | Only the list. |

## The prompt editor's completion popup

| Keys | Action | Notes |
|---|---|---|
| / | Open | At the start of a word, for every agent. The list is the commands and skills that agent actually has installed, for this project; in New Broadcast, Claude's and Codex's skills, from the home and each picked project. `$` opens nothing, so a price or `$HOME` in a prompt stays plain text. |
| @ | Open | At the start of a word, so an address stays plain text. The list is the files git tracks in the project (in New Broadcast, the one picked project; across several it lists none) — what the task's worktree will have — and the folders that hold them; a folder that is not a checkout is walked instead (`ProjectFiles`). `@../`, `@~/` or `@/` lists that folder on disk instead, `@./` is the project's root. |
| ↑ ↓ | Move | Wraps at both ends. |
| ↩ | Accept | Replaces the typed token with the item as its agent runs it: `/bra` → `/brainstorming`. Codex runs a skill as a `$` mention, so for Codex `/imag` → `$imagegen`; its commands, `/prompts:<name>` among them, keep the `/` (`SkillCatalog.invocation`). A file is written as its `@` mention from the project's root, `@rea` → `@README.md`, the form Claude Code and PI attach a file by. A folder is written without the trailing space, `@ap` → `@app/`, and the list stays open on what is inside it. A pick outside the project is written as its absolute path, since `../` means somewhere else in the task's worktree under `.worktrees/`; one back inside it is written from the project's root. |
| ⎋ | Close | Only the popup. Every other key, and every key when it is closed, reaches the text view as usual. |

This is the whole reason the editor is a real `NSTextView` on TextKit 1: SwiftUI's `TextEditor`
exposes neither the caret's position nor the arrow keys, and a TextKit 2 view has no
`NSLayoutManager` to take a caret rectangle from.

## Shelf sheet

The search field keeps the keyboard the whole time the sheet is up, so these keys are the sheet's
even while typing (`ArchiveSheetModel`).

| Keys | Action | Notes |
|---|---|---|
| ↑ ↓ | Move | The highlight, wrapping at both ends. It starts on the first row — the newest, or the best match — and goes back there whenever the search changes. A click highlights a row too. |
| ⌘↩ | Restore | The highlighted row: its worktree back at its own path, its row back in the sidebar and chosen, its window reopened with its conversations resumed; the sheet closes. A refusal comes up as an alert and leaves it on the shelf. With nothing shelved Restore is absent, key and all. |
| ⌘↩ | Open | On an ended broadcast the button reads Open: the Shelf closes and the broadcast's sheet opens in its place, read-only, on Summary. |
| double-click | Restore or Open | That row, as ⌘↩. VoiceOver has it as the row's Restore or Open action. |
| ⌘⌫ | Remove from the shelf | The highlighted row, after Remove's question. In the field ⌘⌫ would delete to the line's start; with a row shown it removes the row instead, and with none the field has it back. |
| ⎋ | Clear the search, then close | A search is cleared first, the whole shelf back; ⎋ on an empty field closes the sheet. |

The search finds a row by its title, ticket key and summary, merge request number and title, branch
or project, and an ended broadcast by its name and what it was asked, ignoring case and accents. A merge request is found by its number in any form — `482`,
`!482`, `#482` — and by its start while it is being typed (`!4`, `#48`, `48`); a lone `!` or `#`
finds none (`ArchiveSearch`).

## Every other sheet

New terminal, Add divider, Rename divider, Rename task, Rename terminal, Rename broadcast, Settings, Jira projects
and a broadcast's board.
Add Project… has no sheet: the folder chooser adds the project at once.

| Keys | Action | Notes |
|---|---|---|
| ⌘↩ | Create Terminal · Add Divider · Rename · Save · End Broadcast · Start Fresh | The same `SheetPrimaryButton` and keycaps. A plain ↩ in a name field does nothing. |
| ⎋ | Cancel | Plain `.cancelAction` where there is no list. Jira projects has one, so ⎋ closes it first, on a hidden button as in New Task. |
| ← → | Move between segments | Any focused `SegmentedControl`: the Settings tabs, the agent picker, Sidebar size. |

The broadcast's sheet takes ⌘1 ⌘2 ⌘3 for Board, Activity and Summary, on hidden buttons as in Settings; Summary only once the broadcast has reached it. Its ⌘↩ is the moment's, the same on every tab: End Broadcast once every task is done, asking nothing; Start Fresh when the Operator's window couldn't be reopened behind it; nothing while it runs, where Pause Broadcast (Resume Broadcast while paused) and End Broadcast… are plain buttons. A card's click closes the board, then opens what resolves it: the task's window for a permission prompt or a started task, the Operator's window for a question or a blocked task, the sidebar's banner for a problem AiTerm hit. A Todo card is not a button. ⎋ is Close.

## Settings

| Keys | Action | Notes |
|---|---|---|
| ⌘1 ⌘2 ⌘3 ⌘4 | Agents, Operator, Integrations, Interface | The tabs in the tab bar's order, from anywhere in the sheet. On hidden buttons, since a view carries one shortcut and the bar's segments are not buttons. |

## Alerts

Every alert has one default button, and only it answers ↩. It is blue, or red when it deletes files
or commits; every other button is the plain grey one, a destructive button that is not the default
included. ⎋ answers the safe choice on every alert (`AlertPrompt.escapeButton`).

| Alert | ↩ | ⎋ |
|---|---|---|
| Remove task / Remove review | Remove, red | Cancel |
| Delete branch | Delete Branch, red | Cancel |
| Remove task / Remove review, after its window was closed | Remove, red | Cancel — Shelve is the grey button between them |
| Uncommitted changes | Keep Task / Keep Review, blue | Keep Task / Keep Review — Delete Changes and Remove, or Delete Changes and Shelve, is the grey button |
| Remove a shelved task or review | Remove, red | Cancel |
| Remove an ended broadcast from the Shelf | Remove, red: its activity log and summary are deleted | Cancel |
| Remove project | Remove, blue: the files are kept | Cancel |
| Stop a task the Operator drives | Stop Task, blue: its window and branch stay | Cancel |
| End a broadcast, before every task is done | End Broadcast, blue: its started tasks stay, worktrees and MRs too | Cancel |
| Import worktrees | Import | Skip |
| An update is available | Update | Later |
| Unsaved workspace on quit | Cancel Quit | Cancel Quit |
| The workspace won't open, at launch | Retry | Quit — Restore Backup and Reveal in Finder are grey |
| One button only (OK) | OK | OK |

NSAlert gives ⎋ to a button titled Cancel by itself; any other safe button is handed it
(`keyEquivalent` ⎋). A safe button that is also the default keeps ↩ — a button holds one key — and
`ModalPrompter` answers ⎋ for it with a key monitor while the alert is up. An alert is never run
inside a SwiftUI key handler, where it comes up without its checkbox: a question is an `await`, and
`ModalPrompter` brings its alert up a turn later, so ⌘⌫'s Remove alert is never inside one.

Closing one task's window in iTerm2 asks the Remove task alert a second later, AiTerm brought
forward for it, with Shelve as a third button; iTerm2 quitting or crashing asks nothing. A task that
can't be shelved — its worktree isn't on a branch — and one that can't be restored are told so in
a one-button alert.
