# Status counts on a folded Operator or Projects heading

## Goal

A folded project header draws `StatusCountChips` — idle, working, waiting, needs input, done — so a glance says
what is busy and what waits. A folded OPERATOR or PROJECTS heading draws only one amber count of the rows that need
you. Give the folded section heading the same chip strip a folded project has, summed over every row in the section,
and let each chip open the section at its first row in that status.

Picked on the design page's Proposals tab (18 Nov 2026): **1A** every status, as a folded project; **2A** every chip
opens its section at its first row in that status.

## Approach

`SectionFold` replaces `attention: Int` with `counts: [StatusCount]`. `SidebarProjection.refresh()` derives them from
one list of the folded section's rows in drawn order, each with its status:

- OPERATOR: its own row (when `signalOperator.shown`), then each signal section's tasks, removed signals included.
- PROJECTS: each project's terminals, then its tasks — the order `SidebarView.rows(of:)` draws them and
  `projectSectionsNeedingAttention` already walks.
- A task on its way out (`leaving()`) is not counted; a row in the background counts as working. The counts go
  through `SidebarModel.statusCounts`, whose `[TaskStatus]` overload is made public (folding background into
  working there, as the row overload does today), so the Operator's own row can be counted with the tasks and order
  and empty-status rules match a project header. An open section's counts are
  empty, so its heading draws nothing and does not redraw for statuses it does not show.

The same row list drives the jump: `openOperatorAttention` and `openProjectsAttention` become one
`openSection(_:at status:)` that picks the first row whose status (background folded into working) matches and goes
through `reveal` + `focus.peek(…, force: true)`. `reveal` already opens the section and unfolds a task's signal or
project, but not a terminal's project, and `peek` unfolds nothing: `reveal` learns to unfold the project of a
`.terminal` row too, or a terminal first in its status would be selected while hidden. (Today's amber jump has the
same gap for a terminal that needs you.)

`StatusCountChips` takes an optional per-status action. With it, each chip is its own plain button, labelled for
VoiceOver and help as that chip alone ("2 working"); without it, the strip stays one ignored-children label, so folded
project and signal headers are unchanged. `SectionFoldLabel` passes the action; the heading's own click still folds
the sections over.

`operatorNeedingAttention` and `projectSectionsNeedingAttention` stay: the Dock badge, Focus View and
`projectsNeedingAttention` read them. The visible behaviour change beyond the strip: a finished task of your own,
which counted in today's amber, now counts in the blue done chip.

No new token: every chip is the existing `StatusCountChip`.

## Files

- **Modify** `app/Sources/AiTerm/SidebarProjection.swift` — `SectionFold.counts`; a per-section row list
  (`(RowID, TaskStatus)` in drawn order, leaving tasks out); counts derived in `refresh()`; a lookup of the first row
  in a status for a section.
- **Modify** `app/Sources/AiTermCore/Sidebar/SidebarModel.swift` — make the `[TaskStatus]` `statusCounts` overload
  public and fold background into working in it.
- **Modify** `app/Sources/AiTerm/AppController+Operators.swift` — `openSection(_:at:)` replaces the two attention
  jumps; `reveal` unfolds a terminal's collapsed project.
- **Modify** `app/Sources/AiTerm/Views/SidebarHeadings.swift` — `SectionFoldLabel` draws `fold.counts` with one
  action per chip; `SectionHeading` wires it to `openSection`; doc comments updated.
- **Modify** `app/Sources/AiTerm/Views/StatusCountChips.swift` — optional per-chip action and per-chip accessibility.
- **Modify** `app/Sources/AiTerm/Snapshots/SignalSidebarSnapshots.swift` — a `projects-folded` pose (Operator open,
  projects folded with rows in several statuses) beside `section-folded`; the comment on `section-folded` no longer
  says "amber count".
- **Modify** `app/Sources/AiTermUI/README.md` — the `SectionFoldLabel` inventory line.
- **Modify** `docs/operators.md` — the paragraph saying a folded section shows an amber count.
- **Modify** `docs/design/design-system.html` — delete the proposal section, restore "No open proposals.", update the
  `SectionFoldLabel` Components row; republish per the `design-system` skill.

## Proof

- Update the tests that read `attention`: `SidebarProjectionTests.aLeavingTaskIsNotWaitingOnYouNorCountedUnderAFoldedHeading`
  (the leaving task drops out of `counts`), `SignalSidebarTests.aRowNeedingYouInTheFoldedSectionIsCountedAndRevealed`
  (counts, then `openSection(.operator, at: .needsInput)` selects `.operatorChat`), `SignalSidebarTests` around line
  349 and `AppControllerTests` around line 1358 (`SectionFold` equality).
- Add: a folded section counts every status, across folded and open children, with background counted as working.
- Add: a working chip opens the folded section, unfolds the folded signal holding the first working row, and selects it.
- Add: with PROJECTS folded and the first row in a status a terminal of a collapsed project, its chip opens the
  projects, unfolds that project and selects the terminal.
- Add (`SidebarModelTests` or the existing status-count tests): the `[TaskStatus]` overload counts background as
  working.
- Add: with an action, each chip is a separate accessibility button labelled with its own count; without one, the
  strip stays a single element (`RowAccessibilityTests`).
- Keep green unchanged: `SidebarRowRedrawTests.theSectionHeadingsDoNotRedrawForAStatusTheyDoNotDraw`.
- Visual: `AITERM_SNAPSHOT_HOSTED=1 scripts/snapshots.sh build/<folder>` (the signal sidebar poses are hosted-only), read the `section-folded` and `projects-folded` PNGs against
  `app/Sources/AiTermUI/README.md`.
- Gate: `scripts/test.sh` before each commit; `scripts/test.sh all` once before merging.

## To-dos

- [ ] Counts in the projection: the public `[TaskStatus]` `statusCounts`, `SectionFold.counts`, the per-section row list, tests updated and added; the heading
      draws the amber chip from `counts` until the next step.
- [ ] Chips with actions: `StatusCountChips` action, `openSection(_:at:)`, `reveal` unfolding a terminal's project, `SectionFoldLabel` draws the full strip;
      jump and accessibility tests.
- [ ] Snapshot pose `projects-folded`; read both poses.
- [ ] Docs: README inventory, `docs/operators.md`, design page synced and republished, proposal removed.
