# 8g. Sheet fixes

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 8f (`SteppedSheet`, `Step`, the `notices` slot,
`CreationNotices`), phase 1, 2b (sheets ask git for the default branch when they open) and 2h (its
guards behind controls that cannot send the input are gone). Audit: SS F5, F6, F10, F12, F13, F15.

## Why

Seven small things in the creation sheets make a person guess. New Signal checks every installed agent
and silently disables Create while it reads or while an agent it will never use is unready; that gate
came from broadcasts' Start button, and Switch On never had it. Every New Task and New Review warns in
amber that PI is not installed, about an option the agent menu does not even show. A saved model that is
no longer offered reads three different ways, and New Signal's Agents step can disable Continue with
nothing said. Add Project asks for the folder twice and validates a typed path nobody types. New Task's
Base branch is a pop-up of every branch, while New Review already filters the same list. And New Review's
ticket field can take a late search answer after a pick because `DebouncedSearch` carries a second,
older cancel rule. The end state: each of these says one true thing once, as the actions below spell out.

## Today

As the code stands after 8f:

- `app/Sources/AiTerm/Operators/SignalReadiness.swift`, `SignalReadiness.of(installed:snapshots:messaging:iterm:)`:
  every installed agent of `ModelChoice.pair`; title "Not ready to start". Read by
  `AppController.signalReadiness` (`AppController+Operators.swift`), which `presentNewSignal`
  (`AppController+Signals.swift`) hands to `SignalModel` twice: `ready:` (part of
  `canAdvance(step: 5)`) and `readinessLines`. `SignalSheet` draws the lines as a `Notice` in its
  notices on every step. Tests: `SignalReadinessTests`, `SignalModelTests`.
- `app/Sources/AiTerm/Views/Steps/AgentStep.swift`: `missingAgentNote(available:)` drawn in amber under
  the fields whenever any agent is missing; `CreationNotices` (`Views/CreationParts.swift`) draws it again
  as a `Notice` on the agent step when none is installed. Tests: `NewReviewSheetTests`.
- Missing models: `ModelReasoningFields` draws a placeholder "Choose a current model…" (today
  `missingModelLabel`, a parameter no caller sets, unless phase 1 folded it). `CreationModel.loadAgentCatalogue`
  blanks the draft's model when `ModelSettings.resolution` says `.missing`, so New Task and New Review
  lose the id. Settings › Agents: `HarnessCardPresentation.modelOptions` adds "Unavailable: <id>" and
  the pane says "Choose a current model to replace the unavailable default."; `HarnessSettingsModel`'s
  check says "The selected model is no longer available.". Settings › Operator:
  `OperatorSettingsModel.options(_:keeping:reasoning:)` offers the id labelled by itself, silently.
  New Signal's rows: `SignalModel.canAdvance(step: 4)` also needs each row's reasoning to be one of its
  model's levels, while `ModelReasoningFields` displays a valid fallback, so Continue is disabled with
  nothing said.
- `app/Sources/AiTerm/ProjectSheetModel.swift` and `Views/ProjectSheet.swift`: Add Project shows an
  editable monospaced Folder `Input` with Choose…, and `folder`, `validatedFolder`, `inspection`,
  `validating` and `inspectFolder()` behind a 250 ms `.task(id: folder)`. The panel already ran once
  before the sheet opened (`SheetCoordinator.presentAddProject`). Tests: `ProjectSheetModelTests`,
  `ProjectSheetPickerTests`.
- `Views/NewTaskSheet.swift`, `NewTaskFirstStep`: Base branch is `Select(values: choices ...)` over
  `model.branches`. New Review's Branch is a `BranchInput` over `branchQuery`/`branchMatches`, which live
  on `ReviewCreation` (`ReviewCreationModel.swift`, `filterBranches`, `filteredBranches(query:)`,
  `branchesChanged`).
- `app/Sources/AiTerm/DebouncedSearch.swift`: `Superseding` with `.everySearch` and `.typedSearchOnly`;
  only `ReviewCreation.ticketSearch` uses the second, whose `cancel()` does not bump the generation, so
  the opening `searchTickets(text: "")` answer lands after `pickTicket` cancels. Tests:
  `DebouncedSearchTests`, `ReviewTicketFieldTests`.
- Re-run: `grep -rn "SignalReadiness\|readinessLines\|missingAgentNote\|missingModelLabel\|Choose a current model\|modelOptions(\|OperatorSettingsModel.options\|inspectFolder\|validatedFolder\|Superseding\|typedSearchOnly" app/Sources app/Tests`.

