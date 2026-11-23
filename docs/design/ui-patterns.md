# App UI patterns

Patterns live in `app/Sources/AiTerm/Views/` and compose [AiTermUI primitives](../../app/Sources/AiTermUI/README.md).
Swift defines geometry and projections. This inventory explains reuse; the [Operator](../operators.md),
[keyboard](../keyboard.md) and [window](../windows.md) guides explain workflows.

## Sidebar

`SidebarRowContent` shares the avatar, title/badge column and trailing mark grid. `FoldOnTap` folds
only the label; `SidebarHeadingInset` owns its gutter. Project headers use `HeaderChevron`,
`HeaderTitle`, `ProviderIcon` and `AddMenu`. `RowPill` declares the surface. `TaskRowView` is used
under both projects and signals. Its actions resolve the current task at invocation; its body reads
cached drawn facts. `TaskRowBadges` drops whole badges so only the branch truncates; a merged request and a Jira ticket
in a Done lane wear `Badge(checked:)`'s corner check on their mark, and say "merged" or "done" in the
tooltip and to VoiceOver.

Project task rows offer Move Up and Move Down in their context menu and VoiceOver actions. Each
moves one place within that project's task or review group; tasks stay above reviews, and terminals
stay above both. The order is saved. Movement is disabled at each group's edges, while the workspace
is locked, or while the target row is being removed or archived. Signal-owned rows have no movement
commands; Take Over returns them to their project's usual task or review group.

Signal headings have Move Up and Move Down in the same place as a project heading's, before Remove.
Each moves the signal one place past its drawn neighbour. Past another signal the two swap: that order is
saved and is the signals' priority for an item several of them match. Dividers sit between signal headings as
they do between projects (`DividerRow`, off the arrow path), and a signal moves past one on one press without
changing priority. So only the first and last drawn rows disable a direction: a signal between two dividers
moves both ways. The Operator's row stays above every divider. A removed signal's heading has no commands, is
drawn after the live ones and every divider, and is never a neighbour.

Restoring an archived row keeps the existing date-based insertion rule, so it may return at the
top of a manually reordered group. Existing rows keep their chosen relative order; the archived
row's previous manual position is not remembered.

`SectionHeading` draws PROJECTS and OPERATOR; OPERATOR shows global pause, offers New Signal… in its + menu and Pause Operator / Resume Operator in its context menu. `SignalOperatorRow` is the active workload’s chat row,
waiting count, errors and window recovery. `HeadingRow` draws project and signal headings with their source marks;
its `HeadingValue` contains only the heading's drawn facts, folded counts (a signal's finished tasks apart, in the
green chip) and tooltip. Folded, OPERATOR draws the Operator's own chip (`OperatorChip`: its most urgent state as a
`TaskRowMark`, needs you, paused, working, waiting, idle, and its workload's count) and the finished chip; PROJECTS
its per-status counts. Each chip opens the section at the row it stands for (`ChipTarget`).
`SignalSidebar` groups existing task rows; Take Over returns the same row to its project.

Signal tasks use the same two-line task row as ordinary tasks: title, badges and branch, with the
same avatar and status grid. The Operator adds no status line and never replaces task badges.
`OperatorBadge` on the Operator’s own row describes its current action, every word in the surface’s
secondary ink; only needs-you stands out, in the attention chip. One view, `DecodeWordsView`, draws
the words whatever they say, in a line that spans the row so a change never resizes it, and its layer
never animates on its own. It morphs only when the words change, from the words standing to the new
ones over 0.5 seconds: the new words settle from the left behind a short band of glyphs in each
character’s case, the old words standing past it, then it stops. The first words a caption is given
stand as they are, so the line always runs from words to words and is never empty.
`OperatorActivityTracker` assigns a new identity to every start, result, failure and return to
watching; `OperatorActivityCaption` keeps a quick completed action readable for one second (its
result carries the same words, so nothing moves) before returning to the current status; a new event
replaces it immediately, and a caption that has just appeared (its section unfolded) shows the
current words without replaying an action that already ended.
The status mark always reflects current work. The title counts the workload (“3 tasks · 2 signals”, or “No tasks”) rather than repeating the heading, and never decodes. Reduce Motion swaps; snapshots remain still.

The dashed ring, turning once every six seconds, means waiting on something that moves by itself or on
someone: a turn's background work that wakes the agent again (`background`), or a driven task that waits
(`waiting`): its workers ended their turn and the Operator is to read it (`worker done · Operator to
review`), or its stage waits for its Done trigger, whose description (or query, when it has none) is the
line, or merge when ready waits on what the merge lacks (`waiting to merge · checks`). The line stays within
40 characters and the tooltip carries the whole sentence. The solid spinner
is only for a worker or the Operator at work now. A waiting task is never counted as working: a folded
section gives it its own chip, and neither Focus View nor the Dock badge counts it. Reduce Motion holds the
ring still.

A trailing mark is a ring for a state that can still move (`StatusMark`) and a filled disc for one that holds
(`SettledMark`): finished, the green check disc, and paused, the pause disc. A finished task (`SignalTask.isFinished`)
is past pausing; a done task with closeout outstanding is paused with the workload.

`TaskRowMarkView`, `StatusMark`, `SettledMark`, `StatusCountChips`, `AvatarGroupView`, `VendorMark`, `BranchLabelView`
and `QuietBadgeLine` share the status/agent/branch vocabulary. `BackgroundCardView` reuses the work
list under a background/working/input mark, only with verified work. Display evidence does not
change persisted state or Operator readiness. Amber means the person needs to act.

