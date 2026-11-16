# 2c. The checkout cleanup trusts the scan's confirmation

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 1 (1i removed the Fix pipeline port from `AppPorts`). Independent of 2a and 2b. Comes from: audit TL F6.

## Why

When a task's worktree disappears outside AiTerm, the checkout monitor's scan already confirms, off the main actor, that the removal is real (`WorkspaceScan.checkoutRemovalIsConfirmed`: a readable project and parent, and "no such file" for the worktree). `TaskRemover.forgetRemovedCheckouts` then confirms it again, about a pass later, on a thread of its own, through an injected port that exists so a test can simulate a mount that never answers. A worktree that comes back within one two-second pass of its deletion being confirmed has not been seen and is not plausible here; a hung mount is already handled in the scan, which treats an unreadable parent as "not confirmed". After this step the cleanup acts on the scan's answer, after the main-actor recheck that the task is unchanged and not busy.

## Today

- `AiTerm/TaskRemover.swift`: `confirmations` (one `Task` per task id), the `confirmsRemoval` closure, the `ConfirmsRemoval` typealias and `diskConfirmsRemoval`, the `confirmsRemoval` init parameter. `forgetRemovedCheckouts(_:)` starts a `confirmations[task.id]` task that awaits `ThreadWork.run { confirms(task, projectPath) }`, then checks `awaitsCleanup(task)` again, starts a `recordCleanups[task.id]` task (`TaskWorkflow.forgetDeletedCheckout`), and calls `automaticallyForgetRemovedTask`. `removalInFlight(_:)` reads `confirmations[id]`; `waitForRemoval(of:)` awaits `confirmations[id]` then `running[id]`.
- `AiTerm/AppPorts.swift`: the `confirmsRemoval` field and a sentence in the type's doc comment. `AiTerm/AppController.swift`: `ports.confirmsRemoval` is read near the top of its init, passed to `TaskRemover`, and `AppController.live` passes `TaskRemover.diskConfirmsRemoval`.
- Test seams: `AiTermTests/ScratchController.swift` and `RaceFixture.swift` (parameter `confirmsRemoval`, default `diskConfirmsRemoval`, also on `TaskFixture`), `CheckoutCleanupTests` (two tests pass a blocking confirmation). Check: `grep -rn "confirmsRemoval\|ConfirmsRemoval\|diskConfirmsRemoval" app`.
- Callers: only `CheckoutMonitor` (a pass, `removals?.forgetRemovedCheckouts(...)`, after applying the scan on the main actor) and tests. `WorkspaceScan.checkoutRemovalIsConfirmed` is also called by `WorkspaceScan.run`, which stays.

## Change

1. In `TaskRemover`: delete `confirmations`, `confirmsRemoval`, `ConfirmsRemoval`, `diskConfirmsRemoval` and the init parameter. `forgetRemovedCheckouts` becomes synchronous work on the main actor: reset stale `.closing` outcomes as today, then for each task that `awaitsCleanup`, start the `recordCleanups` task (if none runs and the project still exists) and call `automaticallyForgetRemovedTask`. Keep `awaitsCleanup` unchanged (task unchanged since the pass, no operation on it, not waiting on a retry, no turn in flight).
2. `removalInFlight(_:)` loses its `confirmations` term: an operation on the task and not waiting on a retry. `waitForRemoval(of:)` awaits `recordCleanups[id]` and `running[id]`, so tests still have one join for a cleanup (the record cleanup is not covered by the closing task; without this a test that reads git's record straight after the wait would race).
3. `AppPorts`: delete the field and the sentence naming it. `AppController`: stop reading and passing it; `live` stops passing `diskConfirmsRemoval`. Tests: delete the parameter from `ScratchController`, `RaceFixture` and `TaskFixture`.
4. Fix the comments that describe the confirmation: the doc comment of `forgetRemovedCheckouts` (the second look, the thread), the `recordCleanups` comment ("apart from `confirmations`"), `WorkspaceScan.checkoutRemovalIsConfirmed`'s doc ("and by the checkout cleanup just before it acts"). In `docs/status-model.md`, section "A turn that removes its own checkout", the sentence "keeps its confirmed-removal check, and also waits while..." becomes "waits while any of the task's sessions is still `working` or `needsInput`".

## Keep

- `awaitsCleanup` and its parts, in particular the main-actor recheck that the task is unchanged: this is the check that matters when the person acts between the pass and the cleanup.
- `TaskWorkflow.forgetDeletedCheckout`'s own `fileExists` guard before it clears git's record: it protects an irreversible record removal, costs one stat, and is not the check being deleted.
- The scan's `checkoutRemovalIsConfirmed` and its rules (readable project and parent, "no such file" only). It is the one confirmation.
- `CheckoutMonitor.retainDiffsDuringRemoval`, which keeps a diff while a removal runs and its parent is offline (`diffRemainsUntilRemovalCompletesOrFails` pins it).
- `outcomes[id] = .closing`, the retry on the next pass and `closeWindowIfOpen`.

## Decisions already taken

- A worktree that reappears between the scan and the cleanup is not a case. If it did, the next pass would find a task whose checkout is back and the row would be as before, minus the closed task; no handling.
- A cleanup now starts in the same main-actor turn that applies the scan. The scan result handed to the cleanup is "as the task is now" already (`CheckoutMonitor` maps through `now.task(id:)`), so no extra freshness read is needed.
- Nothing about the hung-mount case needs a replacement: the scan's stat is off the main actor, and an unreadable parent is "not confirmed".

## Tests

- Delete `CheckoutCleanupTests.aCheckoutThatCameBackBeforeTheCleanupActsIsNotForgotten`, `aConfirmationThatNeverAnswersLeavesTheMainActorFree` and `thePersonsRemoveRunsWhileAConfirmationHangs`: the behaviour (a second disk look, a hung confirmation thread) is deleted. Survivors for what they incidentally covered: `aCheckoutThatComesBackStopsClosing` (a checkout that returns stops a closing row on the next pass) and the Remove tests in `CheckoutCleanupTests.swift` (`removingAnUnknownFolderKeepsItUnlessExplicitlyConfirmed`).
- Add one test: `forgetRemovedCheckouts` leaves a task alone while an operation runs on it (start a Remove held at a port, hand the task to the cleanup, expect no window close and the task still present). It replaces what the deleted hanging-confirmation test showed about Remove racing the cleanup.
- Adjust: `theCleanupForgetsGitsLockedRecordOfADeletedCheckout` and the others using `waitForRemoval` keep working through the new join.
- No fixture is re-recorded.

## Proof

While iterating: `scripts/test.sh swift -- --filter CheckoutCleanupControllerTests`, `CheckoutMonitorTests`, `WorkspaceScanTests`, `ControllerRaceTests`, `AppControllerTests`. Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "confirmsRemoval\|ConfirmsRemoval\|diskConfirmsRemoval\|confirmations\[" app` returns nothing.
- `grep -n "confirmed-removal check" docs/status-model.md` returns nothing.
- Suites above and plain `scripts/test.sh` are green.

## Not in this step

The window-close heuristic and the Remove question (3a), one teardown owner and the remover's dictionaries (4c), the retry state of Remove (4b).
