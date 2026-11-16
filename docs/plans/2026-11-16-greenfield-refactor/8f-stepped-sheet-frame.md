# 8f. One stepped-sheet frame

Implementer: Opus 5.5, high. Depends on: phase 1 (1f deleted the dead sheet parts, 1i deleted Find a
Fix, 1j fixed the names) and 2h (New Review's "press again" recheck is gone); on the app track it runs
after phases 2 to 5 and steps 8a to 8e. Audit: SS F2, SS F3, SS F14 (plain Return in one-field sheets
only).

## Why

AiTerm has three stepped sheets: New Task, New Review and New Signal. New Task and New Review run
through `CreationSheet` over `CreationModel`; New Signal was added on 15 Nov and builds the same parts
by hand in `SignalSheet`, with its own Back, advance, list closing and dismissal, a hard-coded step
count and a different height. So the keyboard routing a person relies on is written twice, and both
copies make Escape mean Back: leaving New Signal from its last step takes five presses, and there is no
Cancel after step 1. The rename, divider and terminal sheets ask one question but ignore plain Return.
The end state: one `SteppedSheet` frame that owns the stepper, the footer buttons, the keys and
dismissal, configured by each sheet with a list of `Step`s, its height, a create action and three slots;
Cancel on every step, Escape cancels after closing an open list, and one-field sheets commit on
Return. Everything else renders the same pixels.

## Today

As the code stands when this step runs:

- `app/Sources/AiTerm/Views/CreationSheet.swift`, `CreationSheet<Kind, Content>`: used by
  `NewTaskSheet` and `NewReviewSheet` only. It draws `SteppedSheetFrame` at `Sheet.creationHeight`
  (500 pt), adds on the last step a `CreationClosingBlock` with the `DestinationLine` and "Runs <agent>
  with <model label>.", draws `CreationFooter`, starts five loads (`search(text: "")`,
  `loadAgentCatalogue` keyed by the draft's agent, `loadBranches`, `loadWorktreeIncludes`,
  `loadProjectFiles`) and cancels the search on disappear. It owns `closeOpenList` (the completion popup
  on the prompt step, the pickers on step 1 only), `navigate`, `back` (dismisses on step 1), `advance`
  (closes pickers, steps on, or creates on the last step) and `create`/`recover` (dismiss when they
  return true).
- `app/Sources/AiTerm/Views/SteppedSheetFrame.swift`, `SteppedSheetFrame`: 29 lines, a pass-through
  of `SheetLayout` with `SheetStepper` as its accessory, a `FrontToBackStack` of the content and a fixed
  height.
