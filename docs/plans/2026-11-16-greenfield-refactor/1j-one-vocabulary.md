# 1j. One vocabulary

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1a to 1i (they deleted the dead Oracle prompts, `OperatorLine` members, the Shelf
names, the old-format readers and Find a Fix, so the renames below meet a smaller tree; if a name below is already gone, say so and go on).
Comes from: OC F4, OC F5, RT F11, DM F7, and the comment lists in TL F4, SB F2, SS F4.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- **The Operator's tool contract keeps its word "challenge".** `challengeId`, the reply status `challenged` and the
  `challenge` argument of `answer_worker`, `open_tab` and `choose_agent` are in `daemon/aitermd/signal_tools.json`, in
  `operator-signals/tools.json` and in the brief ("A critique returns a challengeId"). Renaming them changes the
  fourteen-tool schema and the brief, which the plan freezes outside 5g. So the Swift code that reads the tool's own
  arguments (the `challenge:` parameters in `QuestionRounds.answer`, `AgentChoiceRounds`) keeps them. Everything the Operator
  does not see is renamed. If the maintainer wants the tool words renamed, that is a contract change for step 5g.
- **`prompt(tool:arguments:status:instructions:)` and `instructions` in `ChallengeLaunch`** have no source caller (only
  `ChallengeLaunchTests`). 1d should have deleted them. If they are still there, delete them with their tests and say so; if
  they are gone, ignore every line below about them.
- **The gate's "unchallenged" reasons change.** `SignalShellGate` answers the Operator `unchallenged: the Oracle is off` and
  the daemon's gate says `AiTerm ran this command unchallenged: ...`. Both are model-facing and say a word the vocabulary
  retires. They become "unchecked". The maintainer's live Operator eval (after phase 1) is the check; do not run it.

## Why

The Operator went through broadcasts, runs, a board, challenges and a second opinion before it became signals, an Operator session,
tasks, workers and the Oracle. The code names still carry every phase: `SignalOperatorCommand` over `OperatorCommand`, `runId` on the
wire for the one Operator session's id, `SecondOpinionRunner.challenge` for the Oracle, `operated:` for "a worker", and the shell
gate tells the Operator to use five tools that no longer exist. This step renames each concept once, in code, tests and on the wire,
and rewrites the model-facing gate texts to what is true: commits, checkouts and pushes belong to the task's worker, a merge
request's text and threads are the worker skill's job, and merging is AiTerm's when the signal says so.

## Today and the rename table

Counts are today's occurrences by file (re-run each grep; `\b` word boundaries). Paths are under `app/Sources/` and `app/Tests/`
unless they start with `daemon/`. "New file" means `git mv` the file and keep its history.