## Change

1. **Readiness is advice for the signal's own rows.**
   - `SignalReadiness.of` takes the signal's agents first: `of(agents:installed:snapshots:messaging:iterm:)`.
     Claude Code not installed: the one line "The Operator needs Claude Code. Install it in Settings ›
     Agents." as today. Otherwise one line per agent of `agents` (distinct, in `ModelChoice.pair` order)
     that is installed, in its card's words as today; an agent the rows name but this Mac lacks is left
     to action 4. iTerm2's line as today. `checking`, `ready` and `notReady` keep their meaning.
   - `SignalReadiness.title` becomes "Fix this before its tasks start". Add `SignalReadiness.checkingTitle`,
     "Checking agents…".
   - `AppController.signalReadiness` becomes `signalReadiness(for:)`, taking those agents.
   - `SignalModel`: delete the `ready` parameter and property; `canAdvance(step:)` ends with "step 4,
     or the finish is valid for the source", with no readiness in it. Replace `readinessLines` with
     `readiness`, a closure from agents to `SignalReadiness` (default: always ready), which
     `presentNewSignal` sets to the controller's `signalReadiness(for:)`.
   - `SignalSheet`'s notices, after the failure: while checking, a `Notice` titled "Checking agents…"
     with no description; while not ready, a `Notice` titled "Fix this before its tasks start" with the
     lines as its description; nothing while ready. It asks with the distinct agents of `model.agents`.
   - Rewrite `SignalReadiness`'s doc comment to say what the sheet advises about, with no broadcast.
   - `docs/operators.md`, after the five steps: "While an agent the signal may use isn't ready, a note
     above the buttons says what to fix; you can still create or save the signal."
2. **The "isn't installed" note, once, only when no agent can run.** Replace
   `AgentStep.missingAgentNote(available:)` with `AgentStep.noAgentNote`, built from every agent's display
   name: "Claude Code, Codex and PI aren’t installed. Install them in Settings › Agents." `AgentStep` draws
   it in amber only while `availableAgents` is empty. Delete the agent-step `Notice` from
   `CreationNotices`; the footer no longer repeats it.
