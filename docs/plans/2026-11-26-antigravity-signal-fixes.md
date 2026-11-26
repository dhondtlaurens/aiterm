# Choose Antigravity from the Operator and edit signals offline

## Goal

An Operator can choose, open a work tab for, and resume a permitted Antigravity row. New Signal and Edit Signal open on the first click while model discovery runs. If discovery fails, a person can see why and can save unrelated edits to a signal that already has that row.

## Approach

Populate the three worker enums in the static MCP contract from the daemon’s derived FULL_SUPPORT list when updating the checked-in JSON. The only worker enums are on choose_agent, open_tab and resume_task. Their descriptions and the Operator brief refer to permitted rows without enumerating workers. The brief’s usage advice guides the Operator’s proposal. The automatic fallback switch belongs to ModelChoice.weeklySwitchPair. Check the served list against the daemon’s derived full-support set and the checked-in contract against Swift’s worker list. The Python route forwards arguments. Swift owns the exact permitted row, stage and ownership checks.

Present the sheet synchronously with the installed workers and any saved rows. Use the per-worker readiness probe that the sheet already starts as the single source of model discovery for the sheet. Observe the retained HarnessSettingsModel snapshots, which publish each probe result before the follow-up driver test or other workers finish. Use an earlier snapshot as the last reading while its refresh runs and label it accordingly. Carry the models, freshness and failure explanation. A slow Antigravity read must leave other workers and the name and trigger editors usable. A second click sees the occupied sheet slot immediately.

An Operator draft starts with one row per installed worker in the existing order. A project draft keeps its single-row rule. Keep row identities stable. Fill untouched defaults as results arrive. A removed or changed row, a dismissed sheet and a subsequently opened sheet must all be respected. Show a failed Models check once on the Agents step even when the person can continue. Keep the footer’s other readiness issues, including any other issue for that worker. Preserve the exact model and reasoning of a saved row when discovery fails. A failed refresh with cached models keeps current Signal behavior: those models and their supported efforts can supply defaults and validate new or changed rows. Show that the list is cached. The exception for a saved choice absent from the cache applies only while its original agent, model and reasoning are intact. A failure with no cache leaves new rows unresolved. Fresh results, including a successfully read empty list, retain existing model and reasoning validation. An installed worker with no usable model stays visible and requires a choice or explicit removal before a new Operator signal can be created.

## Files

- Modify `daemon/aitermd/signal_tools.json`, the Operator fixture `tools.json` and its sibling `PROVENANCE.md`. Record the deliberate tool contract change in the implementation commit. Note in provenance that the brief already instructs the Operator to choose a permitted row.
- Modify `SignalOperatorContractTests.swift`, `daemon/tests/test_operator_surface.py` and `SignalAgentChoiceTests.swift` to cover both ends of the MCP contract, exact row selection, opening and resuming.
- Modify `AppController+Signals.swift`, `AppController+Operators.swift`, `Operators/OperatorPorts.swift`, `Operators/SignalContext.swift` and `Operators/SignalModel.swift` for immediate presentation, discovery state and validation. Reuse the retained observable snapshots in `HarnessSettingsModel.swift` and its existing per-worker in-flight guard.
- Modify `Operators/SignalReadiness.swift` and `SignalReadinessTests.swift` so the Models warning appears once on the Agents step and other readiness issues still appear in the footer.
- Modify `Views/Operators/SignalSheet.swift` and `Views/Operators/AgentsStep.swift` to present the model state on both kinds of signal using existing UI components. Correct the weekly switch explanation in the Agents step.
- Modify the signal model, presentation and harness tests and their fixtures (`SignalModelTests.swift`, `SheetPreparationTests.swift`, `OperatorFakes.swift`, `HarnessSettingsModelTests.swift` and the seeded context in `SignalSnapshots.swift` where needed).
- Modify `docs/operators.md` for guarded workers and the scope of the weekly switch. Correct the symbol in `docs/plans/2026-11-26-antigravity-cli.md` to `ModelChoice.weeklySwitchPair`.

## Proof

- First demonstrate a red contract assertion on the three served worker enums. Exercise an exact Antigravity model and reasoning through the real Swift tool handlers, verifying the chosen launch, extra tab and blocked-task resume. Assert the daemon relays the same arguments over the Operator route.
- For a cold installed Antigravity, drive a throwing or failing command through a stubbed `HarnessCommandRunner`. Check the visible failure, preservation and actual saving of an unchanged saved row on unrelated edits, and the visible unresolved row in a new signal. Verify a lone Models warning appears once and a simultaneous integration issue remains visible. Cover a genuinely missing executable separately and a successful empty list. After a forced refresh failure, check a cached default and effort, an unchanged saved choice outside the cache, and a changed choice outside the cache.
- Hold the stubbed `agy models` command at a test-controlled barrier. Open New and Edit through their normal presentation paths. Before releasing the command, verify a usable sheet and a stable identity on another click. Release with success and failure, count exactly one `agy models` invocation and verify the result reaches only the intended sheet and rows. Use synchronization instead of the real 15-second timeout.
- Compare the affected sheet snapshots on base and branch and run the worktree gate `scripts/test.sh` before each commit. Swift builds and tests use the repository wrappers.
- For the requested live proof, use a real Operator signal on a scratch project with two permitted rows, including an installed Antigravity model. Put the exact Antigravity model and reasoning in the scratch signal prompt, ask the Operator to choose it and open a named work tab on the same row, and keep the prompt with the evidence. Capture the actual Operator choosing the exact Antigravity row, the corresponding worker launch, and the Operator opening a named Antigravity work tab in the task’s iTerm2 window. Correlate the calls and tab with the task. Keep identifiers and transcripts with local verification evidence. The maintainer switches the running app to the development build if needed under `docs/workflow/verify.md`. The stubbed MCP evaluation does not exercise this boundary.

## To-dos

- [ ] Test and repair the advertised worker contract, update fixture provenance, and verify all three handlers.
- [ ] Test both presentation paths with a suspended runner. Present immediately and deliver each worker’s models and failure from its readiness probe.
- [ ] Test the installed-but-failed catalogue path and implement row preservation, feedback and validation on those probe results.
- [ ] Correct the documentation and help, inspect the sheet captures, run the gate and record the live Operator proof.