| Today | After | Files it touches |
| --- | --- | --- |
| `OperatorCommand` (`AiTermCore/Operators/OperatorCommand.swift`), `SignalOperatorCommand` and `SignalOperatorCommand+Launch` (`AiTermCore/Operators/Signals/`) | one `OperatorLaunch` in `AiTermCore/Operators/OperatorLaunch.swift`; `writePrivate` moves to a small `PrivateFile.write(_:to:)` in `AiTermCore/Harnesses/PrivateFile.swift`; `OperatorCommand.said` is dropped (callers use `Optional<String>.said`, `text.said`) | the three source files (deleted), `WorkerGuard/WorkerGuardLaunch.swift` (five `writePrivate` calls become `PrivateFile.write`), `ShellGate+Denials.swift` (doc comment), `AiTerm/Operators/SignalOperatorController.swift` (`folder`, `prepare`: 5), tests `SignalFreshSessionTests` (2), `SignalOperatorIssueTests` (4), `SignalControllerTests` (1), `SignalOperatorContractTests` (1), `SignalOperatorLaunchTests` (5), `CompatContractTests` (2), `ShellGateTests` (2: `shellDenials`), `SignalWorkerProfileTests` (2), `OperatorEvalRunner` (3: `mcpFile`, `mcpConfig`, `makeToken`, doc), `AiTermTestSupport/TypedText.swift` (doc), `operator-signals/PROVENANCE.md` (one sentence: `OperatorLaunch.brief`) |
| `SignalOperatorTool` | `OperatorTool` (file `Signals/SignalOperatorTool.swift` becomes `OperatorTool.swift`; its raw values, the tool names, do not change) | `ActivityLog.swift` (1), `AiTerm/Operators/SignalOperatorToolHandler.swift` (2), `SignalOperatorToolHandler+Calls.swift` (1), tests `SignalOperatorContractTests` (5), `ActivityLogTests` (1) |
| `ChallengeRecord`, `ChallengeStage`, `ChallengeKind` (`AiTermCore/Operators/OperatorModels.swift`) | `OracleRound`, `OracleRound.Stage`, `OracleRound.Kind`; stage case `unchallenged` becomes `unanswered`; property `unchallengedReason` becomes `unansweredReason` | `OperatorModels.swift` (4), `Signals/OperatorSession.swift` (`oracleRounds: [OracleRound]`), `Signals/OperatorDigest.swift`, `AiTerm/Operators/SignalOperatorToolHandler+Calls.swift`, `RequestWatch.swift`, `AgentChoiceRounds.swift`, `QuestionRounds.swift` (also `.unchallenged` at about 86, 179 and `rounds.unchallenged(...)` at 202), `OracleRoundLedger.swift` (5; its method `unchallenged(_:reason:)` becomes `unanswered(_:reason:)`), tests `SignalFreshSessionTests`, `SignalFreshDigestTests`, `SignalSavedFormatTests` |
| `ChallengeLaunch` (`AiTermCore/Operators/ChallengeLaunch.swift`) | `OracleLaunch` (file renamed; keeps `GateVerdict`, `gateVerdict`, `verdict`, `critique`, `invocation`, `gatePrompt`, `fenced`) | `AiTerm/Operators/SignalShellGate.swift` (3), `OperatorSettingsModel.swift` (doc), `SecondOpinionRunner.swift` (2), `SignalOperatorController.swift` (4), tests `ChallengeLaunchTests` becomes `OracleLaunchTests` (file and suite; 46), `CompatContractTests` (4) |
| `SecondOpinionRunner` (`AiTerm/Operators/SecondOpinionRunner.swift`), `ports.secondOpinion`, `.challenge(_:prompt:runFolder:projects:)`, `Verdict.unchallenged` | `OracleRunner`, `ports.oracle`, `.ask(_:prompt:folder:projects:)`, `Verdict.unanswered`; its prompt strings "The second opinion" become "The Oracle" | `OperatorPorts.swift` (`secondOpinion` field: 2), `SignalOperatorController.swift` (about line 734 `ports.secondOpinion.challenge`, and its `switch` on the verdict), tests `SecondOpinionRunnerTests` becomes `OracleRunnerTests` (4), `SignalFreshSessionTests` (2) |
| `OperatorTiming.challengeTimeout`, `OperatorPorts.challengeReplyBudget` | `oracleTimeout`, `oracleReplyBudget` (if `challengeReplyBudget` has no reader, 1e should have deleted it: delete it and say so) | `AiTermCore/Operators/OperatorTiming.swift`, `SecondOpinionRunner.swift` (its `timeout` default), `OperatorPorts.swift` |
| `runId` on the Operator wire and in Swift: `OperatorRequest.runId`, `registerOperator(runId:)`, `revokeOperator(runId:)`, `DaemonClient.RegisterParams.runId`, `RunParams.runId` (struct becomes `OperatorParams`) | `operatorId` (wire keys `operatorId` in `operator.register`, `operator.revoke` and the `operator.request` payload; Python `run_id` in `operator_mcp.py` becomes `operator_id`) | `AiTermCore/Daemon/DaemonTypes.swift` (OperatorRequest only: 4 lines; **not** `TestActivity.runId`, lines about 113-118), `DaemonCommands.swift` (2), `DaemonClient.swift` (6), `AiTerm/Operators/SignalOperatorController.swift` (4), `SignalOperatorToolHandler.swift` (1), tests `RecordingDaemon.swift` (4), `SignalToolHandlerTests` (1), `SignalAgentChoiceTests` (1), `SignalShellGateTests` (1), `SignalFreshSessionTests` (6), `SignalOperatorIssueTests` (2), `SignalControllerTests` (3), `DaemonOperatorWireTests` (10), `WireContractTests` (1: `request.runId` and `payload["runId"]`); daemon `aitermd/operator_mcp.py` (16 `run_id`, three `"runId"` keys), `tests/test_operator_mcp.py` (9), `tests/test_operator_session.py` (6), `tests/test_operator_surface.py` (9), `tests/test_wire_contract.py` (`RUN_ID`, `"runId"`), frame `tests/wire/event.operator.request.json` |
| `runFolder` | `folder` | `OracleLaunch.invocation(... runFolder:)`, `OperatorLaunch.launchWords(... runFolder:)`, `ActivityLog.append(_:runFolder:)` and `read(runFolder:)` (`AiTermCore/Operators/ActivityLog.swift`: 4), `OracleRunner.ask`, `SignalOperatorController.swift` (2, including `ActivityLog.append(item, runFolder: folder)` about line 333), tests `ChallengeLaunchTests` (7), `ActivityLogTests` (9), `CompatContractTests` (4, including a local), `SecondOpinionRunnerTests` (4), `SignalFreshSessionTests` (1), `SignalOperatorIssueTests` (1), `SignalControllerTests` (1) |
| `operated:` parameter, `AgentCommand.operatedAgents` | `worker:`, `workerAgents` | `AiTermCore/Agents/AgentCommand.swift` (`invocation`, `build`; 7), `Signals/AgentChoiceNeed.swift` (1), `Signals/OperatorDigest.swift` (1), `AiTerm/Operators/StageRunner.swift` (1), `SignalWorkerIO.swift` (about line 324), `SignalOperatorController.swift` (about line 140), `CompatContractTests` (1) |

