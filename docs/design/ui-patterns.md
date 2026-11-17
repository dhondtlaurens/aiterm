# App UI patterns

Patterns live in `app/Sources/AiTerm/Views/` and compose [AiTermUI primitives](../../app/Sources/AiTermUI/README.md).
Swift defines geometry and projections. This inventory explains reuse; the [Operator](../operators.md),
[keyboard](../keyboard.md) and [window](../windows.md) guides explain workflows.

## Sidebar

`SidebarRowContent` shares the avatar, title/badge column and trailing mark grid. `FoldOnTap` folds
only the label; `SidebarHeadingInset` owns its gutter. Project headers use `HeaderChevron`,
`HeaderTitle`, `ProviderIcon` and `AddMenu`. `RowPill` declares the surface. `TaskRowView` is used
under both projects and signals. Its actions resolve the current task at invocation; its body reads
cached drawn facts. `TaskRowBadges` drops whole badges so only the branch truncates.

`SignalOperatorHeading` shows global pause and offers New Signal / Pause / Resume in its + menu. `SignalOperatorRow` is the active workload’s chat row, with pause,
waiting count, errors and window recovery. `SignalHeader` uses project geometry and source marks;
its `SignalHeadingValue` contains only the heading's drawn facts, folded counts and tooltip.
`SignalSidebar` groups existing task rows; Take Over returns the same row to its project.

Signal tasks use the same two-line task row as ordinary tasks: title, badges and branch, with the
same avatar and status grid. The Operator adds no status line and never replaces task badges.
`OperatorBadge` on the Operator’s own row describes its current action. `OperatorActivityTracker`
assigns a new identity to every start, result, failure and return to watching, including repeated
words. `DecodeWordsView` decodes for 0.5 seconds, retaining the text’s case, ink and width, then
stops. `OperatorActivityCaption` keeps a quick completed action readable for one second,
including its decode, before returning to the current status; a new event replaces it immediately.
The status mark always reflects current work. The title stays “Operator”. Reduce Motion swaps; snapshots remain still.

The dashed ring, turning once every six seconds, means waiting on something that moves by itself or on
someone: a turn's background work that wakes the agent again (`background`), or a driven task that waits
(`waiting`): its workers ended their turn and the Operator is to read it (`worker done · Operator to
review`), or its done condition is someone else's to meet (`waiting on approval · Lawrence`, `waiting on
3 open threads`). The status tooltip names whom or what where the done check already read it, and says the generic
words otherwise; it stays within 40 characters and the tooltip carries the whole sentence. The solid spinner
is only for a worker or the Operator at work now. A waiting task is never counted as working: a folded
section gives it its own chip, and neither Focus View nor the Dock badge counts it. Reduce Motion holds the
ring still.

`TaskRowMarkView`, `StatusMark`, `StatusCountChips`, `AvatarGroupView`, `VendorMark`, `BranchLabelView`
and `QuietBadgeLine` share the status/agent/branch vocabulary. `BackgroundCardView` reuses the work
list under a background/working/input mark, only with verified work. Display evidence does not
change persisted state or Operator readiness. Amber means the person needs to act.

`ToastView` and `Notice` share message hierarchy.
`SidebarFooterHost`/`SelectedRowSidebarFooter` scope telemetry to selection. `UsageRing`, `UsageLine`,
`ToneRing`, `MacMode` and `MacModeLine` keep readings neutral unless their own warning applies.

## One creation family

`SidebarSheet` resets native scale. `SheetLayout`, `SheetSubtitle`, `SheetFooter` and
`SheetPrimaryButton` own header/content/actions. Fixed steps retain one height; short one-step
sheets fit up to `Sheet.height`. The footer's primary action answers ⌘Return. Plain Return stays
with a field/list, Escape closes an open list before going back, and Cancel cancels.

`SteppedSheetFrame` draws the shared frame. `SheetStepper` ticks completed steps and names the
current one; completed steps are clickable and answer their command-number keys. Future steps
cannot be jumped to. `CreationSheet`/`CreationFooter` share task/review validation, destination,
command preview and failure recovery. `CreationClosingBlock` ends each creation sheet with the effect
of its current picks.

| Pattern | Decisions in order |
| --- | --- |
| `NewTaskSheet` | Task (ticket, name, branch beside its base) → Prompt → Agent. |
| `NewReviewSheet` | Review (merge request, ticket, name, branch) → Prompt → Agent. |
| `SignalSheet` | Signal → Starts when → Prompt → Agents → Done. |
| `SignalStartsStep`, `SignalConditionPicker` | Jira conditions/JQL or the host event, optional project chips and complete-read preview. |
| `AgentsStep`, `AgentStep`, `ModelReasoningFields` | Agent/Model/Reasoning as selects; the signal edits a list of permitted rows. |
| `SignalDoneStep` | Source-valid done condition, merge opt-in where applicable, Then, optional merged-branch deletion. |
| `ProjectSheet` | Folder, Jira project links and optional worktree import; explicit Add/Save. Edit keeps the folder read-only. |
| `NameSheet` | One confined group with the same chrome/closing block. |

Use `SegmentedControl` for two/three short alternatives, `Select` for a growing list, a native
checkbox for an independent boolean, `Input` for a short line and `PromptEditor` for prose/JQL.
`DescriptionToggle` consistently says which description gets added. `WorktreeIncludeToggle` keeps
its file-copy explanation. Optional fields end their label with “(optional)” and explain empty.

## Pickers and prompt editing

`ChipsPicker`, `DropdownList`, `PickerResultRow`, `PickChip` and `ChipFlow`
share results, navigation and overhang. A single picked ticket/request/branch
uses a chip in the field. `DropdownKeys` owns arrows/Return/Escape only while open.
`PickerClearButton` uses its tooltip as its accessibility label. Native selection/menu seams stay
in `NativeRowHighlight` and `RowMenuAnchor`.

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
