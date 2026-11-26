# Update scripts: versioned workspace, no compatibility code

## Context

AiTerm's saved workspace (`~/Library/Application Support/AiTerm/state.json`) has no version. Code
spread through the decoders handles format changes in two directions:
- **Backward:** defaults for keys older builds left out, legacy key names, the 0.58 Operator reset.
- **Forward:** `PreservedFields`, `.unknown` enum cases and `UnknownSidebarItem`, so an older build
  can open a newer workspace.

The maintainer wants neither. Instead:
- state.json carries a version.
- A new build compares it with its own and runs **update scripts** in order, so skipped versions run
  every step in between.
- Incompatible changes ship only as a major version.
- Compatibility is one-way: an older build refuses a newer workspace.
- The update shows in the existing "Downloading" panel (`UpdateProgressPanel`).

Decisions already made:
- Remove backward- **and** forward-compat.
- Scripts are Swift steps compiled into the app.
- A state.json without a version counts as 1.5.0, and the 0.58-era reset is dropped. Users on a
  version before 1.0 install 1.5.0 first.

Before slice 1, copy this plan to `docs/plans/2026-11-26-update-scripts.md`, the repo convention that
psg:implement reads.

## Version semantics

The value stored is the AiTerm version of the newest update script the workspace has been through,
not the running bundle's `CFBundleShortVersionString`. This is a deliberate refinement of "store
the AiTerm version", for two reasons:
- Dev builds report 0.1.0 and `swift run` has no version at all. `run-dev.sh` shares state.json with
  the installed app.
- Minor and patch releases never change the format.

So the stamp only ever reads `1.5.0` or `N.0.0`.

How it works:
- **The build's own value:** `UpdateScripts.current = UpdateScripts.all.last?.version ?? 1.5.0`,
  compiled in.
- **At launch:** `WorkspaceUpdater.plan()` reads the raw file and decides:

  | state.json | Result |
  |---|---|
  | No file | Fresh install. Nothing runs, and the first save stamps `current`. |
  | No file, but a backup exists | The existing `missingPrimary` → Restore flow, then plan again. |
  | `version` missing | Treated as 1.5.0. |
  | `version` invalid | Error in the existing Retry/Restore/Reveal/Quit alert. |
  | Equal to `current` | Load. |
  | Lower than `current` | Run the scripts with `stored < v ≤ current`, in order. |
  | Higher than `current` | Refuse: "This workspace was saved by AiTerm X. Install X or newer." Buttons: Reveal / Quit. |

- **Running the chain:**
  - Before the first script, copy the file to `state.json.before-update-<stored>`. Never overwrite
    an existing copy: it is the original.
  - After each script, write the file atomically stamped with that script's version, so a crash
    resumes at the next script.
  - Side effects outside state.json (UserDefaults, files) must be idempotent.
- **Saves:** `StateStore.save` always stamps `current`. `StateStore.load` refuses any other version,
  so a build only saves a workspace in its own format and can never lower the stamp.
- **Restore Backup:** it only copies bytes now. `prepareWorkspace` loops back through
  update → load, because a backup can be from before the update.
- **`hasValidBackup`:** the backup parses and its version ≤ `current`. When the version equals
  `current`, it must also decode.

## Design

**Core**, in `app/Sources/AiTermCore/Updates/`, next to `ReleaseVersion`:
- `UpdateScript.swift`:
  - `UpdateScript { version: ReleaseVersion; summary: String; run: @Sendable (inout UpdateContext) throws -> Void }`
  - `UpdateContext { var state: JSONValue; defaults: UserDefaults; supportDirectory: URL; home: URL }`
- `UpdateScripts.swift`: `all`, `baseline` (1.5.0) and `current`. A test asserts that `all` is
  strictly ascending, that every entry is `N.0.0`, and that every entry is newer than `baseline`.
- `WorkspaceUpdater.swift`:
  - `plan() throws -> .upToDate | .update(from:steps:) | .newer(ReleaseVersion)` and `run(...)`.
  - The scripts and `current` are injectable for tests.
- `JSONValue+Editing.swift`: a setter subscript and an "update each at path" helper, on the
  existing `JSONValue`.
- The stamp stays out of `AppState`. A private `SavedWorkspace` envelope in `StateStore` encodes
  `version` and then `AppState` into the same container.
- `Scripts/Update2_0_0.swift`: the first script (below).

**App**, in `app/Sources/AiTerm/AiTermApp.swift`:
- Between `updates.finishPreviousUpdate()` and loading the workspace, run the updater when it has
  steps:
  - Show `UpdateProgressPanel.show("Updating your workspace for AiTerm X…")`.
  - Run the scripts on a `Thread` or `BackgroundWork`. The main thread waits in a modal session,
    so the spinner animates and launch stays sequential.
  - If a script fails, show an alert with the error and Reveal / Quit. The before-update copy is
    kept.
- Build `AppController` after the update step, because scripts may change UserDefaults that
  `InterfacePreferences` reads at construction. `UpdateController` and the updater get a
  `ModalPrompter` of their own, so `finishPreviousUpdate()` does not force the controller early.
