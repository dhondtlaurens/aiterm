# A project signal can remove its task

Branch `feat/also-have-remove-option`. No ticket: the prompt is the ticket.

## Goal

New project signal › Done when › **Then** offers only **Keep the task** and **Archive it**. Operator signals
also offer **Remove it**, and with it **Delete its branch once merged**. Project signals get the same third
option and the same checkbox, with the same meaning: the task and its worktree go (unsaved work keeps the
worktree), and the branch is deleted only when it is merged at the exact commit that was merged.

## Approach

The pieces exist; before this change only project signals were fenced off from them. `SignalDoneStep` drew Remove
and the toggle, and only `SignalModel.thenValues` hid them; `Signal.isValid` refused Remove and
`deletesMergedBranch` on a project signal, and `ProjectSignalWatch.then` returned on `.remove`. A removed task's item does not start
again while it still matches: `SignalSeen.pruned` keeps a project signal's `.started` record for that reason.
The removal without asking is `TaskTeardown.remove(_, consent: .refuse(stillAllowed:))`, which the Operator's
`ThenRunner` already uses. The branch proof is `MergedBranchCheck.delete` through `SignalHostIO.deleteMergedBranch`.

So: lift the fence in validity, model and watch; `thenValues` goes, and the sheet offers
`SignalFinish.Then.allCases` on both kinds. The watch's Remove reuses Archive's guards (nothing at work, no turn
held, no unsent input, the same origin) and Archive's refusal handling (`ClosingWait` is retried next
pass; any other refusal is kept in `thenNote` and reported through `changed`). The teardown's `stillAllowed`
also requires the live signal, switched on and still asking for that Then, so a signal switched off or edited
while the worktree is checked takes nothing away (Archive gains the same check). On success the row is gone, so
nothing is marked. After the removal, a project-task variant of `deleteMergedBranch` reads the live signal
through `signalOrigin.signal` instead of `signalTask`, keeps the full proof (merged status with a head, a task
and never a review, not the default branch, no other task on the branch, the row gone), and drops only the
Operator-paused gate, because project signals carry on while the Operator is paused. The Operator variant and
the project variant share one body; only the signal lookup and the gate differ.

The saved workspace format does not change: `SignalFinish.then` already encodes `remove`, and
`deletesMergedBranch` exists. Only `isValid` accepts more, so no update script is needed.

Decided in grilling: nothing was left open. The prompt names the option and the checkbox. The checkbox is shown
exactly as on an Operator signal. On a review it deletes nothing (a review's local copy is released as on a
manual Remove), as it already does on an Operator signal.

## Files

- `app/Sources/AiTermCore/Operators/Signals/Signal.swift` (modify): `isValid` accepts Then Remove and
  `deletesMergedBranch` on a project signal, and the general rule (branch deletion only with Remove) still
  holds. Update the doc comment.
- `app/Sources/AiTerm/Operators/SignalModel.swift` (modify): `thenValues` goes, as both kinds offer all three;
  `finish` saves `deletesMergedBranch` for a project signal; update the comments on the project kind.
- `app/Sources/AiTerm/Views/Operators/SignalDoneStep.swift` (modify): Then offers `SignalFinish.Then.allCases`.
- `app/Sources/AiTerm/Operators/ProjectSignalWatch.swift` (modify): a `remove` port beside `archive`; `.remove`
  in `then` through one helper shared with Archive's guards and refusal handling.
- `app/Sources/AiTerm/Operators/SignalOperatorController.swift` (modify): wire `projectWatch`'s `remove` to
  `remove(task, allowed)` followed by the project-task branch deletion.
- `app/Sources/AiTerm/Operators/SignalHostIO.swift` (modify): merged-branch deletion for a project task,
  sharing its body with the Operator variant.
  Its Remove help text and summary already read right for a project task.
- `app/Sources/AiTerm/Snapshots/SignalSnapshots.swift` (modify): a project Done step with Remove and the
  toggle on.
- `docs/operators.md` (modify): the project-signal paragraph no longer drops Remove; "(Keep or Archive on a
  project signal)" goes.
- `docs/design/design-system.html` mirrors "(Keep or Archive on a project signal)". It is synced only on
  request through the `design-system` skill, so the hand-off mentions it.

## Proof

Tests, written first for the new logic:

- `AiTermCoreTests/Operators/SignalDomainTests.swift`: a project signal "removed when done" and "its merged
  branch deleted" become valid; a project signal with `deletesMergedBranch` and Then Archive stays invalid.
- `AiTermTests/Operators/SignalModelTests.swift`: a project signal with Remove and
  the toggle on saves `SignalFinish(then: .remove, deletesMergedBranch: true)`; with Archive, the toggle is not
  saved.
- `AiTermTests/Operators/ProjectSignalWatchTests.swift`: a done task under a Remove signal is removed through
  the port once idle. It is held while at work, while a turn is held and while input is unsent. A refusal is
  kept in `thenNote` and reported once. `ClosingWait` is retried on the next pass. A signal switched off or its
  Then edited while the teardown runs makes it no longer allowed, and nothing is marked.
- `AiTermTests/Operators/SignalHostIOTests.swift`: the project variant deletes a merged task branch at the
  merged head (as `aMergedBranchLearnsItsMergedHeadFromTheStatus` does for the Operator) and still deletes
  while the Operator is paused. It deletes nothing for a review, for a switched-off signal, for a signal
  without the toggle, or while the row still exists.
- Snapshot `signal-project-remove-done.png`, on You decide so Then, the toggle and the summary fit the sheet (with A
  query matches, the query fields push the toggle below the fold).

Gate: `scripts/test.sh` from the worktree's root, in the background. Before merging: `require-full`, or
`scripts/test.sh all`.

Run: launch the app. New project signal › Done when › Then shows three options. Remove shows **Delete its
branch once merged**, and the summary ends "Then its task is removed, and its branch deleted only if it’s
merged and unchanged." Saved and reopened with Edit Signal…, the signal keeps Remove and the toggle.

## To-dos

Built in this order, so the sheet offers only what already runs.

- [x] Remove runs: `Signal.isValid` accepts Remove on a project signal; `ProjectSignalWatch` removes through a
      new port with Archive's guards and refusal handling, wired in `SignalOperatorController`; domain and watch
      tests.
- [x] Branch deleted: `isValid` accepts `deletesMergedBranch` with Remove on a project signal; the project-task
      `deleteMergedBranch` in `SignalHostIO`, called after the removal; host IO tests.
- [x] Remove offered: Then offers all three in the sheet, and the toggle is saved; model tests; snapshot.
- [x] Docs and proof: `docs/operators.md`; snapshots read; gate green. The live run is the maintainer's.
