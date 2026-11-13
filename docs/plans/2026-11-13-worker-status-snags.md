# Worker status and delivery after recovery

## Goal

Fix the three worker snags reported from AiTerm 0.45.0: an API stop remains after activity resumes,
a Codex worker loses message delivery after reconnect, and a reference to another branch's commit
is mistaken for work committed off the task branch. The third report also found the task branch
already at a merge containing that commit; rechecking an earlier warning while the worker carries
on is part of making that report current.

## Approach

Keep genuine stopped turns visible. A busy Claude file while children run past StopFailure is
ambiguous: clear the stop only when a newer parent prompt or successful parent assistant response
appears in the transcript, or an explicit parent hook proves recovery. Cache bounded transcript
reads by file stamp, ignore sidechains and tool results, reject observations overtaken by a new hook,
and preserve the existing 30-second window for discovering a usage-limit reset. Cover the status
engine through the service's hook/file/transcript flow.

Keep Codex's hook-proven thread on its iTerm tab with the process ID that owns it. Recover that
identity after a helper restart, read the version from that thread's rollout, and retain all existing
delivery checks. A different process cannot inherit the identity. Subagent hooks cannot replace the
parent conversation binding.

Use branch ownership rather than prose classification: a commit held by another task branch in
the same broadcast and project is a reference to that task, not proof this worker committed off
its branch. Include closed task records in that ownership set. Continue checking the actual
worktree HEAD first and git ancestry. Recheck an earlier message warning while a worker is active
so merging its named commit onto its task branch clears it. An unknown off-branch commit still
warns as before. The trade-off is conservative: a message alone cannot attribute work to this
worker when another broadcast task owns the branch that holds it.

## Files

- Modify `daemon/aitermd/status.py`: distinguish a child-busy file from parent recovery, including
  an unchanged displayed state.
- Modify `daemon/aitermd/stop_failures.py` and `corroboration.py`: cache bounded stopped-parent
  transcript reads, apply fresh recovery, and retain usage reset discovery.
- Modify `daemon/aitermd/models.py`: name the internal Codex thread tag.
- Modify `daemon/aitermd/iterm_bridge.py`: read that tag with the existing batched variables.
- Modify `daemon/aitermd/sessions.py`: recover its conversation only when agent and pid match.
- Modify `daemon/aitermd/hook_router.py`: distinguish a placement pin from a proven Codex binding.
- Modify `daemon/aitermd/resolver.py`: recover a process-bound binding and keep child hooks out of it.
- Modify `daemon/aitermd/service.py`: write each proven thread/pid to its tab after corroboration;
  retain successful writes so a steady tick does no extra iTerm writes or registry sorts.
- Modify `app/Sources/AiTermCore/BranchDrift.swift` and its Core tests: sibling branch ownership is
  an explicit exclusion beside the existing base/merge exclusions.
- Modify `app/Sources/AiTerm/Operators/BranchWatch.swift`: exclude known sibling branch references,
  include that ownership in lookup validity, and refresh an earlier warning after a merge.
- Modify `daemon/tests/test_stop_failures.py`, `test_delivery_service.py`, `test_resolver.py`,
  `test_sessions.py`, `test_service.py`, `test_iterm_bridge.py`: regressions and adapter fixtures for those paths.
- Modify `app/Tests/AiTermTests/Operators/BranchWatchTests.swift`: real git and run_status proof.
- Modify `docs/architecture.md`, `docs/status-model.md` and `docs/operators.md`: document identity recovery and warning ownership.

Keep frozen tool schemas and saved-format fixtures unchanged.

## Proof

Show each regression failing first. Run the focused daemon tests and BranchWatchTests, including
actual delivery after reconnect/restart and run_status after a foreign commit reference and a merge.
Run scripts/test.sh for the completed change. Do not replace the running app or touch the live broadcast.

## To-dos

- [x] Reproduce and fix stale stop recovery, preserving still-stopped turns
- [x] Reproduce and fix Codex delivery recovery; prove unchecked replacements stay refused
- [x] Reproduce and fix sibling commit references and stale post-merge drift; preserve actual drift
- [x] Focused proof, affected gate, and independent review complete

## Review and limits

Two independent plan rounds settled the approach. The first change review found that a busy
Claude file can belong to children after the parent's failure; the implementation now requires
parent transcript progress in that case. Its second round confirmed the Important finding fixed.
The obsolete reset helper was removed and its tests now exercise the production reader.

One Minor remains outside the reported single-commit case: after an app relaunch during an active
turn, only the previously saved drift SHA can be rechecked. The full earlier report's other SHAs
are no longer cached. Within an app run all cached report SHAs are retained and rechecked, so
resolving one does not hide another. No saved Operator format was changed for this fix.

## Validation

`scripts/test.sh` exited 0 on the completed working tree: 1,596 daemon tests passed (one live
integration skip), mypy and ruff passed, and 4,232 Swift tests passed across the affected targets
with only their existing known issues. The branch-watch and work-budget suites passed, including
the two distinct off-branch changes merged one at a time. Frozen schemas and saved-format fixtures
are unchanged. No live app switch was run. Changes remain uncommitted.