- `app/Sources/AiTerm/Views/SheetChrome.swift`, `CreationFooter`: the failure `Notice` (its reason as
  the title, git's detail as the tooltip), the "no agent can run" `Notice` on the create step when no
  agent is installed (`CreationSteps.saysNoAgentCanRun` and `AgentStep.missingAgentNote`), New
  Signal's readiness `Notice` (`waiting`), then a `SheetFooter` whose secondary is "Cancel" on step 1
  and "Back" after it, whose primary is "Continue" or the create label, and whose status slot holds the
  failure's recovery button (`CreationFailure.recovery`, which creates after it).
- Same file: `SheetFooter` (status slot, spacer, secondary, primary, and a hidden "Close" button with
  the cancel key that calls `closeList` first and `cancel` only when no list was open),
  `SheetPrimaryButton` (answers Command-Return only, disabled with its action), `SheetStepper` (its
  completed steps are buttons with Command-number keys when it has an `onSelect`; `canNavigate`
  allows only an earlier step).
- `app/Sources/AiTerm/CreationModel.swift`: `CreationSteps` and `CreationKind.steps` (three steps,
  agent last). Read by `CreationFooter`, `CreationSheet`, `NewTaskSheet.canAdvance` and
  `.destination`, `NewReviewSheet.canAdvance` and `.destination`, and tests.
- `app/Sources/AiTerm/Views/Operators/SignalSheet.swift`, `SignalSheet`: draws `SteppedSheetFrame` at
  `Sheet.height` (560 pt) with `CreationFooter(steps: SignalModel.steps, availableAgents: [],
  recover: {}, waiting: (SignalReadiness.title, model.readinessLines()))`; its own `closeLists`,
  `closeOpenList` (the prompt's completions, the JQL completions, the projects picker), `navigate`
  (hard-codes 5), `back`, `advance`; no `interactiveDismissDisabled`. `SignalDoneStep` draws the
  closing `CreationClosingBlock` itself as its last child. `SignalModel.steps`, `SignalModel.error`
  is a borrowed `CreationFailure` built from a sentence.
- `app/Sources/AiTerm/Views/NameSheet.swift`, `NameSheet`: Rename (task, terminal, divider), Add
  Divider and New Terminal. One `Input`; `SheetFooter` answers Command-Return only.
- Callers and tests, re-run: `grep -rn "CreationSheet\|SteppedSheetFrame\|CreationFooter\|CreationSteps\|creationHeight\|\.steps\.agentStep\|SignalModel.steps" app/Sources app/Tests docs`.
  Expect the files above, `Snapshots/SheetSnapshots.swift` (footer-only images built from
  `CreationFooter`), `Metrics.swift`, `CreationSheetStepsTests`, `SheetHeaderTests`,
  `TaskCreationModelTests`, `ReviewCreationModelTests`, the UI README, `docs/design/ui-patterns.md`,
  `docs/architecture.md` and `docs/design/design-system.html`.
- Tests that cover the routing today: `NewReviewSheetKeyboardTests` (Escape and Command-Return in a
  hosted New Review), `NewTaskSheetKeyboardTests`, `SheetFooterTests`, `SheetDismissalTests`,
  `SheetHeaderTests`, `CreationSheetStepsTests`.

## Change

1. Create `app/Sources/AiTerm/Views/SteppedSheet.swift` with two types.
   - `Step`, a plain value: its `name` (the stepper's label), `canAdvance` (whether Continue, or the
     create button on the last step, is enabled) and `closeList`, a closure that closes the step's open
     list or popup and returns whether there was one; it defaults to returning false.
   - `SteppedSheet`, the view. It takes the title, the sheet's fixed height, the steps, a binding to the current step (1-based,
     held as `@State` by each sheet so its `seeded(step:)` keeps working), the create label, whether a
     create is running, an async create action that returns whether to close the sheet, and three view
     slots: `content` (the current step), `notices` (lines drawn in the footer above its buttons) and
     `closing` (the content of the `CreationClosingBlock` that ends the last step), plus an optional
     `recovery` slot for buttons beside Cancel.
2. What the frame owns, and nothing else:
   - The layout: `SheetLayout` at `.fixed` of the height the sheet passes (it does not choose one), `SheetStepper` with every step's name as its
     accessory, the content in a `FrontToBackStack` at `Space.block` with the closing block as its last
     child on the last step only, and the footer.
   - The footer, as an internal view `SteppedSheetFooter` so snapshots can draw it alone: a `VStack` at
     `Space.gap` of the notices over one row. The row, leading to trailing: Cancel, the recovery
     buttons, a spacer, Back (from step 2 on), then `SheetPrimaryButton` titled "Continue" before the
     last step and the create label on it. Cancel and Back are house secondary push buttons with no key.
   - The keys, in this order:
     - Escape: one hidden button with the cancel key, as `SheetFooter` has it. First the current step's
       `closeList`; if it closed something, stop. Otherwise, unless a create is running, cancel: dismiss
       after this event (`dismiss.afterThisEvent()`). Escape never goes back.
     - Plain Return: never the frame's. It stays with the focused control: a newline in the prompt or
       JQL editor, a pick in an open dropdown, nothing in a plain field.
     - Command-Return: the primary button's key. Enabled exactly when the current step `canAdvance` and
       no create is running. Before the last step it calls the step's `closeList` and moves to the next
       step; on the last it starts the create.
     - Command-1 to Command-n: `SheetStepper`'s buttons on completed steps only, through `canNavigate`.
       Refused while a create runs; it calls the current step's `closeList`, then sets the step.
   - Back: refused while a create runs; calls the step's `closeList`, then goes one step back. Cancel:
     disabled while a create runs; dismisses after the event.
   - A click on the sheet's background calls the current step's `closeList`.
   - Create: `Task { if await create() { dismiss() } }`, so the dismiss is never inside the key event;
     `.interactiveDismissDisabled` while a create runs.
3. Extract the hidden Escape button from `SheetFooter` into one small modifier in `SheetChrome.swift`
   (it takes `closeList` and `cancel`), used by `SheetFooter` and `SteppedSheetFooter`, so the Escape
   rule is written once. `SheetFooter` keeps its layout and stays the footer of every one-step sheet
   (Name, Project, Settings, Archive, Backpack).
4. New Task and New Review share four small parts in a new `app/Sources/AiTerm/Views/CreationParts.swift`:
   `CreationSummary` (the destination line and "Runs <agent> with <model label>.", as `CreationSheet`
   draws them), `CreationNotices` (the failure `Notice` exactly as `CreationFooter` draws it, and on the
   agent step, while no agent is installed, the "no agent can run" `Notice` it draws today),
   `CreationRecoveryButton` (the failure's recovery button with its title, help and disabled-while-creating,
   running `recoverAndCreate()` and dismissing when it returns true), and a `creationLoads(_:)` view
   modifier holding the five loads and the cancel on disappear.
5. Rewrite `NewTaskSheet` and `NewReviewSheet` on `SteppedSheet`, each passing `Sheet.creationHeight`
   as today. Each builds its three `Step`s from
   its model each render: names Task/Review, Prompt, Agent; `canAdvance` from its existing static
   `canAdvance(step:model:)` and `model.canChangeWorkspace()`; step 1's `closeList` closes its open
   pickers (New Task: tickets; New Review: merge requests, then tickets, then branches, in that order),
   step 2's closes the prompt's completion popup, step 3 has none. Create calls `model.create()`.
   Notices, recovery and closing come from step 4's parts. Keep `seeded(...)` for the snapshots.
6. In `CreationModel.swift` delete `CreationSteps` and `CreationKind.steps`. Keep one fact on
   `CreationKind`: `lastStep` (3), the agent's step, which creates and sums up. `NewTaskSheet.canAdvance`,
   `NewReviewSheet.canAdvance` and `NewReviewSheet.destination(step:...)` read it in place of
   `steps.agentStep` and `steps.showsDestination` (the destination is drawn on the last step only, as
   today).
7. Rewrite `SignalSheet` on `SteppedSheet`, passing `Sheet.height` as today: five `Step`s named from
   `SignalModel.stepNames`, each
   `canAdvance` from `model.canAdvance(step:)`; step 2's `closeList` closes the projects picker, then
   the JQL completions; step 3's closes the prompt's completions. Create label `model.createLabel`,
   creating `model.starting`, create `model.create()`. Notices: the failure `Notice` and the readiness
   `Notice` titled `SignalReadiness.title` with `model.readinessLines()` as its description, only while
   it has lines, as `CreationFooter` draws them today. Move the closing text out of `SignalDoneStep`
   (a static function of the model, or a small view beside it) into the `closing` slot, and delete the
   `CreationClosingBlock` from `SignalDoneStep`. Delete `SignalModel.steps`. Make `SignalModel.error`
   the sentence it shows (`String?`), since it was a `CreationFailure` only to fit `CreationFooter`.
   The four `.task` loads stay on `SignalSheet`. In `SignalStartsStep`, the preview's heading asks the
   model whether it edits an existing signal (add a Bool on `SignalModel` beside `title`, true when it
   has an original) and no longer compares `model.title` with the string "New signal"; the two headings
   keep their wording.
8. Delete `CreationSheet.swift`, `SteppedSheetFrame.swift` and `CreationFooter`. `Sheet.creationHeight`
   and `Sheet.height` in `Metrics.swift` stay as they are.
9. `NameSheet`: give its `Input` an `onCommand` that answers `insertNewline(_:)` by doing what the
   primary button does (submit and dismiss after the event while `canSubmit`; nothing otherwise) and
   returns true only when it submitted. Every other selector returns false.
10. Snapshots: the footer-only images in `SheetSnapshots` (today built from `CreationFooter` at step 3)
    draw `SteppedSheetFooter` on the last of three steps with `CreationNotices` and
    `CreationRecoveryButton`, as wide as a sheet, as before.
11. Docs, one or two lines each:
    - `docs/keyboard.md`: the opening lines say Escape closes an open list, then cancels, and that
      Return in Rename, Add Divider and New Terminal presses the primary button; in Creation sheets,
      the Return row adds "In Rename, Add Divider and New Terminal, Return presses the primary button
      too." and the Escape row reads "Close the current popup first, then cancel. Back and the
      completed steps go back."
    - `app/Sources/AiTermUI/README.md`: "Escape closes an open popup before backing out" becomes
      "before cancelling"; the inventory row lists `SteppedSheet`, `Step`, `SheetLayout`,
      `SheetStepper`, `CreationClosingBlock`.
    - `docs/design/ui-patterns.md` (the creation family paragraphs) and `docs/architecture.md` (the
      line naming `CreationSheet`): name `SteppedSheet` and say Escape cancels.

## Keep

- `SheetFooter` and its hidden Escape behaviour for one-step sheets: Cancel stays at the trailing end
  there; the listed change is for stepped sheets only. `SheetFooterTests` keeps passing unchanged.
- `SheetStepper`'s drawing and `canNavigate`: pixels and the "completed steps only" rule.
- `DismissAction.afterThisEvent()`: a dismiss inside the key event closes a hosted window under the
  event and crashes the process (`SheetDismissalTests`).
- `CreationModel`'s generic kind and its split of `promptText` from the draft
  (`CreationLeafReadTests`): the frame must not read the prompt.
- `TabShortcuts` in Settings: tabs are not steps; leave it.
- The order of decisions in each sheet and every step's content.

## Decisions already taken

- Heights do not change: New Task and New Review stay at `Sheet.creationHeight` (500 pt) and New
  Signal at `Sheet.height` (560 pt), each on every step. The frame takes the height from the sheet.
  Making them one height would be a visual change nobody asked for.
- The only visible differences: Cancel on every step at the leading end (step 1's Cancel moves there
  too), Back beside the primary from step 2, and Escape cancels. The header, every step's content, closing blocks, notices, the primary button and every
  one-step sheet stay pixel for pixel.
- A click on the background now also closes the prompt's completion popup in New Task and New Review,
  as it already does in New Signal: the frame has one "close the step's list" rule.
- A list left marked open on a step that is not the current one is not the frame's to close: leaving a
  step closes its list, so this cannot arise from the keyboard or the mouse. Seeded snapshot states
  need no handling.
- Escape while a create runs: an open list still closes; nothing else happens.
- Create returning false (a failure, a refused workspace) keeps the sheet on the last step with the
  failure in the notices.
- A one-field sheet with `canSubmit` false ignores Return; the field keeps the keyboard.
- Add Project is not a one-field sheet (it has a picker); it keeps Command-Return only.

## Tests

- Delete from `CreationSheetStepsTests`: the three-step `CreationSteps` test (replaced by the
  footer-titles test below) and the five-step broadcast test if phase 1 left it (behaviour deleted).
  Move `onlyCompletedStepsCanBeClickedOrReachedByTheirNumber` into a new `SteppedSheetTests` and
  delete the old file.
- `NewReviewSheetKeyboardTests`: rewrite `escapeWithNoListOpenStepsBack` as "Escape with no list open
  cancels the sheet", `escapeClosesTheCompletionPopupBeforeSteppingBack` as "...before cancelling" (the
  second Escape closes the sheet), and `escapeOnALaterStepStepsBackEvenWithAListLeftOpen` as "leaving
  step 1 closes its lists, so Escape on step 2 cancels". Delete `escapeOnAPreviewedLaterStepStepsBack`:
  Escape going back is the deleted behaviour. A test that expects the sheet to close presents it as
  `SheetDismissalTests.pressEscape(presenting:)` does; a bare hosting window has no presentation to
  dismiss.
