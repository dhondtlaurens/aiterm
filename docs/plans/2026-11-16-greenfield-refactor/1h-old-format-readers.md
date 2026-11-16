# 1h. Old-format readers

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1a to 1g (1a removed the `retired:` parameter of
`PreservedFields`; 1d re-recorded `operator-signals/state.json`; 1g removed fields from `SessionInfo` and left its
hand-written initialiser for this step; 1i is after this step and removes the Fix folder). Comes from: CG F8,
TL F7, PL F3, OC F15, WD F4 (decoding paths only), HO F5 items 1 and 2.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- **A retired `PreToolUse` hook stays for an old install.** `ClaudeSettings.retiredEvents` and its removal in
  `merge`, and the `retiredRemain` clause in `ClaudeSettings.isInstalled`, go. A person whose `settings.json`
  still holds AiTerm's old synchronous Bash `PreToolUse` hook keeps it: Repair no longer removes it, and each Bash
  call of Claude Code posts to the daemon (3 second timeout) for an answer nobody reads. The hook is from before
  23 Oct (about 40 releases back). No code is written for it; if the maintainer minds, the release notes (9b)
  can tell a pre-0.54 install to delete it by hand.
- **`OperatorSession.finishing` stays optional in this step.** Making it a plain `Bool` would make a session saved
  by the installed app undecodable, and one unreadable record fails the whole workspace load. Phases 1 to 3 must
  keep reading the Operator's saved records as the installed app writes them, so the maintainer can try those
  phases on a real workspace without the reset. Step 5f replaces the flag with the chat's one lifecycle state.
- **An old flat-`projects` workspace now loads with no projects** (its `projects` array becomes an unknown
  preserved key). That is the intended end of that reader.

## Why

AiTerm has had about 40 releases in six weeks, and the code still reads formats that only an install from before
23 Oct, or a workspace from before 1 Oct, could hold: per-key Keychain items, an `AIterm` support folder, a JSON
status-line record, a retired hook, an iPhone push key, a single linked Jira project, a flat project list, unnamed
terminals, blocks saved by a build 13 hours older than signals, an optional flag kept optional so older saved
sessions read, and a helper-wire decoder written for helpers that no longer run. This ships as a major release with
no compatibility. After this step every reader decodes only what today's build writes, plus the one tolerance that
stays on purpose (unknown keys round-trip, unknown enum values are inert).

## Today

Re-run the greps. All paths are under `app/Sources/` unless they start with `daemon/`.

**Keychain.** `AiTermCore/Keychain.swift`: `Keychain.separateAccounts`, `Keychain.moveSeparateItems` (called when
the one item reads `.missing`), and the second branch of `ReadOnlyKeychain.get` (`.missing` falls back to a per-key
item). The first case of `Keychain.load` (`.found`) and `.refused` are current. Used by: `Keychain.shared`
(everything), `ReadOnlyKeychain` by `Operators/WorkerGuard/WorkerGuard+Host.swift`. Tests: `KeychainTests`
(`theSeparateItemsOfEarlierVersionsMoveIntoOne`, `theSeparateItemsStayWhenTheOneCannotBeWritten`, and the
`FakeKeychainItems` seeding for them; `aWorkerGuardReadsSecretsWithoutMigrationOrWrites` stays, only its name).

**Support folder.** `AiTermCore/AiTermPaths.swift` `migrateSupportDirectory` (and its two `NSError` branches),
called once in `AiTerm/AiTermApp.swift` `main` inside a `do/catch` that shows an alert. Tests:
`AiTermPathsTests` (every test that calls it: `migratesLegacySupportDirectory`, `migrationErrorsPropagateWithoutChangingData`
and the others in that file about lines 7-50), and the last lines of `HookConfigTests.installRecordsTheShimsPortAndNeverMigratesTheDataFolder`
(the `AIterm` folder left alone).

