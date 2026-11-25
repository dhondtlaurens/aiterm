# Signals by section: Operator signals, project signals, and a sidebar that shows who runs what

Branch: `feat/research`. No tracker. Research: `docs/research/2026-11-25-standalone-signals.md` (local; `docs/research/` is gitignored).

Paths are under `app/Sources/` unless they start with `app/Tests/`, `docs/` or `scripts/`. "(inferred)" marks a
claim that was reasoned from the code and not probed; everything else was read in the code on 25 Nov 2026.

## Goal

A colleague wants a signal to pick up the merge requests where they are reviewer and start a first prompt for them
(say a peer-review skill drafting findings), with every question and decision staying theirs. Today every signal hands
its tasks to the Operator: its chat opens, every worker turn wakes it, it can steer the worker, a worker may not ask
the person directly (AskUserQuestion is denied), and questions reach the person only through the Operator's chat.
The colleague also did not see that the Operator row runs the tasks below it. Research and every design pick are in
`docs/research/2026-11-25-standalone-signals.md` (sections "Design decisions, 25 November 2026" and "Open points");
the one drawing still on the design-system page's Proposals tab is the folded-project stop.

Outcome, one release:
- Two kinds of signal. **Operator signals** behave as today. **Project signals** pick an item up and start an
  ordinary task or review in its project with their prompt and one agent; no Operator chat, Oracle or stage machine.
- Both sections group tasks by project under the Projects dividers; signal headings and Operator dividers go.
- Each section heading gets a signals icon + count (left of +) opening that section's signals sheet; errors turn it
  amber, and a failing source also raises the sidebar banner.
- A task a signal started wears a disc on its avatar; hovering it opens a card (signal, chain, current work).
- The Operator row reads "Running n tasks" and a status line runs down the status column from its mark through each
  task it runs, its stretch marching dotted during an exchange; a folded project takes a stop.

## Approach

Reuse first: a project signal is a `Signal` with an optional `kind`; its pick-up branches off `ItemRouter.apply` into
the existing `TaskLauncher` create path; its task is an ordinary `TaskItem` with a new optional `signalOrigin` mark;
its Done reuses `DoneCheck` and `SignalHostIO`'s query check, its Then `TaskTeardown.archive`. The sidebar reuses
`ProjectSection`, `HeadingValue(ProjectSection)`, `StatusCountChips`, `BackgroundCardHover` and the card chrome,
`ArchiveSheet`'s list pattern, `Notices`/`IssueBanner` and `OperatorNote.Target.task`.

Decided while grilling (25 Nov 2026):
- **Re-review**: when a project signal's item matches again (e.g. review re-requested) and its task exists, the
  signal's prompt is typed into the same conversation once the worker is idle with nothing unsent; an archived task
  is restored first. The notification comes when the turn that prompt started ends, as for the first turn.
- **Priority**: project signals win over Operator signals in one pass; each sheet orders its own signals (Move Up/Down).
- **Delivery**: one plan, one release.

Decided from the code and the agreed design (stated, not asked):
- Several projects match an item: skip it with a reason (shown as a skipped item), never guess.
- A project signal's task launches as an ordinary task (`AgentCommand.build` without `worker:`): no worker guard,
  AskUserQuestion allowed, as for a task you make.
- Pause Operator does not pause project signals; Switch Off does, per signal.
- Creating or switching on a project signal starts every current match, as Operator signals do (the summary says how many).
- "You decide" is a new Done source with no watch. A merged or closed request still counts as done (`DoneCheck`).
- Saved `signalDividers` stay in the file (round-tripped by `PreservedFields`) but are no longer drawn or edited.
- The Operator section keeps its own fold state per project, apart from `Project.collapsed`.
- The pick-up window waits for the person's pause and opens behind (`PauseGate`, `createTaskWindow(background: true)`).

### Corrected against the code

Each of these changes what the first version of this plan said, with the reason.

