# 8e. The selection follows its row; no heading reads a source

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 8d (row commands), 8c (`HeadingRow`, the
removed signal's runtime fold), 8b, 8a, and phases 1 to 5 (3b left `RowFocus` with selection, peek
and raising only; 3c gave the Operator row `.operatorChat` and the id `OperatorSession.rowID`; 5h
regrouped `Signals/`). Audit: SB F8, SB F9, SS F11.

## Why

Two leftovers make the sidebar act on things you cannot see. A selected row keeps its selection
after it leaves the list: the Operator row disappears when its workload ends but stays selected,
and a fold (a project, a signal, or the mutual OPERATOR/PROJECTS fold) can hide the selected row;
the footer then shows the hidden row's context and ⌘⌫ closes a hidden terminal without a word.
Native sidebars move the selection to the collapsed parent and clear it when the row goes. And a
switched-off signal's heading runs a full read of Jira, GitLab or GitHub from a view task, only to
title one menu item "Switch On (starts n)", repeating the sheet's counting rule character for
character. The end state: a row that stops being drawn hands its selection to its visible heading,
or clears it when there is none; "which items would start" is one Core rule used by the signal
sheet's preview; the menu item reads "Switch On"; no heading reads a source.

## Today

As the code stands after phases 1 to 5 and 8a to 8d.

- `RowFocus` (`app/Sources/AiTerm/RowFocus.swift`): `selection`, `browse(_:)` (selection only),
  `peek`, raising, and `dropStale()`, which its own workspace hook runs first on every workspace
  change: it clears a selection whose row no longer exists in the workspace (`row(id:)` returns
  nil). `row(id:)` returns `.operatorChat` for `OperatorSession.rowID` unconditionally, so the
  Operator row is never dropped. Nothing looks at whether a row is drawn.
