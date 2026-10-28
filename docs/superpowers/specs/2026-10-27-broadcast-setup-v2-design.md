# Broadcast setup v2: agents, task settings and the broadcast's goal

## Intent

A broadcast's setup mixes up what belongs to each task and what belongs to the whole broadcast. Today New
Broadcast has four steps, Broadcast · Prompt · Review · Done. Review and Done are free text that apply to each
task, but they read as if they were about the broadcast. The Operator may start any agent, model and reasoning
level: in one run it started several Fable 5.1 workers the person didn't want. Finished tasks keep their tabs,
worktrees and branches. Nothing checks whether the broadcast reached what it was for.

This change makes every setting belong clearly either to each task or to the broadcast as a whole. The Operator
works within the agents the person allows, finished work is cleaned up, and once every task is done the Operator
checks the broadcast's goal with the Oracle and, within a budget, plans what is still missing.

The visual design was picked on the design page's Proposals tab (`docs/design/design-system.html`, sections
`p-bs2-*`): 1A, 10A, 13A, 14A, 15A, 16 and 17A. Those drawings are the reference for every view below.

## Goals

- New Broadcast has five steps: **Broadcast · Prompt · Agents · Task · Done**. Steps 1 and 2 are unchanged.
- **Agents** is the only list the Operator may start workers, tabs and reviewers from, and the board shows which
  combination each worker runs.
- **Task** holds what every task follows, labelled as per-task: its review, its end, and whether it is closed
  once done. The person can change one running task's end from its card.
- **Done** holds the broadcast's goal and its budget, counted in extra rounds.

## Non-goals

- No change to steps 1 and 2, to the slices other than what is said below, or to how a worker is started.
- No new time limits. The fixed 90 minutes without a commit and 4 hours in total (`OperatorTiming`) stay as they
  are, and the Operator resumes a blocked task as today.
- No change to people's review of a merge request (the Review slice).
- No PI workers. PI stays possible as the Oracle only.

## Anti-goals

- Losing work. Nothing removes a worktree with uncommitted or untracked changes, deletes a branch that isn't merged
  into the default branch, or deletes a remote branch.
- A setting that reads as broadcast-wide but acts per task, or the reverse.
- The Operator quietly working around the Agents list or the person's chosen end.

## Decided

### Agents (step 3)

- **The list.** Rows of Agent · Model · Reasoning, built from `ModelReasoningFields` with an Agent `Select` in
  front and a ✕ after (design 1A). The agents are Claude and Codex only. A row's models and reasoning levels are
  that agent's own (`ModelFiles`), as Settings › Agents lists them. “Add an agent” adds a row with that agent's
  default from Settings › Agents. At least one row is needed to continue, and identical rows are kept once.
- **Seeded** from the previous broadcast's list, minus rows whose agent is no longer installed or whose model is
  no longer listed. With no previous list, it starts with one row per installed agent at its Settings › Agents
  default.
- **Enforced.** `create_task`, `update_task` and `open_tab` refuse any agent, model and reasoning level that isn't
  a row, and the refusal names the rows. Reviewer tabs are `open_tab` calls, so the same check covers them. A call
  that names an agent but no model gets that agent's first row.
- **The person's words don't widen it.** If the prompt names a combination that isn't on the list, the Operator
  doesn't start it. It asks the person, with `ask_you` on no task, whether to use a row instead. `agentPinned`
  keeps its meaning only within the list: it lifts the weekly-use rule and the delivery refusal.
- **Weekly use.** At 80 % weekly use on an agent, a new task moves to a row on the other agent: the first such
  row, in the list's order. With none on the list, it stays where it is. The switch happens where it happens today,
  at launch (`WorkerStarter.launchChoice`, `ModelChoice`). Unlike today, it never lands on a model that isn't a row.
  *(My call.)*
- The Oracle is not on the list: it stays Settings › Operator's own setting.

### Task (step 4)

Drawn as design 13A. Every label starts with “Each task” or “A task”, and a lead line says “Every task follows
these. The broadcast's own goal is the next step.”