**Legacy status-line record.** `AiTermPaths.legacyStatusLineOriginalURL`; `Hooks/StatusLineOriginal.swift`
`migrate(home:)` and the `legacy` removal in `record(_:home:)`'s `.missing` case; its caller in
`AiTerm/AgentIntegrations.swift` `readStatusLine(migratingFirst:)` (`Log.harness.attempt("Migrating the saved status line")`).
The line after it, `ShimPort.record(AiTermPaths.hookPort, ...)`, is current: keep it. Tests: `HookConfigTests`
(`anOldJSONRecordIsMigratedAtLaunchWithoutAnInstall` about lines 650-665; the "legacy" expectations in the
install test about lines 55-65), `SheetPreparationTests.theLaunchProbeMigratesAnOldStatusLineRecord` (about line 104).

**Retired hook and push key.** `Harnesses/ClaudeSettings.swift`: `retiredEvents`, its loop in `merge`, and
`retiredRemain` in `isInstalled`. `Backpack/BackpackSettings.swift`: `Key.retired` (`["backpack.pushes"]`) and the
`Key.retired.forEach(defaults.removeObject...)` in `write`. Tests: `HookConfigTests.testRetiredPreToolUseHookIsRemovedButForeignOnesStay`
(about lines 95-130), `BackpackSettingsTests` (about lines 55-65: the `backpack.pushes` test). `PreToolUse` in the
Operator and worker-guard launch settings is a different, live hook: keep every other `PreToolUse` hit.

**Workspace decoders.** `AiTermCore/Models.swift`: `Project.jiraProject` coding key, the hand-written
`Project.init(from:)` and `encode(to:)`; `TerminalItem.init(from:)` (reads a missing `name` as `defaultName`);
`AppState.init(from:)` reading the flat `projects` array when `items` is absent, and `CodingKeys.projects`.
Tests: `ModelsTests` (the `jiraProject` single-project test about lines 181-204: delete the legacy read, keep the
"new saves carry only the list" assertion on the synthesized encoding; `testLegacyWorkspaceWithoutItemsDecodesItsProjectsInOrder`
about line 497), `StateStoreTests.testLegacyFileOnDiskLoadsAndSavesAsItems` (about line 283), any test that
decodes a terminal without a name (grep `"terminals"` JSON without `"name"`).

**Choice blocks.** `Operators/Signals/TaskItem+AgentChoice.swift` `earlierChoiceReasons`,
`normalizeEarlierChoiceBlock(configuration:at:)`; `AiTerm/Operators/SignalOperatorController.swift`
`normalizeEarlierChoiceBlocks()` and its call at the top of the reconcile. Test:
`SignalAgentChoiceTests.blocksSavedByAnEarlierBuildForAChoiceNowWaitForTheOperator` (about line 284).

**`finishing`.** `Operators/Signals/OperatorSession.swift` `var finishing: Bool?` with the comment "Kept optional so
existing saved sessions retain their format". Users: `AiTerm/Operators/OperatorSessionKeeper.swift` (about 16
places: `== true`, `!= true`, `= true`, `= nil`), `AiTerm/SignalSidebar.swift` (two), `Snapshots/SheetSnapshots.swift`
(one), `AiTerm/Operators/SignalOperatorController.swift` (two), tests `SignalSessionKeeperTests`,
`OperatorActivityTests`, `SignalOperatorLifetimeTests`.

**Helper wire, app side.** `Daemon/DaemonTypes.swift`: the hand-written `SessionInfo.init(from:)` (written for
`active` alone, which "an older daemon leaves out"; the daemon always sends it, `WireContractTests` proves it);
`BackgroundJob.init(from:)` with its bare-string branch ("a daemon older than the kinds"); the phrases "and from a
daemon too old to send it" and "Older helpers/daemons omit/do not send it" in doc comments of `SessionInfo`,
`DaemonSnapshot.claudeConfigDirectory`, `.itermVersion`, `.itermCookieRequest`, `Delivery.code`;
`DaemonClient.swift`: `createTaskWindow`/`createTab` send `background ? true : nil` and say "as every window before
operators"; `DaemonProtocol.swift` `DaemonError.Code.unknownMethod` doc ("an older helper"), and the
`livenessCheck` comment in `DaemonClient.swift` (about line 60: "An older helper without it still answers...").
Daemon side: `daemon/aitermd/operator_mcp.py` `generation: int | None = None` in `_call` and `ask_app` (and its
`if generation is not None` branches), `operator_session.py` `revoke(..., generation: int | None = None)`.
`register` already requires one; `owner_for` always returns one.

