# 4c. One teardown owner for archive and remove

Implementer: Opus 5.5, high effort. Depends on: 4b. Audit findings: TL F2, TL F9 (the leaving filter).

## Why

Archive and Remove each exist twice: a version that asks the person (`TaskArchiver.archive`,
`TaskRemover.confirmRemove`) and a version for the Operator's Then that refuses instead
(`archiveAutomatically`, `removeAutomatically`), which redoes the shared preflight by hand with its
own field comparisons. Archive's row state lives in the remover (`recordStop`, `clearOutcome`), the
remover keeps several dictionaries keyed by task, and "a task on its way out is not waiting on you"
is written twice in `AppController` (Dock badge and Focus View). This grew as each piece was added
next to the last: the Operator's variants came from the broadcast finisher, the shared
`WorktreeTeardown` came later and was bolted under the person's versions only. The end state: one
`TaskTeardown` owns archive, remove, removing an archived row and the closing of a task whose
worktree went outside AiTerm, over one prepare and one run. Whether to ask or refuse is a value,
`Consent`. One per-row state (archiving, removing, closing, stopped with a note) is read by the row,
the sidebar projection (which feeds the Dock badge and Focus View) and the checkout monitor. The
blocked reasons the Operator's Then surfaces keep their wording. Nothing a person sees changes.

## Today (after 4b)

Phase 2 (2c) removed the remover's second disk confirmation; 4a made every operation return when
done and removed `running` and `waitForRemoval`; 4b removed the retry state.