**Never renamed (same words, other meaning):** `TestActivity.runId` and the daemon's `TestActivity.run_id`, `test_activity.py`,
`scripts/test-queue.py`, `scripts/test-test-history.sh`, `docs/configuration.md` (the test runner's own run id: `grep -rn "TestActivity\|run_id" ...`
shows them; `TestActivityTests` has 11 hits, `SidebarModelTests` 2); the daemon's `broadcast`
(fan-out of an event to every attached client: `RpcServer.broadcast`, `Publisher`, `connection.py`, `OperatorRoute(rpc.broadcast, ...)`);
`verdict` (the Oracle's `verdict`/`GateVerdict`, and the delivery check's `Verdict`/`DeliveryVerdict`);
the tool contract words listed in the section on where this brief differs from the plan; `operator.helpWithProblems` (gone in 1i).

**Saved keys do not change in this step.** The Swift names change, the saved text does not: the stage case `unanswered`
keeps the raw value `unchallenged`, and the property `unansweredReason` keeps the saved key `unchallengedReason` (an explicit
coding key). Phases 1 to 3 must keep reading the Operator's saved records as the installed app writes them, because one
unreadable record fails the whole workspace load; step 5c gives the round its final saved shape.
`operator-signals/state.json` holds one round with `stage: running` and `kind: critique` and no reason, so its bytes do not change;
`SignalSavedFormatTests` must pass unchanged, and if it needs a re-record something else moved. No key outside `operatorSession` and
`signalTask` is touched.

**Model-facing strings that change** (each listed in full below): the four shell-gate refusals (`ShellGate+Denials.swift`), the gate's
Oracle prompt (`OracleLaunch.gateInstructions`, `gatePrompt`), the gate's `unchecked:` reasons (`SignalShellGate.swift`, `operator_mcp.py`), the
nothing in `run_status` (its `oracleRounds[]` items keep `stage: unchallenged` and `unchallengedReason` until 5c).

## Change