**Hosts.** `Jira/JiraClient.swift` `projects()` (about line 257: `last` is `isLast`, else `total`, else a short
page) and `ProjectPage` (`@Lenient var isLast`, `@Lenient var total`); `Jira/JiraClient+Signals.swift` the
values-pages loop (about lines 56-58) and `SignalValuesPage` (`isLast: Bool?`, `total: Int?`). `Jira/JiraClient+Signals.swift`
`search(jql:...)` uses `isLast ?? (nextPageToken == nil)`: a token is a real continuation signal; it stays.
`CodeHosts/ReviewThreadsReader.swift` `target(of:gitLabHost:)` accepts `/merge_requests/` without `/-/`
(GitLab before 12.0). Tests: `JiraClientTests` (about lines 255-305 pages carry `total` too: harmless; 412, 439-440
pages with `total` and no `isLast`; 537 `"isLast":"yes","total":"many"`), `ReviewThreadsReaderTests` (the
no-`/-/` URL case).

## Change

1. **Keychain.** `Keychain.load` on `.missing` caches an empty dictionary (what it cached before when no old items
   existed). Delete `separateAccounts`, `moveSeparateItems`. `ReadOnlyKeychain.get` returns `nil` on `.missing`.
   Rewrite the doc comments ("move old items") to say what is true.
2. **Support folder.** Delete `migrateSupportDirectory`. `AiTermApp.main` goes straight from the snapshot branch to
   creating the delegate and running the app (the alert path existed only for this).
3. **Status line.** Delete `AiTermPaths.legacyStatusLineOriginalURL`, `StatusLineOriginal.migrate`, the legacy removal in
   `record`. `AgentIntegrations.readStatusLine(migratingFirst:)` keeps its flag (it still gates the hook-port record at
   launch) but no longer migrates: rename the flag `recordingPort` and update the doc comments of `probeStatusLine`
   and the test name reference.
4. **Hooks and push key.** Delete `ClaudeSettings.retiredEvents`, its loop, `retiredRemain`. Delete
   `BackpackSettings.Key.retired` and its `forEach` in `write`; the defaults key `backpack.pushes` is left in a
   person's defaults, unread, no cleanup.
5. **Workspace.** `Project` uses synthesized `Codable` (delete `CodingKeys`, both hand-written methods; keep the
   explicit memberwise `init`). `TerminalItem` likewise (keep its `init`, `defaultName`, `suggestedName`). In
   `AppState.init(from:)` `items` reads `items` only (an absent key is an empty list); `CodingKeys` loses `projects`.
   `PreservedFields` keeps everything else; an old `projects` key now rides as an unknown preserved key (1a already
   removed the `retired:` set). Keep `AppState`'s hand-written `init`/`encode` (forward compatibility needs them).
6. **Choice blocks.** Delete `earlierChoiceReasons`, `normalizeEarlierChoiceBlock` and `normalizeEarlierChoiceBlocks()`
   and its call. A pending `choosing` flow is unaffected: `prepareLaunch` is called where it always was.
7. **`finishing`.** Leave the property optional and its users as they are. Only rewrite its comment: it is optional
   because a session saved before the flag existed has no such key; 5f replaces it. Nothing is re-recorded.