- On a `BuildChannel.dev` build with steps pending, ask first: "the installed AiTerm can't open it
  afterwards".
- Add `AiTerm --workspace-format`, which prints `current`, beside `--worker-guard` in `main()`.

**Release guard** in `scripts/release.sh`, after `make-app.sh`: read `--workspace-format` (F) and
require:
- F ≤ the version being released;
- if F is newer than the latest tag, then F == the version being released, i.e. the version is that
  major's `.0.0`.

## First script: 2.0.0 (raw JSON from 1.5.0)

**Top level:**
- Remove `signalDividers` and the pre-items `projects` key.
- Fill missing values: `items`, `tasks`, `terminals`, `archive`, `signals`, `signalSeen`,
  `scheduleCursors` and `operatorFolded` become `[]`; `operatorOpen` becomes `false`.
- Drop `lastAgentByProject` and `lastModelByAgent` pairs whose agent is not claude, codex or pi.

**Each task**, in `tasks[]` and `archive[].task`:
- Set `kind` to `"task"` when missing.
- Set `takenOver` to `false` when missing.
- Set `conversations` to `[]` when missing. Drop entries with an unknown agent, or an id that is
  empty or starts with `-`.
- Set `jira.source` to `{"jira":{}}` when missing.
- An agent that is not claude, codex or pi (Grok) becomes `claude`, with `model: ""` and no
  `reasoning`.

**Signals:** set `kind` to `"operator"` when missing, on every copy of a signal:
- `signals[]`
- `signalTask.current.configuration`
- `signalTask.pendingStages[].configuration`
- `signalTask.previousStage.stage.configuration`

**`operatorSession.oracleRounds[]`:**
- Change `stage` from `"unchallenged"` to `"unanswered"`.
- Rename the key `unchallengedReason` to `unansweredReason`.
- Drop the legacy raw names at `Operators/OperatorModels.swift:71,75`.

The decoders then require every key the encoder writes:
- No `decodeIfPresent ?? default` and no "left out while empty / as it always was" encoding remain
  in `AppState`, `TaskItem` or `JiraRef`.
- `Signal.kind` becomes non-optional.

These stay optional, because nil carries meaning:
- `sidebarFrame`, `operatorSession`;
- the task's `jira`, `mr`, `reasoning`, `firstPrompt`, `windowId`, `signalTask` and `signalOrigin`;
- `remoteUrl`, `scheduledFrom`.

## Removals

**0.58 Operator reset:**
- In `StateStore.swift`: `OperatorRecordsReset`, `decodeClearingOperatorRecords` and
  `clearedOperatorRecords`, plus the doc comment.
- The toast at `AiTermApp.swift:71`.
- `StateStoreUpgradeTests.swift` and the fixtures `state-0.58.json` and `operator-session-0.58.json`.
- `scripts/reset-operator-state.sh` and its test, plus the references in `scripts/test-routes.tsv`,
  `test-test-select.sh`, `test-swift-toolchain.sh` and `scripts/README.md`.

**Forward-compat:**
- In `SavedEnums.swift`: `OpenStringEnum` goes, and its enums become plain `String` enums.
  `KindTaggedEnum` loses `.unknown` and `preservesInvalidValue`.
- In `Models.swift`:
  - `PreservedFields`, `UnknownSidebarItem` and `SidebarItem.unknown`/`isDrawn`.
  - `TaskItem`'s `preservedFields`, `savedKind`, `unrecognizedAgent` and `SavedConversation`.
  - `AppState`'s `SavedAgent`.
  - `LenientRawDecodable` on `Provider` and `TaskKind`. The protocol stays for daemon messages.
- `OperatorSession.Lifecycle.unknown`, and the unknown checks in `Signal.isValid`.
- Every caller that switches on those cases (about 30 sites: SidebarModel, OperatorSession,
  SignalTrigger, MatchDecision, QueryWriter, SignalTriggerStep, SignalDoneStep, ItemRouter,
  TaskLauncher:325, AppState+Conversations:41-44 and others).
- The UI copy "Not supported by this version".
- **Keep** `DaemonEvent.unknown`, `InputState.unknown` and the `SessionAgent`/`SessionState`
  tolerance: those cover app↔helper messages, not saved data.

- A `TaskPhase` `{"kind":"stopped"}` is not converted. That phase was retired before 1.0, and a real
  1.5.0 workspace checked during the build held none.
- "This version cannot run this signal." in the Signals sheet becomes "This signal can’t run as it is
  set up.": an invalid signal is now only one whose settings conflict.

**Behaviour that changes beyond decoding:**
- An unreadable lifecycle fails the load.
- Sidebar moves no longer skip undrawn rows.
- A former Grok task resumes its Claude conversation, on its defaults.

**Leftovers:**
- `daemon/aitermd/models.py:359-361`: make `terminal_id` required, after checking that the app
  always sends it. App and daemon ship in one bundle.
- The stale comments at `Hooks/ShimPort.swift:19-20` and `AiTermApp.swift:48-50`. The width clamp
  itself stays.
