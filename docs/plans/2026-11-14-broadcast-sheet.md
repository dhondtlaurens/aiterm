# Rebuild the broadcast's sheet around its two jobs: answering what waits on you, and seeing where each task is

Status: design picked on 2026-11-14 on the Proposals tab of `docs/design/design-system.html`
("The broadcast's sheet", commit `51953c32`). Built, gated and reviewed on `feat/design-polish`, not yet merged.
The first three steps were built as one change before the package was built again. This replaces part 3 of
`2026-11-13-design-polish.md`; part 2 of that plan (two-pane Settings) is dropped.

## Goal

While a broadcast runs, its sheet has two jobs, in this order: the person answers what waits on
them, and sees where each task is. Today the sheet spends its first screen on five header lines,
stacks every question at full height in three different shapes, and draws the tasks as kanban cards
in a sheet that shows two and a bit of four columns. The picked design:

- **One question at a time**, in one block that is the same for every kind of question, with a
  pager in the section's heading.
- **Tasks as one list**: each task is the sidebar's own driven-task row, under its stage as a
  heading, in the order In progress, Review, Todo, Done.
- **The summary on the first view**: once written it sits above the tasks; Left for you is a
  section from its first item, during the run too; Worked around in AiTerm closes the view. The
  Summary tab goes.
- **Activity shows what changed**: status checks, reads and shell commands that went through wait
  behind Show everything.
- The sheet stays 560 pt wide and becomes 640 pt tall. Its header is the title, the status line and
  one line of the brief.

It has to hold for a later live broadcast, started by a trigger and never complete. That is a design
constraint here, not something this plan builds.

## Approach

The model keeps its shape where the data is still read, so the tests that prove where a task sits
and what it says keep proving it. `BroadcastBoard` keeps its lanes and its `Card` per task; what only
the kanban drew leaves both the model and the view.

Decided while reading the code:

- **The stages keep the model's pipeline order** (Todo, In progress, Review, Done) under a new name,
  `stages`. A second, derived list gives the view what it draws: In progress, Review, Todo, Done, a
  stage with no task left out. A lane's own empty line goes; a board with no task at all says
  "Nothing planned yet." once.
- **A row is built from the sidebar's parts, not from `TaskRowView`.** `SidebarRowContent`,
  `RowTitle`, `OperatorBadge`, `AvatarGroupView`, `TaskRowMarkView` and `TaskBadges` are plain views;
  `TaskRowView` reads the sidebar's selection, removal and checkout state and stays there. A `Card`
  gains what those parts need and the sidebar's row already derives: its avatars, its status, and
  whether it is queued or paused. The derivation is shared with `SidebarModel.taskRow`, not written
  twice. A task closed and removed at the broadcast's end, read from its record, has its agent as its
  avatar and the check.
- **What leaves a `Card`:** its worker tab lines (`TabLine` and `Opens.tab`; the app's `bringTab`
  stays, since a prompt's Open Its Window and a driven sidebar row's click bring a tab with it), its
  model-and-reasoning line (`combination`), its question (`CardQuestion`) and its fix
  rounds (`FixRounds`). The project, the model by its Settings label, the Operator's reason and a
  worker's unanswered question to the Operator are the row's tooltip. A kept worktree's reason, a closing's wait and
  "merge refused by the Oracle" are the one help line under a row.
- **`ends at` stays changeable, from the row's menu.** A `Card` keeps its `EndLine`. The menu is a
  section headed as today ("Cart drawer ends at") with the four ends, the current one ticked, the
  unavailable ones disabled, then the sidebar row's Operator items (Take Over or Hand Back, Stop
  Task…) through the same `AppController.perform`. A shelved board's rows have no menu.
- **A row's click** does what a card's does (the sheet closes, its window or what resolves it comes
  forward), with one change: a task with an open question that is answered in the sheet shows that
  question in the pager instead of opening the Operator's window. A prompt still opens its window.
- **One block for every question.** `QuestionBlock` draws, in this order: the task's ticket and
  title, who asks and how long ago on one line; the question; at most one quiet line of context (why
  a relayed question reached you, with Read the discussion; or a fix-rounds question's verdict
  counts, which `ListedQuestion` gains as `note`); its answers as secondary push buttons; then the
  field and Send when words are taken. A prompt's one button is Open Its Window, a stopped command's
  Open the Operator’s Chat. Answered, the block is quiet and says what was answered.
- **The pager** is the sheet's own state: the key of the question shown. It opens on the oldest
  question that still waits; answering moves to the next that still waits; a question asked for by a
  notification, the Operator's row or a task's row is shown at once. Its rules are a small value type
  with tests, apart from the view. Drafts are kept per question while the sheet is open. No pager with
  one question, no section with none.
