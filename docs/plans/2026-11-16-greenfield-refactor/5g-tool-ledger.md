# 5g. The tool handler's ledger is the only ledger of calls

Implementer: Opus 5.5, high effort. Depends on: phases 1 to 4 and steps 5a to 5f (5c's
`OracleConsult`, 5e's `OperatorInFlight`, 5f's wake state). Audit findings: operator-runtime F7 and
F12 (`docs/research/2026-11-16-greenfield-audit/operator-runtime.md`), narrowed by the plan's
review: only `answer_worker`'s duplicate ledger goes; the record rules stay.

## Why

Every keyed Operator tool call is made idempotent once, by the tool handler: `tool:<tool>:<key>`,
the same arguments, kept seven days, `pending` while running and `uncertain` recorded before an
effect that a dropped connection could leave half done. `answer_worker` predates that rule and
still keeps a second ledger entry under `answer_worker:<key>`, with its own encoding of the
arguments and its own "already running" set, so the same call is ledgered twice and can be refused
with two different sentences. The `run_status` wake acknowledgement and its refusal live outside
the handler, in the controller's request routing, so one tool's rules sit outside the
validate, decide, act shape. And two agent-choice decisions sit in the wrong owners: the 80 %
weekly-usage switch for a fallback row is decided at launch inside the worker I/O owner, and
`open_tab`'s choice of rows is computed inside the tool handler. The end state: one ledger of
calls; the uniqueness rules on records that outlive the ledger stay with their owners; the wake
acknowledgement is part of the handler; the agent-choice owner makes every agent-row decision. The
fourteen tools and their schema do not change.

## Today

Described as after 5f. Anchors are today's symbols; re-read before changing.

- `SignalOperatorToolHandler.perform` (`app/Sources/AiTerm/Operators/SignalOperatorToolHandler.swift`):
  `requireSession`, then the ledger lookup by `tool:<tool>:<key>` (seven days, same canonical
  arguments or "This key already names a different call. Use the original arguments to retry."),
  the handler's `running` set (same key in flight answers `pending`), task and authority checks,
  `uncertain` recorded first for `message_task`, `open_tab`, `ask_oracle`, `resume_task`,
  `finish_stage`, `choose_agent`, then `execute`, then `remember(result)` unless it is `pending`.
- `QuestionRounds.answer(task:key:proposal:tab:challenge:fromQuestion:person:)`
  (`QuestionRounds.swift`), called only from the handler's `answerWorker` case
  (`rg -n 'answer\(task:' app/Sources`). It builds its own `arguments` string, looks up
  `answer_worker:<key>` in `operatorSession.ledger` (no age check; mismatch: "This key was already
  used for a different answer."), keeps `running` keyed by that string, and wraps each result in
  its private `remember(_:key:arguments:)`, which flushes and throws "The answer couldn’t be saved."
  After 5e its per-question round set is the shared `OperatorInFlight` claim; after 5c its rounds run
  through `OracleConsult`, and the saved "agreed, about to deliver" round still makes a restart ask
  the person instead of typing an answer twice.
- The wake acknowledgement: after 5d the controller's request routing (`answer(_:using:)`, today
  about lines 469 to 484 of `SignalOperatorController.swift`) asks the waker. For `run_status` with a
  `task` while `waker.unread` (after 5f: the waker's state is not none, or the open lifecycle holds
  an unread wake) it checks `requireSession` and answers "A wake may include updates for other
  tasks. Call run_status without task first.", then calls `tools.recorded` by hand. After a global
  `run_status` that returns a result it calls `waker.acknowledge()` (clear, save, succeed `.wake`).
- The record rules: `QuestionRounds.askYou` ("That question key is already in use."),
  `QuestionRounds.resolveQuestion` ("This question already has a different answer."), `report_snag`
  in `SignalOperatorToolHandler+Calls.swift` ("That snag key already names a different report."),
  `SignalJournal.note` ("That note key already names a different decision."), and
  `SignalWorkerIO.openTab`'s tab key ("That tab key names another launch.").
- The launch-time switch: `SignalWorkerIO.launch` (about lines 265 to 283 today) applies
  `ModelChoice.launchChoice(planned:pinned:weekly:installed:rows:)` when the task has no first
  worker conversation, it is launch attempt 1 and its `choice.decided == .disagreed`; it saves the
  switched row on the task and `choice.launchSwitch`, flushes, journals
  `AgentChoiceRecord.switchLine` through the `recordSwitch` port (wired in the controller), and
  re-reads the task. `rg -n 'recordSwitch|launchChoice' app/Sources`.