- **Review: one open prompt.** It is a `PromptStep`, as today's Review step is, and `/` lists both agents' skills.
  Its help says: “Who reviews each task, what counts as passing, and how many rounds of fixes it gets before it
  comes to you. Type / for skills. Optional: left empty, a task is accepted without a review.” There are no
  separate fields for passing or rounds.
- **The reviewer is a visible tab.** The Operator runs each review as a worker tab on the task (`open_tab` with
  `role: review`), on a row from the Agents list that the prompt names, or else of its choosing. Where the list has
  another agent than the task's worker, it should pick that one. The tab works in the task's worktree, and its
  first prompt is the review prompt plus AiTerm's lines:
  - the commit under review;
  - that it only reviews, and never edits, commits or pushes;
  - that it may start its own subagents and run read-only commands;
  - that it ends with a verdict block (`ReviewVerdict.block` below).

  The commit under review is the branch head when the tab opens, and its first prompt names it. For a review tab,
  `brief` is optional: whatever the Operator writes is added after the review prompt. *(My call.)*

  AiTerm starts a review tab read-only where its agent allows it. Claude gets the worker's denials plus Edit, Write
  and NotebookEdit. Codex runs with its read-only sandbox. Subagents and read-only git stay available.
- **Verdicts are recorded, not a gate.** Once a review tab's turn ends, the Operator reads it and calls
  `record_review` with the commit it reviewed, whether it passed by the prompt's own words, and its counts.
  AiTerm keeps each verdict on the task, against its commit. The Operator decides when to accept: AiTerm does not
  refuse an acceptance without a passing verdict. Before a merge, the Oracle's merge check is given the review
  prompt and the task's verdicts, in place of today's Review and Done text.
- **Fix rounds** are counted by the Operator, from the prompt's words. It passes `round` with every
  `record_review`, and `rounds` too when the prompt names a number. AiTerm doesn't parse the prompt. When the rounds
  are used up, the Operator asks the person with `ask_you` on the task and `about: fixRounds`, and the card says so
  (see Board). *(My call.)*
- **The end** is one choice for every task: Commit · Draft MR · Merge · Local merge, as a neutral
  `SegmentedControl`. Help: “Where every task's work ends.” The Merge slice stays a house rule. While it is off,
  Merge and Local merge are dimmed and can't be picked (`isSelectable`). The help adds “Merge is off in Settings ›
  Operator, so a task ends at a commit or a draft MR.”
- **Only the person changes an end.** `create_task` and `update_task` lose `end` for new broadcasts: every task
  starts with the Task step's end. The person changes one running task's end from its card (Board).
- **When the broadcast ends**: two checkboxes on one edge. They read “Close finished tasks’ tabs and remove their
  worktrees” (default on) and “Delete their local branches once merged into the default branch” (default off). The second
  is disabled while the first is off. What they do is under Auto-close.
- The step is 37 pt taller than `Sheet.height` allows, so its content scrolls a little. This is accepted.

### Done (step 5)

Drawn as design 10A.

- **Goal**: a `PromptStep`. Help: “What must be true once every task is done. The Operator checks it with the
  Oracle. Optional: left empty, the broadcast ends when its tasks do.”
- **Extra rounds**: one number, 0 or more, default 2. Help: “How many times the Operator may plan what the goal
  still misses, once every task is done. When they are used up, it stops and says what is left.” There is no
  hours limit and no count of added tasks. Within a round, additions follow today's backlog rule: past a quarter of
  the first plan's size, each needs the Oracle's yes.
- **A goal needs the Oracle.** While the Oracle is off in Settings › Operator, the goal and the rounds are disabled.
  Their help says “The Oracle is off in Settings › Operator, and a goal needs it: the broadcast ends when its tasks
  do.” The broadcast then starts with no goal.

### The goal loop

1. A goal check is due when every task is finished (`RunScheduler.isComplete`), the broadcast has a goal that is
   not yet resolved, and either there has been no check yet or a plan revision has been submitted since the last
   one. It then doesn't complete. It stays `.active` with `goalCheckDue` set, and AiTerm wakes the Operator: “[AiTerm] Every
   task is done: check the goal with check_goal.”