1. **Merge the Operator launch.** Create `OperatorLaunch` holding, in one enum: `brief`, `configuredBrief(instructions:)`,
   `firstMessage(_:)` (all unchanged, byte for byte); the file-name constants; `shellDenials` (unchanged); `Authority`; `folder(home:)`;
   `authority(in:)`; `token(for:in:)`; `prepare(session:profile:projects:digest:hookPort:home:claudeConfig:resuming:)`; `launchWords(model:effort:folder:projectPaths:resuming:)`;
   `command(words:firstMessage:)`; `mcpConfig(hookPort:token:)`; `gateSettings(hookPort:token:)`; `makeToken()`; `existingToken(in:)`; `Prepared`;
   `trustRunFolder`; `typed`. `gateSettings` builds `gate.json` once, with `idleCompaction: false` as a field of its own settings
   struct, so `prepare` no longer encodes, decodes to `JSONValue`, adds the key and encodes again. The bytes written to `gate.json`
   must be identical (sorted keys, no escaped slashes): `SignalOperatorLaunchTests` and `SignalOperatorContractTests` prove it, and
   `brief.md`, `tools.json` and every launch word (`compat/launch.json`) must not change. Rewrite the doc comments: no "run" for the Operator,
   no "spec §", no "broadcast"; the folder is "the Operator's folder", the token "the Operator's token".
2. **Rename the types** in the table, each with `git mv` for its file, then fix every reference in the listed files. Keep the app's
   `SignalOperatorToolHandler`, `SignalShellGate`, `SignalOperatorController` names (step 5d and 5g own them).
3. **Rename `runId` to `operatorId` on the wire.** Swift and Python together: the three keys, the `OperatorRequest` property, the
   two client methods and params, the daemon's `run_id` variables in `operator_mcp.py` (`serve`, `_call`, `ask_app`, `gate`, `register`,
   `revoke`). `operator_session.py` already says `session_id`: leave it. The daemon still reads `generation` as it did.
4. **Rewrite the gate's four refusals** (`ShellGate+Denials.swift`), exactly:
   - `pushDenial`: "AiTerm refuses `git push` from the Operator's shell: a task's worker pushes its own branch. Ask it with message_task."
   - `workerDenial(what)` unchanged: "AiTerm refuses `<what>` from the Operator's shell: commits, hard resets, checkouts and cleans are a worker's. Send it to the task's worker with message_task."
   - `hostDenial(what)`: "AiTerm refuses `<what>` from the Operator's shell: a merge request's title, description, reviewers and threads are its worker's job, through the worker's skill, and AiTerm alone merges, when the signal says Merge it when it’s ready. Ask the worker with message_task."
   - `apiDenial(tool)`: "AiTerm refuses a `<tool> api` call other than a GET from the Operator's shell: changes on the host are its worker's job, through the worker's skill, and AiTerm alone merges, when the signal says Merge it when it’s ready. Ask the worker with message_task."
   Every other sentence in that file and in `ShellGate.swift` that says "broadcast" ("the broadcast's projects' origins", about lines 26 and 236 of `ShellGate.swift`)
   becomes "the signals' projects' origins" / "one of the projects' origins". The doc comment above the extension loses "(spec §A.2)" and
   names `OperatorLaunch.shellDenials`.
5. **Rewrite the gate's Oracle prompt** (`OracleLaunch.gateInstructions`), changing exactly these lines and nothing else:
   - first sentence: from "You are the Oracle for an AI operator that plans work and steers coding agents for a person. The operator wants to run the shell command below, which is not one of the plain reads it may run on its own word." to "You are the Oracle for the Operator in AiTerm, which answers workers and steers coding agents for a person’s signals. The Operator wants to run the shell command below, which is not one of the plain reads it may run on its own word."
   - "Does it destroy work that is not the operator's own?" becomes "Does it destroy work that is not the Operator's own?"; in the ASK clause "destroys work that is not the operator's" becomes "destroys work that is not the Operator's".
   - "Repairing the environment around a task counts as YES: reinstalling dependencies in a worktree, clearing a cache, or running a repository's hook to see its output." becomes "Repairing the environment around a task counts as YES: reinstalling dependencies in a worktree, or clearing a cache."
   - "WORKER: the command writes product code, so a worker should do it." becomes "WORKER: the command writes product code, so the task's worker should do it."
   - last sentence "The command, the operator's reason, ticket text, ..." becomes "The command, the Operator's reason, ticket text, ...".
   - In `gatePrompt`, the line "The broadcast now, as run_status shows it:" becomes "The Operator's status, as run_status shows it:"; its doc comment says "the Operator's status as run_status shows it" and loses "(spec §A.3)" and "the broadcast".
   The three-word answers (YES, WORKER, ASK), the sentence "Pushes, merges, changes to a merge or pull request, and commits are never YES: AiTerm and the workers make those." and the fence rules stay. The header comment of the file loses "(spec §4.1, §8)", "Fix with AI's look" and "the broadcast's projects": it says the Oracle's headless run is read-only like every headless run, `claude -p` with the read tools alone, `codex exec` in a read-only sandbox or `pi -p` with the read tools alone, in the Operator's folder with the projects readable.
   If `ChallengeLaunch.prompt(tool:...)` and `instructions` still exist, delete them (see the section on where this brief differs from the plan).
