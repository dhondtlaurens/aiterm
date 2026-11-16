# 4b. Remove asks everything before it acts

Implementer: Opus 5.5, high effort. Depends on: 4a. Audit finding: TL F1.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The design note says the branch is deleted "forced only when the person said Delete". Today a branch
whose commits are all on its base is deleted with `git branch -D` without asking, because `-d` judges
"merged" against the project folder's HEAD, which usually sits on another task's branch, and refuses
branches whose work is safe in `main` (comment on `TaskWorkflow.releaseBranch`, and
`TaskWorkflowTests.removalDeletesABranchMergedIntoItsBaseWhileAnotherBranchIsCheckedOut`). Deleting
such a branch with `-d` only would make git refuse it and the toast say "kept" for an ordinary,
merged branch. This brief keeps today's rule for a branch with nothing to lose (merged into its base:
`-D`; otherwise `-d`) and adds `-D` only when the person answered Delete Branch.

## Why

Remove with "Delete local branch" ticked, on a branch with commits its base lacks, deletes the
worktree, then parks the row as "Not removed: branch kept" with a banner offering Keep Branch and
Delete Branch…, and Delete asks a further alert. That is four interactions and a row left without a
worktree, waiting on a banner. Remove without AiTerm's helper deletes the worktree under a live
window and then tells the person to close the window by hand. Removing an archived row, by contrast,
already asks the branch question inline and the row goes either way. The end state: Remove asks every
question first (Remove alert, the unlisted-folder question when it applies, unsaved work, then the
unmerged branch), then acts once: closes the window, removes the worktree, deletes or keeps the
branch, and the row goes. A row with a window and no helper is refused before anything is deleted, as
Archive refuses it. The retry state, its banner actions and every guard on them go. Removing an
archived row uses the same branch check and question. This is a listed visible change.

## Today (after 4a)

- `app/Sources/AiTerm/TaskRemover.swift`:
  - `confirmRemove(task:) async`: the Remove alert, then begins `.removing` and runs the private
    `remove(_:from:deleteBranch:holding:before:) async`, which calls `removeWorktree` (the shared
    `WorktreeTeardown.prepare`, then `closeWindow(... requiringDaemon: false ...)`, then
    `WorktreeTeardown.run` around `TaskWorkflow.remove`) and then `finishRemoval(of:after:)`.
  - `finishRemoval`: a `branchRefusal` leaves the row with `.stopped(note: "Not removed: branch kept",
    worktreeRemoved: true)` and reports `OperationIssue.branchKept`; a row still holding a window
    with no daemon, or a window that would not close, leaves `.stopped(..., worktreeRemoved: true)`
    with "Worktree removed; …" banners. Neither window case has a test
    (`grep -rn "Worktree removed" app/Tests` is empty).
  - `keepBranch(of:)`, `deleteBranch(of:)`, `heldForRetry(_:)`: the banner's retries.
  - `deleteUnmergedBranchQuestion(for:)`: "Delete branch X?" / "It has commits that aren't on Y.
    Deleting the branch deletes them too." / ["Delete Branch", "Cancel"], `defaultDeletes`. Used by
    `deleteBranch(of:)` and by `TaskArchiver.confirmRemove(archived:)`.
  - `removalInFlight(_:)` and `awaitsCleanup(_:)` each exclude `removals[id]?.awaitsRetry == true`.
  - `clearStoppedNote(of:)` clears only `.stopped(_, worktreeRemoved: false)`.
- `app/Sources/AiTermCore/Tasks/TaskRemoval.swift`: `.stopped(note:worktreeRemoved:)`, `awaitsRetry`.
- `app/Sources/AiTerm/TaskArchiver.swift`: `archive(task:)` and `archiveAutomatically` refuse a row
  with `awaitsRetry`; `confirmRemove(archived:)` forgets the row, then on `.notMerged` asks the
  delete question and runs `deleteUnmergedBranch`, on `.other` reports a banner without actions.
- `app/Sources/AiTermCore/Interface/OperationIssue.swift`: `Action.keepBranch`, `.deleteBranch`
  (titles "Keep Branch", "Delete Branch…"), their `isStale` cases, `branchKept(_:of:because:)`.
- `app/Sources/AiTermCore/Tasks/TaskWorkflow.swift`: `Removed.branchRefusal`, `BranchRefusal`
  (`.notMerged(base:)`, `.other(reason:)`), `releaseBranch` (base-merged: `-D`; otherwise `-d`; git's
  "not fully merged" becomes `.notMerged`), `deleteUnmergedBranch(of:in:)`, `forgetArchived`,
  `remove(...)` (clears `removalAttempts` only when there was no refusal).
