# Move task rows within their project

Status: implemented and verified on 2026-11-18.

## Goal

Add Move Up and Move Down to task rows inside projects, following the existing project/divider
commands. A row moves one position inside its parent and its order survives restarting AiTerm.
The user confirmed that tasks and reviews keep their separate groups: tasks stay above reviews.

## Approach

Use the existing persisted task-array order within each project's task or review group. Resolve a
move's neighbour from the current workspace, accepting only a row in the same existing project,
the same group and outside Operator ownership. Swap those two task-array positions, leaving all
other records in their original positions. No schema change or migration is needed. Creation and
restore keep their existing insertion behavior; the current stable tasks-before-reviews projection
continues to apply. Legacy tasks without an explicit review kind belong to the task group.

Restore retains its existing rule: insert before the first saved task with a later creation date,
or append when there is none. Once rows are manually reordered this need not be a chronological
position, and a restored row may land at the top of its group. For example, after moving C ahead
of A and B, restoring D (created between A and B) can produce D, C, A, B. Existing rows retain
their chosen relative order; archive/restore does not remember the archived row's manual position.

Add pure task movement and eligibility operations to AppState and a guarded action to ProjectActions,
which already owns sidebar movement and task renaming. The action goes through WorkspaceStore.mutate
and rechecks current eligibility and the workspace lock. Command invocation checks the target
task's current teardown state. A stale menu therefore cannot move a deleted, removing, archiving
or newly Operator-owned task.

Project task rows carry their movement availability as projected values, derived once per group;
their bodies must not observe the whole workspace to build a menu. Operator-owned tasks are removed
from projects later by SignalSidebar, so eligibility must exclude them before deriving the first and
last movable rows. Signal rows have no movement commands; taking one over gives it the usual project
commands and recalculates that project's edges.

Place a Move Up / Move Down command group before Archive / Remove in TaskRowView's existing shared
RowCommand list. This gives the context menu, VoiceOver and background card the same actions. Keep
both menu items present but disabled at the appropriate group boundaries, and disable both while
the workspace is locked or the row is being removed or archived. A singleton has both disabled.
Reviews get the same behavior within their own group. Terminals retain their existing positions
above tasks. Selection follows the task's existing identity; movement performs no window or Git work.

## Files

Modify:

- `app/Sources/AiTermCore/Models.swift`: add pure task-neighbour, eligibility and movement operations
  alongside the existing top-level movement operations.
- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: carry per-task movement availability and derive
  it from visible project siblings while retaining the stable task/review grouping.
- `app/Sources/AiTerm/ProjectActions.swift`: add the workspace-guarded task movement action.
- `app/Sources/AiTerm/Views/SidebarRows.swift`: add the two commands using projected availability;
  resolve current task identity and teardown eligibility when an action runs.
- `app/Tests/AiTermCoreTests/ModelsTests.swift`: exercise both directions, group edges, singleton,
  missing IDs/projects, legacy tasks, and interleaved projects/reviews/Operator-owned records.
- `app/Tests/AiTermCoreTests/SidebarModelTests.swift`: prove task and review order, edge flags and
  exclusion of Operator-owned rows from project movement eligibility.
- `app/Tests/AiTermTests/AppControllerTests.swift`: prove command-to-owner wiring, persistence and
  reloaded order, selection preservation, locked workspace, stale actions and teardown rejection.
- `app/Tests/AiTermTests/RowAccessibilityTests.swift`: check command groups, enabling and VoiceOver
  parity for tasks/reviews, each edge, singleton, locked/removing rows and Operator-owned rows.
- `app/Tests/AiTermTests/SignalSidebarTests.swift`: verify movement boundaries after ownership
  filtering and after Take Over, without adding movement commands to Signal-owned tasks.
- `docs/design/ui-patterns.md`: document project-local task/review movement and its boundaries.

## Proof

Add behavior tests before the new logic. Use synthetic state and the existing shared builders,
scratch persistence and controller ports. One integration test invokes an actual row command,
checks the projected order and selected identity, flushes the workspace and reloads it from its
scratch StateStore. Include nonadjacent saved-array positions to catch accidental movement of
other projects or hidden Operator tasks. Check that other task records, project IDs, terminals,
project/divider ordering and Signal task ordering remain unchanged.

While iterating, run `scripts/test.sh swift -- --filter` with the affected suites: ModelsTests,
SidebarModelTests, ControllerProjectsTests, RowAccessibilityTests and SignalSidebarTests. Also run the
existing SidebarRowRedrawTests and SidebarInteractionTests to check observation and keyboard
selection behavior. Start each run in the background, following only its own log to completion.

Capture fixtures before and after through `scripts/snapshots.sh` into distinct folders under
`build/`, with no competing build/test run. Inspect sidebar PNGs and compare captures; menus are
not drawn there, so command tests are the evidence for the new items. Existing sidebar appearance
and ordering should be unchanged until a person moves a row. Never replace the running app.

Run plain `scripts/test.sh` for the final affected gate before any implementation commit. A later
merge requires plain `scripts/test.sh all` on the final HEAD, as the repository workflow requires.

## To-dos

- [x] Add pure group-bounded task movement with tests, plus projected movement availability and
      tests that show the resulting project order. Existing menus remain functional.
- [x] Wire task/review RowCommands through the guarded owner, with menu/VoiceOver and scratch
      persistence integration tests, including teardown and stale-menu cases.
- [x] Verify Signal ownership filtering and Take Over boundaries, update the interaction guide,
      inspect before/after snapshots, and finish the affected gate.

## Implementation proof

- Plain `scripts/test.sh` passed: 123 UI tests, 1,135 app tests, 1,400 core tests and one Signal
  snapshot test. Four existing known issues were reported across the app and core targets.
- All 102 PNGs from `build/task-movement-before` and `build/task-movement-after` match byte for
  byte. The sidebar capture was inspected before and after.
- Real row commands were exercised through scratch controllers; saved state was flushed and
  reloaded. Tests cover both groups, another project's interleaved rows, Signal ownership,
  Take Over, locked state, stale commands, teardown state and preserved selection.
- `git diff --check` passed. No live app replacement or merge was performed.

## Plan review

One independent Claude review completed with no blocking findings. Its wording correction
(the target row need not be selected) is incorporated. Its optional simplification is adopted:
check current target teardown in the command closure, without passing teardown state into
ProjectActions. The owner still rechecks workspace and group eligibility. The user approved
implementation after confirming that tasks and reviews keep their separate groups.

## Change review

One independent Claude review found no Critical or Important issues. Both Minor findings are
fixed: the plan and interaction guide now explain archive restoration after manual reordering,
and the plan status states the implemented result without temporary commit-state wording.
Archive insertion behavior is unchanged. There are no open findings.