2. The Operator calls `check_goal` with `met`, `evidence` and, when not met, `missing`: the lines still to do. The
   Oracle answers it as a veto. It is asked whether the Operator's verdict is right, given the goal, each task's
   result (its accepted commit, merge record, diff stat and verdicts) and the evidence. Only a yes acts. A no is
   refused with the Oracle's reason, and the Operator calls again (the existing challenge flow). If the Oracle is
   missing, fails or is too slow, the call acts unchallenged, and the check is recorded as not checked by the Oracle.
3. **Met**: the outcome is recorded and the broadcast completes as today (`settle`), and the summary is asked for.
4. **Not met, rounds left**: `roundsUsed` goes up by one, `goalCheckDue` clears, and the answer tells the Operator
   to plan what is missing (`create_task`, then `submit_plan`). Once that revision's tasks are all finished, step 1
   happens again. If the Operator finds that nothing can be planned, it calls `check_goal` again before submitting
   anything. That call is accepted while the last answer was `planMore` and no revision has been submitted since,
   and it takes no further round. *(My call.)*
5. **Not met, no rounds left**: the outcome is recorded as not met, each `missing` line goes to `leftForYou`, and
   the broadcast completes.

With 0 extra rounds the goal is checked once and only reported. The backlog rule stays as picked in 10A: the
quarter is counted from the first plan across the whole broadcast, goal rounds included, so tasks planned in a goal
round past that quarter each need the Oracle's yes. `write_summary` is refused while `goalCheckDue` is
set.

### Auto-close

- **When: at the end of the broadcast** (the person's answer to the builder check). Rows, tabs and worktrees stay
  for the whole run, so dependencies, `code` children, goal rounds, `message_task`'s reopen and the completion
  check all keep reading live tasks as today. Closing runs twice:
  - once the broadcast is complete, with its summary written or given up on;
  - at End Broadcast, for whatever is still eligible.

  A complete broadcast that a new plan reopens may have closed tasks, and a `dependsOn` naming one is refused with
  “<task> was closed when the broadcast completed.” *(My call.)*
- **Which tasks.** Those finished by reaching their end: published, accepted with a commit end, or ended with no
  change. A task that failed, was stopped, or whose publication was left for the person is not closed. It happens
  only with “Close finished tasks’ tabs and remove their worktrees” on.
- **Removed, not shelved.** Closing takes the person's Remove path without its questions: tabs closed and
  confirmed closed, worktree removed, row gone. The person picked Remove, so the task doesn't go to the Shelf.
- **Its card stays.** Before removing anything, AiTerm writes a `FinishedTaskRecord` to the broadcast. The board's
  Done column, the summary, `run_status` and the ended broadcast on the Shelf read removed tasks from these records.
- **Never loses work.** A worktree with uncommitted or untracked changes is not touched: the card says “worktree
  kept” with “Not closed: its worktree has uncommitted changes. Remove it yourself once they are safe.” A task
  with a tab the person is driving (`youAreDriving`) waits until that turn ends. While the closing waits, the
  card says what for in short copy under its rule: “Waiting for your turn to end”, “Waiting for its turn to end”
  or “Waiting for the helper”. A removal that fails leaves the row, and its card says why.
- **The branch** is deleted only when the second box is ticked, the local branch head is still the accepted
  commit, and one of these holds:
  - the accepted commit is an ancestor of the default branch, locally or on origin after a fetch;
  - AiTerm recorded the host merging the request at that commit (`publication.merged` with `mergedHead` equal to
    it), which covers squash merges.

  Remote branches are never deleted. Commit and draft MR ends are never merged, so their branches stay.
- `read_task` on a removed task reads its diff from the accepted commit, and answers that its tabs are closed for
  the rest.

### Board

- **The combination line** (design 14A). Under the ticket and project, in `Typography.monoCode` and
  `Palette.muted`, on the card's text edge, sits the first worker's model and reasoning, such as “Opus 5.5 · High”.
  A card with several tabs puts each tab's combination under that tab's key instead. The line is never cut short.
- **The end line** (design 17A). While a task is not finished, the line under that reads “ends at”, then a `Badge`
  with its end that opens a menu of the four ends, the current one ticked. Merge and Local merge are disabled while
  the Merge slice is off. The badge takes its own click; the rest of the card keeps opening what it opens today.
  The line goes once the task finishes.
- **Changing an end** is the person's act (`OperatorController+Controls`), allowed until the task finishes:
  - It sets the task's end. Of its publication it clears what was in progress for the old end (`waitingSince`,
    `readySince`, `problem`, `mergeRefusal`, `conditionsHeld`) and keeps what already happened (`pushedSHA`, the
    merge request and its number).
  - A switch to an end below what is done finishes the task as it stands. For example Commit, after a draft MR
    was opened: the request is left open, and that goes to `leftForYou`.
  - The Operator is woken: “[AiTerm] You changed <task>'s end to <end>.”, and the next `finish_task` follows the
    new end.
