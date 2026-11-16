# 2h. Small guards: five deletions, each for a case that does not happen

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 1 (1b removed the host write surface, 1i removed Find a Fix from New Review, 1h removed old-format readers). Comes from: audit SS F16, HO F5 item 3, PL F6 and F8.

## Why

Five small pieces of code answer inputs that cannot happen here. New Review re-reads git at Create and refuses with "Press again to continue" when the branch's owner changed, though the create itself already reads the owner again. The Operator profile save `throws` for encoding plain strings and bools, and its caller swallows the throw, so Settings can close as if it saved. Three controls cannot send the input their model rechecks. The hosts' list reads each re-implement paging loops, with two helpers that disagree about what a short page means. Backpack Mode writes its rejoin delays twice and its turn-off block twice. The release feed parses a `github:owner/repo` string from Info.plist, with a character allow-list, for a source that is always this public repository. Each goes. Where a rule is deleted the owner of the real protection is named under Keep.

## Today

### A. New Review's "press again"
`AiTerm/ReviewCreationModel.swift`: `ReviewCreation.confirmBeforeSubmit` calls `model.loadCheckouts()`, compares the owning task with the one shown, and refuses with `model.refuse(...)` ("... Press again to continue."). The protocol requirement `CreationKind.confirmBeforeSubmit`, its default `{ true }` in the extension, and the call in `CreationModel.create(after:)` (`guard await kind.confirmBeforeSubmit(self)`) exist for it alone; `CreationModel.refuse(_:)` has no other caller (check `grep -rn "refuse(" app/Sources/AiTerm`). `TaskLauncher.createReview` already decides from git at create time: `checkoutOwner(of:in:)` first, else a new worktree. Test: `ReviewInTaskTests.theSheetRefusesADestinationThatMovedSinceItWasShown`.