- `open_tab`'s choice: the handler's `openTab` case computes
  `AgentChoiceNeed.decide(permitted:projects:conversationAgent:)` from the task's configuration and,
  only when it is `choose` with more than one row, calls `choices.decide(scope: .tab …)`, journals
  "Work tab <key>: " plus the record's `journalLine`, and opens with the decided row and reason;
  otherwise it opens with the proposal as given.
- The agent-choice owner (`AgentChoiceRounds.swift`, after 5c mapping `OracleConsult` outcomes)
  returns `decided(AgentChoiceRecord)` or `reply`; `StageRunner.choose` applies a decided record to
  the task and journals `choice.journalLine`.

Tests: `SignalQuestionRoundsTests`, `SignalToolHandlerTests`, `SignalAgentChoiceTests`,
`SignalWorkerIOTests` (`onlyAFallbackRowMovesOffAnAgentAtItsWeeklyLimit`), `SignalFreshSessionTests`
(`aScopedStatusCannotAcknowledgeCoalescedUpdatesForOtherTasks`), `SignalOperatorIssueTests`,
`ModelChoiceTests`.

## Change

1. **`answer_worker` uses the handler's ledger only.** In `QuestionRounds.answer`, delete the
   `answer_worker:<key>` lookup, the `arguments` string built for it, the `running` set and the
   private `remember`; each branch returns its result directly. Drop the `key` parameter and the
   `!key.isEmpty` check (the handler requires `key` for every mutating tool). The handler's existing
   `remember` stores every non-`pending` result once under `tool:answer_worker:<key>`.
2. **Do not add `answer_worker` to the handler's `uncertain` list.** A lost reply after delivery
   already replays from the handler's ledger, which is written before the reply is sent; a crash
   between agreement and the ledger write is covered by the saved agreed round, which asks the
   person instead of typing twice.
3. **The wake acknowledgement moves into the handler.** Add two ports to
   `SignalOperatorToolHandler.Ports`: `wakeUnread` (wired to `waker.unread`) and `acknowledgeWake`
   (wired to `waker.acknowledge()`). In `perform`, right after `requireSession` and before the
   ledger and task checks, `run_status` with a `task` while `wakeUnread()` throws a
   `ToolRefusal` with today's sentence. After `execute` returns a `run_status` result without a
   `task` (and after the post-checks), call `acknowledgeWake()`. The controller's request routing
   becomes: `gate_command` goes to the shell gate; every other tool goes to `tools.respond`. Its
   hand-written `tools.recorded` call goes; `respond` records every answer the same way.
4. **The agent-choice owner makes the launch-time switch.** When three rounds end in disagreement
   for a stage (`scope == .stage`, outcome `disagreed`, row = the first permitted row), the owner
   applies `ModelChoice.launchChoice(planned: fallbackRow, pinned: false, weekly:, installed:,
   rows:)` with weekly usage and installed agents from the ports 5c gave it, and puts a different
   result in the record's `launchSwitch`. It does not switch when the task has a saved first worker
   conversation. `StageRunner.choose` applies `launchSwitch ?? row` to the task's agent, model and
   reasoning, journals `choice.journalLine`, then `AgentChoiceRecord.switchLine` when there is a
   switch, then launches. Delete the switch block from `SignalWorkerIO.launch`, the `recordSwitch`
   port and its wiring; `launch` never chooses.
5. **`open_tab` asks the agent-choice owner once.** Add one entry point on the owner for a work
   tab that takes the task, the proposal (row, reason), the challenge id and the tab's prompt,
   computes the choosable rows itself (`AgentChoiceNeed.decide`, as the handler does today) and
   returns either a reply (challenged, pending, retry) or the row and reason to open with, plus the
   record when a round decided it. With one choosable row, or none, it returns the proposal as
   given and no record, as today. The handler journals "Work tab <key>: " plus the record's
   `journalLine` when there is a record, checks `allowed()`, claims the task and opens. The tab's
   scope never switches at launch, as today.
6. **List the changed refusal texts in the commit body** (model-facing):
   - Reusing an `answer_worker` key with different arguments: "This key was already used for a
     different answer." becomes the handler's "This key already names a different call. Use the
     original arguments to retry." (Today the handler's check already answered first in nearly
     every case.)
   - A failed save of an `answer_worker` result: "The answer couldn’t be saved." becomes the
     handler's "The tool result couldn’t be saved."
   No other reply text changes. `tools.json` and the brief are untouched.

## Keep

- The handler's ledger rule, its seven days, its 500-entry cap (`OperatorSession.remember`), its
  `pending` and `uncertain` behaviour, and its `running` set.
