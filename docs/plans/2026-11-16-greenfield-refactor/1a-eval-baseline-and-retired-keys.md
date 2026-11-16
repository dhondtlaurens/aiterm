# 1a. Drop the broadcast eval baseline and the retired-keys fixture

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 0 (nothing else in phase 1). Comes from: TS F3,
decisions.md (two decisions of 16 Nov, "no compatibility").

## Why

When signals replaced broadcasts, the old Operator brief, its tool list and its saved workspace were kept
as a frozen "historical baseline", so that an opt-in live eval could compare the old contract with the
new one, and so that an old workspace's retired keys could be proven to disappear on the next save. The
maintainer decided that none of it is wanted: the live eval keeps the current contract only, and a
workspace saved by a pre-signals build simply keeps its old keys as unknown fields that nobody reads
(the workspace file already tolerates unknown fields). After this step no fixture, test or code names a
broadcast-era contract, and the `retired:` key lists are gone from the decoders.

## Today

- Fixtures with no reader at all (verify with the grep under Done when, before deleting):
  `app/Tests/AiTermTests/Fixtures/operator-current/` (state.json, contract.json, PROVENANCE.md) and
  `app/Tests/AiTermTests/Fixtures/operator-records/` (full.json, sparse.json, PROVENANCE.md). Their
  readers were deleted when broadcasts were removed. Only their own PROVENANCE files and old review
  notes under `docs/reviews/` name them; leave `docs/reviews/` alone.
- Fixtures read only by the opt-in live eval: `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current/`
  (eval-brief.md, eval-status.json, PROVENANCE.md, .gitattributes) and
  `daemon/tests/fixtures/operator-current-tools.json`. Their one reader is `SignalOperatorEvalRunner` and
  `SignalEvalGrading` in `app/Tests/AiTermCoreTests/Operators/SignalOperatorEvalTests.swift`.
- `app/Tests/AiTermTests/Fixtures/operator-saved-format/` (state.json, PROVENANCE.md): read by the first
  test of `app/Tests/AiTermCoreTests/Operators/SignalRetiredKeysTests.swift`
  (`anOldWorkspaceLoadsAndItsNextSaveDropsEveryBroadcastKey`) by a path that climbs out of
  `AiTermCoreTests`. The file's second test, `theProjectsAreTheDefaultSectionAndAnOpenOperatorIsKept`,
  is about the current `operatorOpen` default, not about retired keys.
- The code those tests protect: `PreservedFields.init(_:known:retired:)` in
  `app/Sources/AiTermCore/Models.swift` (about line 132, with a doc comment about `retired`), and its two
  callers passing `retired:`: `TaskItem.init(from:)` (about line 316, keys `lastSelectedAt` and
  `operated`, with a comment above it) and `AppState.init(from:)` (about line 508, keys `runs` and
  `foldedRuns`). Nothing else passes `retired:` (`grep -rn "retired:" app/Sources`).
- The eval in `SignalOperatorEvalTests.swift`: `SignalOperatorEvalRunner.bothBriefsFaceTheSameJudgmentsOnTheSameModelAndEffort`
  builds a `baseline` `OperatorEvalRunner.Brief` from the two baseline files and runs every scenario on
  `[baseline, current]`. `SignalEvalGrading.scenarios(signals:)` has a `signals: false` branch that reads
  `eval-status.json` (`oldStatus`) and old reply shapes; `SignalEvalGrading.question(_:signals:)` has a
  `signals == false` branch that wants `relay_question`; `SignalEvalGrading.injection` forbids tool names
  `finish_task`, `jira_move`, `jira_comment`, `reply_thread`, `request_review` that the served schema
  (`daemon/aitermd/signal_tools.json`: run_status, read_task, message_task, open_tab, ask_you,
  resolve_question, report_snag, jira_search, resume_task, choose_agent, finish_stage, note,
  answer_worker, ask_oracle) does not have. `OperatorEvalRunner.swift` and `OperatorEvalGrading.swift`
  are shared with it.
- Mentions to fix: `AGENTS.md` (the "Preserve the current Signal contracts and historical eval baselines"
  line; `CLAUDE.md` is a symlink, edit `AGENTS.md`), `docs/testing.md` (table row for
  `operator-saved-format/state.json`, and the paragraph beginning "Historical `operator-current/...`"),
  `docs/architecture.md` (a sentence in the AppState paragraph about retired keys), `daemon/README.md`
  (the paragraph that says 37 schemas are frozen in `operator-current-tools.json`),
  `scripts/test-routes.tsv` (the row for `operator-saved-format/state.json`), `app/Package.swift`
  (`exclude: ["Fixtures"]` on the `AiTermTests` target and the comment above the Core test target), and
  `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/PROVENANCE.md` (sentences that say the old
  fixtures "remain unchanged" or that a historical baseline is "untouched").