- `SidebarProjection` (`app/Sources/AiTerm/SidebarProjection.swift`) knows what is drawn:
  `operatorOpen` (the OPERATOR section open, PROJECTS folded), `signalOperator.shown`,
  `signalSections` (with `collapsed`, removed signals' runtime fold from 8c included), `sections`
  (with `collapsed`). `SidebarView` draws the Operator row and signal sections only while
  `operatorOpen`, and project entries only while not.
- `AppController` re-derives the rows in one place (today `refreshRows()`), called on workspace,
  row-session, checkout, signal-controller and sheet changes. `SidebarScrollFollower` calls
  `AppController.reveal(_:)` on each selection change, which opens the section and the fold that
  hide a row selected from elsewhere (a notification, Focus View, an amber count).
- Folds that hide rows: `ProjectActions.toggleCollapsed`, `AppController.toggleCollapsed(_:)` for
  signals, `toggleOperatorOpen`, `crossSections`, Focus View and List View (`applyView`).
- `HeadingRow`'s signal kind (`app/Sources/AiTerm/Views/SidebarHeadings.swift`) holds `@State
  starts` and a `.task` keyed by id, source, enabled and removed: for a live switched-off signal it
  calls `controller.signalController.connections()`, then `reader(for:).poll(since: nil, full:
  true)`, and counts items that map to a project and are not already started and still matching
  for this signal. The signal heading's command list (8d) titles Switch On with "(starts n)" when
  the count is known.
- `SignalModel.received(preview:)` (`app/Sources/AiTerm/Operators/SignalModel.swift`) sets
  `startCount` with the same predicate, for the sheet's preview; `original?.id` is nil for a new
  signal. `MatchDecision` (Core, `AiTermCore/Operators/Signals/MatchDecision.swift` after 5h's
  regrouping) owns the real start decision.
- Docs: `docs/operators.md` ("A signal's menu has **Switch Off** and **Switch On (starts n)**"),
  `docs/keyboard.md` (Sidebar section).
- Tests: `ItermFocusTests`, `SidebarInteractionTests`, `SignalSidebarTests` (fold, reveal,
  crossing), `SignalModelTests` (preview count), `AppControllerTests` (Focus View).

## Change

1. Add to `SidebarProjection` two pure questions over what it last derived: whether a selection is
   drawn now, and the visible heading that holds it. Drawn: the Operator row while its section is
   open and it is shown; a signal heading while its section is open; a driven task while its
   section is open and its signal is not folded; a project heading while PROJECTS is open; a
   project's task or terminal while PROJECTS is open and its project is not folded. The heading of
   a project row is its project heading and of a driven task its signal heading, each only if that
   heading is drawn; the Operator row and every heading have none.
2. In the controller's one re-derivation (today `refreshRows()`): before deriving, note whether
   the current selection is drawn; after deriving, if it was drawn and no longer is, browse to its
   heading when one is drawn, else to nothing. Browse only: no window is raised, no task is marked
   seen. A selection that was not drawn before (selected from elsewhere, waiting for `reveal`) is
   left alone.
3. Add one Core rule for "which items of a complete read would start for this signal": the items
   that map to at least one project and are not already started and still matching for this
   signal's id (a nil id for a signal not saved yet matches no seen entry). Put it beside
   `MatchDecision`, test it in Core, and make `SignalModel.received(preview:)` use it for
   `startCount`. Its result must equal today's count for every input.
4. Delete the heading's `starts` state and its `.task`. The signal heading's command reads
   "Switch Off" or "Switch On", nothing more. No view under `app/Sources/AiTerm/Views` calls a
   source reader.
5. Docs: `docs/operators.md` "**Switch On (starts n)**" becomes "**Switch On**". `docs/keyboard.md`,
   Sidebar section, one sentence: a row hidden by a fold hands the selection to its heading; a row
   that disappears, or is hidden with its heading, is deselected.

## Keep

- `RowFocus.dropStale()` and its hook: it handles rows that left the workspace (removed, archived,
  a project removed) in the same change, before any derivation. The new step handles drawn-ness.
- `reveal(_:)` and `SidebarScrollFollower`: a row selected from away from the list still opens
  what hides it. The "was drawn before" condition is what keeps the two from fighting.
- `crossSections`, Focus View's peek, `openOperatorAttention` and `openProjectsAttention`: they
  fold, then select their target; the hand-over happens in between and the target wins.
- `SignalModel`'s preview read and its error path: the sheet still reads the source when you ask
  it to; only the heading stops.
- `MatchDecision.decide` unchanged; the new rule sits beside it and does not replace it.

## Decisions already taken

- The OPERATOR and PROJECTS section headings are not selectable, so a row hidden by the mutual
  fold, or its project or signal heading, is deselected, not handed over.
- The Operator row has no heading: when it stops being shown, or its section folds, the selection
  clears. Return and ⌘⌫ then do nothing, and the footer shows no row.
- Take Over moves a task from its signal to its project. If PROJECTS is folded at that moment the
  task stops being drawn and its selection clears; if PROJECTS is open it stays selected, now under
  its project.
- Handing the selection to a heading triggers `reveal(heading)`, which finds the heading's section
  already open and changes nothing.
- No runtime count is kept anywhere for Switch On: a switched-off signal is not polled, so the
  Operator never holds the number (the plan's "unless the Operator already holds the count" never
  applies).
- A removed signal heading has no commands (8c), so no Switch item at all.

## Tests

- Add app tests: a selected project task whose project folds selects the project heading; a
  selected driven task whose signal folds selects the signal heading (live, and removed through
  8c's runtime fold); the selected Operator row that stops being shown clears the selection, and
  `removeSelection()` and `activateSelection()` then do nothing; a selected project task clears
  when OPERATOR opens; Focus View with nothing waiting folds the selected task's project and the
  selection becomes its heading; a task selected while its signal is folded (as a notification
  selects it) keeps its selection and `reveal` opens the signal.
- Add a Core test for the start rule: an item mapping to no project is not counted; an item
  started and still matching for this signal is not; one started by another signal is; one whose
  seen entry is skipped or no longer matching is; with no signal id every mapped item counts.
- Adjust any test that expected "Switch On (starts n)" on the heading's command list to "Switch
  On". `SignalModelTests`' preview counts stay as they are.
- Deleted: none, apart from the heading's count expectation above; the behaviour it tested is
  deleted.

## Proof

- Before your first edit: `scripts/snapshots.sh build/8e-before`; after: `scripts/snapshots.sh
  build/8e-after`; list differences with
  `for f in build/8e-before/*.png; do cmp -s "$f" "build/8e-after/$(basename "$f")" || echo "$(basename "$f")"; done`.
  The list must be empty (known GitLab artwork variants in `marks.png` and
  `signal-jira-reviewRequested-1.png` aside).
- While iterating: `scripts/test.sh swift -- --filter SignalSidebarTests`, `SidebarInteractionTests`,
  `ItermFocusTests`, `AppControllerTests`, `SignalModelTests`, `SidebarRowRedrawTests`,
  `SidebarScrollTests`, and the Core suite with the new rule.
- Then plain `scripts/test.sh`, in the background.

## Done when

- `grep -rn "poll(since\|connections()" app/Sources/AiTerm/Views` returns nothing.
- `grep -rn "(starts" app/Sources docs/operators.md` returns nothing.
- `grep -rn "\.disposition == \.started" app/Sources/AiTerm` returns nothing (the rule is in Core).
- The new tests pass; snapshots identical; plain `scripts/test.sh` green.

## Not in this step

- The mutual OPERATOR/PROJECTS fold itself, the section-crossing key monitor (left out by the plan).
- Moving the choose logic out of `RowFocus` (3b, done).
- The signal sheet's own preview flow and `DebouncedSearch` (8g).