- Add `SteppedSheetTests`, driven in a hosted window over a small fake sheet of three steps: Cancel is
  present on every step and Back from step 2; the primary reads Continue, Continue, then the create
  label; clicking Back goes one step back; Command-Return does nothing while the step cannot advance;
  while a create runs, Escape, Cancel, Back and Command-number change nothing; a create that returns
  false keeps the step; a background click closes the current step's list.
- `SheetDismissalTests`: add "plain Return in a name sheet submits and dismisses after the event" and
  "Escape on New Task's second step closes the sheet" (presented).
- `SheetHeaderTests`: `everyCreationStepIsOneHeightAndFits` and `newSignalKeepsTheSheetHeight` keep
  their expectations (500 pt for New Task and New Review, 560 pt for New Signal) and are pointed at
  the rewritten sheets.
- Adjust `TaskCreationModelTests` and `ReviewCreationModelTests` from `steps.agentStep!` to
  `lastStep`, and `SignalModelTests` to the string error.
- No fixture changes.

## Proof

- Before changing anything, on the step's starting commit: `scripts/snapshots.sh build/8f-before`.
- While iterating: `scripts/test.sh swift -- --filter SteppedSheetTests`, then `NewReviewSheetKeyboardTests`,
  `NewTaskSheetKeyboardTests`, `SheetDismissalTests`, `SheetHeaderTests`, `SheetFooterTests`,
  `SignalModelTests`, `CreationLeafReadTests`.
