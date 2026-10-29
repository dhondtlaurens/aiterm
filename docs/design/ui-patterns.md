# App UI patterns

Patterns live in `app/Sources/AiTerm/Views/` and compose [AiTermUI primitives](../../app/Sources/AiTermUI/README.md).
Swift defines their exact geometry and state projection. This guide explains which pattern to
reuse; user workflows belong in the [README](../../README.md), [Operator](../operators.md),
[keyboard](../keyboard.md) and [window](../windows.md) guides.

## Sidebar

`SidebarRows` shares row geometry, titles/captions, selection and action semantics. Project headers
use `HeaderChevron`, `HeaderTitle`, `ProviderIcon` and `AddMenu`; an empty project retains alignment
but has no collapse action. `RowPill` declares its surface. A row's status owns the trailing slot;
`TaskRowBadges` folds a diff to its mark and then drops whole badges so only the branch truncates.

`TaskRowView` reads selection, checkout, removal and review facts for its own identity. Preserve
that focused observation when changing it. `TaskRowMarkView`, `StatusMark`, `StatusCountChips`,
`AvatarGroupView`, `VendorMark` and `BranchLabelView` draw shared status/agent/branch vocabulary.
`BackgroundCardView` presents the jobs behind a background mark; it does not add another persisted
status. Reduce Motion changes animation, not the information shown.

`SidebarHeading`, `DecodeWordsView` and `OperatorBadge` give the Operator section its existing
vocabulary. `SidebarBannerText`, `ToastView`, `Notice` and `FixOfferLabel` reuse the same hierarchy
for messages. Amber means the person needs to act, not that the Operator is busy accepting work.

`DecodeWordsView` uses the words' own ink without a glow. Unsettled characters cycle through
letters/digits of their own case, keeping the settled text's width. `OperatorTitle` decodes OPERATOR
into the Operator row's actual line, uppercased: immediately for a new act (`OperatorLine.isAct`),
and after an unchanged quiet interval for the line then shown. It returns home under the pointer
and remains still while paused, ended, needing input, with the Operator window closed, under
Reduce Motion and in snapshots. Keep this shared line as the source of the heading's words.

`SidebarFooterHost` and `SelectedRowSidebarFooter` scope observation to selection. `SidebarFooter`
aligns SYSTEM and USAGE with the list grid. Context, CPU/RAM/battery and account windows reuse
`UsageRing`/`UsageLine`; `ToneRing`, `SettingsTone`, `MacMode` and `MacModeLine` show Unplugged state.
Mac readings stay neutral unless platform warning signals warrant amber.

## Sheets and creation

`SidebarSheet` fixes native scale. `SheetLayout`, `SheetSubtitle`, `SheetFooter` and
`SheetPrimaryButton` own the title/band/content/actions anatomy. A primary button shows ⌘Return;
plain Return remains with its field. `DestinationLine` states the real target window/worktree.
`CreationSheet` and `CreationFooter` share steps, destination, command preview, recovery and Fix
presentation for task/review creation. `StepBar` names the current step; it is not arbitrary step
navigation. `AgentSegmented`, `AgentSegmentLabel`, `ModelReasoningFields`, `CommandPreview` and
`CommandBlock` are the existing agent/command building blocks.

`Notice` carries an attention title, explanation and only useful actions, led by its standard amber
mark. `CheckChip` and `CheckFailureDetails` show check status and expandable failure. `SettingsTone`
supplies the same semantic vocabulary to cards. Use it instead of another bespoke warning box.
`FixProposalBlock`, `FixBusyLine` and `FixOfferLabel` render the proposal/apply lifecycle; they do
not own a second Fix session.

`ArchiveSheet`, `ArchiveRow` and `ShelvedBroadcastRow` share shelf navigation and search. Keep the
search field's keyboard ownership, meaningful restore/open actions and refusal behavior.

## Pickers and prompt editing

`SearchPicker`, `DropdownList`, `PickerResultRow`, `ChipsPicker`, `PickChip`, `ChipFlow` and
`ProjectResultRow` share result navigation and overhang. `DropdownKeys` handles arrows, Return and
Escape only while a list is open. The parent field remains responsible for ordinary text keys.
`NativeRowHighlight` and `RowMenuAnchor` bridge native selection/menu behavior where required.

`PromptStep` owns field chrome and help around the native `PromptEditor`. Its coordinator owns
caret-based completion state; `CompletionPopup` alone observes popup movement. `/` discovers
installed commands/skills; `@` reads a project/file index prepared outside view rendering. Keep
UTF-16/AppKit selection conversion, undo and plain-text Finder path insertion at this native seam.
Do not replace it with a TextEditor that cannot expose the caret/navigation behavior.

## Broadcast setup and board

`NewBroadcastSheet` composes Broadcast, Prompt, Agents, Task and Done steps. `AgentsStep` reuses
`ModelReasoningFields` without repeated labels. `TaskStep` shows shared review/end/closing choices;
`DoneStep` shows goal/rounds, dimming disabled editors while retaining readable labels/help.
`OracleGroup` supplies the switched-off whole-group treatment in settings. The user-facing
[Operator guide](../operators.md) defines these choices and permissions.

`BroadcastBoardHost` presents `BroadcastBoardSheet` from the pure `BroadcastBoard` projection.
The band shows status, then a line each for Asked, the optional Goal and Each task settings (cut at
the end, whole in the tooltip), then Board/Activity/Summary `Space.block` below them.
No historical Review/Done header variant remains. Summary becomes selectable when available.

`BoardHeading` and `BoardCardView` compose Todo/In progress/Review/Done columns at
`Sheet.boardColumn` with `Space.gap` between them. Review appears when the task review prompt is
written or people's review applies. The board scrolls as one, down and sideways, through
`SheetLayout`'s scroll; no column scrolls on its own.
Cards use `groupChrome`, quiet `TaskBadges`, the agent mark and the Operator's line; an attention
edge and badge make the card actionable without nesting a Notice.

`BoardTabLine` exposes each worker/reviewer tab and its state/model. `BoardEndLine` presents the
person's task-end menu. Review verdicts, fix-round answers, retained-worktree explanations and
finished-task records stay on the same card. Oracle merge refusal is explanatory help, not a
new task state. `BroadcastActivityView` and `BroadcastSummaryView` render recorded events and the
summary/goal outcome. Pause/Resume, End and Close share the sheet footer across tabs.

## Settings and native seams

The Settings tab bar is the accent `SegmentedControl`; fields/cards use the shared chrome and
native text/popup controls. Credentials remain secure Input fields; changes wait for Save except
explicit immediate actions and interface-size preview. Use existing integration card/check patterns
for new settings. AppKit bridges retain weak coordinator links and native focus/editing semantics.

Do not split a large composition solely by line count. Extract a shared pattern when callers have
the same domain meaning and lifetime. Promote it to AiTermUI only once its signature is independent
of AiTerm and it is not app-shell layout. The [design reference](design-system.html) illustrates
shipped patterns; Proposals contains only future options.
