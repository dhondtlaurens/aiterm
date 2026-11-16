# The Operator and the Oracle choose each signal task's agent row

## Goal

A signal may permit several Agent · Model · Reasoning rows. Today every task, later stage and
multi-project ticket on such a signal is created **blocked** and drawn as "blocked · needs you"
while it waits on the Operator, which then picks alone through `resume_task`, without the Oracle
or a recorded reason; a first launch may still swap the agent silently at 80% weekly usage.

After this change waiting for that choice is its own state, drawn as the Operator acting. The
Operator proposes one permitted row (and, when needed, the linked project) with a one-line reason;
the Oracle agrees or critiques through the same round rules as `answer_worker`; the agreed row
launches and is journaled and shown in `run_status`. The choice never reaches the person. A
single-row, single-project signal behaves exactly as today.

## Approach

A new task phase `choosing` sits between a stage's intent and its launch. AiTerm enters it instead
of `blocked` whenever a pure rule says something is left to choose: more than one permitted row
the worker may use, or several linked projects. The Operator settles it with one new tool,
`choose_agent` (row, optional project, reason, optional `challengeId`). Each call is one Oracle
round, bound to the task's stage and ownership, at most three rounds, using the round ledger now
inside `QuestionRounds`, extracted so both owners share it. The outcome is applied by
`StageRunner`, which moves the task back to `launching` and launches as today.

Decided while planning:

- **Project-only choice** (several linked projects, one row) also uses `choosing` and `choose_agent`,
  but with no Oracle round: the Operator alone decides, as today. Nothing about choosing a project
  or a row is drawn as "needs you" any more.
- **Both open** (several projects and several rows): one `choose_agent` call names both; the Oracle
  round judges both together.
- **Outcomes**: Oracle agrees → the proposal. Oracle off, unavailable, answering anything other than
  a clear YES/NO, or an interrupted round found after a restart → the Operator's proposal applies,
  journaled with why. The exception is a check invalidated because the Oracle's settings or the
  standing instructions changed during it (`SignalOracleSettingsChanged`) while the Oracle stays on:
  the round is discarded, the task stays `choosing`, and the call returns `retry` so the Operator
  proposes again against the current instructions (as the shell gate does). Three rounds of disagreement → the first permitted row (in the person's list
  order, among the rows the worker may use) and the Operator's last proposed project; the journal
  says so.
- **Later stage with a saved conversation**: the conversation keeps its agent. The choosable rows are
  the permitted rows for that agent. Exactly one such row applies with no proposal and no tokens;
  none means the full choice and a new conversation, as a changed agent does today.
- **Work tabs**: `open_tab` on a signal with several permitted rows goes through the same rounds
  (`challengeId` added; a critique returns `challenged` and opens nothing). Its existing `why` is the
  reason. One permitted row opens as today.
- **80% switch**: the Operator gets weekly usage per agent and the installed agents in
  `run_status` and weighs the rule itself. A row the Operator chose launches as chosen. Only the
  three-round fallback row still passes through `ModelChoice.launchChoice`; a switch there is
  journaled and recorded on the task's choice, which `run_status` shows.
- **resume_task** stays for `blocked` tasks (worker did not start, interrupted launch, failed
  stage) and always resumes on the decided row and project. It refuses a `choosing` task, and it
  refuses an `agent` or `project` that differs from the decided one, pointing to `choose_agent`.
  `choose_agent` therefore also accepts a `blocked` task whose row or project should change: the
  same rounds run, the new choice and reason replace the saved ones, and the stage resumes on it.
  A project still cannot change once the task has a checkout.
- **Upgrade**: saved tasks blocked by the old router or stage runner with exactly
  "Choose a permitted agent and model for this task.", "… for this stage." or "Choose which linked
  project should hold this ticket." are normalized to `choosing` (with their choosable rows and
  candidate projects) on the controller's first reconcile, and get an `agent_choice` wake. Every
  other block is left as it is.
- **Wake**: entering `choosing` wakes the Operator with `agent_choice <task>`, the same coalescing
  wake path as `task_blocked`.
- Choice rounds of a stale stage or ownership are pruned like stale `answer_worker` rounds; a round
  is refused once the task was taken over, paused or switched off, as every task call is.

Not changed: the candidate-project rule itself (`ItemProjectMapper`), the question rounds'
behaviour, the saved-state golden (new fields are sparse optionals), and the historical eval
baseline.