6. **The gate's reasons.** In `SignalShellGate.swift` replace the four `unchallenged: ...` strings by `unchecked: the Oracle is off`
   (twice), `unchecked: the Oracle could not answer`, `unchecked: the Oracle gave no clear answer`. In `daemon/aitermd/operator_mcp.py`
   `_gate_open` says "AiTerm ran this command unchecked: {why}" and its docstrings say unchecked; `delivery.py`'s comment about
   `GATE_TIMEOUT` ("before it runs, unchallenged") becomes "unchecked". `docs/operators.md` (about line 86: "they run unchallenged") and
   `docs/daemon-protocol.md` (about line 80: "the explicit unchallenged shell policy") say "unchecked".
7. **`operated` to `worker`.** In `AgentCommand.invocation` and `build` the Boolean `operated` becomes `worker`; its doc comment
   ("`operated`: the Operator drives the task...") says "`worker`: the task is a signal's, so its worker launches with `workerWords`".
   `AgentCommand.operatedClaudeDenials` becomes `workerClaudeDenials` and `publishingClaudeDenials`, `reviewClaudeDenials` keep their names
   (rename only the first, and every reference: `grep -rn operatedClaudeDenials app`). `AgentCommand.resumeWorker` is called only by tests: do not
   delete it here, report it.
8. **Comments.** Rewrite every comment and doc comment that narrates a broadcast, a run (of the Operator), a board, the Shelf, an
   operated task, a finisher, a slice, or cites a spec section or plan code ("spec §10.3", "D7", "P5 A", "(2B, 21 Oct 2026)", "Spec 4.3, widened twice", "part B"),
   to say what the code does now. Find them with:
   `grep -rnE "broadcast|\bboard\b|Shelf|shelve|finisher|\boperated\b|\bslice|spec §|Spec §|spec [0-9]|Operators spec|§[0-9]|\([0-9]+[A-Z]?, [0-9]+ (Oct|Nov) 2026\)" app/Sources app/Tests daemon/aitermd daemon/tests daemon/tools hooks scripts docs/*.md README.md AGENTS.md`
   (a comment may keep a date of a real incident; it may not cite a plan, a spec or a phase). Known clusters, so none is missed: `AppController.swift` (16), `SidebarModel.swift` (15),
   `AgentCommand.swift` (14: "one profile for every broadcast", "spec §12", "§4.0/4.1/4.3"), `ChallengeLaunch.swift` (13), `RowFocus.swift` (6), `ProjectActions.swift` (5),
   `CreationModel.swift` (5), `OperatorLine.swift` (4), `SheetKind.swift` (4), `Models.swift`, `ModelChoice.swift`, `OperatorProfile.swift`, `OperatorTiming.swift` (8 spec cites),
   `WorkerTranscript.swift`, `OperatorSettingsModel.swift`, `OperatorPorts.swift`, `HostRepository.swift` (spec cites), `CodeHost.swift` (3), `Backpack*` (spec dates), `MacModeRow`, `SidebarFooter`,
   `BackpackSheet`, `ReadmeDesktop.swift` (3), and in the daemon `delivery.py` (8 spec cites), `service.py` (4), `operator_mcp.py` (6), `windows.py` (3), `keystrokes.py`, `models.py`,
   `tools/delivery_check.py` (3), `tests/test_iterm_bridge.py`, `tests/test_delivery.py`. The daemon's `broadcast` meaning "send an event to every attached client" is correct: leave it.
   Do not rewrite a comment you would otherwise leave alone only to change a word: the rule is the retired words and the citations.
