# Reuse full test proof for unchanged inputs

## Goal

Avoid running the full gate again on main after a branch has already passed with identical
code, including the release's automatic README picture commit.

## Approach

Compare the committed Git trees using the commit IDs already recorded in history. Release can
reuse a recent clean full pass from the same repository when the committed trees match, or when every changed path
selects no tests through the existing test routing table. Unknown paths and changes to the
routing or runner require a new pass. Keep seven-day retention, plain full-run eligibility and
unchanged clean before/after state. The latest full attempt across all equivalent commits decides,
including failures. Use `git diff --name-only --no-renames -z <recorded commit> <current commit>`
and the existing `scripts/test-select.sh`, never a second glob matcher; errors reject reuse.
Changes to the selector or routing table always invalidate reuse, even if the new table ignores
itself. Read attempts newest first and stop at the first equivalent result. Correct the existing
`LICENSE` route to the toolchain guard because its bundle fixture reads that file; such a change
must invalidate proof. Existing history works without a schema migration. Explicit test commands
continue to run.

The initial request authorized implementing this workflow fix. The user subsequently authorized
committing, merging to main and pushing; a release is outside this request.

## Files

- Modify `scripts/test-history.py`: compare relevant committed source contents, using existing history.
- Modify `scripts/test-test-history.sh`: invert the empty-commit assertion and add real Git
  regression cases for merges, docs-only commits, source/test/runner changes, failures, dirty or
  moving sources and repository isolation.
- Modify `scripts/test-routes.tsv` and `scripts/test-test-select.sh`: route `LICENSE` to the
  toolchain guard and pin that existing fixture dependency.
- Modify `scripts/release.sh`: change the missing-proof diagnostic and the post-README-redraw
  comment to refer to unchanged test inputs.
- Modify `AGENTS.md`, `docs/testing.md`, `docs/workflow/project.md`,
  `docs/workflow/release.md` and `scripts/README.md`: document reuse and the read-only proof check.

## Proof

First reproduce rejection of identical trees in the history guard. Run the guard after the fix,
then the normal affected gate in the background. No publishing, live app replacement, or merge.
Use the psg adversarial review for the plan and finished change and triage its findings.

## To-dos

- [x] Challenge the plan and triage findings (revocation, rename-safe routing, schema simplification, existing assertion and release wording all adopted).
- [x] Add failing real-Git cases, then implement source equivalence.
- [x] Update release diagnostics and workflow instructions.
- [x] Run the affected gate and review the finished change.

## Completed proof

- Reproduced the original rejection with an empty-commit case before changing the implementation.
- `scripts/test-test-history.sh` passes, including merge/screenshot reuse, overlapping routes,
  source/runner/routing/license changes, renames, deletions, modes, later failures, edits during
  testing, expiry and repository/worktree isolation.
- Plain `scripts/test.sh` selected everything and passed: 1,553 Python tests (one skipped), mypy,
  ruff and 2,777 Swift tests (four known issues), plus toolchain and script guards. Log:
  `/tmp/aiterm-double-test-runs-gate.log`.
- After the review refinements, reran the history and routing guards successfully. The final
  routing edit only moves the license comment and row below the existing build-script group.
- A read-only check using the actual retained branch pass for `edc532e0` accepts current main
  `202d1f5c`, covering merge `2197cc5c` and its following README picture commit.
- Two Claude plan review rounds and two Claude change review rounds. Adopted all findings:
  equivalent-source failure revocation, rename-safe native routing, existing history reuse,
  newest-first lookup, the license dependency and the routing-comment placement. No open findings.

Implementation and review finished before committing. The user subsequently requested a merge
and push. Run the full suite on the committed branch and reuse that proof on the identical merge
commit. No release or live app switch is included.
