# AiTerm UI

The design system, in code. This file and the Swift beside it are the source of truth — there is no
generated token file, no canvas and no build step. The page
`docs/design/design-system.html` is a human view of this, synced on request; when the two
disagree, **this wins**.

**Module boundary:** `AiTermUI` depends on nothing else in this package — not `AiTermCore`, not
`AiTerm`. It must not import either. `AiTerm` depends on both `AiTermCore` and `AiTermUI`; the
dependency only ever points that direction. `DesignRulesTests` reads the source for this, and for
both rules below: an import of either in `AiTermUI` fails the build, and so does — in `AiTermUI`
and the app alike, bar the app's snapshot renderer (`Snapshots/`) — a literal colour outside
`Palette.swift`, a `Palette` member's `.opacity(…)`, a system text size outside `Metrics.swift`,
or a padding, spacing, corner radius, offset or frame written as a number (zero aside). Its short
list of exceptions each carries its reason.

## The two rules

1. **Every colour comes from `Palette.swift`.** Never a literal, never a `Color(red:…)`, never
   `.white` or `.black`: ink on the accent is `Palette.onAccent` (or the surface's own `ink`), and a
   vendor mark's white and black are `markPaper` and `markInk`. GitHub's mark is `Palette.github`,
   white for the dark ground, and tinted `markInk` on the white `markPaper` disc of its Integrations
   mark. `Palette.swift` is the one file that writes a literal colour — bar a shadow's black, below.

   That includes a colour derived from another: a wash, a dimmed ink, a pressed state. A view never
   writes `Palette.x.opacity(…)`; the derived colour is a named `Palette` member (`accentPressed`,
   `faint`, `keycapFill`), used by one component or by ten. Named, it is in
   `PaletteDistinctionTests`' manifest, so a wash that happens to resolve to the ground it is
   painted on fails the build instead of drawing a halo. `Brand.wash` is the one derivation off a
   token, because it is one rule for every vendor.
2. **Every height, radius, spacing and text size comes from `Metrics.swift`** — `Space`, `Radius`,
   `Size`, `Typography`, `Sheet`.

Where macOS publishes a scale, `Metrics` uses that number: the system text styles for `Typography`,
AppKit's control sizes for `Size`, AppKit's corner radii for `Radius` (4 small, 6 regular, 8 large,
10 for anything that floats). `Space` is the one house scale — a 4-point rhythm with three named
steps off it (`hairline`, `snug`, `inset`) for the places — chip interiors, control tracks, field
interiors — where the rhythm's own steps are the wrong size.

If no existing member fits, you may add one — with a doc comment saying what it is for, and **say so
in your summary**. Do not add one silently, and do not pick a number because it looked right beside
its neighbour.

One-off geometry may stay in its component: a number only that view measures by — a column fitted
to its content (`NewTaskSheet.ticketKeyWidth`), a glyph's optical size inside its tile
(`ProviderIcon.glyphSize`) — can be a `private static let` there, with a doc comment saying what it
measures and why no token fits. It is not a token and nothing else reads it; the moment a second
file needs the same number for the same reason, it moves into `Metrics` (as `Size.pickerLogo` did).

Kerning and shadows (a black at its own blur radius, offset and opacity) are deliberately not
tokenised — they are one-off optical corrections on a single element, not a scale anything else draws
from. Their absence from `Metrics` and `Palette` is a decision, not an oversight.

`Palette` has a third rule enforced by a test: every distinctly-written token resolves to a distinct
colour. Where two roles share a value, declare it as an alias in the source (`sidebar = surface`) —
the test reads the aliases from there, so that declaration is all it takes.
`PaletteDistinctionTests` fails the build otherwise — it exists because a hover wash once resolved
to the surface it was painted over and drew a visible halo around every hovered avatar.

`Metrics` has no equivalent rule, on purpose. Two `Palette` tokens resolving alike is a rendering
hazard — a wash disappearing into the surface behind it, as above. Two `Size` (or `Space`, `Radius`)
members sharing a number is normal: `Size.chip` and `Size.vendorMark` are both 16 today, and that is
fine — the names exist so one can grow without the other, not because 16 must never repeat.

## Scale

Every number in `Metrics` is a size at ×1. It becomes points where a view reads it, at the
environment's `InterfaceScale` (`standard` ×1, `large` ×1.15, `extraLarge` ×1.3):

- `Typography` scales by itself — `View.font(TypeStyle)` reads the environment. Unrounded, so text
  never outgrows the layout around it.
- `Space`, `Radius`, `Size`: read them through `scale(…)` — `@Environment(\.interfaceScale)
  private var scale`, then `.padding(scale(Space.base))`. Whole points; ×1 is the identity.
- A `size:` parameter is points on screen: the caller scales the token it passes, and the view
  never scales its own parameters. A view's *own* token reads it scales itself.
- Strokes do not scale: hairlines, borders, outline rings, the focus ring. (A drawn ring whose
  stroke is a fraction of its diameter — `StatusMark`, `UsageRing`, `ToneRing` — is a mark, not a
  stroke, and scales with the size it is given.)
- Every round status mark is a ring, never a disc: a `size * 0.15` stroke inside the `size` box,
  `strokeBorder` or a trimmed stroke padded by half its width. `StatusMark` is the idle ring, the
  working arc over its whole track, needs input in `Palette.amber` and done in `Palette.done`
  (`Palette.onAccent` on the accent, as the arc is); `UsageRing` and `ToneRing` are drawn the same way.

Only the sidebar is scaled; `SidebarSheet` resets to `.standard`. AppKit's pop-up and push-button
bezels stop at 28 pt (`.extraLarge` draws `.large` on macOS 26), so a sheet — full of them — keeps
Apple's sizes. Of the primitives, `Badge` scales, `SidebarHeading` and `HelpText` (under the empty
sidebar's line) scale through their one token (a `Typography` style) and `Hairline` is a stroke; the
rest are only drawn in sheets and read their tokens at ×1. A primitive that moves into the sidebar must first read its tokens through `scale`.
`Select` can never scale: it is a native bezel.

The person picks the step as `InterfaceSize` (`AiTermCore`, Settings › Interface › Sidebar size,
or View › Zoom In / Zoom Out / Actual Size); the app maps it onto `InterfaceScale`.

## Two tiers

**Primitives** live here, in `app/Sources/AiTermUI/`. They take standard names and **no AiTerm type
appears in their signature**. A primitive that knows what a task is has stopped being a primitive.

**Patterns** live in `app/Sources/AiTerm/Views/`. They keep AiTerm names, carry AiTerm concepts, and
are composed only from primitives.

## Reuse before new

Stop at the first rung that fits:

1. **A new variant or content case on an existing primitive.** `Badge` absorbed three bespoke types
   this way.
2. **A pattern** — existing primitives arranged. AiTerm name, `Views/`, not here.
3. **A genuinely new primitive.** It owes: a standard name, every measurement from `Metrics`, every
   colour from `Palette`, a declared variant × state matrix, a line in the inventory below, and a
   test under `app/Tests/AiTermUITests/` — the one surviving design guard in this repo *is* a test.

   If the primitive is a `public struct`, also add a `public init`. Swift's memberwise init on a
   `public` type is only `internal`, so without one nothing outside `AiTermUI` can construct it.
   Every promotion on this branch needed one.

Promote a pattern to a primitive only when it is used in two or more files *and* carries no AiTerm
type *and* it is not app-shell composition — a sheet's own anatomy, a window's chrome — which stays
in `Views/` regardless of reuse, because it encodes this app's layout decisions rather than a
reusable part. `SheetLayout` (nav above content above actions, plus `isSnapshot`, an affordance that
exists solely for AiTerm's snapshot harness) and `SheetFooter` (where *this app* puts a sheet's secondary
and primary actions, and what ⎋ means) both clear the first two conditions and stay patterns on this one.

## Surface, not a `selected` flag

A component reads the ground it sits on from the environment — `@Environment(\.surface)`, set with
`.surface(_:)` — instead of taking `selected: Bool`. `Surface.sidebar`, `.hover`, `.washed`,
`.washedHover` (the Operator's row), `.accent`, `.sheet` each publish their own `ink`, `secondaryInk`, `badgeWash`, `badgeWashHovered` and
`occludingBackground`, so a badge inside a newly selected row turns white by itself rather than
every call site re-deriving the same colours.

The container that draws the ground declares it, and only it knows whether it is on: `RowPill`
for a sidebar row, `menuRowHighlight` for a dropdown's — so `PickerResultRow` and the completion
popup's rows are handed no flag — and `SegmentedControl` for a segment, whose label it inks itself.

`Surface` is not a component and gets no card — it is a rule the components assume.

## One theme

AiTerm is dark-only. There is no light variant to keep in sync.

## States are a matrix

Default, hover, pressed, disabled, focused, selected. Declare them up front rather than discovering
them. When a target does not exist, the control is **absent, not disabled**. Reduce Motion is
honoured: `StatusMark` keeps its arc and drops the rotation.

## Inventory

Every name here is a type under `app/Sources/`. Nothing aspirational.

### Primitives — `app/Sources/AiTermUI/`

| Type | What it is |
|---|---|
| `Badge` | the one chip: a Jira key, an editor mark (extended with a `+12 −3` `diff`), a merge request's reference (extended with a `suffix`: a bubble and its resolved review threads of all of them, `2/5`, in the label's ink), a `+n` count, a Settings check (with `iconTint`); `style: .quiet` drops the box at rest, for the sidebar rows; `action` makes it a button, `menu` a menu — a project header's Jira mark and total count — the same chip with the same hover, and `accessibilityLabel` says what a bare count cannot |
| `Icon` | every mark, at a size: an SF Symbol (its glyph's own width, in the surface's ink unless tinted), a vendor `Brand` (a `size` square, in its colour unless tinted), or a full-colour artwork that carries its own fallback (`.gitlabTanuki`, `.piBadge`). The one way the app draws a logo — no fill travels as a hex string |
| `FormField` | a label above its control; what the control hangs out of itself — a dropdown's results — draws over the lines after it |
| `FrontToBackStack` | a `VStack` whose earlier children draw over its later ones, so an overhang (a picker's results, the completion popup) needs no `zIndex` at any level of a sheet. `FormField` is one; a sheet's fields and steps go in another |
| `HelpText` | subordinate caption copy under a control, in a `tone`: `.secondary` (the default) or `.warning` — it inks itself, so colour it by tone, never by an outer `foregroundStyle` |
| `Input` | a real `NSTextField` in the house field chrome, with its focus ring; `secure: true` (an `NSSecureTextField`) for a token; `caretAtEnd: true` puts the insertion point after a value filled in as if typed, where AppKit would select it all on focus (the Backpack sheet's saved password). AppKit sizes it: SwiftUI's `TextField` read its height from a cache that could hand it another font's |
| `Select` | a real `NSPopUpButton` that fills its column |
| `SegmentedControl` | a hand-built segmented control that can carry a logo. `style: .neutral` (a grey selection and the focus ring) or `.accent` (an accent selection on `.surface(.accent)`, no ring — the Settings tab bar); a segment `isSelectable` rejects is dimmed and disabled. It inks each label for its ground — the selection in the surface's ink, the rest in its secondary ink — so a label is plain `Text` |
| `Kbd` | keycaps for a shortcut, inked for the surface it sits on: on `.accent` — `SheetPrimaryButton`'s label declares it — white on the keycap washes; anywhere else the surface's ink on its badge wash, edged in the hairline (Settings › Interface's keyboard section). It takes no style: the ground decides |
| `SearchField` | a single-line field that hands navigation keys to an open popup first |
| `SidebarHeading` | `PROJECTS` and a divider's name: micro, uppercase, tracked, secondary ink |
| `SymbolMark` | a round mark for what is not a vendor: an SF Symbol at half the disc's size, in one of two styles — `.quiet` (the default) in `Palette.text` on a `Palette.controlActive` disc, `IntegrationMark`'s family, with `tint` for a muted glyph; `.paper` in `Palette.markInk` on a `Palette.markPaper` disc, the vendor discs' recipe, so a mark beside Claude's and Codex's reads as one of them. `size` is points on screen — the Mac card passes `Size.control`, the footer's Mac readings row `scale(Size.vendorMark)` |
| `Hairline` | every 1 pt rule, in one weight: `border` on a filled rectangle, the same stroke as a control's outline — the sidebar's rules, the step bar, a sheet's header and footer edges, under a card's header, between the Interface tab's rows. Never a bare `Divider()` |

### Foundations — not components, no card

`Palette`, `Metrics` (`Space`/`Radius`/`Size`/`Typography`/`Sheet`/`TypeStyle`), `Brand`, `Surface`,
`InterfaceScale`, `IconSource`, and the view modifiers in `ControlChrome.swift`: `focusRing`,
`fieldChrome` (a single-line field: padding, height and `fieldBox`), `fieldBox` (the field's fill,
hairline and focus ring alone, for the prompt editor), `menuChrome` (the panel a dropdown hangs in), `menuRowHighlight` (a dropdown row on
the accent, declaring `.surface(.accent)`) and `groupChrome` (a Settings card's, a segmented
track's or a board card's box; a board card passes its hover `fill`, `Palette.rowHoverSolid`, and its
needs-you `edge`, `Palette.statusChipAttentionStroke`).
`Logos` (the bundled SVG data and its image cache) and `LogoGlyph` are internal to this module.
`TypeStyle` is the type `Typography`'s members are declared as and the `View.font(_:)` overload
takes; `Brand` is what `Icon(.brand(…))` and `Badge(icon: .brand(…))` consume. An agent adding a text size or a
vendor needs both.

### Patterns — `app/Sources/AiTerm/Views/`

`SheetLayout`, `SheetSubtitle`, `SheetFooter`, `SheetPrimaryButton`, `DestinationLine`, `CreationSheet`, `CreationFooter`,
`AgentSegmented`, `AgentSegmentLabel`, `Notice`, `FixProposalBlock`, `FixBusyLine`, `FixOfferLabel`, `CommandBlock`, `StatusMark`, `StatusCountChips`, `AvatarGroupView`, `VendorMark`,
`BranchLabelView`, `StepBar`, `ToastView`, `ProviderIcon`, `CompletionPopup`,
`NativeRowHighlight`, `RowMenuAnchor`, `SidebarFooter`, `UsageRing`, `ToneRing` (with `SettingsTone`), `MacMode` (with `MacModeLine` and
`MacModePresentation`, in `MacModeRow.swift`), `BackpackSheet`, `SearchPicker`, `DropdownList`, `DropdownKeys`,
`PickerResultRow`,
`PickedItemField`, `LaneChip`, `AgentStep`, `PromptStep`, `WorktreeIncludeToggle`, `CompletionHint`,
`PromptEditor`, `SidebarView`, `SidebarScrollFollower`, `SidebarBanners`, `SidebarBanner`, `SidebarConnectionBanner`, `IssueBanner`, `OperatorWakeBanner`, `SidebarToast`,
`SidebarSheetPresenter`, `SidebarSheet`, `SidebarHeader`, `SidebarEmptyState`,
`ProjectHeaderRow`, `SelectableRow`, `RowPill`, `RowTitle`, `RowCaption`, `TaskRowView`,
`OperatorHeading`, `BroadcastHeaderRow`, `OperatorRowView`, `OperatorBadge`, `BroadcastStatusLine`, `OperatorMenuButtons`, `TerminalRowView`, `DividerRow`,
`JiraProjectSheet`, `SettingsView`, `SettingsCard`, `ServiceCard`, `ItermSettingsCard`, `SettingsGroup`,
`SettingsSwitch`, `SettingsSection`, `NumberedSteps`, `MacSettingsCard`, `IntegrationMark`, `HarnessSettingsPane`,
`HelpWithProblemsGroup`, `OperatorSettingsPane`, `InterfaceSettingsPane`, `KeyboardSettingsPane`, `NameSheet`, `NewTaskSheet`, `NewReviewSheet`,
`NewBroadcastSheet` (with `ChipsPicker`, `PickChip`, `ChipFlow` and `ProjectResultRow`), `BroadcastBoardSheet`, `BroadcastBoardHost`, `BoardCardView`, `BoardTabLine`, `BoardHeading`, `BoardScroll`,
`TaskBadges`, `BroadcastActivityView`, `BroadcastSummaryView`, `ArchiveSheet`, `ArchiveRow`, `ShelvedBroadcastRow`, `ShelvedBroadcastHost`.

**Backpack Mode.** The sidebar's foot (`SidebarFooter`) is two groups under a `Hairline`, on the
list's grid: SYSTEM, then USAGE. SYSTEM is the selected task's or terminal's `ctx` row (its active
tab's mark, the `UsageRing` and the percentage; a shell draws its mark alone), then the Mac's rows,
always there (proposal 1A · 2A · 3A, 6 Oct 2026). The first is its readings, under a `SymbolMark` in
`.paper` style at `Size.vendorMark` with `macbook`: `cpu ◔ 23% · ram ◔ 61%`, and `bat ◔ 64%` while the
Mac runs on its battery, drawn by the same renderer as `ctx` and the vendor windows. `MachineMonitor`
samples them every 5 s through a `MachineSensor` — Mach host statistics, `thermalState` and the
memory-pressure sysctl, in-process — and `MachineReadings` turns two samples and the battery into
`UsageLine`s. A reading turns amber only on macOS's own warning: the CPU when the Mac throttles for
heat, memory under pressure, the battery within five points of Backpack Mode's cutoff. While the mode
is on or switching, a second row follows: a `ToneRing` at `Size.statusMarkSmall`, centred in the marks'
column, then the words in its `SettingsTone` — `backpack turning on…` and `backpack turning off…` idle,
`backpack enabled` ready, `backpack needs you` attention. That is the one colour in the footer that is
not ink or amber, and a Settings card's voice: the task list keeps `StatusMark` to itself. At the desk
there is no such row. A click on either Mac row opens the sheet at the desk and turns the mode off in
the backpack; a right-click offers Mac Settings…; ⌘B does what the click does. The words, tooltip and
VoiceOver sentence come from `MacModePresentation.line`, decided by `MacMode` apart from the view.

Turning on is `BackpackSheet`, one `SheetLayout` with a `SheetSubtitle`, laid out in the order it
is used. While a permission is missing it opens with a `Notice`: its title what the Mac card's status
says is missing, its description the card's steps and where else to find them, and Allow… its one link
(`BackpackSheetPresentation.permissionNotice`). Then Hotspot, a `Select` of the networks one scan finds now — the remembered hotspot first and chosen
once it shows up, scanned again every 5 s while no connect runs — beside a secure `Input` for the
password, filled with the saved one as if typed (`caretAtEnd`) for the remembered hotspot and empty
for any other; a `HelpText` under them, led by a `.working` `StatusMark` (“Looking for hotspots…”)
while nothing is chosen. Under them “Turns off”, a `Select` in the Hotspot's column — “When agents
stop” (the 2-minute idle grace) or “When I turn it off” — with “Either way, at 10 % battery.” as its
`HelpText`; every sheet opens on “When agents stop”, and the choice holds for that trip only. “On the
iPhone” follows as the hotspot's help: three `NumberedSteps`, `receded` (text in `Palette.muted`)
once a hotspot is chosen, full again while a connect waits for it.
Connect (⌘↩) is disabled until both permissions are granted and a hotspot is chosen; it runs in
place, the fields disabled, Cancel the only action, and two live checks appear under the steps — a
`StatusMark` in a `Size.slot` column beside a `Typography.caption` line, amber on the one that
failed. A failure leaves the fields live and Connect retries; there is no Back. Once the Mac has
joined and is held awake the body becomes a `Size.control` accent disc with a checkmark, “Safe to
close the lid.”, a `HelpText` saying what will end it — the work or the person, and the cutoff —
the checks, and Done on ⌘↩; the mode stays on. Closing the lid dismisses the sheet.
Its words are `BackpackSheetPresentation`'s, its state `BackpackSheetModel`'s. The Backpack toasts
wear `BackpackController.symbol`, `iphone`.

**The Operator.** The OPERATOR heading leads the list, above PROJECTS (`OperatorHeading`): a
`SidebarHeading` on PROJECTS' anatomy whose "+", an `AddMenu` with New Broadcast…, is the one way to
start a broadcast, so with none it is the heading and its "+" and nothing else; there is no File menu
item. One broadcast at a time: while one exists the "+" is absent and the broadcast's group sits under
the heading (decided 21 Oct 2026), its own section of the sidebar (`BroadcastSection`,
`SidebarProjection.broadcast`), drawn by `SidebarView.operatorRows` above the projects' `entries`.

Its header (`BroadcastHeaderRow`, a `BroadcastRow` value) is a project header's anatomy at
`Size.projectRow` in a `RowPill`: `HeaderChevron`, the broadcast's glyph, `dot.radiowaves.left.and.right`,
in a `ProviderIcon` (its `IconSource` init) where a project has its host, the name in `HeaderTitle`, its
progress `Space.gap` after it, `2 of 6` (`paused · 2 of 6` while paused; nothing until the first plan is in
Todo) in `Typography.monoChip` and the surface's secondary ink, then in the trailing slot where a project has
"+" the board button, `rectangle.split.3x1` drawn as the "+" is. Its tooltip is its projects over its whole
status line (`OperatorLine.broadcast`, as the board's band says it, the counts `OperatorLine.Count`'s), which
VoiceOver reads as its value. A click on its label or ↩ folds it,
kept with the workspace (`AppState.foldedRuns`), as a project's fold is; selected it shows no window. Folded,
it shows what needs you in it once, as an amber `StatusCountChips` count, and nothing else of what it hides;
that chip's click opens the group and selects its first row that needs you. Its menu is Open Board, Rename…
(`NameSheet`), Pause Broadcast or Resume Broadcast, and End Broadcast…, which is not red: it asks with a blue
default, since nothing is deleted. VoiceOver has the fold as its default action and the menu's items, Open
Board first, as named ones. No ⌘I, no Interrupt Agents. Menus and buttons are Title Case, as everywhere.

The Operator's row (`OperatorRowView`, an `OperatorRow` value) is always first under it: a full `Size.row`
`SelectableRow`, `washed` at rest in `Palette.operatorRow` (an alias of `badge`) and `Palette.badgeHovered`
hovered, in `RowPill`'s pill, which selection replaces; its ground `Surface.washed` and `.washedHover`, so the
avatar ring is `Palette.operatorRowSolid` and `operatorRowHoveredSolid`. Claude's `VendorMark` is its avatar,
`Operator` its title, its line its own session's alone (`OperatorLine.session`: its act, `working`, `watching
3 tasks` between its turns (`waiting for its tasks` with none at work), `waiting on you` (`waiting on you · PAY-232`
for its question about a task), `paused`, `window closed`; never a worker's request nor what its tasks do) and its `StatusMark` trailing, following the line: amber while it asks, spinning while it
acts or works, the accent ring once the summary is written or AiTerm gave up waiting for it, else the idle ring. No project, ticket or branch line. It has an id of its own
(`OperatorRow.id(of:)`), selected as `RowSelection.operation`, the header being `.broadcast` with the run's.
↑ ↓ peek at its window; a click or ↩ brings it to front with iTerm2, or reopens it in front when it is
closed. VoiceOver calls it "Operator, Claude Code session".

Under it come every task the broadcast holds, moved out of their projects, in the plan's order, then the
queued ones (`TaskRow.queued`): a queued row has its planned agent's mark as its avatar, its title in the
surface's secondary ink, its `queued` line and `pause.fill` as its mark (`TaskRowMark.queued`) in
`Palette.idleRing`; it is selectable, and choosing it opens nothing. A project wears a quiet `Badge` with the
broadcast's glyph and how many of its tasks the group holds (`ProjectOperatorBadge`), whose click opens the
group at the first; its header's tooltip and Remove Project's question say how many worktrees the Operator
holds there (`ProjectSection.operatorHelp`), and a project left with only those is empty. Focus View, List
View and the Dock badge know the group: it counts what is amber in it (`BroadcastSection.needingAttention`).

A driven task's avatars are its own
agents, as any task's are; its last line is the Operator's status line, `OperatorBadge(line:)`. While
the Operator holds the task and nothing on it is yours (`TaskRowCaption.folds(under:)`: no needs-you line,
no caption) the badge line folds away, so the row is its title over that line, a `Size.row` like your own
tasks'; a request, a publication left for you, a removal's progress or a caption unfolds it. The fold is the
badge line's opacity and the row's height, 0.2 s ease-out (the toast's curve), at once under Reduce
Motion. Its click or ↩ raises its window with the worker tab that asks in front, else the one last in front
(`AppController.choose(task:)`, `TaskItem.tabToBring`, `session.activate`); ↑ ↓ peek at its window as at any
task's. Its menu leads with Take Over or Hand Back, and Stop Task… (it asks first) while the task is open; a
task of an ended broadcast is yours, and its menu is any task's. Everything the Operator says on a
status line is that badge: its words in `Typography.monoChip` and no mark, since where the line sits
says whose it is, always one `Size.chip` line cut with an ellipsis, the whole in its tooltip. Quiet, and
ended, have no box and the surface's secondary ink; acting has no box and the surface's ink, and when its
words change they decode once: each letter and digit runs through glyphs (`0-9a-z`, one advance wide in the mono
face, so the line keeps its width) and they settle from the left over `OperatorBadge.decodeDuration` (0.5 s),
then stand still, the row's spinner carrying the ongoing motion (`DecodeWordsView`: a `CATextLayer` with frames
of its own at 30 a second, no SwiftUI update per frame, and no loop). The words stand still at once
under Reduce Motion and in the snapshots; needs you is `statusChipAttentionFill` and `Stroke` with
`Palette.text`, and on `Surface.accent` the surface's `badgeWash` and ink. The words are a closed list
decided by `OperatorLine` (`AiTermCore/Sidebar/OperatorLine.swift`), from the task's state, the
broadcast's requests (`OperatorRequests`) and the act AiTerm is carrying out (`OperatorAct`, published
by `OperatorController.acting`); a request outranks an act, and a task you took over has no line. A line
acts exactly when its row's `StatusMark` turns. Ended is every end a task's line names, `done · 4f2a91c`,
`done · no change`, `draft MR · !412`, `merged · 9b3e07d` and `merged locally · 1c84e20`: the Operator's work
on it is over, and the row's trailing mark is a `checkmark` at the mark's size in `Palette.green`,
`Palette.onAccent` on the selection (`TaskRowMark`, `TaskRowMarkView`). The check stands in for the idle ring
and for the accent ring of an unseen turn; a session at work or waiting on input keeps its own mark, and a
removal or shelving spins. Until then, while the Operator holds the task, its mark spins whatever its tabs say,
with no done ring, and turns amber only when it needs you: its tab waiting on input, or its line needing you
(`SidebarModel.heldStatus`, P3 1A). A queued task's is the pause sign. No other state has a mark of its own. The
Operator's words are plain verbs: accepting is its job, so only what you must do is amber. A task row's icon
already names its agent, so wherever the Operator acts on a task its row names the Operator, never the agent
(`Operator answering`, not `answering Codex` on a Codex row, which reads as Codex answering itself). Acting:
`Operator watching` (the task's agent works; `Operator watching · 2 tabs` with several worker tabs open;
`Operator watching · in background` once its turn ended with work still running in the background, which wakes it
again, the commands on the tooltip), `ready for the Operator` (every worker ended its turn with nothing left running:
the Operator checks it next), the broadcast's `3 working` (`2
working · 1 to check` while some wait for the Operator; the words are `OperatorLine.Count`'s, on the header's
tooltip and VoiceOver value, the folded chips and the board's band), and the acts: `loading the construct`, `consulting the Oracle`,
`starting Claude`, `answering Claude`, `checking the work`, `reviewing with Codex`, `opening the MR`,
`assigning Jan` (`assigning reviewers` before it knows who), `relaying feedback`, `merging`, `filing
a ticket` and `reopening its window`, on the broadcast's line and the Operator's row with the task named
after them (`answering Claude · PAY-231`), on the task's own row as `OperatorAct.rowWords` says them:
`Operator starting it`, `Operator answering`, `Operator checking the work`, `Claude reviewing` (its reviewer)
and `Operator relaying feedback`, the rest as they are; `opening the MR` and `merging` also while AiTerm publishes an accepted
task with no act in flight. Quiet: `queued`, `queued · after PAY-232`, `added by the Operator`,
`in review`, `in review · waiting on Jan`, `in review · Codex`, `failed`, `failed · <reason>`,
and on the broadcast's line `2 to check` (every working task's workers done), `paused`, `paused · the Operator’s window is closed`, `done · writing summary`
(every task done, the summary not written yet), `done · summary ready`, `done` (AiTerm gave up waiting for it) and `ended`. Needs you: `waiting on you` (a prompt or a question, what it asks in the tooltip: the task's
window shows it whole), `waiting on you · docs` (one of several worker tabs asks: the first by
`OperatorLine.first`'s order, then by tab order, `main` first), `waiting on you · 2 tasks` (the broadcast's, when several ask), `blocked · the
tests fail on main` and `blocked · the rebase conflicted` (the reason kept: no window says it), and
`left for you · 4f2a91c`, a publication handed back. The Operator's own row says its session's line
(`OperatorLine.session`), nothing of its tasks but how many it watches: its act, `working`, `watching 3 tasks`
between turns (`waiting for its tasks` with none at work), `writing the summary` (acting) once every task is done, then
`done · summary ready` or `done`,
`paused`, `waiting on you` (needs you: its tab waits on input, or one of its questions is open, answered in its
window; a question about one task names it, `waiting on you · PAY-232`, several are counted, `waiting on you · 2
questions`, and the task's own row goes on with its worker's line) and `window closed`; its mark follows the line, the idle ring between turns and amber when it needs you.
A line is at most `OperatorLine.maxLength` (40) characters, its detail cut at a word. The group, its header and
the Operator's row are values, `BroadcastSection`, `BroadcastRow` and `OperatorRow`
(`AiTermCore/Sidebar/BroadcastRow.swift`).

The heading's "+" opens **New Broadcast** (`NewBroadcastSheet`, its state `NewBroadcastModel`), the creation
frame's parts on four steps, Broadcast · Prompt · Review · Done, and no agent step (`CreationSteps.broadcast`):
the shipped `StepBar`, its names not buttons; Continue on ⌘↩ through step 3, Back from step 2, Cancel on step 1,
Start Broadcast on step 4, and a failed start the footer's `Notice` (`CreationFooter`). Step 1 is Name (an
`Input`, optional), Jira projects and Projects, each a `ChipsPicker`: the picks as `PickChip`s (the service's
mark at `Size.pickerRowLogo`, the name in `Typography.caption`, the ✕ in `Typography.micro` and
`Palette.muted`, on `Palette.badge` at `Radius.chip`, `Size.chip` plus `Space.tight` tall), wrapping by
`ChipFlow` `Space.tight` apart, then a search field taking the rest of the line, all in one `fieldBox` at least
`Size.control` tall, its results a `DropdownList` hanging `Space.tight` under it. It needs one project, and
picking a Jira project picks the projects linked to it. The Jira field offers the connection's Jira projects,
fetched as the Jira projects sheet fetches them, the linked ones first; under its help a plain line says while
they load ("Loading Jira projects…", with a small `ProgressView`), when there are none ("No Jira projects
found.") and when the fetch failed, which says why as the Jira projects sheet does ("Connect Jira in Settings › Integrations to choose a Jira project.") and, while any are linked, that only the Jira projects the projects link are offered; it holds nothing up. Prompt, Review and Done are one `PromptStep` each, the
same editor at `PromptStep.editorHeight`, whose `/` lists Claude's and Codex's skills and `@` the files of the
one picked project; under each its help in place of `CompletionHint`. Review's and Done's help say what the
slices allow, from Settings › Operator's profile as the sheet opens, in plain text: Settings is named, not
linked, and nothing is amber. No command preview: the Operator chooses each task's agent. The
`DestinationLine`, `Opens in iTerm2 · the Operator’s window`, ends steps 1 and 4. No new `Palette` or `Metrics` member.
Start Broadcast waits for what the broadcast needs (`BroadcastReadiness`): every agent the Operator may plan on,
Claude Code and Codex where installed, Ready on its Settings card, Messaging included, and iTerm2's own delivery
checks passed. Until then the footer, on every step, carries a `Notice` with no actions, “Not ready to start”,
its description one line per piece in its card's words (`Codex: Messaging not checked for 0.161`, `iTerm2 checks not run`).

The header's board button and Open Board open the broadcast's sheet (`BroadcastBoardSheet`, presented by `BroadcastBoardHost`,
decided by `BroadcastBoard` in `AiTermCore/Sidebar/`): `SheetLayout` at `Sheet.width` by `Sheet.height`, Settings'
footprint, its band sizing itself (`bandHeight: nil`, `Space.base` under the title) and its content scrolling as one
on Activity and Summary but not on Board (`scrolls: tab != .board`), `Space.block` above and below. The title is the
broadcast's name, whole until the sheet's width cuts it (a name made from the brief is its first line, uncut). The
band, `Space.base` apart, is the broadcast's `BroadcastStatusLine`, as its row says it, no projects; the Asked line in
`Typography.help`, `Asked …  · Review …  · Done …` with each label in `Palette.text` at medium weight, cut at two
lines, the whole in its tooltip; and the tab bar, Settings' `SegmentedControl` in its accent style, Board · Activity ·
Summary (`BroadcastBoard.Tab`), its segments sharing the width and its labels in `Typography.body`, picked by click or
⌘1–⌘3 (hidden buttons, as Settings' ⌘1–⌘4). It opens on `BroadcastBoard.firstTab` — Board until the broadcast reaches
its summary, Summary from then on — and stays where you put it; Summary is dimmed and disabled until then. The footer
is the same on every tab.

Board is the columns, Todo · In progress · Review · Done, each `Sheet.boardColumn` (236) wide and `Space.gap`
apart, Review only when the broadcast has a review: two and a bit show at once, the first on the content's leading
margin, the row of them running past the trailing margin to the sheet's edge and scrolling sideways
(`BoardScroll(.horizontal)`). Each is a `BoardHeading` (a `SidebarHeading` and its count in `Typography.monoChip`,
`Size.menuRow` tall) over its cards, `Space.base` apart, scrolling on its own (`BoardScroll`), an empty one saying so
in one `Typography.help` line ("Nothing started yet.") at
`Space.inset` above and below, the card's own inset, so it reads on the line of the cards' titles beside it. A card
(`BoardCardView`) is a `groupChrome` box, `Space.inset` inside: the agent's `VendorMark` at `Size.avatar`
on every card, started or not, and `Space.base` beside it every line on the title's leading edge, as on a
task row, `Space.tight` apart: the title in `Typography.body`, two lines at most; then the quiet Jira and merge-request `Badge`s (`TaskBadges`) and, only when the broadcast
spans several projects, the project in `Typography.mono`, never the branch; then its status line, the
task's `OperatorBadge`, or `taken over` in `Typography.mono` with no badge. An Oracle refusal adds a
separate `HelpText`, "merge refused by the Oracle", with its reason in the tooltip; the status and column
stay unchanged, and the next `finish_task` clears the note. A card that needs you has its
edge in `Palette.statusChipAttentionStroke` and the needs-you badge, and no Notice: the card is the action.
Its tooltip is the model the Operator chose and its one-line reason. A task with several worker tabs keeps one
card, `Operator watching · 2 tabs` on its line, and lists each tab under a `Hairline` (`BoardTabLine`, `BroadcastBoard.TabLine`),
`Space.base` either side of it, `Space.tight` apart: a `Size.chip` line of the tab's agent's `VendorMark` at
`Size.inlineMark`, centred under the card's mark; its key (`main`, `e2e-tests`) in `Typography.monoChip` and
`Palette.text` on the title's leading edge; `Space.base` after it its state, an `OperatorBadge` (`at work`, `turn
ended`, `opening`, `closed`, or `waiting on you` in the attention chip); and its `StatusMark` at
`Size.statusMarkSmall` trailing. Hovered, a tab line takes `Palette.badgeHovered` at `Radius.chip`, `Space.tight`
beyond it. A tab line's click closes the sheet and brings that tab forward (`session.activate`); a closed tab is
listed with its key muted and no mark, and is no button, as is one still opening. A card's click closes the sheet
first, then opens what resolves it (`BroadcastBoard.Opens`): a permission prompt or a started task, the
task's window; a question or a blocked task, the Operator's window; a problem AiTerm hit, nothing more
than the sidebar banner already showing it. A Todo card is no button. The footer is Pause Broadcast or
Resume Broadcast, End Broadcast… (the blue alert), and Close (⎋). When the Operator's conversation can't
be resumed as its window reopens, the board's footer carries a `Notice` ("Couldn’t reopen the
Operator’s window") with Close and Start Fresh on ⌘↩ (`OperatorController.reopenFailed`).

Activity (`BroadcastActivityView`) is the run's log, `activity.jsonl` in its run folder, which the host follows while
the sheet is open (`ActivityFeed`): every call the Operator made, newest first, what it only read included, under a
`SidebarHeading` for each day, `Size.menuRow` tall (`Today`, then the day, `10 Mar`, with the year once it is another
year's). A row is `Space.snug` above and below and `Space.base` either side, its ground reaching `Space.base` past the
content's margins while its text stays on them: the time in `Typography.mono` on the 24-hour clock; `Space.gap` on, the
line in `Typography.caption`, the task's name in medium weight, the whole muted for a call that only read
(`ActivityLine.reads`); and the task's key trailing in `Typography.monoChip`. A call that did not go through says what
it asked (`finish Shipping step`) and leads with its label at medium weight, `Refused` and `Failed` in `Palette.amber`,
`Challenged` muted; a reason sits under the line in `Typography.help`. A click opens the row in place on
`Palette.rowHoverSolid` at `Radius.control`: `Space.tight` under it the call itself — its tool in `Palette.text`, its
arguments as JSON, then `→` how it went and what AiTerm answered — in `Typography.mono` on `Palette.surfaceRaised`,
`Space.base` by `Space.inset` inside, selectable. One row is open at a time; a second click closes it. With nothing
logged it reads "Nothing recorded yet." in muted `Typography.help`.

Summary (`BroadcastSummaryView`) is what the Operator wrote once every task was done (`write_summary`): its paragraphs
in `Typography.body` and `Palette.text`, `Space.gap` apart and selectable, and `Space.base` under them "Written by the
Operator at 16:05" in muted `Typography.help`. Until it has one the same muted line says why: "The Operator is writing
its summary.", "The Operator didn’t write a summary." or "Ended before it finished. The Operator didn’t write a
summary." `Space.section` on, and only when something is, Left for you: a `BoardHeading` with its count over each item
in `Typography.caption`, `Space.base` apart, one line as `leave_for_you` wrote it. Last, `Space.section` on and only
when the Operator reported a snag (`report_snag`), Worked around in AiTerm: its `BoardHeading` and count, with Copy All
a link at its trailing edge while there are two or more; then each snag, `Space.base` apart, its title in
`Typography.caption` and `Palette.text`, what was true under it in `Typography.help` and `Palette.muted`, and Copy
under that, `Space.hairline` apart. Copy and Copy All are links in `Typography.help` and `Palette.link`, drawn as a
Notice draws its actions; Copy puts the snag's Markdown fix task on the clipboard (`BroadcastBoard.fixTask`), Copy All
every one joined by a rule (`copyAll`), and each reads Copied for 2 s, which VoiceOver announces. What AiTerm showed
and how the Operator got unstuck, on screen nowhere else, are the item's tooltip and accessibility value; Copy All
sits beside the heading because `BoardHeading` hides its children from VoiceOver.

Once every task is done the columns stay, every card in Done, the band reads `done · writing summary` and then
`done · summary ready` (or `done`, AiTerm having given up waiting), and the footer is Close and End Broadcast on ⌘↩,
which asks nothing. A broadcast whose last task waits on a person keeps the board. An ended broadcast's sheet, opened
from the Shelf, is read-only (`BroadcastBoard.shelved`): no card or tab line is a button, Activity is its log as it
ended, it opens on Summary, and the footer is Close alone. No new `Palette` member; one `Metrics` member,
`Sheet.boardColumn`, in place of the board's own width.

**A sheet's anatomy.** The band under a sheet's title holds a `StepBar` (New Task, New Review, New Broadcast), a
tab bar (Settings; the broadcast's sheet, under its band), or — on every other sheet — one `SheetSubtitle`: a sentence saying what the
sheet does, never a path. Every sheet that opens a window ends its content with one
`DestinationLine`, in one format: `Opens in iTerm2 · <project>/<worktree path in it> · <branch>` —
the project alone for New terminal, `task “<title>”` in place of the path for a review that opens in
the task that has its branch, `the Operator’s window` alone for New Broadcast. New Task and New Review draw it
on steps 1 and 3, New Broadcast on steps 1 and 4 (`CreationSteps.showsDestination`), New terminal under its
field; nothing else writes where a window opens.
Above it, on step 1 of New Task and New Review, the step's last field is `WorktreeIncludeToggle`
when the project's `.worktreeinclude` selects files and a worktree will be made: “Copy files
listed in .worktreeinclude”, a `.checkbox` `Toggle` in `Typography.body` as step 3's “Include Jira
ticket details” is, ticked, with no caption; its tooltip lists the files. It is left out, not
disabled, otherwise — and for a review that opens in the task that has its branch.

`CreationSheet` is the frame New Task and New Review share — step bar, command preview, destination
line, footer and its keys, the loads on appear — generic over the sheet's `CreationKind`; each
sheet hands it values and keeps its own first step. A kind says how many steps it has and which one
picks the agent (`stepCount`, 3, and `agentStep`, 2, by default), and `CreationSteps` decides the rest
from those two in one place: the last step creates, the first has Cancel and every other Back, the
destination line ends the first step and the last, the command preview and the missing-agent note
belong to a sheet with an agent step, and every step past the first but the agent's is a prompt editor
whose popup ⎋ closes. New Broadcast, which starts no agent of its own, draws the same parts from
`CreationSteps.broadcast` around its own model, `CreationFooter` included. A failed create shows its error as a sentence in
the footer — git's failure lines through `GitError.sentence`, as the banner has them — with git's
whole output in the tooltip (`CreationFailure`). A review's branch git refused offers its fix at the
footer's leading edge, in `SheetFooter`'s `status` slot: **Switch to main** when the branch is checked
out in the project's own folder and that folder has no uncommitted changes, **Rebase** when the local
branch and origin's have diverged. A plain button with no key — ⌘↩ stays the create — that runs the
fix and then the create it stopped (`CreationFailure.Recovery`).

**Notice.** Every “needs your attention or your answer” is one `Notice` (spec §6.1, proposal 19 Oct
2026): an amber `exclamationmark.circle.fill` at `Size.inlineMark`, `Space.snug` before the title in
`Typography.label` and `Palette.text` on one row; the description under it in `Typography.help` and
`Palette.muted`; then the actions as links `Space.gap` apart; `Space.tight` between the rows and nothing
indented. No amber text: the mark carries the tone. It is the sidebar's banner about a failed save
or a failed operation (`IssueBanner`), the Operator's wake line refused (`OperatorWakeBanner`: "The
Operator can’t be woken", what waits on it and why as its description from `OperatorWakeNotice`, Open the
Operator and Fix in Settings its links; not for a prompt that already waits on you, and gone once the
Operator calls `run_status` or a later wake line lands) and iTerm2 refusing the connection (`SidebarConnectionBanner`:
the status its title, what to do its description), a failed create in `CreationFooter`, and the
Backpack sheet's permission ask (Allow… its one link). In a sheet's footer the caller passes no
actions and keeps its buttons, and a failure with one sentence (`GitError.sentence`) is the title
alone. Not Notices: the grey line while AiTerm connects (`SidebarBannerText`), field help, row captions
and toasts. `SidebarBanner` is only the banners' margins now: their text starts where `PROJECTS`
does. The Operator's greenfield design added two Metrics members: `Size.inlineMark` (12), a mark that
leads a line of text — the Notice's, Find a Fix's — and what is now `Sheet.boardColumn` (236), one
column of the broadcast's board in its `Sheet.width` sheet. The board's footer carries a Notice too, when the Operator's window could not be reopened.

**Find a Fix.** A problem an agent can fix — New Review's diverged or rebase-conflicted branch, and
Pull main's — offers **Find a Fix**, after the failure's own recovery and before Dismiss: led by the
Operator's mark, its agent's `VendorMark` (Claude's) at `Size.inlineMark` (`FixOfferLabel`), a plain
button with no key in the footer and a link in the banner. The fix runs as the Operator: Claude, at
Settings › Operator's model and reasoning (`AgentIntegrations.fixModel`); with Help with problems off,
or Claude Code missing, there is no button and the sentence keeps “Rebase it by hand.”. From then on
the session's state (`FixSession.State`) follows the problem, decided by `FixFooterPresentation` in the
footer and `BannerFixPresentation` in the banner, so each state is tested without rendering.
`FixBusyLine` is the line while it looks — “Looking for a fix…”: a working `StatusMark` at
`Size.statusMark`, `Space.snug` before the line in `Typography.caption` and `Palette.muted`.
`FixProposalBlock` is its plan: the agent's `VendorMark` at `Size.vendorMark`, then what it found in
`Typography.label` and `Palette.text`, why in `Typography.caption` and `Palette.muted`, and up to three
numbered steps in `Typography.help`, the number hanging in a `Space.block` indent, `Space.tight` between
the parts and `Space.hairline` between steps; its text is selectable. `compact`, the banner's size,
sets the line and the why in `Typography.help`. In the footer the busy line and the proposal stand
where the failure was; Cancel and a primary **Apply** on ⌘↩ — the footer's only; the banner has no
key — replace Back and Create while a proposal is up, and “Applying…” with Cancel off and the sheet
held open while it is applied. In the banner they are drawn in the issue's `Notice`, under its title
and reason, with Apply and Cancel as its links, then Cancel greyed while it is applied. A fix that
fails, or finds nothing, keeps the problem's title with what it said as the description, and offers
**Try Again** (a failure) or nothing (no fix).

`NameSheet` is every sheet whose one question is a name: New terminal (`NameSheet.newTerminal`), Add divider, and Rename for a
task or review, a terminal (from its row's context menu or VoiceOver actions: "Rename terminal",
"Terminal name"), a broadcast (its header's Rename…) and a divider — each rename's title, field and sentence from `RenameTarget`. A
terminal's name is its row's; its iTerm2 tabs keep their branch titles. `JiraProjectSheet` is
reached only from a project's context menu: Add Project… has no sheet, the folder chooser adds the
project at once, and a folder inside a repository adds that repository with a toast saying so.

`ArchiveSheet` is the Shelf sheet, View › Show Shelf's (⌘S), every shelved task and review and every ended broadcast in one `SheetLayout`. Its
band holds a search in place of a `SheetSubtitle` — a `magnifyingglass` and a `SearchField` in
`fieldChrome`, "Search title, ticket, !MR, branch, project" — which keeps the keyboard throughout:
↑ ↓ move the highlight, wrapping, ⌘↩ or a double-click restores, ⌘⌫ asks Remove's question about
the highlighted row, and ⎋ clears a search before it closes (`ArchiveSheetModel`; the keys are in
`docs/keyboard.md`). Each row is an `ArchiveRow`, the sidebar's own task row as it was put away: the
agent's `VendorMark` at `Size.avatar`, the `RowTitle` with the day it was shelved trailing in
`Typography.help` where the status mark sits (`ArchiveDate`: relative today, then "yesterday", then the day, "9 Oct"),
then the quiet Jira and merge-request `Badge`s, the branch in `Typography.mono`, cut in the middle,
and the project — newest first, or in `ArchiveSearch`'s order. It sits in a `RowPill` whose ground
at rest is `Surface.sheet`, `Space.hairline` from the next, the list padded `Space.base` above and
below rather than `Space.margin`, since the pills pad themselves (`SheetLayout`'s
`contentVerticalPadding`). An ended broadcast is a `ShelvedBroadcastRow` among them, by the day it ended: the
broadcast header's mark (`ProviderIcon` on `BroadcastHeaderRow.glyph`, in its `Size.avatar` square), the
`RowTitle` with its name, and that day trailing as a task's does; its tooltip is what it was asked. On it the
primary button reads Open: the Shelf gives its slot to the broadcast's sheet (`ShelvedBroadcastHost`), the
`BroadcastBoardSheet` of `BroadcastBoard.shelved` — read-only, on Summary, Close alone. The footer counts — "5 shelved", "1 of 5" — beside Close and Restore;
with no row shown Restore is absent. Nothing shelved reads "Nothing on the shelf yet." over a
`HelpText`, as `SidebarEmptyState` does; a search that finds nothing, "No shelved task matches
“…”.".

A project header wears **one** quiet Jira `Badge` beside its name: the Jira mark and the total
number of linked Jira projects, including `1` for a single link. Clicking the badge opens a menu
of every project — `KEY · Name` in the order they were linked, each opening its own — then
"Jira Projects…", greyed while the workspace is locked. Settings › Interface's "Jira project count"
switch hides the number while keeping the mark and menu. Its tooltip names every project and
VoiceOver reads the total and keys ("3 Jira projects: SHOP, PAY and WEB"). `ProjectJiraBadge`
decides all of it, tested without rendering; `ProjectJiraBadgeView` draws it. An unlinked project
wears no badge.

**Alerts** are `NSAlert`s, described by an `AlertPrompt`: one default button, on ↩, blue — or red
(`defaultDeletes`, `hasDestructiveAction`) when it deletes files or commits — and every other
button the plain grey one, a destructive button that is not the default included. ⎋ answers the
safe choice (`escapeButton`). The table is in `docs/keyboard.md`. `PickerResultRow`, `PickedItemField` and `LaneChip` (a result row, the
pick drawn in the field's place, a lane on its service's wash) carry no AiTerm type and are drawn
from three sheets, but promotion's conditions are necessary, not a mandate: their one consumer is
`SearchPicker`, itself a pattern, so they stay beside it as patterns too.

`SelectableRow` is a task's, terminal's or the Operator's row — its indent, the click that activates it —
and owns its row's hover, so the pointer redraws one row. `RowPill` is the one pill every selectable sidebar
row is drawn in, a project's and a broadcast's header included, and the Shelf sheet's rows: the selection fill
on `Surface.accent`, else the hover wash, else its `ground` — `Surface.sidebar` unless the pill sits on
a sheet. A `washed` pill, the Operator's row, wears `Palette.operatorRow` at rest and `badgeHovered` in the
hover wash's place, on `Surface.washed` and `.washedHover`. It declares the row's `Surface`, and `RowTitle` and `RowCaption` — a row's title, and a line
under it — read that rather than a `selected` flag, as a header's chevron, name, provider glyph and
"+" do; `RowCaption(warns:)` is amber off the accent only. Which row is selected — a project's or a broadcast's
header, a task, a terminal or the Operator's; never a divider — is `RowFocus`'s (`controller.focus`), an owner beside the
controller, not a view. A row reads whether it alone is selected (`focus.isSelected(id)`), as a task
row reads its own removal (`controller.removal(of:)`), missing checkout
(`checkouts.isMissing(_:)`), failed restore (`controller.hasFailedRestore(_:)`) and merge request's
thread count (`reviewThreads.threads(of:)`): each a `PerRow` cell, so an arrow key redraws the row it
leaves and the row it reaches, and a removal its own row, and no other — `SidebarRowRedrawTests` counts them. Only
`SidebarScrollFollower` — not `SidebarView`'s body — follows the selection whole, so the list's
model is not redrawn either.
A task row whose window could not be reopened says "Couldn’t reopen" (`TaskRowCaption`, `Note.plain`, read
from the row's own `controller.hasFailedRestore(_:)` cell) in the slot "Worktree missing" uses, and tries
again when chosen — a click or ↩, never the arrows; its hint and tooltip say so (`TaskRowAccessibility`),
except while the workspace cannot change, when choosing the row retries nothing. A row whose window is
still coming back is drawn as it was.

`CompletionHint` is the line `PromptStep` draws under the prompt editor (unless the step hands its own
help, as New Broadcast's three do), saying what `/` and `@` open — `/` the one trigger for every agent's commands and skills, a Codex skill picked there written
as its `$` mention; `@` the project's files and folders, each row a `doc` or `folder` glyph and its
path, truncated in the middle, with no source beside it.
`SheetFooter` is the foot of every sheet — Cancel (or Back), a `SheetPrimaryButton` and optional
status text — and owns what ⎋ means: an open list closes first (`closeList`), and only then is it
Cancel, on a hidden button of its own so that *clicking* Cancel still cancels. An action a sheet does
not offer at that moment is passed as nil and is absent, key and all: the Backpack sheet has Cancel
alone while it connects and Done alone once it is safe, where ⎋ does nothing. `SheetPrimaryButton`
is a sheet's prominent action; it answers ⌘↩ only, the keycaps it shows. No sheet restates either.

`DropdownList` is the panel every dropdown hangs in — `menuChrome`, `Size.menuRow` rows, the accent
behind the highlighted one (the keyboard's or the pointer's), dimmed while pressed — and
`DropdownKeys` its key contract (arrows wrap, ↩ accepts, ⎋ closes only the popup, everything else is
the field's). `SearchPicker`'s results and `PromptEditor`'s completion popup are both drawn and
keyed through them. The completion popup hangs below the caret's line, never wider than its field,
and opens above the line instead when it does not fit below inside the scroll view around the editor
(or its window) and there is more room above: Settings › Operator's Instructions, a scrolling
sheet's last field.

`SettingsView` has four tabs — Agents, Operator, Integrations, Interface — picked from the tab bar
or with ⌘1–⌘4, and none opens with an intro line. It opens on Integrations while iTerm2 is not connected or a
saved service's last test failed (`ServiceTestRecord`), and on Agents otherwise; that is decided
once, as the sheet opens, and a test answering afterwards never switches the tab.

`SettingsCard` is the one box every Settings entry is drawn in — a harness on Agents; iTerm2
(`ItermSettingsCard`), the Mac (`MacSettingsCard`), then Jira, GitLab and GitHub (`ServiceCard`) on Integrations: a `Size.control` mark,
a title with optional check chips, a status line in one of three tones (`SettingsTone`: ready, attention, idle, led by its `ToneRing` — the ring the footer's backpack line draws too)
and with no full stop (`SettingsStatus` drops the one an error's own sentence ends with),
trailing actions at `.controlSize(.large)`, fields below a divider. Cards carry no Test button:
Settings tests every card when it opens (and a service again once its fields stop changing), and
the answer replaces that card's status line rather than landing in the sheet footer. A harness
card's one action is named by the card's state and runs the same code whatever it says: Install
while the CLI or the driver is missing, Repair while a check is amber, Reinstall when the card is
Ready; a card whose only amber check is one Install cannot fix (Grok's Context, when its status line
is the built-in or one AiTerm must not edit) shows no action at all. Claude Code's and Codex's cards
carry a third chip, Messaging: the delivery check's verdict held against the version installed
(`DeliveryCheck.messaging`; a pass covers every patch of its major and minor). Passing, its sentence
(“Messaging ready for 2.1”) is the chip's tooltip; needing attention, it is the status line
(“Messaging not checked for 2.2”, “Messaging failed: approvalRace”, naming the scenario the run
stopped at) and, once nothing Install can fix is amber, the action is **Run check**, which opens an
iTerm2 window in front running the check for that agent; the card says “Check running in iTerm2”
with a spinner until the check writes its verdict, and the window closes itself when it has. The
card follows the policy file while Settings is open. A failed run leaves `CheckFailureDetails` among
its fields: “Why it failed” behind a chevron, in muted `Typography.caption`, unfolding to the check's
reason and the end of the screen it read in `Typography.mono`, selectable. Over a missing CLI it runs the
vendor's own installer and then the driver; over a present one it writes the driver whether or not
it is already installed, so it can be overwritten. Claude Code's card leads its fields with one
`HelpText` line, `Configuration:` and the full path of the folder its settings, models and skills are
read from: the login shell's `CLAUDE_CONFIG_DIR`, else `~/.claude`. A Jira, GitLab or GitHub card
holding saved credentials trails a Disconnect, which empties its fields and marks the service for removal: Save
removes the saved site or host and the Keychain token, Cancel keeps everything. Save is all or
nothing: it checks every card before it writes any, so while one card cannot save (a mistyped URL)
nothing is written at all — a Disconnect or a new connection on another card is not applied either —
and the sheet stays open saying why. A write the Keychain refuses puts back the ones this Save made
before it, and the footer names any service the Keychain would not let it put back. The iTerm2 card
has no fields: below its divider it lists the numbered steps that mend the first broken link to
iTerm2, or one line of `HelpText` when nothing is broken. Its status line is
`ItermConnection.status`, and the banner above the sidebar opens with the same words — grey, or
amber while iTerm2 refuses the connection. It stays a pattern: Settings is its only user and its
layout is this app's.

Integrations heads its cards in two `SettingsSection`s, Core (iTerm2, then the Mac) and Services (Jira,
GitLab, GitHub), each title in `Typography.bodyEmphasis` as Interface heads its keyboard section.
`MacSettingsCard` is a harness card's anatomy for the Mac: `macbook` in a `.paper` `SymbolMark`, the
chips “Lid sleep” and “Network discovery”, one action named by its state — Allow… while something is
missing, Remove once both are granted — and, below its rule, `NumberedSteps` for what is missing or one
line of `HelpText` when nothing is. A missing permission does not move the tab Settings opens on.
`NumberedSteps` is also the iTerm2 card's mending steps and the Backpack sheet's phone steps.

`SettingsGroup(title:help:rows:)` is a group that connects and tests nothing — Sidebar size,
Sidebar badges, each keyboard group: the card's box and rule without its mark, status line or
actions. A heading over one line of `HelpText`, a `Hairline`, then the rows, one heading gap
(`Space.gap`) either side of the rule and between rows; rows split themselves with a `Hairline`.
`SettingsGroup(title:help:accessory:rows:)` puts one control at the heading's trailing edge, as a
card's actions sit — Help with problems' switch; with no rows there is no rule.
The terminal-background row is not one: it has no heading of its own, only a swatch, a title and
a switch, in the same `groupChrome` box.

`HelpWithProblemsGroup` is the top of Settings › Agents: a `SettingsGroup` “Help with problems” with a
`SettingsSwitch` as its accessory and no rows — no agent select, since the fix runs as the Operator
(`HelpWithProblems`, kept under `operator.helpWithProblems`), at the model Settings › Operator sets.
With Claude Code missing the switch is off and disabled, and the group's help says to install it.

`OperatorSettingsPane` is Settings › Operator, four `SettingsGroup`s staged in `OperatorSettingsModel`
until Save writes them through `OperatorProfileStore.save` (only when something changed; Cancel drops
them). **Agent** names Claude Code by its `VendorMark` with no control to pick it, then Model and
Reasoning `Select`s from Claude's catalogue. **Autonomy** lists the base with “Always on” trailing,
then the Jira, Review and Merge slices, each its name in `Typography.bodyEmphasis` over a `HelpText`
with a `SettingsSwitch` trailing, rows split by a `Hairline`; under them the fixed Never lines, each
led by `nosign`, all in `Palette.muted`: facts, not failures. **Oracle** carries its switch as the
group's accessory over Agent (Claude Code or Codex, whichever is installed, and the saved one
shown as it is though it is not), Model and Reasoning; off, they are dimmed and
disabled and keep their values. **Instructions** is a `PromptEditor` whose `/` lists both agents'
skills. Autonomy's and the Oracle's help end “Changes apply to the next broadcast.”: a broadcast
freezes the profile as it starts.

`InterfaceSettingsPane` draws its preferences outside cards: the terminal-background row, a
"Sidebar size" group (a `SegmentedControl` of `InterfaceSize`, applied to the sidebar behind the
sheet as it is picked and put back by Cancel, where the rest of the tab waits for Save), and a "Sidebar badges" group whose rows preview the real `Badge` beside a switch that drops
that badge's detail (`BadgeDetails`) and keeps its mark, click and tooltip. A section's step
(`Space.section`) below them comes `KeyboardSettingsPane`.

`KeyboardSettingsPane` is that tab's "Keyboard shortcuts" section, not a tab of its own: a heading
over one line of help, "Shortcuts can’t be changed yet.", then every key read-only, one
`SettingsGroup` per `KeyBindingGroup`, rows with the action in body text and its keys in `Kbd`. The
groups run from the widest reach to the narrowest — macOS's ⌘⇥, anywhere in AiTerm, the sidebar,
sheets, lists and the prompt — and the table (`KeyBindings.all`) is written by hand, so a key added
to the app goes there too; `KeyboardSettingsTests` fails if the menu bar's keys and the list
disagree.

`SidebarEmptyState` is what sits under `PROJECTS` while there are none: a `Typography.body` line,
a `HelpText` line, and an "Add Project…" push button that runs the header's own action. Its text
starts where the heading's does, and its spacing reads `scale`; the button is an AppKit bezel, so
it steps from `.regular` at ×1 to `.large` above it rather than scaling.

`UsageRing` is the ladder's first rung working as intended: a progress ring carries no AiTerm type
and would make a fine primitive, but only the footer draws one, so it stays a pattern until a second
file needs it. It is drawn to `StatusMark`'s recipe — same diameter, same `size * 0.15` stroke, same
round cap — so the sidebar's two round marks read as one family.

Every window in the footer — its label, ring, number and reset — has one tooltip and one VoiceOver
label in words (`UsageLine.help`): “Weekly limit, 61 % used, resets Friday 23:33”, “Context 84 %
full”, “CPU 87 % busy, slowed by heat”. A vendor's or the context's reading turns amber at 80 % or
more; the Mac's, on macOS's warnings above.

## The artifact

One HTML page, `docs/design/design-system.html`, for humans. It is synced from this code on
request by the `design-system` skill. It is not a gate and not a source of truth — you never need it to write
correct Swift.

It has three tabs. **Foundations** and **Components** describe what ships and are transcribed from
the Swift. **Proposals** holds what does not ship yet: a visual change drawn at real size from the
current tokens, its options side by side with a recommendation, so it can be chosen before any
Swift is written. A proposal obeys the same two rules as the code — every colour and number it
draws comes from `Palette` and `Metrics`, or it says which new member it would add.

When a proposal is implemented, the Swift changes first, then its entry is deleted from the
Proposals tab and the other two tabs are synced to the code. **The tab stays**, empty or not; with
nothing on it, it keeps only its "How this tab works" intro. A proposal on the page is never a
reason to write Swift on its own — only a pick is.

The three-artifact design canvas this replaced was retired on 2026-09-21. Doc comments across this
package that still say "design canvas" are historical provenance for a decision (what a value is,
or why it was chosen) — not a pointer to a document you can open. Leave them; do not chase them down
to delete unless one names a specific file or approval a reader might actually try to open.