- `scripts/snapshots.sh build/8f-after`, then compare with `cmp` file by file. Identical: every image
  that is not a stepped sheet or its footer (the name sheets included). Different, and only in the
  footer row: `step*`, `review-*`, `signal-*`,
  `sheet-git-error.png`, `task-*.png`. Read those PNGs against the UI README.
- Plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "CreationSheet\b\|SteppedSheetFrame\|CreationFooter\|CreationSteps" app/Sources app/Tests docs/keyboard.md docs/architecture.md docs/design/ui-patterns.md app/Sources/AiTermUI/README.md`
  returns nothing.
- `grep -n "func back\|func navigate\|closeOpenList\|dismiss" app/Sources/AiTerm/Views/NewTaskSheet.swift app/Sources/AiTerm/Views/NewReviewSheet.swift app/Sources/AiTerm/Views/Operators/SignalSheet.swift`
  returns nothing: navigation and dismissal live in `SteppedSheet` alone.
- The suites above and plain `scripts/test.sh` are green; the snapshot comparison shows only the
  listed differences.

## Not in this step

- Readiness as advice, the "isn't installed" note, the unavailable-model wording and a reason for a
  disabled Continue: 8g (it adds a "why not" line to `Step`).
- Settings' Save and Cancel: 8h. Agent table: 8i.
- `docs/design/design-system.html` still names `SteppedSheetFrame` and `CreationSheet`: it is synced on request through the design-system skill, not in this step.
- Command-S, Command-A, Command-P and Command-D: left as chosen.