8. **Helper wire, app.** Delete `SessionInfo.init(from:)` (the synthesized decoder reads the same keys; `active` is
   always sent) and `BackgroundJob.init(from:)` (synthesized coding of `kind` and `text`; `Kind` keeps its lenient
   decoding). Delete the "too old to send it" and "older helper/daemon" phrases from the doc comments listed above,
   leaving each field's own description. `createTaskWindow` and `createTab` send `background` as it is: change
   `CreateTaskParams.background` and `CreateTabParams.background` from `Bool?` to `Bool`, pass `background`
   plainly, and drop the "left out when false" sentences. The `livenessCheck` comment loses its older-helper
   sentence; the logic is unchanged (the liveness reply is any answer, `unknown_method` included, as today).
   `DaemonError.Code.unknownMethod`'s comment says the daemon has no handler for the request name.
9. **Helper wire, daemon.** `operator_mcp._call` and `ask_app` take `generation: int` (required), the `is not None`
   branches go, the request payload always carries `generation`; `OperatorSessionTokens.revoke` requires one. Fix
   the callers in `operator_mcp.py` and `test_operator_mcp.py`, `test_operator_session.py`. The wire frame
   `event.operator.request.json` already carries `generation: 1`: it must not change.
10. **Hosts.** `JiraClient.projects()` reads a page as last when `isLast == true` and otherwise continues; the page
    type has `var isLast: Bool` (strict, no `Lenient`) and no `total`. The values-pages loop and `SignalValuesPage`
    likewise. If a page lacks `isLast` the read fails as a decoding error, which is what Jira Cloud never does.
    `ReviewThreadsReader.target` accepts only `/-/merge_requests/`; fix its doc comment.
11. **Comments.** Rewrite the doc comment of every symbol you edit to say what the code does, never "older" or
    "earlier"; do not hunt other comments (1j).

## Keep

- `PreservedFields`, `.unknown` enum cases, `LenientRawDecodable` and lenient raw decoding everywhere (`SidebarItem.unknown`,
  `AppState.lastAgentByProject` dropping unknown agents, `Provider`, `TaskKind`): dev builds and the installed app share one
  `state.json`. Unknown keys must still round-trip: `StateStoreTests` and `ModelsTests` cases for them stay.
- `JiraRef`'s default `source: .jira` and its omitted-when-Jira encoding: that is today's format.
- `ShimPort.record` at launch and `ReadOnlyKeychain` itself.
- `DeliveryCode.unknown`, `DeliveryOutcome`, `DeliveryPolicy` fallbacks: they handle a newer daemon, not an older one.
- `Delivery.code` stays optional (nil when delivered).
- The daemon's own `background` and `tabKey` optional request params: leave the daemon tolerant.
- `HelpWithProblems`' old `fixer` keys: part of the Fix folder step 1i deletes whole; do nothing here.
- `StateStore` backup/restore, the iTerm2 batched-read fallback and reftable handling: 2a, 2e, 2i.
- `DaemonConnection`'s mismatch hold, `HeldStatus`, the unreadable-line limiter, adoption: 6b.
- Jira's `/search/jql` token paging, `JiraClient.tickets` per-key fallback (a real 400 case).

## Decisions already taken

- **Nothing migrates.** A person with any of these old shapes starts clean for that item: tokens re-entered, the old
  support folder ignored, a flat project list empty. No alert, no log line, no cleanup of the old file.
- **`Project` without `jiraProjects`** (a hand-edited file): fails the load as any malformed key does; the real
  workspace always has it (`encode` always wrote it). Add no default.
- **A terminal without `name`:** same.
- **Tests that build JSON by hand** and omit a now-required key get the key, not a decoder default.
- **`SessionInfo` JSON in app tests** (`DaemonTypesTests`, `WireContractTests`) carries `active`.
- **Where a deleted test's failure mode is "old input accepted":** the behaviour is deleted; no survivor is needed.
  Where it also checked current behaviour (the status-line install test keeps writing `statusline-original.cmd`),
  keep that half.

## Tests

Delete (behaviour deleted unless a survivor is named):
- `KeychainTests`: the two separate-items tests. Survivors for the one-item rules: `everySecretLivesInOneItem`,
  `theItemIsReadOncePerProcess`, `aRefusedReadIsNeverWrittenOver`. Rename `aWorkerGuardReadsSecretsWithoutMigrationOrWrites`
  to `aWorkerGuardReadsSecretsWithoutWrites` and delete its assertion, if it has one, that a per-key item is read.