- **Summary's three parts become three views** in the file they are in, with their words and tests
  kept: the summary (heading, paragraphs, byline, the goal's outcome, or why there is none), Left for
  you, Worked around in AiTerm. The sheet orders them: Waiting on you, Summary, Left for you, the
  stages, Worked around in AiTerm.
- **The tabs are Tasks and Activity**, ⌘1 and ⌘2. `firstTab` and `isSelectable` go: the sheet always
  opens on Tasks.
- **Activity's filter** is one function on an entry: it shows among the changes unless its call
  only looked (`isRead`, or the gate's `shell`) and went through. Refused, challenged and failed
  calls always show. Show everything and Show what changed are a link at the first day's heading;
  the choice lasts while the sheet is open. With entries but no changes, the tab says so and offers
  the link.
- **The header** keeps one line, Asked, cut at its end; the whole brief (Asked, Goal, Each task) is
  its tooltip and its VoiceOver value.
- **Height:** `Sheet.boardHeight`, 640, beside Settings' own; `Sheet.boardColumn` goes.

Not changed: every word the Operator's tools, briefs, wake lines and `run_status` say, including the
places that say "card" and the JSON key `answeredOnCard`; the daemon; `OperatorController`'s
answering, end-changing and fix-rounds functions; the footer and its states; the Shelf opening an
ended broadcast's sheet read-only.

## Files

Modify:

- `app/Sources/AiTermCore/Sidebar/BroadcastBoard.swift`: stages and their listed order; the card's
  row facts, tooltip and help line; `ListedQuestion.note`; two tabs; the brief's whole text; what
  leaves, as above.
- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: the row facts' derivation, shared.
- `app/Sources/AiTermCore/Operators/ActivityLog.swift`: whether an entry shows among the changes.
- `app/Sources/AiTermUI/Metrics.swift`, `app/Sources/AiTermUI/README.md`: the board's height, the
  column's width gone, the inventory.
- `app/Sources/AiTerm/Views/Operators/BroadcastBoardSheet.swift`: the sheet, the row, its menu.
- `app/Sources/AiTerm/Views/Operators/WaitingOnYouList.swift`: the pager and the one block.
- `app/Sources/AiTerm/Views/Operators/BroadcastSummaryView.swift`: three views.
- `app/Sources/AiTerm/Views/Operators/BroadcastActivityView.swift`: the filter and its link.
- `app/Sources/AiTerm/AppController+Operators.swift`: the row menu's actions; the `Opens.tab` case
  gone, `bringTab` kept.
- `app/Sources/AiTerm/Operators/BroadcastBoardHost.swift`: comments, the shelved board's opening.
- `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift` and the pinned list in
  `app/Tests/AiTermTests/OperatorSnapshotTests.swift`.
- Tests, below.
- `docs/operators.md`, `docs/keyboard.md`, `docs/architecture.md`, `docs/daemon-protocol.md`,
  `docs/design/design-system.html` (Components synced, the proposal removed), and the status of
  `docs/plans/2026-11-13-design-polish.md`.

Create: nothing outside tests, unless the pager's rules read better in a file of their own.

## Proof

- **Model** (`BroadcastBoardTests`, `BroadcastBoardSetupTests`, `BoardRecordsTests`, and the tests
  that read cards through the lanes in `OperatorRelayTests`, `OperatorMergeTests`, `RunControlsTests`,
  `BoardModelLabelsTests`, `SidebarProjectionTests`): kept, reading `stages`. New or rewritten: the
  listed order and the left-out empty stage; a card's avatars, status and mark facts equal the
  sidebar row's for the same task, queued, paused, held and ended; the tooltip's lines; the help
  line; a fix-rounds question's note; two tabs. Removed with what they proved: tab lines, the
  combination line, the card's question and fix rounds, `firstTab`, `isSelectable`.
- **Pager**: the question shown on opening, after an answer, after the shown one is resolved, and
  when one is asked for; none and one question.
- **Activity**: which entries show among the changes, for each outcome; the link's two states.
- **Sheet** (`BroadcastBoardSheetTests`, `TaskEndControlsTests`, `BoardActionsWiringTests`,
  `ViewWorkBudgetTests`): a row's click and a waiting row's; the menu's items for a running, a taken
  over, a finished and a shelved task, and that picking an end reaches the controller; only the row
  that changed redraws; the Activity list still materialises its viewport; the sheet's width and the
  board's height. `MetricsTests` for the height.
- **Snapshots**, read after each slice: the sheet running, waiting, paused, planning, complete with
  its summary, writing its summary, with something left for you during the run, worked around,
  shelved; every kind of question; every state of the row; Activity as it opens and with everything.
  The pinned list changes in the same change.
- **Gate**: plain `scripts/test.sh` before the commit, `scripts/test.sh all` before the merge.
- **Run**: the dev build is a live switch and needs the maintainer's go; until then the snapshots
  are the visual proof, and the report says so.

## To-dos

Each step ends with the package building and its tests green: a model member leaves in the same step
as the last view, snapshot and test that reads it.

- [x] The Tasks tab as one list: the model's stages, listed order and row facts (shared with the
      sidebar's row), tooltip and help line; the row, its click and its menu in the sheet; the kanban's
      card, tab lines and end line removed with their snapshots and tests; the sheet at 640 with one
      line of the brief. Waiting on you and the three tabs still as they are.
- [x] The summary on the first view: three views, Left for you from its first item, the Summary tab,
      `firstTab` and `isSelectable` removed in this step with the tests that read them; two tabs.
- [x] The one question block and the pager, with the question's note; a waiting row's click shows its
      question; the card's question and fix rounds removed from the model in this step.
- [x] Activity's filter and link; tests.
- [x] Snapshots and their pinned list; every image read.
- [x] Docs, the README inventory, the design page synced with the proposal removed and published.
- [ ] Gate, review, one commit, `scripts/test.sh all`; stop before the merge.
