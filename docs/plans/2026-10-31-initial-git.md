# Task creation in an unborn Git repository

## Goal

Replace the invalid-reference failure for a new repository's unborn base branch with an explicit,
optional empty first commit and task retry. Preserve staged, unstaged and untracked files. Explain
Git identity failures and retain ordinary behavior for valid, invalid and missing base references.

## Approach

Recognize an unresolved task base only when it names Git's current unborn symbolic HEAD. Return a
typed failure that the existing creation footer maps to “Create Empty Commit and Retry”. That button
is consent; ordinary task creation never commits. Run initialization on TaskWorkflow's mutation queue,
recheck the branch and HEAD before writing, and use `git commit --only --allow-empty` to exclude staged
files. Keep the draft on failures and explain how to configure Git identity locally. Require a configured identity and disable hooks for the empty commit so they cannot
add files or rewrite the checkout. Honor Git signing settings. A retry uses the
normal task creation flow. Clear the offer when the selected base changes. Report the actual unborn
HEAD in default-branch detection and watch HEAD for changes, including custom initial branch names.

## Files

- Modify `app/Sources/AiTermCore/Git/Repository+Worktrees.swift` and `Repository.swift`; add
  `Repository+Initialization.swift` for detection, safe empty commits and diagnostics.
- Modify `app/Sources/AiTermCore/Git/DefaultBranchResolver.swift` to watch unborn HEAD changes.
- Modify `app/Sources/AiTermCore/Tasks/TaskWorkflow.swift` and `app/Sources/AiTerm/TaskLauncher.swift`
  to serialize consented initialization.
- Modify `app/Sources/AiTerm/CreationModel.swift`, `TaskCreationModel.swift` and `SheetCoordinator.swift`
  to offer and wire recovery. The shared error's description also explains manual recovery to callers
  without a button, including Operator workers.
- Modify `app/Sources/AiTerm/Snapshots/SheetSnapshots.swift` and `Snapshots.swift` to render the task
  recovery footer after the established snapshot set. Update the recovery comment in
  `app/Sources/AiTerm/Views/FixViews.swift`.
- Add `app/Tests/AiTermCoreTests/UnbornRepositoryTests.swift` and
  `app/Tests/AiTermTests/UnbornTaskCreationTests.swift` for real-Git and creation-model coverage.

## Proof

Reproduced with `git init -b main` followed by `git worktree add … main`: exit 128, invalid reference.
Probed `git commit --only --allow-empty` with a staged file and further unstaged edits: the first commit
has an empty tree and the file remains staged and modified. Tests cover no automatic commit, file and
index preservation, identity failure/retry, changed repository state, valid/missing/invalid bases and
creation through the sheet model after consent. Run affected suites and the project's gate; inspect a
fixture rendering of the recovery footer without disturbing the running app.

## To-dos

- [x] Add real-Git regression cases and demonstrate the existing failure.
- [x] Implement precise unborn-base errors and consented initialization.
- [x] Wire the recovery into task creation and retain draft/error behavior.
- [x] Prove initialization, retry and existing behavior; run the gate and independent review.

## Plan review

Independent Claude review caught non-main unborn branches missing from the picker. Added actual
unborn HEAD detection and cache invalidation, plus master and custom-branch cases. Also adopted
configured identity enforcement, clarified the shared error and named exact files. Tests and product
changes were reviewed together.

Second plan review settled all earlier findings. Its remaining Minor describes an existing limit:
committed repositories with only a custom local branch and no origin still use the existing default
branch policy. This change recognizes their unborn branch and completes the retained draft's retry;
it does not change default selection for existing committed repositories.

## Change review

Independent Claude review found no behavioral defects. Fixed both Minor findings about stale
comments. New recovery snapshots append after the established regression set to preserve its render
order. No Critical or Important findings remain.

The first broad gate exposed a pre-existing race in
`app/Tests/AiTermTests/Operators/OperatorChallengeTests.swift`: the fixture appended activity entries
while its preceding tool call was still recording asynchronously. The resulting prompt lost the first
two expected commands. The test now waits for that recording before directly appending fixture data;
Operator behavior and contracts are unchanged. Focused verification and a fresh broad gate follow.

Second change review confirmed the test synchronization and final snapshot ordering. Fixed its one
remaining Minor, a dangling default-protocol comment. No behavioral findings remain.

## Final verification

- `scripts/test.sh` passed: 92 UI, 1,734 app, 1,989 core and 4 isolated snapshot tests (3,819 total),
  with only the suites' existing known issues.
- Real-Git/controller coverage proves project addition, repeated ordinary Create without a commit,
  explicit initialization, persisted task/worktree creation and a terminal-window request.
- Both recovery footer PNGs were rendered offscreen and inspected: the explicit consent button fits,
  file-preservation wording is visible and local Git identity commands are readable.
- The earlier mixed filtered snapshot run failed a byte comparison because it mixed snapshot and
  non-snapshot suites. The project runner's isolated snapshot pass is green.
- Two independent Claude change-review rounds left no behavioral findings; all Minor comment findings
  were fixed. `git diff --check` is clean. The running app was not restarted.
- Changes were kept uncommitted until review and verification were complete.

## Pre-merge verification

`scripts/test.sh all` passed before the local merge: 1,408 daemon tests (one expected skip),
Python type/lint checks, and all 3,819 Swift tests including the isolated snapshot pass. The earlier
affected gate and independent reviews were also green. No live app restart was needed.