- **No stale lines.** A card's status line is always worked out from the task's current end and the publication
  state that end uses, so a switch never leaves “merging” or “refused” behind.
- **The header** (design 15A) has two lines in the Asked style, each limited to two lines, with the whole text in
  the tooltip:
  - **Asked** with **Goal**;
  - **Each task**, which quotes the review prompt, then “ends at <the Task step's end>”, then “closed at the end”
    when closing is on.

  The band's tail adds “round n of m” once the goal is being checked, when the band reads “checking the goal”. An
  ended broadcast's band says “goal met”, “goal not met” or “goal not checked by the Oracle”, then how much was
  left for the person.
- **The new stops** (design 16):
  - A task in review lists its review tab like any other tab. Its line reads “in review · round n of m” when the
    prompt names the rounds and the Operator has recorded verdicts; otherwise it uses today's words.
  - A task whose open question is `about: fixRounds` reads “out of fix rounds” in the needs-you badge. Under the
    card's rule sit the last verdict's counts, then two link-style actions: “One More Round” and “Accept As It Is”.
    Each wakes the Operator with the person's answer (“[AiTerm] You answered <task>'s fix rounds: one more
    round.”). The Operator resolves the question, as with an answer in its chat.
  - The “worktree kept” card is as under Auto-close. Its words appear only after the closing has run.
  - A removed task's card is drawn from its record, its line ending “· removed”.

### What the Operator is told

`OperatorCommand.brief` and `firstMessage` change for new broadcasts:

- **This broadcast**: the Agents rows; under “Each task”, the review prompt, the end and the closing; then the goal
  and its extra rounds.
- **Agent and model**: choose only from the rows. The person's words choose among them, never outside them, and an
  off-list ask goes to `ask_you`.
- **The end**: every task ends at the Task step's end, which only the person changes. Don't plan around it.
- **Reviews**: run each one as an `open_tab` with `role: review`, then `record_review`. Count the rounds by the
  prompt's words, and when they run out, `ask_you` on the task with `about: fixRounds`. Accept on your own
  judgement of the verdicts.
- **The goal**: when woken for it, call `check_goal`. Plan only what `missing` names. The rounds are the budget.

The first message reads “Your broadcast:”, then the prompt, then “Each task is reviewed with: …” when there is a
review, then “Goal: …” when there is one.

## Data

New file `app/Sources/AiTermCore/BroadcastSettings.swift`, beside `OperatorModels.swift` and plain data like it.
Every field may be missing on decode, and unknown keys are preserved (`PreservedFields`), as elsewhere in that file.