The work card floats in a borderless nonactivating child panel owned by the sidebar. Its heading
stays fixed above at most five single-line job rows, with the jobs scrolling beyond that. It
normally grows downward, fits inside the list viewport above the footer, and leaves row geometry
unchanged. Native descriptions use the system face; raw shell-command fallbacks use monospace.
The panel keeps hover tracking active while iTerm2 is key. Row and presenter share source
eligibility, including no card during task teardown, and the open card observes current projected
jobs rather than keeping a copied list. Empty/hidden/removed sources or scrolling the source mark
out of the viewport close it; layout-induced clip movement repositions an eligible card. A click
on the card invokes its source row’s activate action, and its context menu reuses that row’s
commands. The card’s jobs still scroll without activating the source. The card captures wheel
events within its bounds even when every job fits; move outside it to scroll the sidebar list.
Unhandled wheel events are not forwarded to the underlying list across the panel boundary.

`ToastView` and `Notice` share message hierarchy.
`SidebarFooterHost`/`SelectedRowSidebarFooter` scope telemetry to selection. `UsageRing`, `UsageLine`,
`ToneRing`, `MacMode` and `MacModeLine` keep readings neutral unless their own warning applies.

## One creation family

`SidebarSheet` resets native scale. `SheetLayout`, `SheetSubtitle`, `SheetFooter` and
`SheetPrimaryButton` own header/content/actions. Fixed steps retain one height; short one-step
sheets fit up to `Sheet.height`. The footer's primary action answers ⌘Return. Plain Return stays
with a field/list, except in a one-field `NameSheet`, where it presses the primary too. Escape closes
an open list before cancelling, and Cancel cancels.

`SteppedSheet` is the one frame of New Task, New Review and New Signal, configured with their
`Step`s: it owns the stepper, Cancel, Back and the primary button, the keys and dismissal. Escape
closes the step's open list, then cancels. `SheetStepper` ticks completed steps and names the
current one; completed steps are clickable and answer their command-number keys. Future steps
cannot be jumped to. New Task and New Review share their notices, failure recovery, closing summary
and loads (`CreationParts.swift`). `CreationClosingBlock` ends each creation sheet with the effect
of its current picks.

| Pattern | Decisions in order |
| --- | --- |
| `NewTaskSheet` | Task (ticket, name, branch beside its base) → Agent → Prompt. |
| `NewReviewSheet` | Review (merge request, ticket, name, branch) → Agent → Prompt. |
| `SignalSheet` | Signal → Starts when → Agents → Prompt → Done when. |
| `SignalTriggerStep`, `SignalMatchPreview` | A Start or Done trigger: Reads (Jira, GitLab, GitHub), Describe it with its Write button on the label row, the query, and on Start the complete-read preview. |
| `AgentsStep`, `AgentStep`, `ModelReasoningFields` | Agent/Model/Reasoning as selects; the signal edits a list of permitted rows. |
| `SignalDoneStep` | The Done trigger, merge opt-in where offered, Then, optional merged-branch deletion. |
| `ProjectSheet` | Folder, Jira project links and optional worktree import; explicit Add/Save. Edit keeps the folder read-only. |
| `NameSheet` | One confined group with the same chrome/closing block. |

Use `SegmentedControl` for two/three short alternatives, `Select` for a growing list, a native
checkbox for an independent boolean, `Input` for a short line and `PromptEditor` for prose, descriptions and queries.
`DescriptionToggle` consistently says which description gets added. `WorktreeIncludeToggle` keeps
its file-copy explanation. Optional fields end their label with “(optional)” and explain empty.

## Pickers and prompt editing

`ChipsPicker`, `DropdownList`, `PickerResultRow`, `PickChip` and `ChipFlow`
share results, navigation and overhang. A single picked ticket/request/branch
uses a chip in the field. `DropdownKeys` owns arrows/Return/Escape only while open.
`PickerClearButton` uses its tooltip as its accessibility label. The native selection seam stays
in `NativeRowHighlight`.

`PromptStep` wraps `PromptEditor` in shared field chrome/help. The native text coordinator owns
caret-based completions; `CompletionPopup` alone observes popup movement. `/` discovers installed
skills, `@` reads a prepared file index. Preserve UTF-16 selection conversion, undo, plain-text
Finder paths and TextKit 1 caret geometry. `FrontToBackStack` keeps earlier dropdowns over later
fields and previews.

## Settings, archive and messages

`OperatorSettingsPane` composes Operator, `OracleGroup` and Steer the Operator. Role/help copy
explains behavior; only the Oracle's disabled fields fade, with their values kept. Instructions use
`PromptEditor`. `TabBar`/`TabShortcuts` own Settings' command-number navigation. `SettingsGroup`,
`SettingsSwitch`, `SettingsTone` and native controls remain the shared settings vocabulary.

`ArchiveSheet`/`ArchiveRow` restore or remove tasks. Search retains keyboard ownership; there are
no broadcast records. `Notice` offers useful actions and one amber attention mark. `CheckChip`
and `CheckFailureDetails` show check status and failure details.

The [design reference](design-system.html) mirrors shipped components; Proposals holds only future
options. Add domain-independent primitives to AiTermUI only when existing compositions cannot
express the shared meaning. Keep app-shell composition here.