- The "legacy header" case in `HookConfigTests`.

**Out of scope:**
- The `compat/` CLI checks.
- The Settings › Agents "Outdated → Repair" detection of the Claude, Codex and PI integration
  files. That is a runtime health check of files the user can edit, not a reader for saved data.

## Tests and goldens

- `Operators/Fixtures/operator-signals/state.json` is byte-identical to v1.5.0, so:
  1. `git mv` it to `app/Tests/AiTermCoreTests/Updates/Fixtures/state-1.5.0.json` and freeze it.
  2. Re-record `state.json` with `AITERM_RECORD_SIGNAL_STATE=1`.
  3. Read the diff. It may only add `version`, the task `kind`, the Jira `source`, the signal
     `kind`s, and the empty collections and false flags.
  4. Record it in `PROVENANCE.md` as the deliberate 2.0.0 format change. CLAUDE.md forbids
     regenerating goldens only for an incidental refactor; this one is intended.
- Proof: 2.0.0 applied to `state-1.5.0.json`, then `StateStore.load`, must equal the state
  `SignalSavedFormatTests` builds, and the bytes must match the new `state.json`. Move that builder
  into a shared helper.
- `Update2_0_0Tests`: one inline 1.5.0 workspace that covers Grok, `signalDividers`, `projects`,
  an unchallenged round, Jira and GitLab refs, and a missing kind or conversations.
- `WorkspaceUpdaterTests` with injected scripts:
  - running in order;
  - skipping from 1.5.0 straight to 4.0.0;
  - resuming after a script throws;
  - the before-update copy kept and never overwritten;
  - a newer stamp refused;
  - a missing version treated as 1.5.0;
  - a fresh install;
  - Restore Backup of an older backup.
- `StateStoreTests`: "no envelope" (line 225) becomes "stamped `current`"; a different stamp is
  refused.
- Delete: `SignalForwardCompatibilityTests`; the unknown, preserved and Grok tests in
  `ModelsTests`; the newer-build cases in `SignalKindFormatTests` and `SignalScheduleFormatTests`.
- Register `Update2_0_0Tests` as a fixture reader in `scripts/test-routes.tsv`, where
  `StateStoreUpgradeTests` was. The folder is already routed by `app/Tests/AiTermCoreTests/*`.

## Docs

- `docs/workflow/release.md`: "Operator format" becomes "Workspace format and update scripts":
  - any change to the saved workspace adds an update script and ships as its major `.0.0`;
  - `release.sh` enforces this;
  - no going back.
- `docs/architecture.md` (Workspace and observation, lines 30-38), `docs/operators.md:521-524` and
  `scripts/README.md`.
- `docs/release-notes/2026-11-update-scripts.md`, the 2.0.0 note:
  - the update runs once at first launch, with the panel;
  - a copy is kept as `state.json.before-update-1.5.0`;
  - installs from before 1.0 install 1.5.0 first;
  - never open the workspace with 1.x afterwards. 1.5.0 would save it in a shape 2.x refuses;
    restore the before-update copy by hand.
- `2026-11-signals-by-section.md` ships in this same release (its change is after `v1.5.0`): its
  "dividers stay" and its older-build warning now point at the update.
- A CLAUDE.md invariant: "A saved-format change ships with an update script in
  `AiTermCore/Updates/Scripts/` and a major version; no decoder reads an older or newer format."
  Edit the original file, not the symlink.

## Slices (each green under `scripts/test.sh`, one commit each)

1. Drop the 0.58 reset and the reset script. Done when the gate is green.
2. Update machinery with no scripts (`current` = 1.5.0, format unchanged): the Core types and tests,
   the app wiring (panel, controller built after the update, refusal alert, Restore → update → load,
   dev confirmation), `--workspace-format` and the `release.sh` guard.
3. Workspace 2.0.0: the script, the stamp and its check, strict decoders, the OracleRound names,
   the fixture move and re-record, and the docs and release note.
4. Forward-compat removal across Core and App. The saved format is unchanged, so the golden must
   not move.
5. Leftovers: the daemon's `terminal_id`, comments, the legacy-header test.

## Verification

- `scripts/test.sh` after each slice. Before merging: `scripts/test.sh all` plain, or the
  test-history `require-full` check in `docs/workflow/project.md`.
- `scripts/make-app.sh && scripts/test-app-bundle.sh build/AiTerm.app`, then
  `build/AiTerm.app/Contents/MacOS/AiTerm --workspace-format` prints `2.0.0`.
- Dry-run the `release.sh` guard logic: F=2.0.0 against 1.6.0 must be refused, and against 2.0.0
  accepted.
- `scripts/snapshots.sh`, before and after, for the panel text and the changed UI copy.
- Live check, by the maintainer and not by agents:
  1. Copy a real 1.5.0 `state.json` aside.
  2. Launch the dev build with `scripts/run-dev.sh` and confirm the dev prompt.
  3. Watch the "Updating your workspace for AiTerm 2.0.0…" panel.
  4. Check that the workspace is intact and `state.json.before-update-1.5.0` exists.