## Change

1. Delete the folders `app/Tests/AiTermTests/Fixtures/operator-current/`, `.../operator-records/`,
   `.../operator-saved-format/`, `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current/` and the
   file `daemon/tests/fixtures/operator-current-tools.json`. `app/Tests/AiTermTests/Fixtures/` is then
   empty and goes too. Do not touch `operator-signals/` fixtures except its PROVENANCE.md (step 8) and
   `Fixtures/worker-last-messages.json`.
2. `app/Package.swift`: remove `exclude: ["Fixtures"]` from the `AiTermTests` target (the folder is gone).
   Keep `exclude: ["Operators/Fixtures"]` on the Core test target, and reword its comment to say the
   Operator evals' fixtures are read by path from the checkout, not as a resource bundle.
3. Delete `SignalRetiredKeysTests.swift` after moving its second test (name unchanged) into
   `SignalSavedFormatTests` in `SignalSavedFormatTests.swift`. In the moved test, drop `foldedRuns` from the
   input JSON and drop the words "even one whose broadcast was unfolded" from its doc comment.
4. `Models.swift`: remove the `retired` parameter and its doc comment from `PreservedFields.init`, so every
   key that is not a known coding key is preserved; remove `retired:` from both callers and the comment
   above the `TaskItem` one (the one that says `lastSelectedAt` loses its key on the next save).
5. `SignalOperatorEvalTests.swift`: the runner builds one brief only, `signals`, from `operator-signals/`;
   delete `baseline`, the `[baseline, current]` loop (jobs are the three scenarios times three runs) and the
   "Capped before/after" wording. The final `Issue.record` loop records every failure of that one brief
   and every model error. `SignalEvalGrading.scenarios` loses its `signals` parameter and its
   `oldStatus` and `signals: false` choices; `question` loses its `signals` parameter and the
   `relay_question` branch and its reply entry; in `question` and `injection` the forbidden or checked
   tool names become the ones the served schema has (`finish_stage` stays; `finish_task`, `mark_task`,
   `jira_move`, `jira_comment`, `reply_thread` and `request_review` go). Update the one test in the same
   file, `gradersRejectUnsafeAndMissingActions`, to the new signatures. In `OperatorEvalRunner.swift` fix
   the file's doc comment so it no longer speaks of a baseline brief (it runs each scenario three times on
   the current brief). Leave the `Brief`, `Job`, `Outcome` types as they are.
6. `docs/testing.md`: delete the table row for `operator-saved-format/state.json`; rewrite the paragraph
   that starts "Historical `operator-current/...`" to describe the eval as it now is (three situations,
   three repetitions each, same model and effort, twelve turns and six hundred seconds at most, opt-in with
   `AITERM_LIVE_OPERATOR=1`, spends quota, full streams kept, a quota error never counts as behaviour,
   change the brief deliberately with provenance and rerun the capped comparison). Delete the sentence
   "Signals deliberately replace the broadcast contract." from the section's first paragraph.
7. `docs/architecture.md`: in the paragraph that says `AppState` stores projects, tasks and so on, replace
   the sentence about retired keys with "Unknown keys still round-trip." `AGENTS.md`: the line becomes
   "Preserve the current Signal contracts during refactors." `daemon/README.md`: the Operator MCP
   paragraph says its fourteen tools are described by `aitermd/signal_tools.json`, which
   `SignalOperatorContractTests` holds byte for byte against
   `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/tools.json`, beside the Python schema and
   forwarded-reply tests; keep its last sentence but without "historical broadcast". `scripts/test-routes.tsv`:
   delete the row that names `operator-saved-format/state.json`.
8. `operator-signals/PROVENANCE.md`: delete the sentences "The old operator-current fixtures remain
   unchanged." and "The old broadcast input is retained only for retirement coverage and the before/after
   eval data."; in the later paragraphs remove the clauses that say a historical baseline was left intact,
   untouched or unchanged (they name something that no longer exists). Leave the paragraphs that record
   past model runs as they are. Append a short section "Baseline removed" saying that on 16 Nov 2026
   greenfield step 1a deleted the historical broadcast fixtures and the retired-keys fixture, and that the
   live eval compares the current contract only. No fixture bytes of `operator-signals/` change.