- `app/Sources/AiTerm/TaskRemover.swift` (`TaskRemover: CheckoutRemovals`):
  - State: `removals` (whole, for readers that read it whole), `outcomes` (what the last removal or
    archive left: `.stopped(note:)`, or `.closing` after a failed cleanup close), `rows`
    (`PerRow<TaskRemoval?>`, what a row reads), `recordCleanups` (git-record clearing tasks, to
    de-duplicate). `refresh(_:)` derives `work.operation(onTask:)?.removal ?? outcomes[id]` into
    `removals` and `rows` and calls `removalsHooks`.
  - Person: `confirmRemove(task:)` (4b's questions, then `removeWorktree`, `finishRemoval`, `forget`).
  - Operator: `removeAutomatically(_:starting:stillAllowed:)`, `requireIdleForAutomaticCleanup`,
    `turnInFlight`, `hasWorktreeFolder`.
  - Cleanup: `forgetRemovedCheckouts(_:)`, `awaitsCleanup(_:)`, `automaticallyForgetRemovedTask(_:)`.
  - Readers: `removal(of:)`, `isRemoving(_:)`, `leavingTasks`, `removalInFlight(_:)`,
    `onRemovalsChanged`, `pruneRemovals`, `clearStoppedNote(of:)`, `recordStop`, `clearOutcome`,
    DEBUG `seedSnapshotRemoval`. Statics `offersBranchDeletion`, `deleteUnmergedBranchQuestion`,
    `unlistedFolderQuestion`.
- `app/Sources/AiTerm/TaskArchiver.swift`: `archive(task:)` (person; uses `remover.recordStop` and
  `clearOutcome`), `archiveAutomatically(_:starting:)` (Operator), `restore(_:)` (stays here until
  4d), `confirmRemove(archived:)` (4b's branch question).
- `app/Sources/AiTerm/WorktreeTeardown.swift`: `Verb`, `Prepared`, `prepare` (one
  `TaskWorkflow.preflight`, the unlisted-folder question, the unsaved-work question; after the
  question, Remove goes on with the row as it is then and Archive with the row it had),
  `run` (git, asking again on git's unsaved-work refusal), `confirmDeletingUnsavedWork`,
  `closeWindow(of:holding:requiringDaemon:operation:)`, `TeardownStop`.
- `app/Sources/AiTerm/AutomaticCleanup.swift`: `unsavedWork` sentence and `isDriving`. Only the
  remover and archiver use it (`grep -rn AutomaticCleanup app/Sources`).
- `app/Sources/AiTerm/AppController.swift`: builds `WorktreeTeardown`, `TaskRemover`, `TaskArchiver`;
  `RowFocus(isRemoving:)`; `signalController.archive`/`remove` closures call the automatic
  variants; `remover.onRemovalsChanged { updateDockBadge() }`; `workspace.onChange { remover.pruneRemovals() }`;
  `updateDockBadge()` and `showFocusView()` each filter `rows.projectsNeedingAttention` by
  `remover.leavingTasks`; `choose(task:)` reads `remover.removal(of:)?.inProgress`;
  `removeSelection()` calls `remover.confirmRemove`; `removeFromArchive` calls
  `archiver.confirmRemove(archived:)`.
- `app/Sources/AiTerm/SidebarProjection.swift`: `projectsNeedingAttention`,
  `operatorNeedingAttention`, `projectSectionsNeedingAttention` and the heading counts know nothing
  of leaving tasks.
- `app/Sources/AiTerm/CheckoutMonitor.swift`: `CheckoutRemovals` (`removalInFlight`,
  `forgetRemovedCheckouts`); the remover sets itself as `checkouts.removals`.
- `app/Sources/AiTerm/Views/SidebarRows.swift`: `TaskRowView` reads `controller.remover.removal(of:)`
  and calls `controller.archiver.archive(task:)` and `controller.remover.confirmRemove(task:)`.
- `app/Sources/AiTerm/Operators/ThenRunner.swift`: `Ports.archive`/`remove` take the task and
  `allowed`, and treat `ClosingWait` as "try again later".
- Snapshots: `SidebarSnapshots.swift` seeds removals through `seedSnapshotRemoval`.
- Tests: `ArchiveTests`, `CheckoutCleanupTests`, `ControllerRaceTests`, `SignalAutomaticCleanupTests`,
  `OperationIssueTests`, `SidebarProjectionTests.aRemovedTaskLeavesTheBadgeOnce`,
  `CheckoutMonitorTests` (its own fake `CheckoutRemovals`), `RestoringRowTests`, `ItermFocusTests`,
  `SidebarRowRedrawTests` (seeding), `WorkBudgetTests`. List with
  `grep -rln "remover\|archiver\.archive\|archiveAutomatically\|removeAutomatically\|seedSnapshotRemoval" app/Tests`.

## Change

1. Create `app/Sources/AiTerm/TaskTeardown.swift`, `@MainActor final class TaskTeardown: CheckoutRemovals`.
   It takes the workspace, `WorkInFlight`, `TaskWorkflow`, `Notices`, the prompter, the checkout
   monitor, `LiveSessions`, the daemon getter and the clock, sets itself as `checkouts.removals`, and
   adds the same `work.onChange` and `notices.onWithdrawn` hooks the remover adds today.
2. `TaskTeardown.Consent`: `.ask` (questions go to the prompter the teardown holds; failures are said
   to the person on the row and in the banner, and the operation does not throw) or
   `.refuse(stillAllowed:)` (no question is ever asked; anything that would ask, and any failed
   check, throws to the caller; nothing is said to the person, no row note is left).
3. Operations, each `async throws`, each returning when done:
   - `archive(_ task:, consent:)`: the person's archive under `.ask`, Then's under `.refuse`.
   - `remove(_ task:, consent:)`: under `.ask` it starts with 4b's Remove alert, whose box decides
     the branch; under `.refuse` the branch is left alone (`preserveBranch` when the task has a
     signal record, `deleteBranch: false`), and Then deletes a merged branch itself as today.
   - `removeArchived(_ id:)`: always asks (4b's flow, moved as is).
   - `forgetRemovedCheckouts(_:)` and `removalInFlight(_:)` (`CheckoutRemovals`): the closing.
4. One prepare and one run, private to `TaskTeardown`, replacing `WorktreeTeardown`: the preflight,
   the unlisted-folder and unsaved-work decisions taken through the consent, the window closed and
   confirmed before git deletes anything (`closeWindow`, unchanged, with `requiringDaemon: true` for
   both verbs since 4b), git's run with its re-ask. Drop the Remove/Archive fork: after a question
   both go on with the row as it is now, provided it is still in the same project and folder (else
   stop, as the unlisted-folder answer already does). `TeardownStop` and `Verb` become private.
5. Under `.refuse`, the checks run in this order and throw these exact sentences (each kept from
   today unless marked new):
   1. Entry: workspace changeable, the row as it is now equals the task handed in, its project
      exists, the work token begins. Archive: "The task changed or is busy." Remove: "The task
      changed or is busy. Remove it yourself once it is safe."
   2. No turn under way: `ClosingWait.turn` (the person is driving a worker tab), `.agentTurn`
      (an agent is mid-turn).
   3. The preflight. Folder git no longer lists: Archive "Git no longer lists its folder. Archive it
      yourself once it is safe."; Remove "Git no longer lists its folder. Remove it yourself once it
      is safe." (new; today Remove said "Its worktree is no longer on its task branch." here). Head:
      Archive, detached "Its worktree is detached, so it was kept.", another branch "Its worktree is
      no longer on its task branch."; Remove, detached or another branch "Its worktree is no longer on
      its task branch.". A missing folder passes.
   4. Unsaved work: `AutomaticCleanup.unsavedWork`'s sentence (both).
   5. Before closing the window. Archive: still allowed and project, folder and branch unchanged,
      else "The stage changed while its worktree was checked.". Remove: the row unchanged (project,
      folder, branch, base, window, kind, the record's stage and ownership), else "The task changed
      while its worktree was checked."; still allowed, else "Its finished record couldn’t be saved,
      so nothing was removed."; a worker tab outside the task window, "One of its tabs is outside its
      task window. Close it yourself, then retry Remove.". Then step 2 again.
   6. Close the window, helper required: no helper, `ClosingWait.helper`; a window that will not
      close, the `ActionUnavailable` sentence `closeWindow` builds ("Its iTerm2 window did not close,
      so nothing was deleted. …"). Today the automatic paths let the internal `TeardownStop` through,
      which `OperationIssue.reason(of:)` cannot word; throw its `ActionUnavailable` instead.
   7. Archive only, after the close: still allowed and unchanged, else "The stage changed while its
      window closed."; the head read again, missing or its own branch and still allowed, else "Its
      stage or branch changed while its window closed."; step 2 again. Remove reads nothing here (as
      today, and as `WorkBudgetTests` counts).
   8. Archive: the row into the archive and saved before git; a failed save moves it back and throws
      "Its archived row couldn’t be saved, so its checkout was kept." (under `.ask` the existing
      "Its place on the archive couldn’t be saved, so nothing was deleted.").
   9. Git, never forced: git's unsaved-work refusal throws `AutomaticCleanup.unsavedWork`'s sentence
      for both verbs (Archive gains this mapping; today it threw git's raw error). Archive's git
      failure moves the row back from the archive, saves, rethrows.
   10. Remove only: not still allowed after git, the checkout is restored and it throws "A new stage
       waits, so its checkout was restored and the task was kept.".
   11. Remove: the row goes, the toast "Task removed." shows (as today for both consents); if the row
       is still there or the save failed, "Its removal could not be completed or saved.". Archive:
       checkout bookkeeping as today and no toast under `.refuse`.
6. The closing (a worktree deleted outside AiTerm), inside `forgetRemovedCheckouts`: for each task
   the pass found gone that is unchanged, has no work on it and no turn in flight, begin `.closing`
   (this one token is the de-duplication; `recordCleanups` goes), clear git's record
   (`TaskWorkflow.forgetDeletedCheckout`), close the window if the row has one (a failed close leaves
   the state `.closing`, drops the diff, and the next pass retries), then forget the row with its toast
   "<Kind> closed because its worktree was removed.". A task left `.closing` whose checkout came back
   is cleared, as today.
7. One per-row state. Store only what the last teardown left (`.stopped(note:)` under `.ask`, or
   `.closing` after a failed cleanup close) in one dictionary; the state of a row is the running
   work's `TaskOperation.removal`, else what was left. Mirror it into one `PerRow<TaskRemoval?>`.
   Readers: `state(of:)` (the row, through `PerRow`), `isLeaving(_:)` and `leaving` (rows whose state
   is in progress), `onChanged(_:)` hook, `removalInFlight(_:)` (the checkout monitor holds a diff
   while the row's state is in progress). Keep `pruneStates()` (workspace change),
   `clearStoppedNote(of:)` (banner withdrawn) and DEBUG `seedSnapshotState(_:of:)`. Keep the name
   `TaskRemoval` for the state type.
8. Questions: move `offersBranchDeletion`, `unlistedFolderQuestion`, `deleteUnmergedBranchQuestion`
   and the unsaved-work question into `app/Sources/AiTerm/Prompter.swift` as `AlertPrompt` statics
   beside `removeTask`, wording unchanged. Fold `AutomaticCleanup` into `TaskTeardown` and delete its
   file.
9. `SidebarProjection`: take the leaving set as an input, as it takes `operatorIssue` (a closure set
   by `AppController`, part of `Inputs`). `projectsNeedingAttention`, `operatorNeedingAttention`,
   `projectSectionsNeedingAttention` and the heading attention counts leave out leaving tasks;
   `refresh()` reports a change when the leaving set moved.
10. `AppController`: build `TaskTeardown` where the remover was built; property `teardown` replaces
    `remover`. `RowFocus(isRemoving:)` reads `teardown.isLeaving`. `teardown.onChanged { refreshRows() }`
    replaces the badge hook; `updateDockBadge()` counts `rows.projectsNeedingAttention` and
    `showFocusView()` takes its first, with no filter of their own. `choose(task:)` reads
    `teardown.isLeaving`. `signalController.archive` and `remove` call `teardown.archive`/`remove`
    with `.refuse(stillAllowed:)`. `removeSelection`, `removeFromArchive` and the row's menu and
    VoiceOver actions call the teardown with `.ask`. The pruning hook calls `teardown.pruneStates()`.
11. `TaskArchiver` keeps only `restore(_:)` and loses its `remover`, `teardown` and `now` inputs.
    Delete `TaskRemover.swift` and `WorktreeTeardown.swift`.
12. `docs/architecture.md`: the sentence naming `TaskRemover`, `TaskArchiver` and `WorktreeTeardown`
    (about line 78) and the table row "`ThenRunner`, `TaskArchiver`, `TaskRemover`" name
    `TaskTeardown`; `docs/windows.md` and `docs/status-model.md` follow the same grep
    (`grep -n "TaskRemover\|WorktreeTeardown\|TaskArchiver.archive" docs/*.md`).

## Keep

- Archive saves the row into the archive before git removes the worktree, with its rollback: a crash
  must never leave a task whose checkout the cleanup would forget.
- `TaskWorkflow.RemovalAttempts`: git may finish a half-done removal without asking.
- The re-ask about unsaved work after the window closed, the unlisted-folder question, Archive's
  detached refusal and its re-read of the head after the close: all real (agents write, rebase and
  bisect while windows close).
- `closeWindow`'s order: the row drops its window first and the work token says the window is let go
  (`TaskOperation.removing(windowLetGo:)`, `.archiving(windowLetGo:)`), so the closing window is not
  adopted back. If `grep -rn "letsWindowGo" app/Sources` shows no reader after phase 3, leave the
  flag and say so in your report.
- `ClosingWait` as the "try again later" signal to `ThenRunner`; its home moves in 5h.
- `CheckoutRemovals` as the one two-way pair between the monitor and the teardown.
- `ThenRunner.Ports` shape and its `allowed` closure.
- `restore(_:)` stays in `TaskArchiver` until 4d.

## Decisions already taken

- `Consent.ask` holds no prompter: the teardown already has one, and tests answer through
  `ScriptedPrompter` as before.
- Under `.ask`, failures keep today's row notes ("Not archived…", "Not removed…") and banners; under
  `.refuse`, none. Today's automatic paths also leave none.
- "Its finished record couldn’t be saved, so nothing was removed." is kept because the Operator's
  blocked reasons keep their wording; its meaning today is "Then is no longer allowed".
- The projection's heading counts now leave out a leaving task too. A task being removed was never
  waiting on the person; this is the one rule, applied once.
- The cleanup's git-record clearing now runs inside the closing instead of beside it. Its result is
  best effort as today and does not stop the row going.
- A second operation on a busy row returns at once under `.ask` and throws step 1's sentence under
  `.refuse`, as today.

## Tests

- Rename throughout: `controller.remover` and the archive half of `controller.archiver` become
  `controller.teardown`; `removals[id]` becomes `teardown.state(of: id)`; `removals.isEmpty` becomes
  `teardown.leaving.isEmpty` plus `state(of:) == nil` where the test meant "no note";
  `seedSnapshotRemoval` becomes `seedSnapshotState`.
- `SignalAutomaticCleanupTests`: call `teardown.archive`/`remove` with `.refuse(stillAllowed:)`; the
  four tests keep their assertions. Add: a folder git no longer lists is refused with Archive's and
  with Remove's sentence and nothing is asked; a window that will not close throws the window
  sentence; unsaved work written while the window closes is refused with the unsaved-work sentence
  and the row is back from the archive.
- `SidebarProjectionTests.aRemovedTaskLeavesTheBadgeOnce` stays the survivor for the leaving filter;
  add a projection test that a leaving task is not in `projectsNeedingAttention` nor in a folded
  heading's count.
- `CheckoutMonitorTests`' fake `CheckoutRemovals` is unchanged.
- No test is deleted.

## Proof

- `scripts/test.sh swift -- --filter ArchiveControllerTests`, then `CheckoutCleanupControllerTests`,
  `AppControllerRaceTests`, `SignalAutomaticCleanupTests`, `OperationIssueControllerTests`,
  `SidebarProjectionTests`, `CheckoutMonitorTests`, `WorkBudgetTests`, `SidebarRowRedrawTests`,
  `SignalJourneyTests` (the Then archive journey from 0b).
- `scripts/snapshots.sh build/4c`: every PNG equal to 4b's.
- Plain `scripts/test.sh`.

## Done when

- `grep -rn "TaskRemover\|WorktreeTeardown\|archiveAutomatically\|removeAutomatically\|recordStop\|clearOutcome\|leavingTasks\|AutomaticCleanup\b\|recordCleanups" app`
  returns nothing (rename `SignalAutomaticCleanupTests` only if you want; the grep's `\b` leaves it).
- `grep -rn "leaving" app/Sources/AiTerm/AppController.swift` finds no filter in `updateDockBadge` or
  `showFocusView`.
- The suites above, unchanged snapshots and plain `scripts/test.sh` are green; the docs lines name
  `TaskTeardown`.

## Not in this step

- Restore leaving `TaskArchiver`, one worker checkout, one window opener: 4d.
- Take Over: 4e.
- `ClosingWait`'s new home and the regrouping of `Signals/`: 5h.
- The Core "this task is under the Operator" rule: 8a.
