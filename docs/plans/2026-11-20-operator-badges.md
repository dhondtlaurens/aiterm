# The folded Operator heading says how the Operator is doing; finished and paused marks become discs

## Goal

Before this change, the folded OPERATOR heading drew `StatusCountChips` over every row under it, the Operator's own row
and each signal task, one chip per status. `○ 1 ◌ 1` read as bookkeeping; a finished task (its row's bare green check,
status idle) was counted with the Operator's idle row; and when the last task finished the Operator row closed and its
chip went with it.

The folded heading should say how the Operator is doing, in one chip, and show the tasks that are really finished (the
signal's done trigger fired) apart from everything else, in green. The two marks that are not rings, finished and
paused, become filled discs.

Picked on the design page's Proposals tab (`#p-operator-badges`, 20 Nov 2026): **1A** one Operator chip, its most
urgent state, counting its unfinished tasks; **2B** a green finished chip on a green wash; **3A** the Operator row lives
as long as its work, unchanged; **4A** ring means live, disc means settled.

## Approach

**The Operator chip.** One chip on the folded OPERATOR heading. Its mark is the most urgent state among the Operator row
and the workload tasks' rows, in this order:

1. needs you (amber `StatusMark(.needsInput)`): the Operator row's own needs-you, or any task row that needs you;
2. paused (the pause disc): the Operator is paused and holds unfinished work;
3. working (the spinner): the Operator row acting, or any task working or in the background;
4. waiting (the dashed ring): any task waiting (its merge request, its done trigger, its worker's turn to read);
5. idle (the idle ring).

Its number is the workload count, `state.operatorWorkTasks.count`, the same count as the row's title. With no
workload but a global question (or an app issue) the chip draws the amber mark without a number. With no workload and
nothing needing you or working there is no Operator chip. A click opens the section at the row the mark comes from: the Operator
row for its own state, else the first task row in that state.

**What finished means.** A signal task is finished when its phase is `done` or `archived` and it no longer keeps the
Operator's session (`keepsOperatorSession == false`: no pending stage, its Then step applied): that state, not the
row's mark, says a task is finished. A folded heading counts it in the green chip while its row draws the finished mark
(below). A done task whose closeout is still outstanding is workload: it counts in the Operator chip,
not here. Found in the plan's review: `presentLine` checked pause before phase, so a finished task under a paused
Operator or a switched-off signal was drawn "paused" with the pause sign. A finished task is past pausing, so `presentLine` draws it
"done" with the finished mark whatever the pause; a done task with closeout outstanding still shows paused, since its
closeout is what the pause holds.

**A finished task you continue.** Found in the change's review: Then Keep leaves a finished task's worker open, and
you can continue it; while it asks or works its row draws that state. A folded heading counts a finished task in the
green chip only while its row draws the finished mark (`TaskRow.countsAsFinished`); otherwise by its status, and a
prompt in it turns the Operator chip amber (needs you is read over every row under OPERATOR, not only the workload), a
running worker in it the spinner; without workload the chip then draws the mark alone (second round of that review).

**The finished chip.** A second chip counts the finished signal tasks still listed under their signals,
on a green wash with `Palette.green` ink: two new tokens, `statusChipFinishedFill = green.opacity(0.17)` and
`statusChipFinishedStroke = green.opacity(0.42)`, the done chip's proportions. Its mark is the finished disc. A click
opens the section at the first finished row. It is drawn whether or not the Operator row is shown, so "all finished,
the Operator gone" still says so on the folded heading.

**The discs.** A new AiTermUI primitive, `SettledMark`, draws the two settled marks as shapes, not SF Symbols:

- **finished:** a `Palette.green` disc with the white check in `CheckGlyph`'s proportions. This is `Badge`'s
  `CornerCheck` mark, moved into `SettledMark` so the badge corner and the rows draw one shape (the corner keeps its
  ring of the occluding ground and its `Size.cornerBadge` size).
- **paused:** a `Palette.idleRing` disc with the two pause bars knocked out in the surface's occluding ground.

On the accent surface both draw in `onAccent`, as the symbols do today. `TaskRowMarkView` draws `.ended` and
`.pauseSign` through it at `Size.trailingGlyph`, so every row changes at once: finished signal tasks, paused tasks and
the paused Operator row. The chips draw the same marks at `Size.statusMarkSmall`. `StatusMark`'s rings do not change.

**Folded signal headings.** A folded signal's `HeadingValue` counts its finished rows in the green finished chip instead
of as idle; its other rows keep their per-status chips. Confirmed while planning, so the two folded headings agree.

**Unchanged:** the PROJECTS heading and folded project headings, the open OPERATOR heading (no chips), the Operator
row's lifetime and title, `TaskRowMark`'s rule for choosing a mark (only the line `presentLine` hands it changes for a
finished task under a pause), and the blue done ring (a chat ended its turn).

**VoiceOver:** the Operator chip reads "3 tasks, working" (or "needs you", "paused", "waiting", "idle"; "needs you"
alone without tasks), the finished chip "1 finished" / "2 finished"; each stays its own button.

## Files

- **create** `app/Sources/AiTermUI/SettledMark.swift`: the finished and paused discs, with `CheckGlyph` moved here
  from `Badge.swift`.
- **modify** `app/Sources/AiTermUI/Badge.swift`: `CornerCheck` draws `SettledMark`'s finished disc inside its ground
  ring.
- **modify** `app/Sources/AiTermUI/Palette.swift`: `statusChipFinishedFill`, `statusChipFinishedStroke`.
- **modify** `app/Sources/AiTermUI/README.md`: `SettledMark` in the inventory; the chip tokens; ring vs disc rule.
- **create** `app/Tests/AiTermUITests/SettledMarkTests.swift`: both kinds render, on a plain and an accent surface.
- **modify** `app/Tests/AiTermUITests/PaletteDistinctionTests.swift`: the two new tokens in its manifest.
- **modify** `app/Sources/AiTerm/Views/SidebarRows.swift`: `TaskRowMarkView` draws `SettledMark` for `.ended` and
  `.pauseSign`.
- **modify** `app/Sources/AiTerm/SidebarProjection.swift`: `SectionFold` carries the Operator heading's summary (the
  Operator chip's mark and optional count, the finished count) for the Operator section, the per-status counts for
  PROJECTS; `firstRow` finds the row each Operator chip opens.
- **modify** `app/Sources/AiTerm/Views/StatusCountChips.swift`: draw a chip from a `TaskRowMark` and a count, and the
  finished chip's green wash and ink; labels.
- **modify** `app/Sources/AiTerm/Views/SidebarHeadings.swift`: `SectionFoldLabel` draws the Operator summary when
  folded; `HeadingRow` draws a signal heading's finished chip.
- **modify** `app/Sources/AiTerm/HeadingValue.swift`: a signal heading's finished count.
- **modify** `app/Sources/AiTermCore/Sidebar/OperatorLine+Task.swift`: a finished task is drawn done, not paused.
- **modify** `app/Sources/AiTerm/Snapshots/SignalSidebarSnapshots.swift`: three new poses, `finished-folded` (OPERATOR
  folded over a mixed workload: one working task, one finished), `all-finished-folded` (OPERATOR folded, only finished
  tasks, no Operator row) and `finished-signal-folded` (the section open, a signal folded over a waiting and a finished
  task); and the paused poses with a finished task beside the paused one.
- **modify** `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: the counting helpers and labels (finished rows
  apart from idle; the Operator chip's ranking if it lives in Core).
- **modify** `app/Sources/AiTerm/AppController+Operators.swift`: chip clicks open the right row.
- **modify** tests: `app/Tests/AiTermTests/SignalSidebarTests.swift` (the folded-count expectations near lines 374
  and 403), `AppControllerTests.swift` (near line 1358), `StatusCountChipsAccessibilityTests.swift`,
  `SidebarProjectionTests.swift` if the Operator fold changes shape there; new cases listed under Proof.
- **modify** `docs/operators.md` and `docs/design/ui-patterns.md`: the folded heading's chips and the settled marks.
- **modify** `docs/design/design-system.html`: delete `#p-operator-badges` and its scoped `.pob` styles (restore the
  `no-proposals` line), add the two tokens to the status-chip swatches, add `SettledMark` to Components and the ring vs
  disc rule to `#c-operator`, replace the native references with fresh captures, publish through the `design-system`
  skill.

## Proof

- Test first, failing before the change:
  - the Operator chip's mark and count: acting, a question on the Operator, a worker needing you, paused with work,
    waiting only, idle, a global question with no workload, no workload and nothing to say (no chip);
  - the finished count, with and without the Operator row shown; a done task with closeout outstanding counts in the
    Operator chip, not the finished one;
  - a finished task under a paused Operator and under a switched-off signal stays "done" with the finished mark and
    stays counted; a done task with closeout outstanding under a pause still shows paused;
  - a finished task you continue, its worker asking, then working: the Operator chip turns amber, then the spinner,
    and both headings count it by that status, not finished;
  - where each chip opens;
  - a folded signal heading's finished count beside its other chips;
  - `TaskRowMark` is unchanged; `TaskRowMarkView` and `SettledMark` draw the discs (UI test);
  - the chips' VoiceOver labels.

  Through `scripts/test.sh swift -- --filter <Suite>` while iterating.
- Before each commit: plain `scripts/test.sh`, in the background. Once before merging: `scripts/test.sh all`.
- Visual: `AITERM_SNAPSHOT_HOSTED=1 scripts/snapshots.sh <dir>` before and after; compare `signals-section-folded`,
  `-paused`, `-idle-paused`, `-done`, `-folded`, `-waiting-folded` and `-acting`, and the new
  `signals-finished-folded.png`, `signals-all-finished-folded.png` and `signals-finished-signal-folded.png` (after only): the folded heading shows the one
  Operator chip and the green finished chip, finished and paused rows show the discs, nothing else moved. A folded
  project heading (`sidebar` captures) is unchanged. The design page's references come from the after set.

## To-dos

- [x] `SettledMark` (finished and paused discs), `Badge`'s corner check through it, `TaskRowMarkView` drawing it;
      UI test; filtered suites green.
- [x] A finished task is drawn done, not paused, under a pause; tests first.
- [x] The folded OPERATOR heading's Operator chip and green finished chip, with tokens, labels and clicks; tests first.
- [x] A folded signal heading's finished chip; tests first.
- [x] The three new snapshot poses; snapshots before and after compared; `docs/operators.md`, `docs/design/ui-patterns.md` and `AiTermUI/README.md`
      updated; design page synced (proposal removed) and published; plain `scripts/test.sh` green.

## Completed proof

- Plain `scripts/test.sh` green (20 Nov 2026, after the change's review fixes): AiTermCoreTests, AiTermTests and
  AiTermUITests picked; 129, 1,197 and 1,450 tests passed, the known issues the suites already carry and nothing new; the Signal snapshot pass too.
- New tests: `SettledMarkTests` (both discs, their grounds and the accent), `aFinishedTaskStaysDoneUnderAPauseAndOnlyItCountsAsFinished`,
  `aFoldedOperatorDrawsItsMostUrgentStateAndItsChipOpensThatRow` (rewritten), `theOperatorChipIsPausedWaitingOrAQuestionAlone`,
  `finishedTasksHaveTheirOwnChipOnBothFoldedHeadings`, `theOperatorChipAndTheFinishedChipAreButtonsOfTheirOwn`,
  `aFinishedTaskYouContinueIsCountedByWhatItsRowDraws` (from the change's review).
- The change's review, three rounds with Codex: round 1, a continued finished task's prompt hidden in the green chip
  (Important, fixed) and stale plan wording (Minor, fixed); round 2, its running worker leaving the heading blank
  (Important, fixed) and a contradictory counting rule in the plan (Minor, fixed); round 3, the plan's test inventory
  (Minor, fixed). Nothing open.
- Hosted snapshots in `build/operator-badges-after/`, read one by one. The before set is the design page's native
  references from 16 and 19 Nov, not a second build of the base: `signals-finished-folded` shows the working chip and
  the green finished chip, `-section-folded` the amber chip with one task, `-paused` the pause discs beside the finished
  check, `-finished-signal-folded` a folded signal's waiting and finished chips, `-all-finished-folded` the green chip
  alone with no Operator row; the PROJECTS heading's chips are unchanged.
- Design page synced (proposal removed, two tokens, `SettledMark`, eight fresh captures) and published.