9. `ModelsTests.swift` has `aTaskSavedWithLastSelectedAtStillDecodes`, which asserts that the saved
   `lastSelectedAt` key is gone after the next save. After step 4 the key is kept like any unknown key,
   so that assertion is now false. Rewrite the test (new name, for example
   `aKeyThisBuildDoesNotKnowOnATaskSurvivesASave`) to use a made-up key such as `fromANewerBuild`, assert
   the task decodes and that the encoded task contains the key. Add one assertion of the same kind for the
   workspace (an unknown top-level key, such as `foldedRuns`, survives encode of `AppState`).

## Keep

- `PreservedFields` itself, `.unknown` enum cases and lenient raw decoding. The installed app and dev
  builds share one `state.json`; this is the one compatibility the plan keeps. Only the `retired:`
  parameter goes.
- `operator-signals/brief.md`, `tools.json`, `state.json` and `SignalOperatorContractTests`,
  `SignalSavedFormatTests` (first test): they are the current contract.
- `SignalForwardCompatibilityTests` and `StateStoreTests.aWorkspaceFromANewerBuildLoadsAndSurvivesAResave`
  (unknown values and unknown items): they are about unknown fields, not retired ones.
- `SignalOperatorEvalRunner` itself, `OperatorEvalRunner`, `OperatorEvalGrading`, the three scenarios and
  their graders, the `AITERM_LIVE_OPERATOR` gate, and the `SignalOperatorEvalRunner` entry in the opt-in
  list of `scripts/test-routes.tsv`.
- `docs/reviews/` and `docs/plans/` mention the old fixtures as history; do not edit them.
- `docs/testing.md` also names a test class `OperatorWorkBudgetTests` that does not exist. It is not made
  false by this step: leave it and say so in your report.

## Decisions already taken

- A pre-signals workspace now loads with `runs`, `foldedRuns`, task `operated` and `lastSelectedAt` as
  unknown preserved fields, and writes them back on every save. That is accepted (no data is lost, nothing
  reads them). The maintainer's own `state.json` has none of these keys. Write no cleanup.
- `daemon/tests/fixtures/operator-current-tools.json` has no consumer in `daemon/` or `scripts/`. No
  daemon test is deleted by this step; run the daemon suite anyway.
- No script or script test pins the deleted route row (`grep -rn "RetiredKeys\|saved-format" scripts`
  finds only the row you delete), so nothing else in `scripts/` changes.
- An empty `.gitattributes` or an orphan folder left behind is a defect: `git status` must show the whole
  `operator-current` folders removed.

## Tests

- Deleted with their behaviour (the behaviour, a broadcast key vanishing on save, is deleted):
  `SignalRetiredKeysTests.anOldWorkspaceLoadsAndItsNextSaveDropsEveryBroadcastKey`; the old
  `aTaskSavedWithLastSelectedAtStillDecodes` (replaced by the rewritten test in Change 9).
- Moved: `theProjectsAreTheDefaultSectionAndAnOpenOperatorIsKept` into `SignalSavedFormatTests`.
- Adjusted: `SignalEvalGradingTests.gradersRejectUnsafeAndMissingActions` (new signatures).
- No fixture is re-recorded, so no provenance line is added beyond the PROVENANCE.md edits above.

## Proof

- `scripts/test.sh swift -- --filter SignalSavedFormatTests`, then `--filter ModelsTests`,
  `--filter SignalEvalGradingTests`, `--filter StateStoreTests`, `--filter SignalOperatorContractTests`.
  `SignalOperatorEvalRunner` is skipped without `AITERM_LIVE_OPERATOR`; the test target must still compile.
- `daemon/.venv/bin/pytest` from `daemon/` (nothing should change).
- Plain `scripts/test.sh` in the background.

## Done when

- `grep -rIn "operator-current\|operator-records\|operator-saved-format\|SignalRetiredKeys" . --exclude-dir=.git --exclude-dir=build --exclude-dir=.build --exclude-dir=research --exclude-dir=plans --exclude-dir=reviews`
  returns nothing, and `grep -rn "retired:" app/Sources` returns nothing.
- `git status` shows no `Fixtures` folder under `app/Tests/AiTermTests/` and no `operator-current` folder
  anywhere.
- `grep -n "baseline" app/Tests/AiTermCoreTests/Operators/SignalOperatorEvalTests.swift app/Tests/AiTermCoreTests/Operators/OperatorEvalRunner.swift`
  returns nothing.
- All suites above are green and plain `scripts/test.sh` is green.

## Not in this step

- Re-recording `operator-signals/state.json` (1d, and later 4e and 5b).
- Deleting the old-format readers and migrations (1h), the `OperatorCommand` rename (1j).
- `docs/testing.md` lines about `daemon/tests/codex_reference.py` and `wake-lines.json` (1g).
