# 8h. Settings tidy

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 1i (Find a Fix and its "Help with problems" switch
are gone), 1j (comments say what the code does), 2h (the profile save that cannot fail), 8g (the Settings
model wording). Audit: SS F1, the tidy part only.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

Most of this step has landed by the time it runs. 1i deletes the "Help with problems" switch, the only
Settings control that applied at once while looking staged, and 2h makes `OperatorProfileStore.save`
non-throwing, which removes the `try?` that let Settings close as if it had saved. What is left is
checking both, finishing the copy that explained the exception, and two redundant guards. The audit's
other F1 deletions (the Keychain undo, `original`, `picked`, the Cancel size revert) belong to a Settings
window that was not chosen: each is live behaviour of a sheet with Save and Cancel, so this brief keeps
them.

## Why

Settings is a sheet with Save and Cancel, and it stays one. While Find a Fix existed, one of its switches
saved on every toggle while looking exactly like the staged switches beside it, so the Agents tab had to
say that Cancel does not undo it, and the Operator profile's write could fail silently behind a `try?`.
With the switch gone and the write unable to fail, every switch and field in Settings is staged until
Save; only the actions that say so (Install, Repair, Run check, the Mac card's Allow… and Remove) and
the sidebar size preview apply at once. The end state is code and copy that say exactly that, with no
path left for a case that no longer exists.

## Today

As the code stands after 1i, 2h and 8g (re-check each with the greps):

- `app/Sources/AiTerm/Operators/OperatorSettingsModel.swift`, `save()`: `guard isLoaded, let original`,
  then fills an empty model from `original`, then writes when the profile changed. After 2h its `write`
  closure should be non-throwing and the "One that could not be written is still a change to save"
  guard gone: `grep -n "try?\|throws" app/Sources/AiTerm/Operators/OperatorSettingsModel.swift app/Sources/AiTermCore/Operators/OperatorProfileStore.swift`.
  `isLoaded` and `original` are set together in `received(_:)`, so either says the profile was read.
  The header comment still cites "spec §8". Called by `SettingsView.save()`; tests in
  `OperatorSettingsPaneTests` (`savesTheProfile`, `cancelDiscards`, `anEmptyModelIsNeverSaved`).
- `app/Sources/AiTerm/HarnessSettingsModel.swift`, `save()`: saves an agent's default only when
  `picked`, `loaded`, the snapshot is fresh and lists the model. `picked` is only ever inserted by
  `select` and `selectReasoning`, which need the agent's snapshot, which only `accept` sets, which also
  inserts into `loaded`: so `loaded.contains(agent)` in `save()` never decides anything. `loaded` stays
  for `install`. The `load(_:)` comment still names New Broadcast. Tests: `HarnessSettingsModelTests`.
- `app/Sources/AiTerm/Views/HarnessSettingsPane.swift`, the closing `HelpText` of the Agents tab: its
  last sentence was "The install and Help with problems both take effect immediately; Cancel does not
  undo them." 1i may have shortened it; check with `grep -n "Cancel does not undo" app/Sources`.
- `app/Sources/AiTerm/Views/SettingsView.swift`: the doc comment on `agents` ("The Agents tab's fixer
  choice and the CLIs it can choose from") and on `save()` ("the next broadcast").
- `app/Sources/AiTerm/AgentIntegrations.swift`: comments on `operatorProfile` ("a broadcast freezes it
  as it starts, and every Fix runs at its model and reasoning") and `taskModel` ("a Fix runs at the
  Operator's own").
- `docs/configuration.md`, first paragraph; `docs/keyboard.md`, Settings and alerts, first paragraph.
- Re-run: `grep -rn "Help with problems\|helpWithProblems\|broadcast\|Broadcast\|a Fix\|fixer\|spec §" app/Sources/AiTerm/Views/SettingsView.swift app/Sources/AiTerm/Views/HarnessSettingsPane.swift app/Sources/AiTerm/Views/OperatorSettingsPane.swift app/Sources/AiTerm/Operators/OperatorSettingsModel.swift app/Sources/AiTerm/HarnessSettingsModel.swift app/Sources/AiTerm/IntegrationSettingsModel.swift app/Sources/AiTerm/AgentIntegrations.swift docs/configuration.md docs/keyboard.md`.

## Change

1. The Operator profile save cannot silently fail. If the first grep above still shows a `try?` or a
   throwing `write`, make `OperatorProfileStore.save` non-throwing (its encoding of strings and booleans
   cannot fail), make `OperatorSettingsModel`'s `write` closure non-throwing, and write without a
   guard. Then reduce `save()`'s first guard to `original` alone: it is set exactly when the profile
   was read.
2. `HarnessSettingsModel.save()`: drop `loaded.contains(agent)` from its condition. Keep the other
   three conditions.
3. The Agents tab's closing help ends: "Install and Run check take effect immediately; Cancel does not
   undo them." The sentences before it stay as they are.
4. `docs/configuration.md`, first paragraph after the opening one: "**Save** applies every switch and
   field in Settings. Installing, repairing and **Run check** take effect immediately; **Cancel** does
   not undo them. Sidebar size previews immediately, and Cancel restores its previous size. The Mac
   card's **Allow…** and **Remove** permission actions also apply immediately."
5. `docs/keyboard.md`, Settings and alerts, the sentence after the Command-1 to Command-4 line:
   "Settings stages every switch and field until Save; Install, Repair, Run check, the Mac card's
   Allow… and Remove, and the sidebar size preview apply at once."
6. Rewrite the comments listed under Today to say what the code does now: `agents` is "where the
   Agents tab reads the installed CLIs and Claude's configuration path"; `save()` validates the
   integrations before committing the Operator's profile and the agents' defaults, so a refused save
   changes nothing those read; `operatorProfile` is "read by the Operator for its next session";
   `taskModel` drops the Fix clause; `OperatorSettingsModel`'s header drops the spec reference;
   `HarnessSettingsModel.load(_:)` says New Signal probes only the agents it may use.

## Keep

- `IntegrationSettingsModel`'s all-or-nothing save with its undo of earlier cards (`PendingWrite.undo`):
  with Settings a sheet, Cancel promises that nothing changed, and a refused Keychain write after an
  earlier card's write would otherwise leave half a save. The audit dropped it only for a Settings
  window.
- `OperatorSettingsModel.original`: Save writes only a change, so a profile never saved keeps following
  Claude's default from Settings › Agents (`savesTheProfile`).
- `HarnessSettingsModel.picked` and `loaded`: only a picked default is saved, else a resolved default
  would be pinned; `loaded` decides how `install` resolves.
- `SettingsView.cancel()` putting back the opening size, `saveInterface()`, `pickInterfaceSize(_:)`:
  the size preview and its revert are the listed exception.
- `ServiceTestRecord`, `SettingsTab.opening`, `TabShortcuts`.
- `OperatorSettingsModel.load()` beside `loadIfNeeded()`: tests and snapshots hand in a loaded model.

## Decisions already taken

- Save pressed before the Operator profile has loaded writes nothing: the Operator tab draws nothing
  until it loads, so there is no edit to lose. No message.
- No new message for a failed profile write: after action 1 there is no failure to report.
- The defaults key `operator.helpWithProblems` may still be in a person's defaults: it is unread and
  stays; no cleanup code.

## Tests

- No test is deleted. If action 1 changed signatures, `try` goes from the `OperatorProfileStore.save`
  calls in `OperatorSettingsPaneTests`, `SignalFreshSessionTests`, `OperatorProfileStoreTests` and any
  other caller the compiler names.
- No new behaviour: no new test. `HarnessSettingsModelTests` must pass unchanged after action 2.

## Proof

- `scripts/test.sh swift -- --filter OperatorSettingsPaneTests`, `HarnessSettingsModelTests`,
  `OperatorProfileStoreTests`, `SettingsToggleLayoutTests`, `SheetDismissalTests`.
- `scripts/snapshots.sh` before and after: only `settings-agents.png` may differ, in its last help line.
- Plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "Help with problems\|helpWithProblems" app/Sources docs/configuration.md docs/keyboard.md README.md`
  returns nothing.
- `grep -n "try?" app/Sources/AiTerm/Operators/OperatorSettingsModel.swift` returns nothing, and
  `OperatorProfileStore.save` does not throw.
- `grep -n "loaded.contains" app/Sources/AiTerm/HarnessSettingsModel.swift` shows only `install`.
- The suites above and plain `scripts/test.sh` are green.

## Not in this step

- A Settings window, per-card connect, applying preferences on change (SS F1's main proposal): left out
  by the maintainer's choice.
- The unavailable-model wording in Settings: 8g. The agent table: 8i.