- `AiTermPathsTests`: every test of `migrateSupportDirectory`; keep tests of the other path functions.
- `HookConfigTests`: `anOldJSONRecordIsMigratedAtLaunchWithoutAnInstall`; in the install test, the lines about the
  legacy file and its `.json` removal (keep the `.cmd` write, rewrite, and removal assertions);
  the three last lines of `installRecordsTheShimsPortAndNeverMigratesTheDataFolder` and rename it
  `installRecordsTheShimsPort`; `testRetiredPreToolUseHookIsRemovedButForeignOnesStay`.
- `SheetPreparationTests.theLaunchProbeMigratesAnOldStatusLineRecord`: keep a version that proves the launch probe
  records the hook port (the other half of that test), without the status-line record.
- `BackpackSettingsTests`: the `backpack.pushes` removal test.
- `ModelsTests`: the single-`jiraProject` load test; the flat-`projects` test. `StateStoreTests`:
  `testLegacyFileOnDiskLoadsAndSavesAsItems`. Add one `ModelsTests` case: a workspace holding an old `projects` key and
  no `items` loads with an empty list and writes the `projects` key back unchanged (preserved), pinning the forward rule.
- `SignalAgentChoiceTests.blocksSavedByAnEarlierBuild...`.
- `DaemonTypesTests`: the bare-string `BackgroundJob` case and the "older daemon omits `active`" case.
- `JiraClientTests` (about 439-440 and 537) and `ReviewThreadsReaderTests` (no-`/-/` URL): delete; rewrite the 439-440
  pages to carry `isLast` if the test is about something else.

`operator-signals/state.json`, `daemon/tests/wire/` and `compat/` must not change in this step (check
`git status`).

## Proof

`scripts/test.sh swift -- --filter KeychainTests`, `AiTermPathsTests`, `HookConfigTests`, `BackpackSettingsTests`,
`ModelsTests`, `StateStoreTests`, `SignalSavedFormatTests`, `SignalAgentChoiceTests`, `SignalSessionKeeperTests`,
`SignalOperatorLifetimeTests`, `DaemonTypesTests`, `WireContractTests`, `DaemonOperatorWireTests`, `JiraClientTests`,
`SignalSourceTests`, `ReviewThreadsReaderTests`, `SheetPreparationTests`; from `daemon/`
`.venv/bin/pytest -k "operator or wire"`; then plain `scripts/test.sh` in the background. No snapshot capture (no
view changes).

## Done when

- `grep -rnE "separateAccounts|moveSeparateItems|migrateSupportDirectory|legacyStatusLineOriginalURL|StatusLineOriginal\.migrate|retiredEvents|Key\.retired|normalizeEarlierChoiceBlock|earlierChoiceReasons|jiraProject\b" app/Sources app/Tests`
  returns nothing (the `jiraProject` pattern may still hit unrelated Interface-setting names: check each).
- `grep -rnE "too old to send|older helper|older daemon|Older helpers|Older daemons" app/Sources` returns nothing.
- `grep -n "generation: int | None\|generation is not None" daemon/aitermd/operator_mcp.py daemon/aitermd/operator_session.py`
  returns nothing.
- `operator-signals/state.json`, `daemon/tests/wire/` and `compat/` unchanged.
- Plain `scripts/test.sh` green; the report lists each deleted test and why, and which Planner points held.

## Not in this step

- The Fix folder and `HelpWithProblems`: 1i. The `retired:` key sets and the eval baseline: 1a. Wire fields,
  slash tracking, requests: 1g. `runId`: 1j.
- The helper-adoption machinery (`.adopted`, held status, mismatch hold, unreadable-line limiter): 6b.
- Codex config editor simplifications and the model fallback from the config file: 2d. Reftable and rebase-scratch
  handling: 2a. The workspace backup: 2i.
- A second look at `SessionInfo`'s remaining optional defaults: 6a and 6d restructure the payload.
