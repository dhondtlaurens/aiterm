# Broadcast cleanup status

## Goal

Make the Operator's status distinguish a completed broadcast from removal of its task worktrees
and local branches. The reported Simplify broadcast retained locked, merged task worktrees with
untracked plan files while the completion wake gave the Operator no cleanup outcome.

## Approach

Keep completion and the existing automatic removal policy. Add an optional cleanup projection to
run_status for completed broadcasts with closing enabled: awaitingSummary, pending, or
settled. Settled means the current completion's cleanup pass ran, not that every task went.
Share the board's current-pass predicate for settled and gate keptReason/closingWait the same way
as its cards, hiding stale reasons while a run reopens or its next pass is pending. Ended runs remain
unavailable to Operator tools; their cleanup is proved through the persisted finished records and
Git outcomes, not an unreachable status projection.
The run cleanup phase participates in the existing waker's run-change news: after write_summary,
cleanup settling wakes the complete broadcast's Operator to read its outcome. Test that delivery.
Expose each task's applicable keptReason and closingWait beside its branch. Finished records already
carry branchDeleted. Explain that AiTerm owns cleanup, including its summary gate, and retained
worktrees with unsaved files require the person's action. Do not force removal or delete live data.

## Files

- Modify app/Sources/AiTerm/Operators/TaskAutoCloser.swift: name untracked files in the refusal.
- Modify app/Sources/AiTermCore/Operators/RunStatus.swift: project the cleanup phase and reasons.
- Modify app/Sources/AiTermCore/Operators/AppState+Operators.swift and Sidebar/BroadcastBoard.swift:
  share the board's current-pass predicate without changing card behavior.
- Modify app/Tests/AiTermTests/Operators/OperatorWakerTests.swift: prove a post-summary cleanup wake.
- Modify app/Tests/AiTermCoreTests/Operators/RunStatusTests.swift: phase, stale-pass, and JSON coverage.
- Modify app/Tests/AiTermTests/Operators/TaskAutoCloserTests.swift: real locked worktree lifecycle
  through the app's run_status request boundary before End; verify saved records and Git after End, including untracked files and merged branch deletion.
- Modify docs/operators.md: describe the new status evidence.

## Proof

First reproduce the missing status in a failing tool-boundary test using a temporary repository.
Verify pending summary, refused removal preserving the lock/file/branch, then a later End cleanup
after the fixture's untracked file is saved or removed. Cover deferred helper/turn reasons and a
closedAt from an earlier completion. Run focused tests and scripts/test.sh. Preserve frozen fixtures.
Challenge the plan and change with the adversarial-review skill.

## To-dos

- [x] Reproduce the missing cleanup status at the tool boundary.
- [x] Project cleanup phases and task wait/refusal reasons.
- [x] Prove the locked/untracked lifecycle and current contract, then run the affected gate.
- [x] Review and triage the change.

## Review

The independent plan review identified the ended-tool boundary, cleanup wake and stale reasons.
The implementation uses the request boundary, wakes on cleanup phase changes and shares the board
predicate. The change review found two minor wording and timeout-wake coverage issues; both were
addressed. The initial locked-worktree regression failed on missing cleanup status and reason.

The focused suites passed 130 tests, including the real Git lifecycle, wake and frozen contract.
The affected gate passed, including the final untracked-file wording.