## Files

### AiTermCore

- `Operators/Signals/TaskPhase.swift` — modify: add `choosing` (`{"kind":"choosing"}`); neither active
  nor continuable. Older builds read it as `unknown` and leave it inert.
- `Operators/Signals/SignalAction.swift`, `SignalTransitions.swift` — modify: `needChoice`
  (`launching → choosing`) and `chosen` (`choosing → launching`, ownership + 1, like resume); stop and
  Take Over from `choosing`.
- `Operators/Signals/AgentChoiceNeed.swift` — create: the pure rule. From the stage's permitted rows,
  candidate projects and the main worker's saved-conversation agent it returns either the row to
  apply or what is left to choose (rows, projects), plus the fallback row. Also the saved
  `ChosenRow` record: row, project, reason, how it was decided (Oracle agreed in round n, Oracle off,
  Oracle unavailable with why, three-round fallback, Operator alone for a project), when, and any
  launch switch.
- `Operators/Signals/SignalTask.swift` — modify: sparse `choosableRows` and `chosen`.
- `Operators/Signals/AppState+Signals.swift` — modify: a `choosing` task may still start work.
- `Operators/Signals/OperatorDigest.swift` — modify: task lines carry `choosableRows` and `chosen`;
  the digest carries `installedAgents`; tab lines carry their reason.
- `Operators/Signals/SignalOperatorTool.swift` — modify: `choose_agent`, mutating, task-bound, act
  "choosing its agent". Fourteen tools.
- `Operators/Signals/SignalOperatorCommand.swift` — modify: the brief's hard-limit line and Work
  section say how a row and project are chosen (`choose_agent`, reason, usage and installed agents,
  the 80% rule, rounds, no person) and that `resume_task` is for blocked tasks; "fourteen tools".

### App

- `Operators/ItemRouter.swift` — modify: new tasks and continued stages ask `AgentChoiceNeed`;
  `choosing` instead of `blocked`, including multi-project tickets.
- `Operators/StageRunner.swift` — modify: `finish` enters `choosing` the same way; new `choose`
  applies a decided row/project, journals it and runs the stage; after a launch that switched agent,
  journal the switch; `resume` refuses `choosing` and keeps the current permitted row by default.
- `Operators/OracleRoundLedger.swift` — create: the round bookkeeping extracted from `QuestionRounds`
  (open round by binding, `challengeId` continuity, round count, discussion history, mark and clear).
- `Operators/QuestionRounds.swift` — modify: use the ledger; behaviour unchanged.
- `Operators/AgentChoiceRounds.swift` — create: proposal ↔ Oracle rounds for a stage choice and for a
  work tab, mapping verdicts to the outcomes above.
- `Operators/SignalOperatorToolHandler.swift`, `+Calls.swift` — modify: execute `choose_agent`
  (validating against `choosableRows` and candidate projects), route multi-row `open_tab` through the
  rounds, mark both uncertain before their effect, pass installed agents to `run_status`.
- `Operators/SignalOperatorController.swift` — modify: build `AgentChoiceRounds` with its Oracle
  prompt (item, stage brief, project, permitted rows, proposal and reason, usage, installed agents,
  discussion; YES or NO); wake `agent_choice`; prune stale choice rounds; normalize old choice
  blocks to `choosing` once on reconcile.
- `Operators/SignalWorkerIO.swift` — modify: `launchChoice` only for a fallback row; record the
  switch on the task's choice.
- `SignalSidebar.swift` — modify: `choosing` draws "Operator choosing its agent" (or "its project")
  with the acting look and working status, so it counts toward nothing that needs the person.
- `Snapshots/SignalSidebarSnapshots.swift` — modify: a `choosing` pose; the `blocked` pose gets a
  reason that is still a block (an interrupted launch).
- Any other exhaustive `TaskPhase` switch the compiler finds.

### Daemon, fixtures and docs

- `daemon/aitermd/signal_tools.json` — modify: add `choose_agent`; `open_tab` gains `challengeId`;
  `resume_task` described as for blocked tasks.
- `daemon/tests/test_operator_mcp.py` — modify: fourteen tools.
- `app/Tests/AiTermTests/Operators/SignalSelectionTests.swift`, `SignalEngineTests.swift` — modify:
  the cases that expect choice blocks and `resume_task` selection move to `choosing` and
  `choose_agent`.