1. **A pick-up is recorded as started only once its task is saved.** The first version recorded `seen(.started)`
   in `ItemRouter` and then queued the create. `TaskLauncher.create` can throw before a row exists (`work.begin(.creatingTask)`
   busy, git's refusal; `TaskLauncher.swift:141-148`), and `MatchDecision.swift:14-19` drops a still-matching item
   whose record says started, so the item would never start; a quit with queued work lost it too. Now the started
   record is written in the same workspace change that appends the task, and until then every pass decides the item
   again (deduplicated in memory). A failed create writes a skipped record with its reason, which every pass retries.
2. **A project signal's match on an existing task needs its own route.** `MatchDecision.swift:32-46` answers
   `.continueTask` for any task of the item, and `ItemRouter.swift:73-90` then installs a `SignalTask` on it, which
   makes it the Operator's. Project signals get the decisions `.startOrdinary` and `.rematch`, and never
   `.continueTask` (policies under "Decided with the owner", O1 and O2).
3. **Scheduled project signals need their own path.** `SignalScheduler.tick` passes one Boolean (`canSchedule`, the
   Operator's pause) for every signal; `ScheduleDecision.previousRunUnfinished` reads only `signalTask.scheduledRun`;
   `ItemRouter.apply(schedule:)` builds an Operator task (`makeRunTask`). Step 3c covers all three.
4. **To-do order.** Signal headings carry the tasks the Operator holds (`SignalSidebar.swift:75-78` removes them from
   Projects; `SidebarView.operatorRows` draws them under their signal), and the signal's menu, pause mark and tooltip.
   The signals sheet now comes before the regrouping, and the regrouping replaces signal headings by project headings
   in one step, so no step hides the Operator's tasks or leaves a signal without its menu.
5. **Pause gating is per signal, not per pass.** Signals with equal reads share one read key and one observation
   (`SignalPoller.swift:65,95`), so an Operator signal and a project signal can arrive together. `canPoll`
   (`SignalOperatorController.swift:202`) and `onPass` (`:252`) gate everything on the Operator's pause; the poller
   needs a per-signal rule, and so does `AppState.operatorMayStartWork` (`AppState+Signals.swift:27-29`), which
   Backpack Mode reads.
6. **A project signal's read failures are not saved in `operatorSession.sourceFailures`.** `poller.onFailure`
   (`SignalOperatorController.swift:262-273`) creates an `OperatorSession` when there is none, writes the Operator's
   activity log and wakes the Operator; `OperatorDigest` hands `sourceFailures` to the Operator. A project signal's
   failures stay in memory (`SignalReadIssues`, step 9).
7. **`OperatorDigest` needs three filters, not one**: `signals`, `skipped` and `nextRuns`
   (`OperatorDigest.swift:109,120-125`) all read every signal.
8. **`SignalTransitions` lives in `AiTermCore/Operators/Signals/StageMachine.swift`**, not in `SignalTask.swift`.
9. **The Done source's Swift case is `.person`, saved as `"person"`, not `.none`.** `Source.none` reads as
   `Optional.none` wherever a trigger is reached through an optional chain (`task.signalTask?…done.source == .none`
   would be true for a task with no record), which is a silent bug. The decision, a Done with no watch, is unchanged.
10. **An own merge request needs a new create.** `TaskWorkflow.checkOutRequest` (`TaskWorkflow.swift:74-86`) takes a
    saved task and returns no agent command, and `TaskCreator.create` always adds a new branch
    (`Repository+Worktrees.swift:68`, `-b`). Step 3a adds `TaskWorkflow.createOnRequest`, used only for a merge request
    the account authored or is assigned to. A ticket whose branch already exists fails and is reported; it is not
    checked out.
11. **`TaskLauncher.createReview` must not reach `openReview` from a pick-up.** A branch another row has checked out
    opens a foreground tab in that row's window, activates it and adds no row (`TaskLauncher.swift:51-53,95-121`).
    The unattended create skips the item with the owner's name as reason.
12. **The line stops 8 pt from a mark's centre**, 3 pt clear of the 10 pt ring, and 5 pt from a stop's centre: the
    Proposals drawing masks `r = 8` around marks and `r = 5` around the 5 pt stop. The dash is 2 pt on, 4 pt off; one
    period (6 pt) per 0.25 s is the proposed 24 pt/s.
13. **The banner needs two additions to `Notices`.** `Notices.report` lets an issue that has actions replace a shown
    question (`Notices.swift:70-75`), and `OperationIssue.isStale` treats `subject` as a task or terminal
    (`OperationIssue.swift:53-60`). A failing signal's banner is a background report with actions, so it must wait
    behind a question, and the signal's id travels in its action.
14. **A list row's id cannot be shared.** An Operator project heading and its Projects heading are the same project;
    `RowFocus.row(id:)` (`RowFocus.swift:138-146`) resolves an id to one selection, and `SidebarProjection.viewLayout`
    keys folds by id. The Operator heading gets a derived id and the layout two maps.

### Decided with the owner (25 Nov 2026)

- **O1. A project signal's first match on a task made by hand** (no `signalOrigin`, not taken over): the task is
  marked with the signal and the prompt runs in its conversation once its worker is idle, exactly as a re-match; this
  is what `docs/operators.md` "One item keeps one task" promises for Operator signals.
- **O2. A project signal's match on a task the Operator holds:** skipped with the reason "The Operator runs this
  item's task.", so it shows as a skipped item (amber). The Operator keeps the task. (The reverse is already decided:
  an Operator signal never continues or adopts a task with a project signal's origin.)
- **O3. A scheduled project signal's unfinished run:** a run is unfinished until its Done is reached or its task is
  archived or removed. With **You decide** the next run is skipped, with its reason, until the person archives the task.
- **O4. File › New Signal… (⌘S):** makes the open section's kind, as File › Add Divider… picks its section; with
  Projects open, the default, that is a project signal.
- **O5. Re-match notification:** no note when the item matches again; the turn the re-typed prompt starts notifies
  when it ends ("is ready for you" / "asks you something"), as the first turn does.
- **O6. The signals glyph:** `dot.radiowaves.left.and.right` for the heading icon and the avatar disc, as drawn.
- **O7. Status line rules:** "up, once" lasts a new `Motion.pulse` of 1 s; where an exchange and a question overlap,
  the moving exchange shows while it lasts and the stretch is amber again after.
- **O8. Menus:** after Edit Signal… or New Signal… from the signals sheet, the list does not reopen (one sheet slot);
  in the Operator section a divider and a project heading have no menu.

### Data shapes

All new saved fields are optional or left out while empty, so `Fixtures/operator-signals/state.json` keeps its bytes.

- `Signal.kind: Signal.Kind?` (`AiTermCore/Operators/Signals/Signal.swift`). `Kind` is an `OpenStringEnum`:
  `.operator`, `.project`, `.unknown(String)`. Nil means Operator and is what an Operator signal always saves, so
  existing signals and every stage's copy of one are unchanged. `Signal.isProject` reads `kind == .project`.
- `SignalTrigger.Source.person`, saved `"person"`: a Done only, "You decide". `readsItems` is false.
- `TaskItem.signalOrigin: SignalOrigin?` (`AiTermCore/Models.swift`, key `signalOrigin`, written only when set).
  `SignalOrigin` (new file `AiTermCore/Operators/Signals/SignalOrigin.swift`):
  - `signal: UUID`: the signal that started the task, or the last one that ran it.
  - `name: String`: that signal's name then. The live name wins while the signal exists; this one names a removed signal.
  - `item: ItemRef`: what matched. Its identity joins the task to later matches and keeps the seen record. A
    scheduled run's `.run` reference is here too.
  - `startedAt: Date`.
  - `earlier: [SignalStep]?`: the signals that ran the task before, oldest first. `SignalStep` is `signal`, `name`, `at`.
  - `owed: OwedPrompt?`: a prompt still to reach its worker, the first launch's or a re-match's. `OwedPrompt` is
    `text` (the composed prompt), `at`, and `kind`: `.launch` (the first prompt, given to a new agent at launch) or
    `.delivery` (typed into an existing conversation: a re-match, or O1's hand-made task). Recovery treats them apart.
  - `doneKey: String?`, `doneMatched: Bool?`: the Done trigger the baseline was read for (source, newline, query)
    and whether it matched at the last complete read.
  - `doneAt: Date?`: when the Done edge, a merge or a close was seen; no query is read after it.
  - `thenApplied: Bool?`: Then is finished (Keep at once; Archive once the teardown succeeded or refused for good).
    While `doneAt` is set and this is not, Then is pending and is retried, after a restart too, as
    `ThenRunner` does with `SignalTask.thenApplied` (`ThenRunner.swift:29,59,66`).
  - `thenNote: String?`: why Then's archive did not happen (a refusal for good, e.g. unsaved work).
  - `turn: SignalTurn?`: the signal's latest prompt in its worker: `sentAt` (Enter pressed by the delivery, or the
    launch), `pastedAt` (pasted, Enter left to the person: a `pasteOnly` agent's `.partial`), and `seenWorking`
    (the task's session was seen working after `sentAt`/`pastedAt`). Saved on every change, so a restart keeps it.
  - `notifiedAt: Date?`: when the notification for the latest turn a signal's prompt started was posted. Cleared
    when a re-match's prompt is delivered, so that turn's end notifies again.
- `SignalTask.earlier: [SignalStep]?` (`SignalTask.swift`): the Operator task's own chain, since stages keep no
  history. `AppState.takeOver` copies it into `signalOrigin`.
- `AppState.operatorFolded: Set<UUID>` (key `operatorFolded`, a sorted array, left out while empty): the projects
  folded in the Operator section.
- In step 10c `AppState.signalDividers` and its key leave `CodingKeys`; `PreservedFields` then reads and writes the
  key as it came. `SignalDivider`, `OperatorSlot`, `operatorSlots` and the divider mutators are deleted with it.
  Until then dividers load, draw and save as today.
- In memory only: `ProjectPickup` (a decided pick-up waiting for its create), `SignalReadIssues` (failed reads per
  signal with their attempts), the wake pulses of `OperatorActivityTracker`.

### Flows

**Pick-up** (project signal, item with no task):
1. A complete read reaches `ItemRouter.apply`. `MatchDecision` answers `.startOrdinary(match)`. The router writes
   nothing for it and returns a `ProjectPickup` (signal id, the `SignalItem`, project, account user, matched time).
2. `ProjectSignals.enqueue` drops a pick-up whose key (signal and item identity) is queued, under way or backing
   off, and otherwise appends it to its project's queue. The item's identity is **claimed**: `MatchDecision` drops
   an Operator signal's match on a claimed identity for that pass, so a long wait cannot hand the item to the Operator.
3. One runner per project takes its queue in order. It waits while the helper is away or iTerm2's tabs are unknown.
4. Before the create it checks again: the signal exists, is runnable and is a project signal; the project exists;
   no task has the item now. Otherwise the pick-up is dropped, and the next pass decides the item afresh.
5. `TaskLauncher.createUnattended` makes the checkout (git, on the repository's lane), then appends the row in one
   workspace change that also sets `signalOrigin` (with `owed` holding the composed prompt) and writes the
   `seen(.started)` record, and flushes. It selects nothing. A project busy with another create
   (`CreationBusy`) puts the pick-up back without counting a failure.
6. The Done baseline (from step 4 on): with Done **A query matches**, the runner reads the Done query for the new task
   (the generalised check from step 4) and saves `doneKey` and `doneMatched` in one change before any window opens,
   as `StageRunner.baseline` (`StageRunner.swift:147-167`) does before an Operator worker launches. A read that fails
   holds the launch with the reason as the signal's skipped record and is tried again after five minutes, as an
   Operator stage holds; the task stays, owing its prompt. **You decide** (`.person`) reads nothing.
7. The window: the runner waits for the person's pause (`PauseGate.quiet`), takes the one window turn
   (`ports.pause.turn`, shared with the Operator), looks at the pause once more with no await after it, and opens
   the window with `createTaskWindow(background: true)` and the ordinary agent command. Choosing the row during the
   wait ends the wait, as choosing the Operator's row opens its chat at once.
8. The window id is saved and `owed` cleared in one change.

The baseline is never read after the prompt reached the worker: a worker that meets the Done query during its first
turn (a ticket moved to Done, say) would otherwise make the matching state the baseline, `DoneCheck.reached` would
never see an edge, Archive would never run and a scheduled signal would stay blocked.

A create that throws writes `seen(.skipped, reason: "Couldn’t start its task: …")` and backs off 300 s
(`SignalPoller.failureBackOff`) in memory; the record shows as a skipped item and is replaced when the create
succeeds. A quit loses only the queue: nothing was recorded, so the first full read after launch decides again.

**Re-match** (its own task, or under O1 a hand-made one): `.rematch(task, match)`. The router, in one workspace
change, sets `signalOrigin` (a hand-made task gets one; a different earlier signal moves to `earlier`), sets `owed`
to the newly composed prompt (`kind: .delivery`), clears `doneKey`, `doneMatched`, `doneAt`, `thenApplied`,
`thenNote`, `turn` and `notifiedAt` so Done is an edge again and Then runs again, as `StageMachine.continueStage`
clears `thenApplied` for a continued Operator task, and
writes `seen(.started)`. The intent is durable from that change. `ProjectSignals`
delivers at each tick: an archived task is restored first; the Done baseline is read and saved before anything is
typed (as in step 6 above, held on a failed read); a worker idle with nothing unsent gets the text typed
(`daemon.deliver` in its guarded mode, below); a task with no window gets one, pause-gated and behind, resuming its first conversation with
the prompt; a window with no agent gets a background tab. A worker at work, asking or with unsent input keeps the
prompt owed, with no limit. A newer re-match replaces the owed text.

**Done edge**: each minute `ProjectSignalWatch` reads every marked task whose signal is a live, enabled project
signal, whose `doneAt` is nil and whose baseline was saved before its prompt was sent (a task still owing its first
prompt is not read). A `doneKey` that no longer matches the signal's Done (the signal was edited) makes the read a new
baseline; that one change is accepted after launch, since the person changed the trigger. Otherwise
`DoneCheck.reached(facts, before: doneMatched)` decides. On done: `doneAt` is saved, and Then is pending until
`thenApplied`. Each pass also takes every task with `doneAt` set and `thenApplied` not true, so a quit or a temporary
refusal is retried. Keep sets `thenApplied`. Archive calls `TaskTeardown.archive(_, consent: .refuse(stillAllowed:))`
once no session of the task works, asks or holds a turn: success sets `thenApplied`; a `ClosingWait` (a person
started a turn, the helper went away) leaves it pending for the next pass; any other refusal (unsaved work) is saved
in `thenNote` with `thenApplied`, not retried, as `ThenRunner.swift:66-67` does.

**Turn-end notification** (the first turn, and each turn a re-match's prompt starts): `LiveSessions.onSessionsChanged`
→ for a task with a project signal's origin, no `owed`, no `notifiedAt` and a `turn`: first, a session of the task
seen working after `turn.sentAt` (or, for a pasted prompt, after `turn.pastedAt`, i.e. once the person pressed Enter)
sets `turn.seenWorking`. Only a turn with `seenWorking` notifies: its worker asking (`needsInput`) posts "asks you
something"; its turn ended (`done` or `idle`) with nothing holding the turn posts "is ready for you". A session that
was already done before the prompt, or an unrelated session update, never counts: the evidence is a working state
after the send. A pasted prompt the person never sends never notifies. `notifiedAt` is saved before
the post, so a crash never posts twice. The click chooses the row (`AppController.swift:234-240`, already wired).

**Read failures**: `poller.onFailure` → `SignalReadIssues.fail` for every signal that shares the read, every time.
The icon turns amber from the first failure. At the third in a row the banner is raised once for that streak. A
good read (`onPass`) calls `succeed`, which clears the issue and takes its banner down.

## Files (representative; patterns described once)

Core (`AiTermCore/`)
- Modify `Operators/Signals/Signal.swift`: `kind`, `Kind`, `isProject`, validity by kind.
- Modify `Operators/Signals/SignalTrigger.swift`: `Source.person`.
- Create `Operators/Signals/SignalOrigin.swift`: `SignalOrigin`, `SignalStep`, `OwedPrompt`.
- Modify `Models.swift`: `TaskItem.signalOrigin`; `AppState.operatorFolded`; `move(signalId:)` within one kind;
  in step 10c `signalDividers` out of `CodingKeys` and the divider model out.
- Modify `Operators/Signals/SignalTask.swift`, `StageMachine.swift`: `earlier`, appended and popped by the transitions.
- Modify `Operators/Signals/AppState+Signals.swift`: `takeOver` writes the origin; pruning keeps origin items;
  `operatorMayStartWork` by kind.
- Modify `Operators/Signals/MatchDecision.swift`: priority, `.startOrdinary`, `.rematch`, claims, protection of marked
  tasks, `matchesItem`, pruning of records still matching.
- Modify `Operators/Signals/ScheduleDecision.swift`: per-signal `mayAct`, unfinished runs of marked tasks.
- Modify `Operators/Signals/OperatorDigest.swift`: Operator signals only.
- Create `Operators/Signals/SignalReadIssues.swift`: failed reads per signal (pattern `Operators/OperatorIssues.swift`).
- Create `Operators/Signals/SignalSummary.swift`: a signal's Starts and Done lines, moved from `HeadingValue.triggers`.
- Modify `Interface/OperationIssue.swift`: actions `.openSignals(signal:)` and `.openSettings`.
- Modify `Tasks/TaskWorkflow.swift`: `createOnRequest`. `Agents/AgentCommand.swift` is read, not changed.
- Modify `Sidebar/SidebarModel.swift`, `Sidebar/OperatorLine+Task.swift`: `TaskRow.startedBySignal`; the title's counts.
- Create `Sidebar/StatusLine.swift`: `StatusLinePiece`, `StatusLineInk` and the pure layout rule.

App (`AiTerm/`)
- Modify `Operators/ItemRouter.swift`: project decisions, `ProjectPickup`, the run task for a project signal.
- Create `Operators/ProjectSignals.swift`: queue, create, launch, delivery, first-turn notification.
- Create `Operators/ProjectSignalWatch.swift`: Done baseline and edge, Then.
- Modify `Operators/SignalHostIO.swift`: `doneFacts(for:done:item:)`, the query check taking a trigger and an item.
- Modify `Operators/SignalPoller.swift`, `SignalScheduler.swift`, `SignalOperatorController.swift`: per-signal gating,
  the project steps of the tick, failures by kind, ports for create, restore, archive and delivery.
- Modify `TaskLauncher.swift`: `createUnattended`, `openUnattended`, `CreationBusy`.
- Modify `AppController.swift`, `AppController+Signals.swift`, `AppController+Operators.swift`, `AiTermApp.swift`,
  `SheetKind.swift`, `SheetCoordinator.swift`, `ProjectActions.swift`, `Notices.swift`: wiring, sheets, menus, folds, banner.
- Modify `SignalSidebar.swift`, `SidebarProjection.swift`, `HeadingValue.swift`, `RowFocus.swift`: sections by project,
  `SectionFold`'s signal count and issue, `RowSelection.operatorProject`, the status line cells.
- Modify `Operators/SignalModel.swift`, `Views/Operators/SignalSheet.swift`, `SignalDoneStep.swift` (with
  `SignalDoneSummary`), `SignalTriggerStep.swift`: kind, titles, project steps 3 and 5.
- Create `SignalsSheetModel.swift`, `Views/SignalsSheet.swift`: the list per section.
- Modify `Views/SidebarHeadings.swift`, `SidebarView.swift`, `SidebarRows.swift`, `SidebarRowContent.swift`,
  `AvatarGroupView.swift`, `DividerRow.swift`, `Operators/SignalRows.swift`: icon and count, Operator project heading,
  disc, line slot.
- Modify `Views/BackgroundCard.swift`, `BackgroundCardPresenter.swift`; create `Views/SignalCard.swift`.
- Create `Views/StatusLine.swift`: the segment view, beside `StatusMark`.
- Modify `Operators/OperatorActivity.swift`, `OperatorWaker.swift`: wake pulses per task.
- Modify `Snapshots/SignalSidebarSnapshots.swift`, `SignalSnapshots.swift`, `SheetSnapshots.swift`, `ReadmeDesktop.swift`.

UI tokens (`AiTermUI/`)
- Modify `Palette.swift`: `statusLine`, an alias of `idleRing` (the page called it `wire`).
- Modify `Metrics.swift`: `Motion.march` (24 pt/s) and `Motion.pulse` (O7); `Size.statusStop` (5 pt).
- Modify `README.md`: both inventories and the new tokens.

Docs: `docs/operators.md`, `docs/architecture.md`, `docs/keyboard.md` (⌘S, if O4 stands), `app/Sources/AiTermUI/README.md`,
`docs/design/design-system.html`, a release note in `docs/release-notes/`.

## Proof

- **Per step**: the filter named in the step, `scripts/test.sh swift -- --filter <Suite>`, then `scripts/test.sh`
  before the commit. Runs queue machine-wide: start them in the background and wait for the command to exit.
- **Contracts**: `SignalSavedFormatTests` passes with `state.json` untouched after every step; `brief.md` and
  `tools.json` are not edited. `SignalJourneyTests` passes after every step.
- **Visual**: `scripts/snapshots.sh build/snapshots-before` on `main` once, `build/snapshots-after` on the branch
  after each visual step (7, 8, 9, 10, 11, 12), both sets read and compared. The status line needs
  `AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_NATIVE_CAPTURE=1`: `ImageRenderer` cannot draw a `List`, so the stacked
  snapshots prove the pieces and only hosted captures and the pixel tests prove the seams.
- **Before merge**: `python3 scripts/test-history.py require-full …` or `scripts/test.sh all` plain on a clean tree.
- **Live**, the maintainer's, through `scripts/run-dev.sh`, with a "Reviews for me" project signal. To look at: the
  window opens behind and only in a pause; the worker can ask through its own menu; no Operator row or chat
  appears; the notification's click opens the row; a review asked again types the prompt once the worker is idle; a
  failing token turns the icon amber and, after three reads, raises the banner; the line's dots meet across rows
  while scrolling and at ×1.15 and ×1.3.

## Risks

- **Seams across list rows.** A row's rect is 8 pt taller than its pill and its content is padded by `Space.base`,
  so a segment must draw outside its slot to meet its neighbour, and whether the table's row or cell views clip that
  is unknown. Step 0 probes it first. Fallbacks, in order: (1) the overdraw stays inside the row's own rect, which
  works if the 8 pt belongs to the hosting cell; (2) the Operator section's rows take zero list insets and paint
  their own gap; (3) one overlay over the list, placed from row anchors as `BackgroundCardViewport` does. If none
  holds, stop and ask: gaps in the line are a design change.
- **Downgrade.** `Signal` has synthesized Codable and no `PreservedFields`, so an older build that saves the
  workspace drops `kind`: a project signal with a Done query becomes an Operator signal there. A "You decide" signal
  decodes its Done as unknown and stays inert. `TaskItem` and `AppState` keep their new keys. The release note says
  not to run an older build on this workspace; `docs/architecture.md` points at an "Operator format" section that
  `docs/workflow/release.md` does not have, which step 13 raises.
- **Saved signal dividers.** Dropped from the drawn model but kept in the file. `ModelsTests` pins that a workspace
  with dividers loads, saves the same `signalDividers` value and survives a removed signal.
- **Operator adoption.** Three guards, each with a test: `MatchDecision` never answers `.continueTask` for a project
  signal; an Operator signal never continues a task with `signalOrigin` and no `signalTask`; a claimed identity is
  dropped for Operator signals. Across passes of two hosts or two read keys, the first read wins.
- **Descriptions appended twice.** `TaskWorkflow.create` composes the prompt itself (`AgentCommand.composePrompt`,
  which calls `SignalWork.workerPrompt`). The pick-up hands the draft the signal's bare prompt and its two
  description switches, never `ItemRouter.prompt`'s composed text. A test counts the envelope sentence once.
- **`createReview` and a checkout owner** (correction 11): the unattended create never opens a tab in another row.
- **An unattended first turn has no branch guard.** Decided ("as for a task you make"); the summary on step 5 of
  New Signal says so, and `docs/operators.md` states it.
- **A prompt typed twice.** A crash between `daemon.deliver` answering and `owed` being cleared delivers the
  re-match prompt again at the next tick. Not handled: it needs the reply fingerprints the Operator's stages keep
  (`SignalWorkerReply`), and a repeated review prompt costs one turn.
- **Redraws.** A line that changed every row's value on each exchange would redraw the section. The pieces live in
  per-row cells that only a leaf view reads (step 12b), with a redraw test.
- **The README picture.** `ReadmeDesktop.swift` draws signals; `docs/desktop.png` changes and the next
  `scripts/release.sh` redraws it. `scripts/readme-picture.sh --check` already fails on `main`.

## To-dos (each leaves the project green)

Each step lists its changes, the cases it must handle, its tests and its proof. "Not handled" names a case judged
not worth the code, with the reason.

- [ ] **0. Probe the status line's seams** (test code only).
  - Create `app/Tests/AiTermTests/StatusLineSeamTests.swift` in the style of `SidebarRowGeometryTests`: host a
    `List` set up as `SidebarView` sets its own up (sidebar style, hidden separators, `NativeRowHighlight.off`) with
    three `SelectableRow`s whose trailing slot holds a throwaway overlay drawing a 1.5 pt vertical stroke that
    reaches `Space.tight` above and below the row's pill. Capture the bitmap and count the stroke's pixels in the
    gap between two rows. Run it at standard, large and extra large.
  - Outcome: if the gap is fully painted, the test stays as the seam guard and step 12 draws by overdraw. If not,
    try fallbacks 1 and 2 from Risks in the same test, keep the one that passes, and write the result into this plan
    before step 12.
  - Proof: `scripts/test.sh swift -- --filter StatusLineSeamTests`.

- [ ] **1. Model and saved format.**
  - `Signal.swift`: `kind` and `Kind`; `isValid` gains: an unknown kind is invalid; a project signal has exactly one
    agent row, no `mergesWhenReady`, Then `.keep` or `.archive`, no `deletesMergedBranch`, and a Done that is not
    `.operator`; an Operator signal's Done is not `.person`.
  - `SignalTrigger.swift`: `.person` in `allCases`, `savedName`, `refusal(start:)` (refused as a Start with "You
    decide only when a signal is done."; no refusal as a Done), `startRole`. Every exhaustive switch over `Source`
    gets the case: `SignalHostIO.accountReference` and its Done check, `ProviderIcon.source(of:)`,
    `HeadingValue.triggers`, `OperatorLine.waiting(for:)`, the query writer and `SignalConnections.reader(for:)`
    (the compiler lists them).
  - `SignalOrigin.swift`: the three types, synthesized Codable.
  - `Models.swift`: `signalOrigin` in `TaskItem.CodingKeys`, decoded with `decodeIfPresent`, encoded when set;
    `operatorFolded`. `signalDividers` is not touched yet (step 10c).
  - `SignalTask.swift`, `StageMachine.swift`: `earlier`. `continueStage` appends the stage it leaves (signal, the
    configuration's name, `startedAt`); `.dropped` pops it again, since the task returns to that stage.
  - `AppState+Signals.swift`: `takeOver` sets `signalOrigin` from the removed record (current signal, its name,
    item, `startedAt`, `earlier`).
  - `app/Tests/AiTermTestSupport/Builders.swift`, `SignalWorld.swift`: a project signal builder and a marked task.
  - Cases: a task saved before has no key and writes none; an origin from a newer build with extra keys fails only
    if a required key is missing (as every record does at this boundary).
  - Tests: new `app/Tests/AiTermCoreTests/Operators/SignalKindFormatTests.swift` (pattern
    `SignalScheduleFormatTests`): an old signal decodes with `kind` nil and encodes to the same object; a project
    signal with a `.person` Done round-trips; an origin with every field and one with only the required ones
    round-trip; a task without one writes no key; a record with `earlier` nil writes none. `SignalForwardCompatibilityTests`:
    an unknown `kind` and an unknown Done source round-trip and leave the signal not runnable. `SignalDomainTests`:
    validity rows for each project rule and for an Operator signal with `.person`; `earlier` after continue, after
    drop, and in the origin after `takeOver`. `ModelsTests`: `operatorFolded` round-trips and is absent while empty.
    `SignalSavedFormatTests`: unchanged and green.
  - Proof: `--filter SignalKindFormatTests`, `SignalSavedFormatTests`, `SignalDomainTests`, `ModelsTests`.

- [ ] **2. Matching rules** (pure Core; no runtime reads the new decisions yet).
  - `MatchDecision.swift`:
    - `decide` takes `claimed: Set<String>` (default empty). Ranks: runnable project signals first in their order
      in `signals`, then Operator signals in theirs.
    - New cases `.startOrdinary(SignalMatch)` and `.rematch(UUID, SignalMatch)`.
    - A project signal's match: a `.run` item starts ordinary or skips with `projectGone`. An item whose task was
      taken over: nothing. A task the Operator holds: skip (O2). A task whose origin names this signal: `.rematch`.
      A task whose origin names another signal and has no `signalTask`: nothing, and no record (the first project
      signal keeps the item). A hand-made task: `.rematch` (O1). No task: no project → skip with today's reason;
      several projects (`ItemProjectMapper.projects`) → skip, naming them; one → `.startOrdinary`.
    - An Operator signal's match: a task with `signalOrigin` and no `signalTask` is never continued, as a
      taken-over one is not. An identity in `claimed`, or one a project signal started in this call, yields nothing:
      no pending stage, no record.
    - `matchesItem` also compares `task.signalOrigin?.item.identity`.
    - `SignalSeen.pruned` takes the live project signals' ids and keeps a record of one that is started and still
      matching, whatever its age: a removed task whose request still matches must not start again after 90 days.
  - `AppState+Signals.swift`: one helper for the identities held by marked tasks, in `tasks` and the archive;
    `pruneOperator` and `ItemRouter`'s closing prune both add it to their live items.
  - `Models.swift`: `canMove(signalId:)` and `move(signalId:)` step over signals of the other kind: through
    `operatorSlots` while dividers exist, between plain neighbours after step 10c.
  - `ScheduleDecision.swift`: `decide` takes `mayAct: (Signal) -> Bool`; a signal that may not act is not due and its
    cursor does not move. `previousRunUnfinished` also counts a task, not archived, whose origin's item is a run of
    the signal and whose `doneAt` is nil (O3), and a run of the signal that is queued or being created and has no task
    yet: `decide` takes the signals with such a pending run (`pending: Set<UUID>`, from `ProjectSignals`' queue), so
    two scheduled times while iTerm2 is away start one task and skip the second with its reason.
  - `ItemRouter.swift` compiles against the new cases by ignoring them for now (project signals do nothing yet).
  - Cases: two project signals on one item in one pass (the higher starts, the lower yields nothing); a project and
    an Operator signal in one pass (project starts, Operator gets nothing); the same two in separate passes (the
    first read wins, the second meets a task and follows the rules above); an archived marked task (`.rematch`, the
    restore is the runtime's).
  - Tests: new `app/Tests/AiTermCoreTests/Operators/ProjectSignalDecisionTests.swift`, one test per rule above,
    plus priority across kinds, claims, and `matchesItem` by origin. `SignalDomainTests`: the existing adoption,
    take-over and priority tests stay green; seen retention with a still-matching project record. `ModelsTests`:
    Move Up skips a signal of the other kind and leaves its place. `ScheduleDecisionTests`: a paused Operator stops
    only Operator schedules; a marked run blocks its signal until `doneAt` or the archive; a taken-over run does not.
  - Proof: `--filter ProjectSignalDecisionTests`, `SignalDomainTests`, `ScheduleDecisionTests`, `ModelsTests`.

- [ ] **3. Pick-up.** Three sub-steps, each green.
  - **3a. An unattended create.**
    - `TaskLauncher.swift`: `createUnattended(_ request:) async throws -> UUID`. The request carries the project,
      the kind of create (review, task, own request, run), the draft, and `saving: (inout AppState, UUID) -> Void`,
      run inside the change that appends the row. It reuses `create`'s order (`work.begin(.creatingTask)`, checkout,
      `work.begin(.opening)`, append, `checkouts.refresh`, flush) without `focus.browse`, without the window and
      without `rememberChoice` (a signal's agent row is not the person's last choice); a launch warning and a
      `.worktreeinclude` note are still reported about the row. The busy guard throws the new
      `CreationBusy` (same sentence as today, so the sheets read as before). A review whose branch has a checkout
      owner throws with the owner's title instead of calling `openReview`.
    - `TaskLauncher.swift`: `openUnattended(_ id:, prompt:) async throws`: the task's window opened behind
      (`createTaskWindow(background: true)`) with the ordinary command for the prompt, resuming the first
      conversation when there is one, the other conversations as background tabs; or a background tab when the
      window is open with no agent. The caller holds the pause and the window turn.
    - `TaskWorkflow.swift`: `createOnRequest(draft:project:source:target:reserved:)` returns `Created`: the
      request's source branch in a worktree named as a review's, its target as base, the row a `.task`, the command
      built as `checkOut` builds it.
    - Tests: `app/Tests/AiTermCoreTests/TaskWorkflowTests.swift`: `createOnRequest` checks out the existing branch
      and builds an ordinary command (no `--disallowedTools`). New `app/Tests/AiTermTests/UnattendedCreateTests.swift`:
      the row is appended with what `saving` wrote in the same flush; the selection does not move; no window opens;
      a busy project throws `CreationBusy`; a checkout owner throws and opens no tab (`RecordingDaemon` saw no
      `createTab` and no `activate`); `openUnattended` asks for a background window.
    - Proof: `--filter UnattendedCreateTests`, `TaskWorkflowTests`, `ReviewInTaskTests`.
  - **3b. Route, queue, gate, launch** (item signals).
    - `ItemRouter.swift`: `apply(observations:)` returns launches and pick-ups. `.startOrdinary` builds a
      `ProjectPickup` and writes nothing. `.rematch` is written in step 5; until then it only records
      `seen(.started)`. Skips are recorded as today. Project events go to a second hook, not `changed`, so they are
      neither written to the Operator's activity log nor wake it. The router is handed the claims.
    - `ProjectSignals.swift` (new, built lazily by `SignalOperatorController` like `stages`, its effects behind a
      `Ports` struct the app sets: create, open, restore, deliver): `enqueue`, the per-project runners, the
      re-check before the create, the pause wait and window turn copied from `SignalWorkerIO.launch`
      (`SignalWorkerIO.swift:212-261`), `drop(notListed:)` for a full read that no longer lists a queued item,
      `claimed`, and `tick()`, which starts runners and re-queues every task whose origin still owes its launch.
      All work starts through `ports.work`, so tests join it with `settled()`.
    - Forks first: a merge request from a fork (`MergeRequest.forkHead != nil`, `CodeHost.swift:26`; set by
      `GitLabAccount.swift:110`) is skipped before any branch matching or create, with the reason "From a fork:
      AiTerm checks out only branches of the project's own repository.", as `ReviewCreationModel.pick` already
      refuses one. `TaskLauncher`, `TaskCreator.createReview` and `Repository.prepareReviewBranch` do not check, and
      the last resolves only local and `origin` branches, so a fork with an upstream branch's name would otherwise
      review the wrong code. The same check sits in `MatchDecision` for project signals, so a fork never `.rematch`es
      a task on a same-named branch either.
    - What the pick-up builds, from the `SignalItem` as `ItemRouter.makeTask` does: a merge request that is a review
      (`ItemRouter.isReview`) → a `ReviewDraft` with the request and ticket; an own merge request →
      `createOnRequest`; a ticket → a `TaskDraft` with the ticket, its base the project's default branch read off
      the main actor. Agent, model and reasoning are the signal's one row. `promptText` is the signal's bare prompt;
      `appendTicket` and `appendRequest` are its two switches.
    - `SignalPoller.swift`: `mayRead: (UUID) -> Bool` replaces the pause in `canPoll`. A read key is due only when a
      signal sharing it may read; an observation and a failure name only those signals, checked again after the await.
    - `SignalOperatorController.swift`: `canPoll` keeps stopped and locked; `mayRead` is "a project signal, or the
      Operator is not paused"; `onPass` loses its pause guard, routes, starts stages for launches and enqueues
      pick-ups; `reconcile` calls `projectSignals.tick()` after `scheduler.tick()`, before the pause returns;
      `onFailure` for a project signal writes no session, no activity record and no wake.
    - `SignalReadIssues.swift` (Core): per signal `text`, `since`, `attempts`, `raised`; `fail`, `succeed`, `current`,
      `attemptsBeforeBanner = 3`. The controller owns one, observed: `onFailure` calls `fail` for every signal, before
      its same-reason guard, and `onPass` calls `succeed`. For an Operator signal the saved `sourceFailures`, the
      activity record and the wake stay exactly as they are. Nothing draws the issues until steps 7 and 9.
    - `AppState+Signals.swift`: `operatorMayStartWork` is true for a runnable project signal whatever the pause.
    - `OperatorDigest.swift`: `signals`, `skipped` and `nextRuns` keep Operator signals only.
    - `AppController.swift`: sets the ports from `launcher` and the helper, as it sets `signalController.archive`.
    - Launch recovery: at start and each tick, a task whose `owed.kind` is `.launch` and that has an agent session
      or a saved conversation is taken as launched (`owed` cleared, no second prompt, `turn.sentAt` set from the
      launch); otherwise it is queued again. An owed `.delivery` is never cleared by recovery, whatever conversations
      exist (`AppState.rememberingConversations` keeps them after windows close): only a delivery result clears it.
    - Cases: two matches for one project (one after the other); matches for two projects (in parallel, windows one
      at a time through the window turn); the person creating a task in that project (`CreationBusy`, retried next
      tick); the signal switched off or removed, the project removed, or a task made for the item while queued
      (dropped); the item gone from a full read while queued (dropped); the helper away (waits); the row chosen
      during the pause wait (opens at once); the Operator paused (project pick-ups carry on, Operator ones wait); a
      quit during the pause wait (the row and its owed prompt are saved; the next start launches it). Not handled:
      a crash between git's worktree and the saved row leaves a worktree with no row, as a manual create does; the
      next attempt fails with git's reason and shows as skipped.
    - Tests: new `app/Tests/AiTermTests/Operators/ProjectSignalsTests.swift` on `SignalHarness`: a restart with a `.launch` debt and a live agent clears it without a second prompt, and a restart with a `.delivery` debt and an existing conversation keeps it and delivers when idle; a forked request whose source branch has an upstream branch's name is skipped with the fork reason and makes no checkout; a GitLab reviewer
      match makes an ordinary review row with an origin and no `signalTask`; `operatorHasWork` stays false and no
      chat is ensured; the command has no worker denials and no guard; the description envelope appears once; the
      seen record and the row land in one flush; a throwing create leaves a skipped record with the reason and the
      next pass after the back-off succeeds; two matches queue; the pause gate holds the window and a later quiet
      releases it; a paused Operator still lets a project pick-up through while its own signal's item waits; a
      shared read key delivers the observation to the project signal only; the claim keeps an Operator signal off a
      queued item; a relaunch with an owed launch opens once and never twice. `SignalPollerTests`: `mayRead` per
      registration. `SignalControllerTests`: a project signal's failure creates no session and no wake, and counts its
      attempts; a good pass clears them; an Operator signal's saved failure and wake are as before. New
      `app/Tests/AiTermCoreTests/Operators/SignalReadIssuesTests.swift` (pattern `OperatorIssuesTests`).
      `SignalFreshDigestTests`, `SignalStatusBudgetTests`: the digest has no project signal, skip or next run, within
      its budget. `SignalEngineTests`, `SignalJourneyTests`: green unchanged.
    - Proof: `--filter ProjectSignalsTests`, `SignalPollerTests`, `SignalControllerTests`, `SignalReadIssuesTests`,
      `SignalEngineTests`, `SignalJourneyTests`, `SignalFreshDigestTests`.
  - **3c. Schedules.**
    - `SignalScheduler.swift`: `canSchedule` becomes per signal (stopped: none; an Operator signal: not paused; a
      project signal: always). `ItemRouter.apply(schedule:)`: a due run of a project signal returns a pick-up and
      moves its cursor in the same flush, as a run's cursor, not `signalSeen`, keeps it from starting twice
      (`ItemRouter.swift:115-116`). The pick-up's draft: title `ScheduleDecision.runTitle`, branch
      `BranchNaming.runBranch`, the default branch as base, the bare prompt, no descriptions.
    - Because the cursor has moved, a run's pick-up cannot be decided again: a create that fails is retried from
      the queue after the back-off, up to three times, then skipped for good with its reason (the next scheduled
      time is a new run). A quit loses a queued run; it is skipped, as a time missed while AiTerm was closed is
      dropped when a later one is due.
    - Tests: new `app/Tests/AiTermTests/Operators/ProjectSignalScheduleTests.swift` (pattern
      `SignalScheduleJourneyTests`): a due time makes an ordinary task on a run branch with a `.run` origin and no
      `signalTask`; a paused Operator does not stop it and does stop an Operator schedule beside it; the next time
      is skipped with "The last run is still unfinished." while the first task is live and not done, and runs after
      its `doneAt` or its archive; with the helper away across two scheduled times, one run queues, the second is skipped
      as unfinished, and only one task is made when iTerm2 returns; a failing create retries three times and then
      records the skip.
    - Proof: `--filter ProjectSignalScheduleTests`, `SignalScheduleJourneyTests`, `ScheduleDecisionTests`.

- [ ] **4. Done and Then.**
  - `SignalHostIO.swift`: the private query check takes the Done trigger and the item instead of reading
    `task.signalTask`; the Operator's two callers pass their stage's. New `doneFacts(for:done:item:)`: the task's own
    request by `task.mr` or its branch, its merged and closed state, and the query's answer, with the rule that a
    merged or closed request is done even when the query cannot be read (`SignalHostIO.swift:203-205`). `.person`
    asks no query.
  - `ProjectSignalWatch.swift` (new, a tick step run from `reconcile` each `OperatorTiming.reconcileInterval`, after
    the tabs are known and before the pause returns): the pass described under Flows. It skips a task with a
    session at work or asking, as the Operator's watch skips a worker at work. A failed read is unknown and changes
    nothing. Then's archive goes through a port to `TaskTeardown.archive`, with `stillAllowed` true while the task
    exists, keeps the same origin and has no live work.
  - Cases: the signal's Done edited (the key changes, the next read is a baseline); the signal switched off (no
    reads; the first read after it is back compares with the last one, so a Done reached meanwhile counts); the
    signal removed (never read again); a Jira Done on a merge-request task (the key in its branch or title, as today); a scheduled task with a
    GitLab Done before its request exists (no request, no match); unsaved work at archive (`thenNote`, kept); a
    re-match after done (step 5 clears `doneAt`, so the task is watched again). Not handled: Then `.remove`, which a
    project signal cannot save.
  - Runner and re-match: the pre-send baseline read of Flows (pick-up 6 and Re-match) is added here, since it uses this
    step's generalised check; until this step a project signal with a Done query launches without watching Done.
  - Tests: new `app/Tests/AiTermTests/Operators/ProjectSignalWatchTests.swift`: two full review cycles (pick-up, Done,
    Archive; re-match restores, Done again, Archive again) archive both times; Then is retried after a `ClosingWait`
    and after a restart with `doneAt` set and `thenApplied` unset, and not after unsaved work; the baseline is saved before the
    window opens, also when it matches (a Done reached during the first turn is then an edge and archives); a failed
    baseline read holds the launch and retries; a task owing its first prompt is not read by the watch; a re-match
    reads a fresh baseline before typing; not matching then matching is done; merged or closed is done with **You decide**; Keep leaves
    the row and sets `doneAt`; Archive archives through the scripted teardown; a working session delays Then; a
    refusal lands in `thenNote` and is not retried; a paused Operator does not stop the pass; a switched-off signal
    does. `SignalHostIOTests`, `SignalWatchTests`: green, the Operator's reads unchanged.
  - Proof: `--filter ProjectSignalWatchTests`, `SignalHostIOTests`, `SignalWatchTests`, `SignalAutomaticCleanupTests`.

- [ ] **5. Re-match delivery.**
  - `ItemRouter.swift`: `.rematch` writes the change described under Flows and reports the task to `ProjectSignals`.
  - `ProjectSignals.swift`: the delivery step of `tick()`, and on `LiveSessions.onSessionsChanged` for a task that
    owes a prompt: restore, then deliver, open or add a tab as Flows says. Today the typing, unsent-input and
    unwatched-keys checks apply only to the Operator's wake lines (`daemon/aitermd/delivery.py:172-174`), and an
    ordinary delivery types into a draft (`test_a_wake_line_waits_while_you_type`). So the daemon gains a guarded
    mode: `deliver(..., guard_input=True)` applies those three checks to any text without the wake grammar or the
    Operator's pass (`delivery.py` `_check`/`_changed`, the RPC in `docs/daemon-protocol.md`, the app's delivery port).
    `ProjectSignals` always delivers guarded, with ownership 0; `typing`, `unsentInput` and `keysUnwatched` are
    refusals that keep the prompt owed for the next tick. `.delivered` clears `owed` and sets `turn.sentAt`; `.partial` clears it too, since the text now waits in the
    input for the person, and sets `turn.pastedAt` (no `sentAt`: the turn starts only when the person sends it); `.refused` keeps it. An owed prompt whose signal was removed is cleared; one whose signal
    is switched off waits.
  - No note when the item matches again (O5): delivering the prompt clears `notifiedAt`, so step 6's rule notifies
    when the turn it started ends.
  - Cases: the worker at work, asking, or with typed but unsent input (waits); the window closed (opened behind in
    a pause, the conversation resumed with the prompt); the task archived (restored, then as a closed window); the
    restore refused by git (kept owed, the reason shown as the signal's skipped record); a second re-match before
    the first was delivered (one prompt, the newer); an agent whose messaging check has not passed (refused by the
    helper; stays owed and the card says why).
  - Tests, daemon: `daemon/tests/test_delivery.py`: a guarded delivery waits while you type, refuses with unsent
    input and without a key monitor, and types into an empty idle input; an unguarded delivery behaves as today;
    `test_delivery_service.py` covers the RPC field. Tests, app: `ProjectSignalsTests`: a typing or unsent-input
    refusal keeps the prompt owed and it is typed on a later tick; a record flipped to not matching and a new match
    yields one delivery to the same session; nothing is typed while the session works, and it is typed when it turns idle; a closed window is
    opened in the background with a resume command; an archived task is restored first; `.partial` clears the
    debt; under O1 a hand-made task gains an origin and gets the prompt, and has no `signalTask`.
    `SignalSelectionTests.aMergeRequestOnAnExistingTasksBranchContinuesThatTask` stays green for Operator signals.
  - Proof: `--filter ProjectSignalsTests`, `SignalSelectionTests`.

- [ ] **6. First-turn notification.**
  - `ProjectSignals.swift`: the hook and rule under Flows. The note's id is per task; its title is the task's
    title, its body the signal's name and "is ready for you" or "asks you something". It is withdrawn when the row
    is chosen (`RowFocus.onSelectionChanged`) or the task goes.
  - `Operators/OperatorNotifications.swift`: a small maker beside `SignalQuestionNotification`.
  - Cases: a turn that ends with background work running (waits for the real end); a restart after the turn ended
    (the session reads `done`, so it posts once); the worker asking before any turn ends ("asks you something",
    and nothing more for that task); a hand-made task marked under O1 (notified when the turn its
    delivered prompt started ends, like a re-match).
  - Tests: `ProjectSignalsTests`: an O1 hand-made task already done gets no note on delivery and one note after the
    signal's turn worked and ended; a pasted (`pasteOnly`) prompt notifies only after the person sent it and it
    worked; unrelated session updates do not notify; posted once across repeated session events and across a restart; the wording by
    state; nothing for an Operator task, a taken-over task or a task you made; the click's target is the task
    (`SignalSidebarTests.aQuestionNotificationSelectsTheOperatorThroughTheManagedFocusPath` is the pattern).
  - Proof: `--filter ProjectSignalsTests`.

- [ ] **7. The signals sheet and the OPERATOR heading's icon.**
  - `SignalSummary.swift` (Core): `triggers(_:nextRun:calendar:)` moved from `HeadingValue`, with the `.person` line
    "Done: You decide". `HeadingValue` calls it until step 10 removes its signal case.
  - `SignalsSheetModel.swift`: a section kind and a closure giving its rows. A row: id, source mark, name, Starts
    and Done lines, next run, issue lines (cannot run in this version, the failure from the controller's
    `SignalReadIssues`, each skipped item), switched off, can move up and down. Actions: edit, switch, move,
    remove, new; each resolves the saved signal at action time.
  - `Views/SignalsSheet.swift`: `SheetLayout` at `Sheet.height` titled "Operator signals" or "Project signals";
    rows in `RowPill(ground: .sheet)` with `ProviderIcon`, the name in `Typography.bodyEmphasis`, the lines as
    `HelpText`, issues in the warning tone, a switched-off row at `Opacity.disabled` with the pause glyph; the menu
    as a context menu and a trailing menu button (inferred: decision 4 says "each row's menu", the drawing is gone);
    a double-click edits; an empty state sentence; the footer has New Signal… and Done. No switch per row.
  - `SheetKind.swift`, `SheetCoordinator.swift`, `AppController+Signals.swift`: `.signals(SignalsSheetModel)`,
    `presentSignals(_ section:)`. Edit and New replace the sheet (O8).
  - `SidebarProjection.swift`: `SectionFold` gains `signals: Int` and `signalIssue: String?` (set in step 9).
    `Views/SidebarHeadings.swift`: in `SectionHeading`, between the fold chevron and the `+`, a button with the
    signals glyph (O6) and the count in `Typography.chip.tabular`, shown while the section has a signal, with an
    accessibility label in words ("3 Operator signals"). Step 7 wires the Operator's only.
  - Signal headings stay as they are in this step; the sheet is a second way to the same actions.
  - Tests: new `app/Tests/AiTermTests/SignalsSheetModelTests.swift`: rows in priority order; lines for a query, a
    schedule with its next run and **You decide**; issue lines; Move Up changes the order and the priority; Switch
    Off saves through the controller; Remove asks through the scripted prompter. `SidebarProjectionTests`: the count
    follows the signals and redraws only the heading. `SheetDismissalTests`: Edit replaces the list.
    `StatusCountChipsAccessibilityTests` pattern for the icon's label.
  - Proof: `--filter SignalsSheetModelTests`, `SidebarProjectionTests`; snapshots `signals-sheet-operator`,
    `signals-sheet-empty`, `signals-heading-icon` (new poses in `SheetSnapshots.swift` and `SignalSidebarSnapshots.swift`).

- [ ] **8. Project signals in the interface.**
  - `Operators/SignalModel.swift`: `kind`, set by the caller for a new signal and read from the signal when
    editing; `title` is "New Operator signal", "New project signal", "Edit Operator signal" or "Edit project
    signal". For a project signal: one agent row (the first; Add and Remove are absent), `DoneKind` gains
    `.youDecide` in place of `.operatorDecides`, `then` offers Keep and Archive, merge and branch deletion are off,
    a new scheduled signal opens on **You decide** and an item signal on **A query matches**. `signal` writes
    `kind` nil for an Operator signal.
  - `Views/Operators/SignalSheet.swift`: step 1's help line and the name's help by kind (a project signal has no
    heading: "Its tasks start in their projects."); step 3 draws `AgentStep` through its memberwise initializer,
    offering `SignalModel.offeredAgents`, for a project signal and `AgentsStep` otherwise; the prompt step's
    placeholder says "the agent" where it says "the worker".
  - `Views/Operators/SignalDoneStep.swift`: the Done kinds and Then's values come from the model; `SignalDoneSummary`
    for a project signal: "…starts a review in its project with your prompt; a later match runs the prompt again in
    the same task. Its agent asks you directly and no branch guard applies. It’s done when …, or its merge request
    is merged or closed. Then its task is kept / archived." With **You decide**: "You decide when it’s done; a
    merged or closed merge request still ends it."
  - `AppController+Signals.swift`: `presentNewSignal(kind:editing:)`; a new Operator signal opens the Operator's
    section as today, a project signal does not. `Views/SidebarHeadings.swift`: the Projects `+` gains New
    Signal…; the PROJECTS heading gets its icon and sheet. `AiTermApp.swift`: File › New Signal… follows the open
    section (O4).
  - `SignalSidebar.swift`: a project signal never gets a heading under OPERATOR.
  - Tests: `SignalModelTests`: the saved signal has the kind, one row and a valid finish; editing keeps the kind;
    an Operator signal still saves `kind` nil; titles by kind; `canAdvance` at each step. `SignalScheduleModelTests`:
    a scheduled project signal opens on **You decide** and refuses a Jira Done. `FileMenuTests`: the menu's kind by
    open section. `SignalSidebarTests`: no heading for a project signal. `SignalSnapshotTests`: new poses.
  - Proof: `--filter SignalModelTests`, `SignalScheduleModelTests`, `FileMenuTests`, `SignalSnapshotTests`; snapshots
    `signal-project-gitLab-1..5`, `signal-project-schedule-5`, `signals-sheet-projects`; the existing `signal-*`
    poses change only in their title.

- [ ] **9. Errors.**
  - `SignalOperatorController.swift`: at the third failure in a row of a signal (`SignalReadIssues`, step 3b) it
    raises the banner and marks the issue `raised`; `succeed` takes the banner down.
  - `OperationIssue.swift`: `.openSignals(signal:)` ("Open Signals") and `.openSettings` ("Settings…"); `isStale` is
    true once the signal is gone. `Notices.swift`: `report(_:background:)`, which waits behind a shown question even
    when it has actions, and `dropIssue(aboutSignal:)`, which takes a shown or held one down. `AppController.perform`
    opens that signal's section sheet, or Settings › Integrations.
  - The banner: title "“Reviews for me” can’t read GitLab.", reason the error and "AiTerm tries again at 14:05."
    (the failure time plus `SignalPoller.failureBackOff`). Raised once per streak; dismissed, it does not return
    until the signal has recovered and failed three times again.
  - `SidebarProjection.swift`: its `failures` input reads the issues; `SectionFold.signalIssue` is the first
    failing signal's sentence in the sheet's order, else the first skipped item's. `SectionHeading`: the icon and
    count in `Palette.amber` with that sentence as help. The sheet's failure line gains the retry time.
  - Cases: two signals failing (the newest banner wins the one slot; both show in the sheet); a failure while a
    Rebase question is up (held, shown when the question goes); the network back (the read is due at once; a good
    read clears); the signal removed while failing (stale, dropped); a restart (attempts start again).
  - Tests: `SignalControllerTests`: three failures raise the banner once, a fourth does not, a good pass clears the
    issue and the banner. `NoticesTests`: the background
    report waits behind a question; `dropIssue(aboutSignal:)`. Both `OperationIssueTests`: titles and staleness.
    `SidebarProjectionTests`: the amber fact is on the fold value and redraws only the heading.
  - Proof: `--filter SignalControllerTests`, `NoticesTests`, `OperationIssueTests`, `SidebarProjectionTests`;
    snapshots `signals-heading-issue`, `signals-sheet-issues`, `issue-signal-read`.

- [ ] **10. The Operator section by project.** Three sub-steps; signal headings are replaced in 10b, in one commit.
  - **10a. Values, beside the old ones** (nothing drawn changes).
    - `SignalSidebar.swift`: `operatorEntries: [SidebarEntry]`, the Projects entries with each section's tasks cut
      to the ones the Operator holds (presented by `presentingOperator`), no terminals, no move flags, its fold read
      from `operatorFolded`; a section with none is left out; a divider stays only when a project survives between
      it and the next divider.
    - `OperatorSession.projectRowID(_:)` (Core): the project's id XORed with `rowID`, so the heading has an id of
      its own that turns back into the project's.
    - `RowFocus.swift`: `RowSelection.operatorProject(UUID)`, its `id` the derived one; `row(id:)` resolves it.
    - `HeadingValue.swift`: `Kind.operatorProject(Project)` and `init(operatorSection:)`: the project's mark and
      name, folded counts as a signal heading counted them (statuses of the unfinished, the finished apart).
    - `ProjectActions.swift` or `AppController+Operators.swift`: `toggleOperatorFold(_ project:)`.
    - Tests: `SignalSidebarTests`: grouping, task order, a project with none left out, a divider with no surviving
      project left out, two dividers in a row, the fold apart from `Project.collapsed`. `ModelsTests` or a small new
      test: the derived id round-trips and differs from the project's.
  - **10b. Draw it.**
    - `SidebarProjection.swift`: publishes the new entries and their sections; every reader of `signalSections`
      moves to them (`operatorNeedingAttention`, `rowStatuses`, `finishedTasks`, `operatorChip`, `operatorPath`,
      `isDrawn`, `visibleHeading`, `backgroundJobs`, `crossing`); `viewLayout` returns the Projects folds and the
      Operator folds apart; the inputs lose the removed-signal folds, dividers, skipped items and next runs and gain
      `operatorFolded`; `folds` is "the Operator's row is shown, or the section has an entry".
    - `Views/SidebarView.swift`: `operatorRows` draws the Operator's row, then each entry: a divider as a label
      (`DividerRow` with no commands) or a `HeadingRow` tagged with the derived id and its tasks.
    - `Views/SidebarHeadings.swift`: `HeadingRow` for `.operatorProject`: no `+`, an empty trailing slot (the line's
      in step 12), no menu, its click and Return fold through `toggleOperatorFold`; the signal case, its menu and
      its pause mark go. The Operator `+` loses Add Divider….
    - `AppController.swift`, `AppController+Operators.swift`: `activateSelection`, `choose`, `targetProject` and
      `reveal` handle `.operatorProject` (a revealed task unfolds its project in the Operator section);
      `toggleCollapsed(_ signal:)` goes. `ProjectActions.swift`: Focus View and List View save both layouts.
    - `SignalSidebar.swift`: `SignalOperatorRowValue.title` is "Running 3 tasks", "Running 1 task" or "No tasks".
    - Removed with this step: `SignalSection`, `OperatorEntry`, the removed-signal headings and their runtime
      folds, `RowSelection.signal`. A removed signal's tasks stay under their project; the card (step 11) names the
      signal as removed.
    - Cases: a task of a folded project needing you (Focus View and a notification unfold it); the last held task
      of a project leaving (its heading and, if it was the last, its divider go; a selection on the heading is
      dropped by `RowFocus.dropStale`); the arrows crossing the fold (the path's last row is now a task or a folded
      project heading); a project in both sections selected in one and then the other (two ids, no shared selection).
    - Tests: `SignalSidebarTests`: the tests about signal headings, their moves, dividers, removed headings and
      their tooltips are replaced by project-heading tests (drawn order, fold, selection, Return, the chip's
      target, crossing); the title tests read "Running n tasks". `SidebarProjectionTests`, `AppControllerTests`,
      `SignalSelectionTests`, `SidebarInteractionTests`, `RowAccessibilityTests`, `LockedSidebarTests`,
      `SignalSidebarPresentTests`: updated to the new entries and selection. `SidebarRowRedrawTests`:
      `expandedSignalHeadersIgnoreLedgersAndTheirChildStatusChanges` becomes the Operator project heading's;
      `SidebarRowGeometryTests`: row counts.
  - **10c. Delete what nothing reads.** `signalDividers` leaves `AppState.CodingKeys`, so `PreservedFields` carries
    the key, and `removeSignal` becomes a plain removal; the divider model and mutators in `Models.swift`; `addSignalDivider`,
    `renameSignalDivider`, `moveSignalDivider`, `removeSignalDivider`, `presentNewDividerInOpenSection`'s Operator
    branch and `canAddSignalDivider` in `AppController+Signals.swift`; `RenameTarget.signalDivider` and
    `SheetKind.newDivider`'s section in `SheetKind.swift`, `SheetCoordinator.swift`, `Views/NameSheet.swift` and
    `Views/SidebarView.swift`; `DividerRow.init(signalEntry:)`; the File › Add Divider… rule in `AiTermApp.swift`
    (it always adds to Projects). `Signal.collapsed` stays in the model, unread: removing it would change the
    bytes of every saved signal and stage. Tests: `FileMenuTests`, `ModelsTests`, `AppControllerTests` lose their
    signal-divider cases; `ModelsTests` gains: a workspace saved with dividers loads, saves the same
    `signalDividers` value, and still does after a signal is removed.
  - Proof: `--filter SignalSidebarTests`, `SidebarProjectionTests`, `AppControllerTests`, `SidebarRowRedrawTests`,
    `FileMenuTests`, `ModelsTests`; snapshots: `signals-by-project`, `signals-by-project-divider`,
    `signals-by-project-folded` and `signals-removed-signal` are new; `signals-divider`, `signals-removed` and
    `signals-off` go; every other `signals-*` pose is compared with its "before".

- [ ] **11. The avatar disc and the signal card.**
  - Core: `TaskRow.startedBySignal`, set in `SidebarModel.taskRow` for a task with `signalOrigin` or `signalTask`.
    `SidebarProjection.DrawnTask` gains the origin's drawn facts (signal, name, the steps, whether a prompt is
    owed, `doneAt`, `thenNote`) and the record's `earlier`, so the row and an open card follow them.
  - `Views/AvatarGroupView.swift`, `SidebarRowContent.swift`: an optional corner disc on the group's first mark:
    `SymbolMark` with the signals glyph at `Size.cornerBadge`, ringed in `surface.occludingBackground` at
    `AvatarGroupView.ringWidth`, as a badge's corner check is. The column's width does not change. Its hover
    target is a `Size.chip` square centred on it (inferred).
  - `Views/SignalCard.swift`: `SignalCard` (heading, steps, current line) and `SignalCardView`, on the chrome
    extracted from `BackgroundCardView` (padding, `menuChrome`, `.surface(.sheet)`): the heading in the help style,
    one `Size.chip` line per signal that ran the task, oldest first, with its time, earlier ones in `muted`, and a
    last line for the work going on now.
  - The current line: an Operator task says the Operator's act ("Operator answering its worker") or its line's
    words; a project task says "waiting for your pause to open its window", "waiting for its worker to be idle"
    (with the helper's refusal as help), its status's label, or "Done · kept" / "Done · archived" with `thenNote`.
  - `Views/BackgroundCard.swift`: a second environment key and hover object (`BackgroundCardHover`, same delays) for
    the disc, and a `signalCard(_:source:)` modifier beside `backgroundCard`. `BackgroundCardPresenter.swift`: the
    card's content is jobs or a signal card, and its anchor the trailing mark or "after the avatar" (leading edge
    at the avatar column's trailing edge plus `Space.tight`, the same vertical rule). One card at a time: presenting
    one closes the other. `SidebarProjection.signalCard(for:)` resolves the open card, as `backgroundJobs(for:)` does.
  - `TaskRowAccessibility`: the row's value says "Started by <signal>".
  - Cases: a hand-made task (no disc); a taken-over task (disc and chain; its current line is its status's label); a
    removed signal ("<name> (removed)"); a row on its way out (no card, as `eligible` rules for jobs); both cards'
    hovers on one row (the newer wins).
  - Tests: `BackgroundCardTests`: the signal card's lines for an Operator task, a project task in each state, a
    chain of three and a removed signal; the second hover opens and closes on its own delays.
    `BackgroundCardPresentationTests`: the "after the avatar" frame at each interface size, and that one card replaces the other.
    `SidebarProjectionTests`: an origin change redraws its row only. `RowAccessibilityTests`. `SidebarRowGeometryTests`:
    the title's x is unchanged with a disc.
  - Proof: `--filter BackgroundCardTests`, `BackgroundCardPresentationTests`, `RowAccessibilityTests`; snapshots
    `signals-disc`, `signals-card-operator`, `signals-card-project`, `signals-card-chain`.

- [ ] **12. The status line.** Four sub-steps. Step 0's result decides how a segment reaches its neighbour.
  - **12a. Tokens and the segment.**
    - `Palette.statusLine` (alias of `idleRing`, added to `PaletteDistinctionTests`' alias manifest); `Motion.march`;
      `Size.statusStop`. An exchange is `Palette.text`, a question `Palette.amber`.
    - `Views/StatusLine.swift`: `StatusLineSegment`, drawn from a `StatusLinePiece`: the stroke is
      `RingGeometry.strokeWidth` of the scaled trailing glyph, round ends, centred in the trailing slot; it stops
      `Space.base` from a mark's centre and `Size.statusStop` from a stop's centre (correction 12), all scaled.
      Dotted: `Space.hairline` on, `Space.tight` off. Marching is a Core Animation dash-phase animation whose start
      is anchored to media time, as `SpinnerArc`'s is, so every segment is in step without a `body` per frame; each
      segment's base phase is its top's y in the list's document coordinates modulo the period, so dots line up
      across rows and stay so while scrolling. With `motionStill` set (Reduce Motion or a snapshot) the dots stand
      still at that phase; the snapshot path draws a SwiftUI stroke, since `ImageRenderer` cannot draw a layer.
    - Tests: `app/Tests/AiTermUITests/MetricsTests.swift`, `PaletteDistinctionTests`, `DesignRulesTests` green; a
      view test that a still segment's dash phase follows its y, and that Reduce Motion adds no animation.
  - **12b. Where the line runs** (at rest, solid).
    - `Sidebar/StatusLine.swift` (Core): `StatusLinePiece` has `above` and `below` (each an optional
      `StatusLineInk`) and a node: none, a mark, or a stop with its ink. The pure rule takes the open Operator
      section's rows in drawn order and the workload's task ids: the line starts under the Operator's mark and ends
      above the last row that is a workload task or a folded project holding one; a task row in between is passed
      around its mark; a divider and an unfolded heading are passed through; rows after the end have no piece; no
      shown Operator row or no workload means no line.
    - `SidebarProjection.swift`: writes each row's piece into a `PerRow` cell, only when it changed.
      The task row's and the Operator row's mark slots, `HeadingRow`'s trailing slot and the Operator section's
      `DividerRow` (whose rule now ends before the trailing slot) host a leaf view that reads its own cell.
    - Tests: `app/Tests/AiTermCoreTests/SidebarModelTests.swift` or a new `StatusLineTests`: the rule for one task,
      several projects, a finished task in between, a finished task last, a divider, no workload.
      `StatusLineSeamTests` now measures the real segments. `SidebarRowRedrawTests`: a piece changing redraws no
      row body.
  - **12c. Exchanges.**
    - `Operators/OperatorActivity.swift`, `OperatorWaker.swift`: a wake for a task (`workerEnded`, `taskBlocked`)
      records a pulse on the tracker that ends after `Motion.pulse` and publishes through `activity.changed`.
    - The rule gains the acts (`actsByTask`), the pulses and the tasks with a current question. An exchange's
      stretch is every segment from the Operator's mark to its task's mark. Acting marches down in `text` for as
      long as the act lasts; a wake marches up in `text` once; a question holds its stretch amber and still.
      Overlaps follow O7.
    - Tests: the rule's tests for each ink, the stretch's extent and overlaps; `OperatorActivityTests`: a pulse
      starts on a wake and ends by itself; `SidebarRowRedrawTests`: an act on the third task redraws that task's
      row and the Operator's, and no other row's body.
  - **12d. The folded stop.** A folded Operator project holding a workload task has a stop node on its heading's
    row; an exchange with a task inside ends at the stop, which takes the stretch's ink; unfolding removes it. The
    heading's status chips are unchanged. Tests: the rule for a folded project at rest, acting, asking, with only
    finished tasks (passed through, no stop), and last in the section.
  - Proof: `--filter StatusLineTests`, `StatusLineSeamTests`, `SidebarRowRedrawTests`, `OperatorActivityTests`;
    snapshots `signals-line-rest`, `signals-line-acting`, `signals-line-waking`, `signals-line-asking`,
    `signals-line-stop`, `signals-line-stop-acting`, `signals-line-stop-asking`, stacked and hosted, at the three
    interface sizes.

- [ ] **13. Docs, design system, release.**
  - `docs/operators.md`: the two kinds and what a project signal keeps and drops; the sections by project; the
    signals sheets, priority within a kind, project signals first; the icon, amber and the banner; the disc and
    card; the line; schedules for project signals and O3's rule; that a project signal's first turn has no branch
    guard; "Running n tasks"; the Create steps in the sheet's order (Agents before Prompt; the doc has them
    swapped); every sentence about signal headings, their tooltips, Add Divider… under the Operator and removed
    signals' headings.
  - `docs/architecture.md`: the owners table gains `ProjectSignals`, `ProjectSignalWatch` and `SignalReadIssues`;
    "Signals have one runtime and one Operator chat" names the ordinary route; `AppState`'s list of what it stores;
    `TaskLauncher`'s paragraph gains the unattended create and open. Its link to `workflow/release.md#operator-format`
    has no target: propose the section to the owner (workflow docs change only on a yes).
  - `app/Sources/AiTermUI/README.md`: `Motion`, `Size.statusStop`, `Palette.statusLine`; the App composition rows
    for `SectionHeading` (icon, no Operator divider), `HeadingRow` (project, Operator project), `SignalsSheet`,
    `SignalCardView`, `StatusLineSegment`, the avatar disc.
  - `docs/design/design-system.html`: remove the signals proposal from the Proposals tab, then sync Foundations and
    Components from the Swift with the `design-system` skill. `docs/keyboard.md` if ⌘S's meaning changed (O4).
  - `docs/release-notes/`: what a user sees, and the downgrade warning from Risks. The version is ship's call.
  - Propose for `docs/workflow/verify.md` (on the owner's yes): that hosted captures are the proof for anything
    drawn across list rows.
  - Proof: snapshots before and after read and compared one last time; `scripts/test.sh`; before the merge the
    full-suite proof or `scripts/test.sh all`; the live list in Proof handed to the maintainer.