### B. The profile save that cannot fail
`AiTermCore/Operators/OperatorProfileStore.swift`: `save(_:_:)` is `throws` and encodes with `try`. `AiTerm/Operators/OperatorSettingsModel.swift`: the `save:` closure is `@MainActor (OperatorProfile) throws -> Void`, `save()` does `guard (try? write(saving)) != nil else { return }` with the comment "One that could not be written is still a change to save". The closure is built in `OperatorSettingsModel.live` (`save: { try OperatorProfileStore.save($0, store) })`. Callers of `OperatorProfileStore.save` are tests: `OperatorProfileStoreTests`, `OperatorSettingsPaneTests`, `SignalFreshSessionTests`, and `FixerSettingsTests` if 1i left it.

### C. Guards behind controls that cannot send the input
`OperatorSettingsModel.select(oracleAgent:)`: `guard agent != oracle.agent, oracleAgentChoices.contains(agent)`; the pane's `Select` offers only `oracleAgentChoices`. `Views/Operators/SignalDoneStep.swift`: the `Select` over `doneChoices.indices` whose setter checks `indices.contains(index)`. `ProjectSheetModel.chooseFolder`: `guard !editing` (the Choose... button is drawn only when not editing).

### D. Paging in the hosts
`HTTPJSON.swift` has two helpers: `shortPages(perPage:pages:read:)` (a short page ends the list; returns items and whether it ended) and `pagesUntilEmpty(limit:exhausted:read:items:)` (only an empty page ends it; throws `exhausted` when the limit is spent; validates per page). Hand-written `for page in 1...N` loops remain at: `GitLabClient.signalRequest`, `GitHubClient.signalRequest` (both stop at a short page or at the first match, and throw `IncompleteRead("branch requests")` when the limit is spent), the request poll in `GitLab/GitLabAccount.swift`, `GitHubClient.protection(branch:)`'s ruleset loop (stops at the first non-harmless rule, throws `ProtectionUnknown.tooManyRules` when the limit is spent), `GitLabClient.readDiscussions` (an empty page ends a complete read; a short page ends a badge read) and, if 1b left it, `GitHubClient.findUsers`. Users of `shortPages`: `openMergeRequests`, `openPullRequests`, and the two `+SignalReview` readers. Users of `pagesUntilEmpty`: `GitLabClient.protectedRules`, `GitHubClient.approvals`. `GitHubClient.listed` reads a list that reports its own `total_count`. Re-run `grep -rn "for page in\|shortPages\|pagesUntilEmpty" app/Sources/AiTermCore`; 1b may have removed some.

### E. Backpack Mode
`Backpack/BackpackMode.swift`: `static let rejoinDelays: [TimeInterval] = [5, 10, 20, 30]` (internal), used by `bookNextRejoin`. `AiTerm/BackpackController.swift`: init parameter `retryDelays` defaulting to `[.seconds(5), .seconds(10), .seconds(20), .seconds(30)]`, used in the connect retry loop; tests pass their own. `BackpackController.turnOff()` and `undoWhileBusy(leaving:)` are one block twice: set `transition = .turningOff`, run on the worker `mode.turnOff()` then, optionally, `mode.rejoinPreferred(leaving:)`, read the current network, then set `state`, `phase = nil`, `currentNetwork`, and, when the restore failed, toast `Self.restoreFailed` and `startTicking()`. They differ only in whether the rejoin runs (always for `turnOff`; only when `joinedHotspot` for the undo), in `turnOff` also guarding on `busy`/`isOn`, taking `busy`, cancelling `ticking`, and in the hotspot name (`network ?? ""` against the argument).

### F. The release feed
`AiTermCore/Updates/ReleaseFeed.swift` (`ReleaseFeed`, parsing `github:<owner>/<repo>[.git]` with an allow-list; `source(for:)` throws `UpdateError.noFeed` for nil or unparsable text); `AiTerm/UpdateController.swift` `live(prompter:)` reads the Info.plist key `AiTermUpdateFeed` and passes `makeSource: { try ReleaseFeed.source(for: feed) }`; `UpdateController.checkForUpdates` also reports `UpdateError.noFeed` when the bundle has no version. The key is in `AiTerm/Resources/Info.plist`. Other readers: `ReleaseFeedTests`, `scripts/test-app-bundle.sh` (checks the key in the built bundle), `scripts/test-routes.tsv` (a row mapping the Info.plist to that suite), `scripts/test-test-select.sh` (a pinned check of that row), `UpdateControllerTests.aBuildWithoutAnUpdateSourceSaysSo`, `UpdateCheckTests.everyErrorHasItsExactLine`. Check: `grep -rn "ReleaseFeed\|AiTermUpdateFeed\|noFeed" app scripts docs README.md`.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

1. Part D: the plan says "one paging helper". The audit also proposed folding `GitHubClient.listed` into it. I kept `listed` as it is: it is the one list that reports its own total, and `GitHubPublishTests.checksThatCannotBeReadWholeNeverReadReady` pins that a list that ends short of its reported total makes a merge wait, which a short-page rule cannot see. I also kept both ending rules, as a named parameter of the one helper, because the audit's own recommendation was to keep "until an empty page" for lists that decide something (protection, threads, approvals) and `GitHubPublishTests.rulesetsAreReadUntilAnEmptyPage` and `GitLabPublishTests` (a host that caps `per_page` at 20) pin it. What goes is the second helper and every per-site loop.
2. Part B overlaps the plan's 8h ("the Operator profile save cannot silently fail"). This step does it; 8h can drop that item.
3. Part F removes the Info.plist key. `UpdateError.noFeed` and its text stay because `checkForUpdates` still uses them for a build with no version (`swift run`); only the "feed" meaning goes.

## Change

### A
1. Delete `confirmBeforeSubmit` from `ReviewCreation`, from the `CreationKind` protocol, from its default extension, and the guard in `create(after:)`. Delete `CreationModel.refuse(_:)` when no caller remains. `loadCheckouts()` stays: the sheet's open still reads checkouts to show the destination.
2. If the destination shown differs from where the review opens, the person sees the result of the click. No replacement message.

### B
1. `OperatorProfileStore.save` becomes non-throwing. Encode with a forced try and a one-line comment that the profile is plain strings and bools, as `WorkerGuardCLI.result` does for its fixed value. Keep the oracle-revision bump and the notification.
2. The `save:` closure of `OperatorSettingsModel` is non-throwing; `save()` writes and then sets `original`. Update `live`. Remove `try` from every `OperatorProfileStore.save` call in tests (a call with `try` on a non-throwing function is a warning, and the toolchain guard fails on warnings).

### C
1. `select(oracleAgent:)` keeps `guard agent != oracle.agent` and loses the `contains` check. The setter of the done `Select` assigns `doneChoices[index]` without the range check. `chooseFolder` loses `!editing` from its guard (keep the `choose()` and cancellation guards).

### D
1. Replace `shortPages` and `pagesUntilEmpty` with one `HTTPJSON.pages(perPage:limit:ending:stopWhen:read:)`. `ending` is `shortPage` (a page with fewer than `perPage` raw entries ends the list, an empty one included) or `emptyPage` (only an empty page ends it). `stopWhen` is optional: a page for which it answers true ends the list at once. It returns the items read and `complete`: true when the list ended or `stopWhen` fired, false only when `limit` pages were spent. Entries are counted raw, as `shortPages` does, before any decoding is judged. A `limit` below one reads one page.
2. Move every site in Today D onto it. Users of `shortPages` keep their arguments and `.shortPage`. `protectedRules` and `approvals` use `.emptyPage`, throw their `exhausted` error when `complete` is false, and validate the items after the read instead of page by page. `signalRequest` (both hosts) use `.shortPage`, limit 100, `stopWhen` the page holds the request of the task's own branch, and then take the first match; `!complete` throws `IncompleteRead("branch requests")`. The GitLab account poll uses `.shortPage`, limit 100, and sets its overall `complete` false when the limit was spent; the per-entry decode checks run over the items afterwards. `GitHubClient.protection(branch:)` uses `.emptyPage`, its `listedPages` limit and `stopWhen` a non-harmless rule; `!complete` throws `tooManyRules`. `readDiscussions` picks `.emptyPage` with `threadPagesRead` for a complete read and `.shortPage` with `discussionPages` for a badge read, throws `IncompleteRead("review threads")` for a complete read that did not end, and applies its item mapping to the items read. Request counts in tests may rise by one where an early return used to skip an empty last page; adjust the count, never the outcome.

### E
1. One constant: make `BackpackMode.rejoinDelays` public. `BackpackController.retryDelays` defaults to it, mapped to `Duration`. Tests still pass their own.
2. One private routine in `BackpackController` that does the shared block: it takes whether to rejoin and the hotspot to leave, runs it on the worker, and applies state, phase, current network and the failed-restore toast and ticking. `turnOff()` keeps its guards, `busy`, `transition` and `ticking?.cancel()` and calls it with rejoin on and `network ?? ""`. `undoWhileBusy` captures and clears `joinedHotspot` first and calls it with that value. Behaviour is identical.

### F
1. Add two constants in `GitHubReleaseSource` (or one `static let` source) for the owner and repository the Info.plist value names today (read it from `app/Sources/AiTerm/Resources/Info.plist`; do not copy a different one). `UpdateController.live` passes a source built from them; its `makeSource` seam stays for tests but no longer throws.
2. Delete `ReleaseFeed.swift`, the `AiTermUpdateFeed` key from Info.plist, and `ReleaseFeedTests`. In `scripts/test-app-bundle.sh` remove the feed check. In `scripts/test-routes.tsv` delete the Info.plist row and fix the header comment that names "the release feed's" test; in `scripts/test-test-select.sh` change the "the plist adds the release feed" check to the selectors the remaining rows give the Info.plist (the `app/Sources/AiTerm/*` row), and in `scripts/test.sh` fix the comment that quotes a `ReleaseFeedTests` test id. Run `scripts/test-test-select.sh` to confirm it passes.
3. Rewrite `UpdateControllerTests.aBuildWithoutAnUpdateSourceSaysSo` to build a controller whose bundle has no version, expecting the same message. `makeSource` closures that throw `.noFeed` go.

## Keep

- `TaskLauncher.createReview`'s fresh `checkoutOwner` read: it is the real decision, and `ReviewInTaskTests` other tests pin where a review opens.
- `OperatorSettingsModel.oracleAgentChoices` (offers installed agents plus the saved one) and the `agent != oracle.agent` guard (picking the shown agent is a real input).
- `ProjectSheetModel.inspectFolder`'s `!editing` guard: the folder field's task runs while editing too.
- `IntegrationSettingsModel`'s rollback of earlier cards on a later Keychain failure: the audit left it to the Settings step; not in this one.
- `GitHubClient.listed` and the GraphQL cursor paging.
- `HTTPJSON.CredentialGuard` (strips credentials on a cross-origin redirect; the update download follows redirects to a CDN).
- `UpdateError.noFeed` and `ReleasePage.newest`, `UpdateStager`, `UpdateInstaller`, the `ReleaseSource` protocol (the controller's test seam).
- Backpack's ports, `engaged` marker and quit guard.

## Decisions already taken

- Another session checking out a review's branch inside the minute the sheet is open is possible but not likely, and git refuses a conflicting checkout with its own failure, which the sheet already shows.
- A host that returns fewer entries than asked in the middle of a list is not a case for `.shortPage` lists (GitHub and GitLab cap at the 100 we ask); lists that decide something keep `.emptyPage`.
- A changed update repository means a code change in a release, as any constant does. No test pins the constants to a literal.
- No migration for the removed Info.plist key.

## Tests

- Delete `ReviewInTaskTests.theSheetRefusesADestinationThatMovedSinceItWasShown` (behaviour deleted; `createReview` reading the owner fresh is covered by the other tests in that file). Delete `ReleaseFeedTests` (behaviour deleted). In `OperatorSettingsPaneTests.theOraclesAgentIsOneInstalled` delete the three lines that call `select(oracleAgent: .codex)` on a Claude-only install and assert nothing changed; the `oracleAgentChoices` assertions stay.
- Adjust `HostTextTests` (the paging reference test) to the new helper: keep its reference loop for `.shortPage`, add the same exhaustive check for `.emptyPage`, and add cases for `stopWhen`. Adjust request counts in the GitHub and GitLab tests that fail for the reason above.
- `BackpackControllerTests` and `BackpackSheetTests` already cover turn-off and Cancel's undo; they run unchanged as the proof for E. No test is added for A to F: they are deletions and moves.
- No fixture is re-recorded.

## Proof

While iterating: `scripts/test.sh swift -- --filter ReviewInTaskTests`, `OperatorSettingsPaneTests`, `OperatorProfileStoreTests`, `SignalFreshSessionTests`, `HostTextTests`, `GitHubClientTests`, `GitHubPublishTests`, `GitLabClientTests`, `GitLabPublishTests`, `MergeRequestPublisherTests`, `BackpackControllerTests`, `BackpackSheetTests`, `UpdateControllerTests`, `UpdateCheckTests`, `SignalModelTests`. Run `scripts/test-test-select.sh`. Then plain `scripts/test.sh` in the background. Do not run `scripts/make-app.sh` or the bundle test; the maintainer does at phase end.

## Done when

- `grep -rn "confirmBeforeSubmit\|pagesUntilEmpty\|shortPages\|ReleaseFeed\|AiTermUpdateFeed" app scripts` returns nothing.
- `grep -rn "for page in" app/Sources/AiTermCore` hits only `GitHubClient.listed` and the GraphQL cursor loop, if that is a loop.
- `grep -rn "undoWhileBusy" app/Sources/AiTerm/BackpackController.swift` shows one shared routine and no duplicated block.
- `grep -rn "\[5, 10, 20, 30\]\|.seconds(5), .seconds(10)" app/Sources` returns one hit.
- Suites above, `scripts/test-test-select.sh` and plain `scripts/test.sh` are green.

## Not in this step

Settings' dead staging paths and the copy about Cancel (8h). One interface and one status read for hosts (7a to 7c). The stale paragraph in `docs/configuration.md` about pausing the Operator before Backpack Mode, and `BackpackRefusal.quitting`, are noted by the audit and not planned.