- Every record rule listed under Today, with its wording. These records outlive the ledger (seven
  days, 500 entries): a question id is recorded once, a resolved question keeps its answer, a snag
  key and a note key each name one record, a tab key names one launch.
- The worker-answer owner's other refusals and saves as 5c left them (for example "The Operator
  cannot answer right now.", the saved `ready` round and the binding checks on `fromQuestion`).
- The saved agreed round that makes a restart ask the person: the protection against typing an
  answer twice.
- `AgentChoiceRecord.launchSwitch` and `switchLine`: `run_status` shows the switch and the journal
  says it.
- `ModelChoice.launchChoice` and `launchAgent` as pure rules with their tests.

## Decisions already taken

- **A saved `answer_worker:` entry from before this step** is left in the ledger until it ages out;
  nothing reads it. No cleanup code.
- **The scoped `run_status` refusal** now passes through the handler's `respond`, so it is recorded
  in the activity log exactly as before (refused outcome, the same sentence).
- **Order of checks for scoped `run_status`:** session first, then the wake refusal, then task
  validation, as today; an unknown task during an outstanding wake still gets the wake sentence.
- **The switch is decided when the disagreement ends, not at launch.** `StageRunner.choose` launches
  at once, so weekly usage is read at the same moment in practice. A later launch attempt of the
  same stage (resume after a block) keeps the decided row, as the launch-attempt-1 condition did.
- **Weekly usage unavailable** (no usage read yet) means no switch, as `launchChoice` already does
  with an empty map.
- **The project-only choice** (`operatorAlone`) and single-row signals never switch, as today.

## Tests

- Move `SignalQuestionRoundsTests.agreementAnswersOnceAndTheSavedKeySurvivesARestart` to
  `SignalToolHandlerTests` through the handler: an agreed `answer_worker` replays after a restart
  with no second Oracle call or delivery, and the saved ledger holds exactly one entry,
  `tool:answer_worker:a1`. The `QuestionRounds` version is deleted; the moved test detects the same
  failure.
- Adjust every `rounds.answer(task:key:…)` call in `SignalQuestionRoundsTests` to the new signature;
  assertions do not change.
- Move `SignalWorkerIOTests.onlyAFallbackRowMovesOffAnAgentAtItsWeeklyLimit` to
  `SignalAgentChoiceTests`: three disagreeing rounds with Claude at 80 % and Codex installed at 20 %
  launch on Codex's first row, the choice's `launchSwitch` is that row and the journal has the
  agent-row line then the switch line; an agreed row at 80 % launches as chosen. The old test is
  deleted with the code it tested.
- Add to `SignalToolHandlerTests`, with fake ports: a scoped `run_status` is refused while
  `wakeUnread` and is recorded; a global one acknowledges once; a refused scoped call does not
  acknowledge.
- `SignalFreshSessionTests.aScopedStatusCannotAcknowledgeCoalescedUpdatesForOtherTasks` and
  `SignalAgentChoiceTests`' work-tab tests must pass unchanged.

## Proof

- Iterate: `scripts/test.sh swift -- --filter 'SignalQuestionRoundsTests|SignalToolHandlerTests|SignalAgentChoiceTests|SignalWorkerIOTests|SignalFreshSessionTests|SignalOperatorIssueTests|SignalControllerTests|ModelChoiceTests|SignalOperatorContractTests|SignalJourneyTests'`.
- Then plain `scripts/test.sh`, started in the background.
- `SignalOperatorContractTests` proves the brief and the fourteen-tool schema did not change.

## Done when

- `rg -n '"answer_worker:"' app/Sources` returns nothing.
- `rg -n 'recordSwitch|launchChoice' app/Sources/AiTerm/Operators/SignalWorkerIO.swift` returns
  nothing; `launchChoice` is called only by the agent-choice owner.
- `rg -n 'AgentChoiceNeed.decide' app/Sources/AiTerm/Operators/SignalOperatorToolHandler*.swift`
  returns nothing.
- The controller's request routing has no `run_status` special case
  (`rg -n 'run_status' app/Sources/AiTerm/Operators/SignalOperatorController.swift` finds none).
- The suites above and plain `scripts/test.sh` are green; the commit body lists the two changed
  refusal texts.
- `docs/architecture.md`'s tool-handler row still reads true (it says it validates idempotency).

## Not in this step

- Regrouping `Signals/` and moving the agent-choice types into one Core file: 5h.
- The Oracle prompts and `OracleConsult` itself: 5c, already done.
- The eval with the live Operator: the maintainer's, after phase 5.