3. **One wording for a saved model that is no longer offered.**
   - `ModelReasoningFields`: when `model` is not among `models`, its placeholder row reads
     "Unavailable: <model>", or "Choose a model…" when `model` is empty. Delete the `missingModelLabel`
     parameter if it is still there. Add `ModelReasoningFields.unavailableHelp`: "A model marked
     Unavailable is no longer offered. Choose a current one."
   - `CreationModel`: add `unavailableModel` (read-only outside), set in `loadAgentCatalogue` to the
     saved model's id when the resolution is `.missing`, and to nil for every other outcome. The draft
     keeps its blank model, so nothing unavailable can reach a launch.
   - `AgentStep`: show the draft's model when the catalogue lists it, else `unavailableModel` when set;
     while the shown id is not listed and not empty, draw `unavailableHelp` in amber under the fields.
   - Settings › Agents (`HarnessSettingsPane.defaults`): delete `HarnessCardPresentation.modelOptions`;
     pass the catalogue and the saved preference's id; replace "Choose a current model to replace the
     unavailable default." with `unavailableHelp` in amber. In `HarnessSettingsModel.applyingSelection`
     the check's explanation becomes "The default model is no longer offered."
   - Settings › Operator (`OperatorSettingsPane`'s `ModelFields` and `OracleGroup`): delete
     `OperatorSettingsModel.options(_:keeping:reasoning:)`; pass the catalogue and the saved id, and pass
     no reasoning options while the id is not listed (the Reasoning field is then not drawn); draw
     `unavailableHelp` in amber under the Operator's fields and under the Oracle's fields when their id is
     not listed. `OracleGroup` draws its "no models" line only when the catalogue is empty and no id is
     saved. Keep `OperatorSettingsModel.efforts(of:keeping:)`.
4. **A visible reason for a disabled Continue on New Signal's Agents step.**
   - `Step` gains `whyNot`, an optional sentence. `SteppedSheetFooter` draws it first in its notices,
     as `HelpText` in amber, while the step cannot advance and no create runs.
   - `SignalModel.agentsWhyNot`, the first that applies, in row order: no rows, "Add an agent."; a row
     whose agent is not in `offeredAgents`, "<Agent> isn’t installed. Choose another agent for its row,
     or remove it."; a row whose model its agent's catalogue does not list, `ModelReasoningFields.unavailableHelp`.
     Nil otherwise. `SignalSheet` passes it on step 4 only.
   - `SignalModel.init`: for each loaded row whose model is listed but whose reasoning that model does
     not offer, take the model's level as `ModelPreference.select` does, so what the row shows is what
     it saves. `canAdvance(step:)` keeps its rule.
5. **Add Project shows the chosen folder as a line with Choose….**
   - `ProjectSheet`, adding: the Folder field holds one row, the folder's path (`preparation.project.path`)
     in `Typography.monoCode` and `Palette.text`, one line, cut in the middle, the full path as its
     tooltip, filling the row, then the existing Choose… button. Under it, as today: "Reading the
     folder…" while preparing, the error in amber, else "<provider> · <default branch or "No default
     branch yet">".
   - `ProjectSheetModel`: delete `folder`, `validatedFolder`, `inspection` and `inspectFolder()`;
     rename `validating` to `preparing`. `chooseFolder()` runs the panel; a cancelled panel changes
     nothing; a picked folder sets `preparing`, clears the error, calls `inspect` with the path, and on
     success replaces `preparation` and resets `importWorktrees` to its `canImport`; on failure keeps the
     previous preparation and shows the error. `canSave` is the workspace can change, not saving, not
     preparing. Choose… is disabled while preparing or saving.
   - Delete the `.task(id: folder)` debounce from `ProjectSheet`.
   - `docs/keyboard.md`, the Command-P row: "Asks for the folder, then opens one sheet for its Jira
     links and worktree import; Choose… there picks another folder."
6. **Base branch is the filtered field New Review uses.**
   - Move `branchQuery`, `branchMatches`, `filterBranches()` and `filteredBranches(query:)` from
     `ReviewCreation` to `CreationModel`, filtered when the query or the branch list changes. Delete the
     `branchesChanged` hook from `CreationKind` once nothing else uses it.
   - `BranchInput` takes a placeholder, default "feat/my-task".
   - `NewTaskFirstStep`'s Base branch: a `BranchInput` with placeholder "main", text bound to
     `draft.baseBranch` (setting it also sets `branchQuery`), its own open state held by `NewTaskSheet`,
     choices `model.branchMatches`, in the same 190 pt column. Its help is "The branch it starts from.",
     or in amber "That branch doesn’t exist in this repository." once branches are loaded and a
     non-empty base is not among them. Delete `choices`.
   - Step 1's `closeList` closes the ticket list, then the base list; leaving the step closes both.
   - `NewTaskSheet.canAdvance` also needs a non-blank base branch.
7. **One cancel rule in `DebouncedSearch`.** Delete `Superseding`, its parameter and property. `cancel()`
   always cancels the typed search, bumps the generation and drops `typed`, so an answer that lands after
   any cancel is dropped. `ReviewCreation.ticketSearch` uses the plain initialiser. Fix the comments that
   name the second rule.

## Keep

- The readiness probes when New Signal opens (`checkSignalReadiness`) and the delivery check where AiTerm
  types into a worker: messaging is still checked where it matters.
- `ModelSettings.resolve` returning an empty model for a missing default: an unavailable id must never
  reach a launch command.
- `OperatorSettingsModel.save` never writing an empty model, and `efforts(of:keeping:)` for a saved
  reasoning level a listed model no longer names.
- New Review's soft "That branch doesn’t exist" warning: the listing is local plus fetched origin refs,
  so a just-pushed branch can be missing (SS considered and kept it).
- `SheetCoordinator.presentAddProject` running the panel before the sheet, and Edit's read-only header.
- The disabled-step rule of `SignalModel.canAdvance(step: 1)` for an unsupported saved source: inert
  unknown data from a newer build.

## Decisions already taken

- Switch On keeps starting work with no readiness check: readiness is advice everywhere now.
- Rows can only name Claude Code or Codex; PI never appears in readiness.
- A row's reasoning cannot become invalid after load: model picks keep a supported level and the
  reasoning menu offers only the model's levels. No sentence for that case.
- Re-choosing the same folder prepares it again; harmless.
- A picked folder that is already a project shows "<name> is already in your projects" under the line,
  which keeps showing the previous folder; Save adds that previous folder.
- An empty base branch disables Continue on step 1; a base that is not a listed branch only warns, and
  git's own refusal at Create shows as a failure.
- Visible changes, all listed in the plan: the readiness note and its titles, the "isn't installed"
  note, the unavailable wording, the Agents reason, Add Project's folder line, the Base branch field.

## Tests

- `SignalReadinessTests`: give `of` the agents. `onlyTheAgentsTheOperatorMayPlanOnAreWaitedFor` becomes
  "only the signal's own agents are checked" (a Claude-only signal is ready while Codex is not). Keep
  `codexWorkersStillNeedClaudeForTheOperator` and `itChecksUntilEveryPieceIsRead`. Adjust
  `theControllerReadsTheCardsAndThePolicyFile` to `signalReadiness(for: [.claude, .codex])`.
- `SignalModelTests`: drop `ready:`; add "readiness never disables Create" (step 5 can advance with any
  readiness), "a row whose model is no longer offered says why Continue is disabled", "an empty Agents
  list says Add an agent.", "a saved row's reasoning its model no longer offers loads as the model's
  level".
- `NewReviewSheetTests`: `anAgentIsSelectableOnlyWhenItsCLIIsInstalled` keeps only the note: its text
  is "Claude Code, Codex and PI aren’t installed. Install them in Settings › Agents.", a hosted
  `AgentStep` with no agent installed draws it once, and one with any agent installed draws no amber
  line. `missingSavedModelDoesNotVisuallySelectTheFirstCurrentModel` expects "Unavailable: <id>" when
  given the unavailable id.
- `ReviewCreationModelTests.staleDefaultCannotCreateAReviewUntilCurrentModelIsSelected`: also expect
  `unavailableModel` is the saved id, and nil after picking a current model and reloading.
- `HarnessSettingsLayoutTests` (the `modelOptions` case) and `HarnessSettingsModelTests` (the summary
  string): the new wording. `OperatorSettingsPaneTests.aModelOffTheCatalogueIsStillOffered` becomes "a
  saved model off the catalogue shows as Unavailable and Save keeps it".
- `ProjectSheetModelTests`: delete `anOldFolderInspectionCannotReplaceTheNewerOne` (typed folders are
  the deleted behaviour). Rewrite `aLockedWorkspaceOrFailedInspectionCannotSaveAPreviousFolder` as "a
  failed choice keeps the previous folder and stays saveable; a locked workspace cannot save". Add "a
  chosen folder replaces the preparation and its import choice" and "a cancelled panel changes nothing".
- `TaskCreationModelTests`: add "the base field's list follows what is typed" and "an empty base
  disables Continue".
- `DebouncedSearchTests`: delete `theTicketFieldShowsWhatItsOwnRuleShowed`, the ticket reference model
  and `Shared`'s superseding argument (the second rule is the deleted behaviour);
  `thePickersSearchShowsWhatItsOwnRuleShowed` covers the one rule. `ReviewTicketFieldTests`: add "the
  opening ticket search answering after a pick changes nothing" with a held lookup.
- No fixture changes.

## Proof

- Before starting: `scripts/snapshots.sh build/8g-before`; at the end `scripts/snapshots.sh build/8g-after`.
  Expected differences only: `step1-*.png` (Base branch field) and `add-project.png` (folder line). Read
  them against the UI README; `cmp` the rest as identical.
- While iterating: `scripts/test.sh swift -- --filter SignalReadinessTests`, then `SignalModelTests`,
  `NewReviewSheetTests`, `ReviewCreationModelTests`, `TaskCreationModelTests`, `ProjectSheetModelTests`,
  `ProjectSheetPickerTests`, `HarnessSettingsModelTests`, `HarnessSettingsLayoutTests`,
  `OperatorSettingsPaneTests`, `DebouncedSearchTests`, `ReviewTicketFieldTests`, `SteppedSheetTests`.
- Plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "readinessLines\|missingAgentNote\|missingModelLabel\|Choose a current model\|modelOptions(\|OperatorSettingsModel.options\|inspectFolder\|validatedFolder\|Superseding\|typedSearchOnly\|no longer available\|Not ready to start" app/Sources app/Tests docs/operators.md docs/keyboard.md`
  returns nothing.
- `grep -n "ready()\|let ready\|ready:" app/Sources/AiTerm/Operators/SignalModel.swift app/Sources/AiTerm/AppController+Signals.swift`
  returns nothing.
- The suites above and plain `scripts/test.sh` are green; snapshots differ only as listed.

## Not in this step

- The frame itself: 8f. Settings' Save and Cancel: 8h. The agent table: 8i.
- Routing the assignee search through `DebouncedSearch` and naming the other pauses (SS F10, second
  part): not in the plan.
- A Settings window, or making "go to Settings" advice followable from an open sheet (SS F1): left out.