- `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/brief.md`, `tools.json`,
  `PROVENANCE.md` — modify deliberately, with a provenance entry for this contract change.
- `docs/operators.md` — modify: step 4, the linked-projects paragraph and the Oracle section.
- `docs/architecture.md`, `docs/daemon-protocol.md`, `docs/testing.md`, `docs/workflow/release.md` —
  modify: fourteen tools; the choice owner in the ownership map.

## Proof

- New `AiTermCoreTests/Operators/AgentChoiceNeedTests`: one row; several rows; several projects;
  both; a saved conversation with one, several and no rows for its agent; the fallback row.
- `SignalDomainTests` / `SignalForwardCompatibilityTests`: `choosing` transitions and edges, Take Over
  and stop from it, `choosing` and the sparse fields round-trip, absent fields decode.
- `SignalOperatorContractTests`: fourteen tools, updated brief and schema bytes.
- New `AiTermTests/Operators/SignalAgentChoiceTests` on `SignalHarness` with a fake Oracle:
  - Oracle agrees; critiques then agrees (`challengeId`, new key); three rounds of disagreement →
    first row and the Operator's project, journaled; Oracle off; Oracle unavailable.
  - A single-row signal: the task launches as today and the Oracle port is never called.
  - A later stage: re-enters `choosing`; with a saved conversation only that agent's rows are
    accepted, one such row applies with no round.
  - A ticket with two linked projects on a two-row signal: one call settles both; a project-only
    choice applies without an Oracle round.
  - The done-when journey: a two-row signal and three matching tickets start three workers; at every
    step no task is `blocked` and no sidebar row is `needsInput`; each journal names the row and its
    reason; `run_status` shows them.
  - `open_tab` on a two-row signal is challenged before anything opens, then opens on agreement.
  - `resume_task` still resumes a blocked task on its decided row, refuses a choosing task and a
    different row; `choose_agent` on a blocked task re-runs the rounds and resumes on the new row.
  - An Oracle check invalidated by changed settings keeps the task choosing and returns `retry`.
  - A saved task blocked with an old choice reason becomes `choosing` on reconcile; a task blocked
    for another reason stays blocked.
  - A stale ownership or Take Over during a round refuses the late result.
- Existing `SignalSelectionTests` and `SignalEngineTests` cases that expect a multi-row or
  multi-project task to be `blocked` and resumed through `resume_task` are rewritten to the new
  flow in the same step; their intent (no launch before a choice, only permitted rows, project
  candidates) is kept.
- `SignalWorkerIOTests`: an agreed row at 90% weekly usage launches unchanged; a fallback row
  switches, and the switch is recorded.
- `SignalSidebarTests` and `scripts/snapshots.sh build/agent-choice`: the choosing row reads as the
  Operator acting; I read the PNGs against `app/Sources/AiTermUI/README.md`.
- `daemon/.venv/bin/pytest -k operator_mcp`; the gate before each commit; `scripts/test.sh all` plain
  before merging.
- The brief changed, so the capped comparison is rerun once (`AITERM_LIVE_OPERATOR=1`, three
  repetitions, same model and limits) and recorded in `PROVENANCE.md`. It spends quota: run on the
  maintainer's go. A live Jira flow only through `scripts/run-dev.sh` on the maintainer's go.

## To-dos

- [ ] The rule and the phase: `AgentChoiceNeed`, `ChosenRow`, `choosing`, its transitions and sparse
      fields, with their core tests. Nothing routes into it yet.
- [ ] Extract `OracleRoundLedger` from `QuestionRounds`; `SignalQuestionRoundsTests` stay green
      unchanged.
- [ ] `choose_agent` end to end: schema, handler, `AgentChoiceRounds`, `StageRunner.choose`, router and
      `finish` entering `choosing`, the `agent_choice` wake, digest fields, the sidebar row, the
      fallback-only launch switch, `resume_task` changes, the upgrade normalization; in the same
      step the brief, `brief.md`/`tools.json` fixtures, the daemon tool test and the rewritten
      `SignalSelectionTests`/`SignalEngineTests` cases, so the gate stays green;
      `SignalAgentChoiceTests` and the journey.
- [ ] `open_tab` through the rounds for multi-row signals, with its schema fixture and tests.
- [ ] Provenance, docs and snapshots; read the PNGs; capped eval on the go.