```swift
public struct AgentChoice: Codable, Equatable, Hashable, Sendable { var agent: AgentKind; var model: String; var reasoning: String? }
public struct TaskSettings: Codable, Equatable, Sendable {
    var review: String?            // the open prompt; nil: no review
    var end: TaskEnd               // every task's end at the start
    var closeWhenDone: Bool        // default true
    var deleteMergedBranch: Bool   // default false; ignored while closeWhenDone is false
}
public struct BroadcastGoal: Codable, Equatable, Sendable { var text: String; var extraRounds: Int }
public enum GoalOutcome: String, Codable, Sendable { case met, notMet, unchecked }
public struct GoalCheck: Codable, Equatable, Sendable {
    var round: Int; var met: Bool; var evidence: String; var missing: [String]
    var oracleAgreed: Bool?        // nil: not checked by the Oracle
    var at: Date
}
public enum TabRole: String, Codable, Sendable { case work, review }
public struct ReviewVerdict: Codable, Equatable, Sendable {
    var tab: String; var sha: String; var passed: Bool; var round: Int; var rounds: Int?
    var critical: Int; var important: Int; var minor: Int; var summary: String; var at: Date
    // `static let block`: the lines a review tab is told to end with, as AiTerm words them.
}
public struct FinishedTaskRecord: Codable, Equatable, Sendable {
    var task: UUID; var key: String; var title: String; var ticket: String?; var project: UUID
    var agent: AgentKind; var model: String; var reasoning: String?
    var end: TaskEnd; var state: OperatedState; var acceptedSHA: String?; var branch: String
    var mergeRequestURL: String?; var mergedSHA: String?; var result: String   // the card's line, as it read
    var branchDeleted: Bool; var at: Date
}
```

- `OperatorRun` gains:
  - `agents: [AgentChoice]`, `taskSettings: TaskSettings?`, `goal: BroadcastGoal?`;
  - `goalCheckDue: Bool`, `roundsUsed: Int`, `goalChecks: [GoalCheck]`, `goalOutcome: GoalOutcome?`, and
    `revisionAtLastCheck: Int?` (the plan revision when the last check was answered);
  - `finished: [FinishedTaskRecord]`, and `closedAt: Date?` (when the closing last ran).

  Each new field is left out of the save while empty or nil, as `gateAllowances` is.
- `OperatedTask` gains `reviewVerdicts: [ReviewVerdict]`. `ExtraTab` gains `role: TabRole` (default `work`).
  `OperatorQuestion` gains `about: String?` (`"fixRounds"`).
- **No new `OperatorRunState` case.** The goal check is `.active` with `goalCheckDue`, so no existing switch changes.
- **Legacy.** A run with `taskSettings == nil` was started before this change. It keeps today's behaviour in every
  respect: `review` and `done` text, any agent and model, `end` on `create_task`, no closing and no goal. New runs
  leave `review` and `done` nil.

## Operator tools

The daemon serves the schemas (`daemon/aitermd/operator_mcp.py`); the app checks every argument.

- `create_task`, `update_task`: `end` is refused for a new broadcast, with “Every task ends at <end>, which only
  the person changes.” It stays for legacy runs. They gain `reasoning`, checked against the rows.
- `open_tab`: gains `reasoning`, and `role` (`work` or `review`, default `work`).
- `review_task`: refused for a new broadcast, with “Run the review in a tab: open_tab with role review, then
  record_review.” It stays for legacy runs.
- **New** `record_review(task, tab, sha, passed, critical, important, minor, summary, round, rounds?, key)`:
  - It records a verdict. `sha` must be on the task's branch, `tab` must be one of its review tabs, and the same
    key returns the first answer.
  - It answers the task's verdicts and how many failed.
  - Mutating, and not challenged.
- **New** `check_goal(met, evidence, missing?, challengeId?, challengeReply?)`: refused unless `goalCheckDue`. It
  is challenged as a veto (it joins `CHALLENGED_TOOLS`). It answers `complete`, `planMore` with the rounds left, or
  `stopped` with what went to `leftForYou`.
- `ask_you`: gains `about` (only `fixRounds` for now).
- `run_status` adds the Agents rows under `agents.allowed`, `taskSettings`, `goal`, `goalCheckDue`, `roundsUsed`,
  each task's `reviewVerdicts`, and the removed tasks from `finished`.

## Slices

**Where it lands.** Everything merges into an integration branch, `feat/broadcast-setup-v2`, cut from `main`:
first S0, then each of P1–P7, then the docs sync. `main` gets the branch once, after all of them are in and
`scripts/test.sh all` passes. So no slice has to keep a half-built new broadcast safe on `main`. *(My call.)*

**S0 goes first, alone.** Once it is merged, P1–P7 are built in parallel. Each owns the files listed and touches no
other slice's files; its tests sit beside them. A slice that finds it needs another slice's file says so and stops,
rather than editing it.