- `app/Sources/AiTerm/AppController.swift`: `perform(_:)` cases `.keepBranch`, `.deleteBranch`.
- `app/Sources/AiTerm/Notices.swift`: comments on `report` (a background report must not take
  "Branch X kept" and its Keep or Delete) and `dismissIssue` (a removal past its worktree "still waits
  on a retry"). The hold logic itself also protects the Rebase question of a diverged pull.
- `app/Sources/AiTerm/Views/SidebarRows.swift`: `TaskRowView` reads `awaitsRetry` to grey Archive;
  `TaskRowAccessibility` takes `awaitsRetry` and then offers only Remove.
- `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift` about line 263 seeds
  `.stopped(note: "Not removed: branch kept", worktreeRemoved: true)`.
- After phase 3, re-check whether `RowWindows` still reads `awaitsRetry`:
  `grep -rn "awaitsRetry\|worktreeRemoved" app/Sources app/Tests` lists every reader.

## Change

1. Core, `Repository` (beside `isMerged(_:into:)` in `Repository.swift`): add a question "is this
   branch's tip reachable from its upstream", answered with `merge-base --is-ancestor` against
   `<branch>@{upstream}`; no upstream (git's 128) is false.
2. Core, `TaskWorkflow`:
   - Add `branchHasUnmergedCommits(of:in:) async throws -> Bool`: false for a review (its branch is
     never deleted on request) and for a branch that does not exist; otherwise true when the tip is
     reachable neither from its base (`isMerged`) nor from its upstream. Read off the repository's
     lane-free pool, as `head(of:in:)` is.
   - `remove(...)` and `forgetArchived(...)` take, beside `deleteBranch`, whether the person agreed
     to lose commits only the branch has. Agreed: `git branch -D`. Not agreed: today's rule.
   - Delete `BranchRefusal`, `Removed.branchRefusal` and `deleteUnmergedBranch(of:in:)`. A task
     branch git refuses to delete is reported through `Removed.keptBranch` as
     `.notDeleted(reason)`: for git's "not fully merged", "it has commits that aren’t on <base>"
     (or "its base" when empty); for anything else, `GitError.sentence(of:)`. `removalAttempts` is
     cleared after every completed removal.
3. `TaskRemover.confirmRemove(task:)` asks, in this order, and acts only after the last answer:
   1. `AlertPrompt.removeTask` (unchanged after phase 3): message `Remove task “<title>”?`
      (`review` for a review), detail "Deletes its worktree and closes its iTerm2 window." plus, for a
      review, " Its local branch goes too, unless it has unpushed commits."; buttons Remove, Cancel;
      checkbox "Delete local branch" for a task, its tooltip the branch; Remove is the red default.
   2. Only when git no longer lists the folder: `unlistedFolderQuestion` unchanged ("Delete the
      unlisted folder for “<title>”?", "Git no longer lists this folder as a worktree. It may contain
      files AiTerm did not create." then the path; Keep, Delete Folder; Keep is ⎋). Keep ends the
      Remove; nothing changed.
   3. Only when the worktree has uncommitted or untracked files: the existing question ("The
      worktree has uncommitted changes" / "Removing this worktree permanently deletes its
      uncommitted changes and untracked files." / Keep Task or Keep Review, Delete Changes and
      Remove; Keep is ⎋ and the default). Keep ends the Remove; nothing changed.
   4. Only when the box was ticked and `branchHasUnmergedCommits` is true:
      `deleteUnmergedBranchQuestion` with buttons Delete Branch and Keep Branch (Delete Branch the red
      default, Keep Branch answers ⎋); message and detail unchanged. Either answer goes on.
   Then it acts once: close the window with the helper required (Change 4), remove the worktree
   (unforced unless 3 said Delete Changes), and if git refuses for work written since question 3,
   ask question 3 again (existing; nothing has been deleted yet) and run forced on a yes. Then the
   branch: Delete Branch, `-D`; no question needed, today's rule; Keep Branch or box unticked, left.
   The row goes and the toast says "Task removed." plus, when git kept the branch, "Branch <name>
   kept: <reason>." (`Notices.showRemoval` already builds this from `keptBranch`).
4. Remove requires the helper for a row that has a window: `closeWindow(... requiringDaemon: true ...)`.
   `TeardownStop.noDaemon` stops it with nothing deleted: the row's note "Not removed: iTerm2 isn’t
   connected" and the banner "Couldn’t remove the task." with reason "iTerm2 isn’t connected, so its
   window couldn’t close and nothing was deleted." (Archive's sentences with Remove's verb). A row
   without a window needs no helper. Reword `TeardownStop.noDaemon`'s comment for both verbs.
5. `finishRemoval`: delete the branch-refusal block and the whole "window the task has now" block.
   After the close succeeded the row is windowless until it goes.
6. Delete `keepBranch(of:)`, `deleteBranch(of:)`, `heldForRetry(_:)`, the `before:` parameter of
   `remove`, the `awaitsRetry` terms in `removalInFlight` and `awaitsCleanup`, and the comments that
   describe the retry.
7. Core: `TaskRemoval.stopped(note:)` loses `worktreeRemoved`; delete `awaitsRetry`. `clearStoppedNote`
   clears any `.stopped`. `OperationIssue`: delete `Action.keepBranch`, `.deleteBranch`, their
   `isStale` cases and `branchKept`; reword the type's comment so Rebase is the one action.
8. `TaskArchiver.confirmRemove(archived:)`: Remove alert (unchanged wording), then, box ticked and
   `branchHasUnmergedCommits`, question 4; then `forgetArchived` with the answer; then the row goes,
   whatever git did with the branch, and the toast says so as in 3. A thrown git error (other than a
   kept branch) keeps "Couldn’t remove the task." and leaves the row archived, as today. Drop the
   inline `.notMerged`/`.other` handling.
9. `TaskArchiver.archive(task:)` and `archiveAutomatically`: drop the `awaitsRetry` guard.
10. `AppController.perform(_:)`: only `.rebaseDefault` remains. `Notices`: keep the hold logic
    (it still protects the Rebase question), rewrite its two comments to name Rebase instead of Keep
    and Delete, and drop the "waits on a retry" sentence from `dismissIssue`.
11. `SidebarRows.swift`: drop `awaitsRetry` from `TaskRowView` and `TaskRowAccessibility` (Archive is
    greyed only while removing). `SidebarSnapshots.swift`: seed `.stopped(note: "Not removed: its
    window did not close")` for `fixture.other`.
12. Docs: fix any sentence in `docs/windows.md` and `docs/keyboard.md` that mentions Keep Branch,
    Delete Branch… on the banner, "branch kept" as a row state, or Remove without the helper
    (`grep -n "Keep Branch\|Delete Branch\|branch kept\|close its iTerm2 window, then retry" docs/*.md`).

## Keep

- The re-ask about unsaved work after the window closed (`WorktreeTeardown.run`): an agent mid-turn
  writes while its window closes. Nothing is deleted before it.
- The unlisted-folder question: `RemovalAttempts` lives in memory, so it is real after a relaunch.
- `releaseBranch`'s base-merged `-D` rule and a review's `releaseReviewBranch` (unchanged).
- `removeAutomatically` (the Operator's Remove): it never deletes a branch (`deleteBranch: false`,
  `preserveBranch`), so it asks and checks nothing new.
- The `Notices` hold logic (a background report must not take the Rebase question away).
- `offersBranchDeletion(for:)`: a review's alert has no checkbox.

## Decisions already taken

- The branch check runs only with the box ticked, after the unsaved-work question. With the box
  unticked, Remove spawns no more git than today (`WorkBudgetTests.removingATaskSpawnsGit` stays 7).
- Git cannot answer the branch check (timeout, broken repository): ask question 4, the safe side.
- Commits added to the branch between question 4 and the delete (an agent still running): git's
  refusal of the unforced delete keeps the branch, the toast says so, the row goes.
- `-D` after Delete Branch fails (the branch is checked out in the project folder): the branch is
  kept, the toast says so with git's sentence, the row goes. Same for an archived row: its row goes
  too, which replaces today's "removal failed, row stays archived".
- The helper goes away while questions are up: the close step refuses then, nothing deleted.
- Escape on question 4 is Keep Branch, never a cancel of the whole Remove.
- The toast for a branch kept by the person's own Keep Branch answer is just "Task removed.".

## Tests

Delete, each with its survivor:

- `OperationIssueControllerTests` (`app/Tests/AiTermTests/OperationIssueTests.swift`):
  `aBranchKeptForUnmergedWorkIsReportedWithItsWaysOut`, `keepBranchFinishesTheRemovalAndLeavesTheBranch`,
  `deleteBranchAsksFirstThenDropsTheBranch`, `cancellingDeleteBranchChangesNothing`,
  `theIssueGoesWithTheTaskItIsAbout`, `dismissingClearsTheIssueButNotTheRowsNote`,
  `aLaterReportLeavesTheRowWaitingOnItsRetry`, `theIssueStaysWhenItsRowsWindowCloses`,
  `aRowAwaitingARemovalsRetryIsNotRestored`: the retry behaviour is deleted; the new Remove tests
  below cover keeping and deleting the branch. `aReportWithNoActionsLeavesAPendingQuestionShowing`,
  `aNewerReportReplacesWhatItDoesNotOutrank`, `theNewestHeldBackReportIsTheOneShown`,
  `aHeldBackReportForARowThatWentIsDropped`, `theIssueGoesWithItsProject`,
  `theIssueGoesWhenABackupWithoutItsRowIsRestored`: rewrite each on a Rebase question
  (`OperationIssue(title:actions: [.rebaseDefault(project)])` reported directly) instead of the
  `removedWithUnmergedBranch` helper, which goes. Keep the stopped-note tests, on `.stopped(note:)`.
- `ArchiveControllerTests.aRowWaitingOnItsRemovalsRetryIsNotArchived`: behaviour deleted.
- Core `OperationIssueTests.aBranchWithCommitsItsBaseLacksOffersKeepAndDelete` and
  `anyOtherRefusalKeepsGitsReasonAndOffersOnlyKeep`: behaviour deleted;
  `anIssueIsStaleOnceWhatItNamesHasGone` loses its keep/delete cases only.
- `TaskWorkflowTests.deletingAnUnmergedBranchDropsItsCommits`: rewrite on `remove` with the agreed
  flag. `removalRetainsUnmergedBranchAndRetryOnlyDeletesBranch` becomes "an unmerged branch is kept
  and said so; agreed, it is deleted". Every `branchRefusal` expectation becomes one on `keptBranch`.

Adjust: `NoticesTests` (questions built with `.rebaseDefault` instead of `.keepBranch`),
`TaskRowCaptionTests`, `RowAccessibilityTests` (drop the `awaitsRetry` case), every
`.stopped(note:worktreeRemoved:)` in `ArchiveTests` and `CheckoutCleanupTests`, and in
`ArchiveTests`: `removingAnArchivedRowWhoseBranchHoldsUnmergedCommitsAsksBeforeDeletingIt` (the
question comes before the row is forgotten), `decliningTheUnmergedBranchQuestion…` (answer Keep
Branch), `aBranchGitWillNotDeleteForAnotherReason…` (toast, no banner),
`aBranchThatCannotBeDeletedAfterTheUnmergedQuestion…` (the row goes, the toast says kept).

Add (controller tests, real git through `RaceFixture`):

- Remove with the box ticked on a branch with a commit its base lacks asks Delete Branch while the
  window is still open and the worktree still there (check inside `whileAsking`).
- Delete Branch removes the row, the worktree and the branch; Keep Branch (and ⎋) removes the row and
  the worktree and keeps the branch.
- A branch merged into its base, the project folder on another branch, is deleted without question 4.
- A branch on its upstream only is deleted without question 4.
- A branch git still refuses (checked out in the project folder) is kept, the toast names it, the row goes.
- A row with a window and no helper: nothing deleted, note "Not removed: iTerm2 isn’t connected";
  a row without a window and no helper is removed.
- Core: `branchHasUnmergedCommits` for base-merged, upstream-only, neither, missing branch, review.

## Proof

- `scripts/test.sh swift -- --filter OperationIssueControllerTests`, then `ArchiveControllerTests`,
  `CheckoutCleanupControllerTests`, `AppControllerRaceTests`, `NoticesTests`, `TaskWorkflowTests`,
  `OperationIssueTests`, `TaskRowCaptionTests`, `RowAccessibilityTests`, `WorkBudgetTests`.
- `scripts/snapshots.sh build/4b` and compare the sidebar snapshot with `build/refactor-before`:
  only `fixture.other`'s amber caption text differs.
- Plain `scripts/test.sh`.

## Done when

- `grep -rn "awaitsRetry\|worktreeRemoved\|keepBranch\|deleteBranch(of\|heldForRetry\|branchKept\|BranchRefusal\|branchRefusal\|deleteUnmergedBranch(" app`
  returns nothing.
- `grep -rn "Worktree removed" app/Sources` returns nothing.
- The suites above and plain `scripts/test.sh` are green; the docs grep in Change 12 finds nothing stale.

## Not in this step

- Folding remover, archiver and teardown into one owner, and the Operator's refusing variants: 4c.
- Restore and the one window opener: 4d. Take Over: 4e.
