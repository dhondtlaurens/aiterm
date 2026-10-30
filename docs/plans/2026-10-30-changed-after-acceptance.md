# Changes after acceptance

## Goal

An unchanged accepted branch, including after local merge, must not be listed or wake the
Operator as changed after acceptance merely because its worktree retains an untracked plan.
Keep detecting new commits and actual edits after acceptance.

## Approach

Persist an optional acceptance fingerprint on OperatedTask, outside the model-facing
TaskAcceptance evidence. Compute it off the main actor from the paths differing from HEAD
and nonignored untracked paths, hashing each path's final content, type and executable bit.
Staging alone must not alter the fingerprint. Do not write the index or object database.
Include symlink targets rather than following links. Compare fingerprints as well as the accepted
commit when reading ended turns; include the baseline in the reader's identity so refreshing
evidence on the same SHA invalidates the prior reading. Preserve repeat-call idempotence.

Older saved acceptances have no baseline. Their HEAD can still prove a change; dirt alone
cannot prove when it appeared, so do not claim it changed after acceptance. A failed current
fingerprint read likewise supplies no evidence of a content change. Keep tool/status schemas,
publication state and current contract goldens unchanged.
If the acceptance-time fingerprint cannot be read for an existing checkout, refuse with a
retryable read error before changing acceptance. A failed same-SHA refresh retains its old
baseline and evidence. Tasks without a checkout retain no baseline.

## Files

- Modify `app/Sources/AiTermCore/Operators/WorkerTurn.swift`: content fingerprint adapter and
  comparison rule.
- Modify `app/Sources/AiTermCore/Operators/OperatorModels.swift`, `OperatedTransitions.swift`
  and `UpstreamReplacement.swift`: optional internal persisted baseline, cleared whenever an
  acceptance is replaced or revoked and saved atomically with acceptance at the tool boundary.
- Modify `app/Sources/AiTerm/Operators/OperatorToolHandler+Tasks.swift`: read the baseline at
  acceptance off the main actor, retaining current ownership checks.
- Modify `app/Sources/AiTerm/Operators/WorkerTurnReader.swift`: compare current content with
  the persisted baseline and invalidate readings when it changes.
- Modify focused core and app Operator tests: real Git acceptance/local-merge/restart regression,
  later content/commit changes, legacy loading, and refreshing evidence on the same SHA.
- Modify `app/Sources/AiTermCore/Operators/RunStatus.swift` comments and `docs/operators.md`:
  describe the baseline requirement and legacy behavior.

## Proof

First reproduce through the real-Git worker/Operator tool fixture: create an untracked plan,
accept the task and merge locally, then end a worker turn with no new work. Assert published
state, no changed obligation and no changed wake. Prove it fails before the fix and passes after.
Cover unchanged dirty content, later edits with identical status text, new untracked files,
tracked/staged edits and HEAD movement. Run focused suites with `scripts/test.sh swift`, then
the affected `scripts/test.sh` gate. Keep the installed app and live broadcast untouched.
Seed the existing accepted-worktree fixtures with a baseline and preserve their later-edit
expectations. Update pure comparison tests for fingerprint inputs; add a separate legacy case.

## To-dos

- [x] Reproduce the false changed obligation and wake in an isolated real-Git fixture.
- [x] Persist and compare acceptance content, including legacy and same-SHA identities.
- [x] Prove regression and real subsequent changes, then run the affected gate.
- [x] Challenge the plan and finished change and triage the findings.

## Review

The plan review found that putting the fingerprint on TaskAcceptance would expose internal
state through acceptanceEvidence and Oracle evidence. Store it on OperatedTask instead.
It also identified staging-only false alerts from hashing index and worktree patches separately.
Hash final file content across the union of changed tracked and untracked paths instead.
The display-only workingDiff reader truncates its input, so it cannot supply this fingerprint.

The second plan pass settled those findings. Its two remaining minor requests are covered by
retryable acceptance-time failures that preserve previous evidence, and baseline-seeded existing
reader tests that retain their later-edit expectations. The finished-change review found one
minor documentation issue, fixed in the obligation and test comments. No functional findings
remain open.

## Evidence

Before the fix, the corrected local-merge regression passed its acceptance, published-state,
unchanged-branch and main-ancestry checks, then failed precisely its empty changedAfterAcceptance
and absent changed-wake expectations. Reproduction log: `/tmp/aiterm-acceptance-repro.log`.

The focused gate passes all 164 tests across eight suites, including the real acceptance/local
merge/restart journey, a later plan edit and wake, old acceptances, same-SHA baseline refresh,
repeat-call baseline preservation, retryable read failures, symlinks, binary content, unusual
filenames, staging, tracked deletion and the frozen current Operator contract.

Plain `scripts/test.sh` passes all affected checks: 1,726 app tests, 1,973 core tests,
92 UI tests and four snapshot tests (3,795 total). The three intentional known issues in
the existing scripted-prompter and eventual-wait tests remain expected. No contract golden,
installed app or live broadcast was changed.