**S0 · Contract and persistence.**
- **Files:**
  - `AiTermCore/BroadcastSettings.swift` (new) and `AiTermCore/OperatorModels.swift`;
  - `AiTermCore/Operators/OperatorTool.swift` (the two new cases), `AiTermCore/Operators/ActivityLine.swift` (their
    words) and `AiTermCore/Operators/RunStatus.swift` (the new fields);
  - `AiTerm/Operators/OperatorToolHandler.swift` (dispatch, `mutating`, and `write_summary` refused while
    `goalCheckDue` is set);
  - `AiTerm/Operators/OperatorToolHandler+Verdicts.swift` and `AiTerm/Operators/OperatorToolHandler+Goal.swift`,
    both new, each one function refusing with “not built yet”;
  - `AiTerm/Operators/OperatorToolHandler+Challenge.swift` (`check_goal` registered as a veto, with a placeholder
    prompt);
  - `AiTerm/Operators/OperatorController.swift` (`startBroadcast` takes `agents`, `taskSettings` and `goal`,
    freezes them, and saves the rows as the last broadcast's);
  - `AiTerm/Operators/OperatorProfileStore.swift` (the last broadcast's rows: load and save);
  - `AiTerm/Operators/NewBroadcastModel.swift` (`Request` and `start()` only);
  - `AiTerm/Operators/TabOpener.swift` (a `role` parameter, passed through, with no behaviour yet);
  - `daemon/aitermd/operator_mcp.py`: every schema above, worded in full;
  - the shared touch points that the parallel slices would otherwise fight over:
    - the `startBroadcast` call and `presentNewBroadcast` in `AiTerm/AppController+Operators.swift`, and
      `presentNewBroadcast` in `AiTerm/SheetCoordinator.swift`, which hand the sheet one `NewBroadcastContext`
      (slices, the Oracle setting, installed agents and their models, Settings › Agents defaults, the last
      broadcast's rows);
    - the `NewBroadcastModel` fixture in `AiTerm/Snapshots/OperatorSnapshots.swift`;
    - `ask_you`'s `about`, stored by `askYou` in `OperatorToolHandler.swift`;
    - an `onRunChanged` hook called from `OperatorController.runChanged`, for P6 to subscribe to;
    - the shared test fixtures (`OperatorFakes`, `OperatorFixtures`, `OperatedWorld`, `OperatorUIFixtures`), extended
      for the new fields. After S0, a slice adds fixtures in a file of its own.
- **Tests:** codable round-trips, a legacy run decoding unchanged, and the tool registry
  (`OperatorToolTests`, `test_operator_mcp.py`).

**P1 · What the Operator is told.**
- **Files:** `AiTermCore/Operators/OperatorCommand.swift` and its tests.
- **Builds:** the brief and first message under “What the Operator is told”, for new runs, with legacy runs
  unchanged.

**P2 · The Agents list, enforced.**
- **Files:** `AiTerm/Operators/OperatorToolHandler+Plan.swift`, `AiTerm/Operators/OperatorToolHandler+Tabs.swift`,
  `AiTerm/Operators/WorkerStarter.swift` and `AiTermCore/Operators/ModelChoice.swift`, with their tests.
- **Builds:** the row check on `create_task`, `update_task` and `open_tab`, including `reasoning`; the refusal of
  `end` on new runs, with the task's end taken from `taskSettings`; `role` passed to `TabOpener`; the weekly-use
  switch at launch within the rows; and `dependsOn` naming a closed task (one in `finished`, no longer a row)
  refused with the words under Auto-close.

**P3 · The setup sheet.**
- **Files:** `AiTerm/Operators/NewBroadcastModel.swift`, `AiTerm/Views/Operators/NewBroadcastSheet.swift`, the
  broadcast's `CreationSteps` in `AiTerm/CreationModel.swift`, new `AiTerm/Views/Operators/AgentsStep.swift`,
  `TaskStep.swift` and `DoneStep.swift`, a new snapshot file `AiTerm/Snapshots/BroadcastSetupSnapshots.swift`, and
  its registration in `AiTerm/Snapshots/Snapshots.swift`.
- **Builds:** steps 3–5 as designed, seeded from S0's last-broadcast rows, with the slices and the Oracle read from
  the profile the sheet opened with.

**P4 · The board.**
- **Files:**
  - in Core, `AiTermCore/Sidebar/BroadcastBoard.swift`, `AiTermCore/Sidebar/OperatorLine.swift`,
    `AiTermCore/Operators/RunSummary.swift` and a new `AiTermCore/Operators/TaskEndChange.swift`;
  - in the app, `AiTerm/Views/Operators/BroadcastBoardSheet.swift`, `BroadcastHeaderRow.swift`,
    `BroadcastSummaryView.swift`, `AiTerm/Operators/OperatorController+Controls.swift` and
    `AiTerm/Snapshots/OperatorSnapshots.swift`.
- **Builds:** the combination and end lines; the end change and its wake line; status lines from the current end;
  the header; the new stops and their actions; cards from `finished` records; the goal outcome in the band and
  the summary.

**P5 · Review tabs and verdicts.**
- **Files:** `AiTerm/Operators/TabOpener.swift` (the review brief and the read-only launch),
  `AiTermCore/Agents/AgentCommand.swift` (the read-only flags), `AiTerm/Operators/OperatorToolHandler+Review.swift`
  (`review_task` refused on new runs), `AiTerm/Operators/OperatorToolHandler+Verdicts.swift` and
  `AiTermCore/Operators/AgentReview.swift` (`ReviewVerdict.block`'s wording, if kept there).
- **Builds:** a review tab that starts read-only and is told to end with the verdict block, and `record_review`.

**P6 · Auto-close.**
- **Files:** a new `AiTerm/Operators/TaskAutoCloser.swift`, a new `AiTermCore/Operators/MergedBranchCheck.swift`,
  `AiTerm/TaskRemover.swift` (a removal without questions, for AiTerm's own use),
  `AiTerm/Operators/OperatorToolHandler+Tasks.swift` (`read_task` on a closed task) and
  `AiTerm/AppController+Operators.swift` (wiring), and `AiTermCore/Tasks/TaskWorkflow.swift` if deleting a
  squash-merged branch needs a forced delete that it doesn't offer yet.
- **Builds:** everything under Auto-close, including the `FinishedTaskRecord` written before the removal.

**P7 · The goal loop.**
- **Files:** `AiTerm/Operators/OperatorController.swift` (`settle` and the wake), `AiTerm/Operators/OperatorToolHandler+Goal.swift`,
  `AiTerm/Operators/OperatorToolHandler+Challenge.swift` (the goal veto, and the merge check's inputs) and
  `AiTermCore/Operators/ChallengeLaunch.swift` (`goalPrompt`, and `mergePrompt` taking the review prompt and the
  task's verdicts in place of Review and Done text).
- **Builds:** everything under The goal loop, and the Oracle's merge check fed with the verdicts.

**After P1–P7 merge.** One last step syncs `docs/design/design-system.html` to the Swift (the `design-system`
skill): the `p-bs2-*` proposals leave the Proposals tab, Components gains what shipped, and
`app/Sources/AiTermUI/README.md`'s inventory changes with the new views. The README's Operator section describes
the five steps.

## Left to the builder

- The verdict block's exact lines, as long as it carries passed, the three counts and a one-line summary that the
  Operator can copy into `record_review`.
- How the read-only launch is spelled for each agent, checked against the installed CLIs. If an agent has no
  read-only mode for an interactive session, its review tab starts with the worker's denials alone, and its brief
  says so.
- Where the previous broadcast's rows are kept in `OperatorProfileStore`, and their key.
- The board's spacing and sizes, from `Metrics` and the design page's drawings. Nothing invents a token.

## Testing

Each slice follows `CLAUDE.md`: `scripts/test.sh swift -- --filter <Suite>` while iterating, plain `scripts/test.sh`
before each commit, and `scripts/test.sh all` once before merging. The Swift snapshots cover the three new steps,
the Merge-off and Oracle-off states, and the cards and header of P4. Engine tests cover:
- the row check, the end refusal and the end change's publication clearing;
- the branch rule, including a squash merge and a moved branch head, and a dirty worktree being kept;
- the goal loop's three answers and the 0-rounds case;
- a legacy run behaving as today.