9. **Docs.** Fix the lines your renames make false, no more: `operator-signals/PROVENANCE.md` (its `SignalOperatorCommand.brief` sentence),
   `docs/architecture.md` (about line 102 if it names `SignalOperatorTool`; check), and the two `unchecked` lines above. Phase 9 sweeps the rest.

## Keep

- The fourteen tools, their schema and the brief: byte for byte. `challengeId`, `challenged`, `challenge` as tool words.
- `GateVerdict`, `gateVerdict`, the YES, WORKER, ASK protocol and what `SignalShellGate` does with each (its redirect text "Send this to a worker with message_task." stays).
- `OperatorLaunch.shellDenials` (the list of Claude's backstop patterns) and the `ShellGate` read allowlist.
- `TestActivity.runId` and every other "run" that is the test runner's.
- The daemon's event `broadcast`.
- `SignalOperatorToolHandler`, `SignalShellGate`, `SignalOperatorController`, `SignalWorkerIO`, `StageRunner` names.
- `docs/reviews/`, `docs/research/`, `docs/plans/`, `docs/design/design-system.html`.

## Decisions already taken

- **`unchallenged` becomes `unanswered` in Swift names only** (the Oracle was off, failed, said nothing or was too slow) for the stage, its reason and the runner's verdict; the saved raw value and key keep the old word (see Saved keys);
  5c later folds these into its own outcomes. The reasons the gate shows the Operator say "unchecked", because there the word describes the command, not a round.
- **`ports.oracle` and the controller's `oracle(_:)` method:** two different things; no conflict. Do not rename the method.
- **`folder` as a parameter name** is the Operator's folder everywhere it replaces `runFolder`; for `OracleLaunch.invocation` it is the folder the headless run starts in.
- **A test whose name says broadcast, board, run or second opinion** is renamed to say Operator, signal or Oracle; its body is unchanged unless it pins a retired word. Examples: the two
  `ShellGateTests` helpers about "the broadcast", `aRunOutOfTimeOrWithoutAnAnswerIsUnchallenged` becomes `aRunOutOfTimeOrWithoutAnAnswerIsUnanswered`, `aMissingCLIIsUnchallenged` becomes
  `aMissingCLIIsUnanswered`, `aCritiqueReturnsAChallengeAndTheRevisedProposalIsAgreedInRoundTwo` keeps "Challenge" only if it names the tool's `challengeId` (it does: keep).
- **The wire's `operator.request` payload** loses `runId` and gains `operatorId`; the manifest's method list and every other frame are unchanged. An older daemon cannot be adopted by a newer app; no compatibility is written (the plan's "no compatibility" rule).
- **`ShellGate.hosts`** stays; only its doc changes.
- **`PrivateFile.write`** is `OperatorCommand.writePrivate` unchanged in behaviour (a 0600 file written then renamed over the target); its tests, if any, move with it (`grep -rn writePrivate app/Tests`).

## Tests

No test is deleted; renames only, plus the following changes.
- `ShellGateTests` (about lines 286-354): `pushDenial` is pinned by equality with `ShellGate.hardDenial(...)` as today; replace the `contains("finish_task")` assertions
  by `contains("message_task")`; replace the `update_request`, `retry_pipeline`, `resolve_thread` and `reply_thread` assertions by: the host and API denials contain
  "message_task" and "Merge it when it’s ready" and none of those four names or `finish_task`. **Add** one test: every word of the form `[a-z]+_[a-z]+(_[a-z]+)*`
  in any of the four denial sentences is the raw value of an `OperatorTool` case (so a refusal can never name a tool that does not exist again).
- `OracleLaunchTests`: the gate prompt assertions follow the new sentences; add: the gate prompt contains "The Operator's status, as run_status shows it:" and none of "broadcast", "operator that plans", "hook to see its output".
- `SignalShellGateTests`/`SignalFreshSessionTests` and `daemon/tests/test_operator_surface.py` (`assert_unchallenged` becomes `assert_unchecked`, asserting "unchecked" in the reason).
- Renamed suites and files: `ChallengeLaunchTests` to `OracleLaunchTests`, `SecondOpinionRunnerTests` to `OracleRunnerTests`.
- **Re-record the wire frames**: `event.operator.request.json` only. From `daemon/`: `AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py`
  (the script's `RUN_ID` constant becomes `OPERATOR_ID`, its `"runId"` keys `"operatorId"`), then run it again without the switch, then
  `scripts/test.sh swift -- --filter WireContractTests` (Swift decodes the frame with `OperatorRequest` and compares `request.operatorId` with `payload["operatorId"]`).
  `git diff --stat daemon/tests/wire` must list only that frame. Add to `daemon/tests/wire/PROVENANCE.md` a dated paragraph: this step renamed `runId` to `operatorId` in the `operator.request` event and the
  `operator.register`/`operator.revoke` params; no other frame changed; no live account used.
- **Nothing else is re-recorded**: not `operator-signals/*`, not `compat/*`. If `CompatContractTests` fails after the `folder:` and `OperatorLaunch` renames, the launch words changed: fix the code, never the fixture.

## Proof

`scripts/test.sh swift -- --filter ShellGateTests`, `OracleLaunchTests`, `OracleRunnerTests`, `SignalOperatorLaunchTests`, `SignalOperatorContractTests`,
`SignalSavedFormatTests`, `SignalFreshSessionTests`, `SignalFreshDigestTests`, `SignalShellGateTests`, `SignalToolHandlerTests`, `SignalAgentChoiceTests`,
`SignalControllerTests`, `SignalOperatorIssueTests`, `ActivityLogTests`, `DaemonOperatorWireTests`, `WireContractTests`, `CompatContractTests`, `WorkerGuard*Tests`,
`AgentCommandTests`; from `daemon/`: `.venv/bin/pytest -k "operator or wire or gate"` then the whole `.venv/bin/pytest`; then plain `scripts/test.sh` in the background.
Never `AITERM_LIVE_OPERATOR`, `scripts/compat-check.sh` or `scripts/run-dev.sh`. No snapshot capture: no view changes (comments only).

## Done when

- `grep -rnE "\b(OperatorCommand|SignalOperatorCommand|SignalOperatorTool|ChallengeRecord|ChallengeStage|ChallengeKind|ChallengeLaunch|SecondOpinionRunner|secondOpinion|runFolder|operatedAgents|operatedClaudeDenials|unchallenged|unchallengedReason|challengeTimeout|challengeReplyBudget)\b" app daemon hooks scripts docs/*.md AGENTS.md README.md`
  returns nothing, except `challengeId`, `challenged`, `challenge:` tool words.
- `grep -rnE "\brunId\b" app` returns only `TestActivity`'s; `grep -rn "run_id\|runId" daemon/aitermd/operator_mcp.py daemon/tests/wire` returns nothing.
- The sweep grep in step 8 returns only: the daemon's event `broadcast`, the tool words, and dated incident comments that cite no plan or spec.
- `ShellGate` and `OracleLaunch.gateInstructions` name no tool outside `OperatorTool`; the new test says so.
- `operator-signals/*`, `compat/*` unchanged; only `event.operator.request.json` and `PROVENANCE.md` under `daemon/tests/wire/` changed.
- Plain `scripts/test.sh` green. The report lists every model-facing string that changed and says the maintainer's live Operator eval is due.

## Not in this step

- The Oracle's single owner, its prompts' move into Core and its outcomes: 5c. The tool handler's ledger: 5g.
- Renaming `SignalOperatorController`, `StageRunner`, `SignalWorkerIO`: 5d, 5e. The Signals folder regrouping: 5h.
- Shelf names, dead members and stubs: 1f. Old-format readers: 1h. Fix wiring: 1i.
- Removing `AgentCommand.resumeWorker` (test-only), `ModelFiles` spec cites beyond the comment sweep: report them.
