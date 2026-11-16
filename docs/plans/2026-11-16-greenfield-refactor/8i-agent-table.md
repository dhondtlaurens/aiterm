# 8i. The agent table describes headless launches too

Implementer: Codex `gpt-6.1-sol`, high. Depends on: phase 1 (1i deleted Find a Fix and its two headless
runs; 1j named `OracleLaunch` and `AgentCommand.workerAgents`), 5c (the Oracle's invocation and prompts
live in Core `OracleLaunch`). Independent of 8f to 8h. Audit: PL F5, PL F7.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The plan says the skill and project-file catalogues "move beside the prompt step". The prompt step is
`app/Sources/AiTerm/Views/Steps/PromptStep.swift`, in the app target, while `SkillCatalog` and
`ProjectFiles` are Core: they read the agent table's internal `Harness.skillRoots` and `skillSigil`,
Core's internal `FileStamps` and `KeyedStates`, and their tests are `AiTermCoreTests`. Moving them into
the app would mean making four Core internals public for a locality change. This brief moves them into
a Core folder of their own, `app/Sources/AiTermCore/Prompt/`, named for the prompt editor they serve,
and out of `Agents/`, which is what the audit's point was (they are the completion feature, not agent
description).

## Why

`Harness` (`Harnesses/Harness.swift`, filled by one table in `Harness+Agents.swift`) is the one place
that says how each agent's CLI is installed, launched, resumed and listed, so a vendor's change is one
edit. Headless launches never joined it: when the Oracle and Find a Fix were built, each wrote its own
switch on the agent with the executable names as literals, and the effort lists the table points at
were left in `ModelFiles` and `PiModelCatalog`. With Find a Fix gone the Oracle is the only headless
run, so describing it in the table is small. The end state: every fact about how a CLI is spelled,
interactive or headless, sits in its table entry, and nothing outside the table switches on the agent
to build a command line. No command line changes by a single byte.

## Today

As the code stands when this step runs. Re-run
`grep -rnE 'case \.(claude|codex|pi)\b|[!=]= \.(claude|codex|pi)\b|"(claude|codex|pi)"' app/Sources --include='*.swift'`
and `grep -rn "HeadlessInvocation(\|HeadlessRun\.\|codexReadOnlyLaunchWords\|claudeEfforts\|codexEfforts\|thinkingLevels" app/Sources app/Tests`.
Every per-agent switch or list outside the table, and what this step does with it:

| Where | What it switches on | This step |
| --- | --- | --- |
| `Harness.modelArguments(model:reasoning:)` in `Harness.swift` | a `switch agent` with each CLI's model and reasoning flags | moves into the table |
| `Harness.codexReadOnlyLaunchWords` in `Harness.swift` | Codex's read-only launch, a method on every harness | moves into the table |
| `Agents/HeadlessRun.swift`: `claude(...)`, `codex(...)`, `claudeSettings`, `claudeSettingSources`, `claudeNoWeb`, `codexQuiet`, `answerLimit`, `modelArguments` (PI's level filter) | headless spellings per agent | moves into the table; the file goes |
| `OracleLaunch.invocation` (today `ChallengeLaunch.invocation`) | `switch` with literal "claude", "codex", "pi", `readTools`, `writeTools`, `piReadTools`, `piQuiet` | asks the table |
| `OracleLaunch.critique` | `switch` on how each answer is read | asks the table |
| `ModelFiles.claudeEfforts`, `ModelFiles.codexEfforts`, `PiModelCatalog.thinkingLevels` | effort lists the table's `fallbackEfforts` points at | the lists move into the table |
| `AgentCommand.workerWords` | Claude's worker denials and permission mode; Codex's read-only review tab | keeps its Claude case (worker policy), reads the table's read-only launch |
| `AgentCommand.workerAgents` (today `operatedAgents`) and `ModelChoice.pair` | both "Claude Code and Codex" | stay: which agents the Operator may use is Operator policy |
| `WorkerGuardLaunch.prepare`, `shim`, `launchScript` | the CLIs a worker may call nested, with the guard's own options | stay: guard policy, pinned by `WorkerGuardLaunchTests` and `WorkerGuardCodexTests` |
| `OperatorLaunch` | the Operator is Claude | stays: already built from Claude's table entry |
| `WorkerTranscript`, `SignalOperatorController` (the chat's Claude tab), `VendorMark`, `SidebarModel`'s short names, `HarnessSettingsPane`'s Claude configuration line, `AgentIntegrations`' status-line refresh, `SkillCatalog`'s Claude configuration key | reading, drawing, Claude-only features | stay: not launches |

Callers: the Oracle runner (`OracleRunner`, today `SecondOpinionRunner`) calls `OracleLaunch.invocation`
and `OracleLaunch.critique`; `CompatContractTests.launches()` builds the Oracle's template from
`OracleLaunch.invocation`. `ModelFiles` uses `claudeEfforts` and `codexEfforts` as per-model fallbacks;
`PiModelCatalog.parse` gives thinking models `thinkingLevels`. `SkillCatalog.swift` and `ProjectFiles.swift`
sit in `app/Sources/AiTermCore/Agents/`; their users are `CreationModel`, `OperatorSettingsModel`,
`OperatorSkills`, `AppController+Signals`, `AgentIntegrations` and `PromptEditor`.

## Change

1. `Harness` gains these fields, filled in each entry of `Harness+Agents.swift`:
   - `modelArguments`: the model and reasoning words, as each entry spells them today (Claude
     `--model` and `--effort`; Codex `-m` and `-c model_reasoning_effort=<level>`; PI `--model` and
     `--thinking`). The method `modelArguments(model:reasoning:)` reads it, so its callers do not change.
   - `readOnlyLaunchArguments`, optional: Codex's `--sandbox read-only --ask-for-approval never` then its
     model words; nil for Claude and PI. Replace `codexReadOnlyLaunchWords` with `readOnlyLaunchWords(model:reasoning:)`,
     which returns the executable and those arguments, or nil.
   - `readOnlyHeadless`: given the prompt, the working folder, the folders it may read besides, the
     answer file, the model and the reasoning, the arguments of a run that only reads and answers once.
     Claude: today's `HeadlessRun.claude` with the read tools as its whole tool set, the write tools and
     the web tools denied, its settings and setting sources, `--add-dir` for the readable folders.
     Codex: today's `HeadlessRun.codex` (`exec`, read-only sandbox, `-C` folder, `-o` answer file, its
     quiet flags, the prompt last). PI: today's `-p`, its quiet flags, its four read tools, then `--`
     and the prompt. Every entry leaves an empty model to the CLI; PI's passes a reasoning level only
     when it is one of its own levels, as `HeadlessRun.modelArguments` does.
   - `readsAnswerFromFile`: true for Codex only, so the invocation carries the answer file.
   - `headlessAnswer`: given the run's standard output and its answer file, the answer text. Claude: the
     `result` of its JSON. Codex: the answer file, read with `RegularFile.read` up to 1,000,000 bytes.
     PI: the standard output.
   The constant word lists (`claudeSettings`, `claudeSettingSources`, `claudeNoWeb`, `codexQuiet`, the
   read and write tool lists, PI's read tools and quiet flags, the answer limit) become private
   constants beside the entries in `Harness+Agents.swift`.
2. Add `Harness.readOnlyHeadless(prompt:folder:readable:answerFile:model:reasoning:)` returning a
   `HeadlessInvocation` (executable from the table, arguments from the entry, the answer file only when
   `readsAnswerFromFile`). Move `HeadlessInvocation` to `app/Sources/AiTermCore/Harnesses/`. If no
   caller sets its `environment` or `sessionID` any more (grep `HeadlessInvocation(`), drop both fields
   and pass an empty environment where the runner needs one.
3. `OracleLaunch.invocation` keeps its signature and calls
   `opinion.agent.harness.readOnlyHeadless(...)` with the prompt, the Operator's folder, the projects as
   the readable folders, the answer file, the model and the reasoning (empty reasoning as none, as today).
   `OracleLaunch.critique` keeps its checks (timed out or non-zero exit is no critique; empty text is no
   critique) and reads the text through `agent.harness.headlessAnswer`. Delete `readTools`, `writeTools`,
   `piReadTools` and `piQuiet` from `OracleLaunch`.
4. Delete `app/Sources/AiTermCore/Agents/HeadlessRun.swift`.
5. `AgentCommand.workerWords`: the Claude case is unchanged; for every other agent a review tab
   (`readOnly`) launches with `readOnlyLaunchWords` when the harness has one and with its plain launch
   words otherwise. Rewrite its doc comment without spec references.
6. Effort lists live only in the table: the entries write `fallbackEfforts` as literals
   (Claude low, medium, high; Codex minimal, low, medium, high, xhigh; PI off, minimal, low, medium, high,
   xhigh, max). `ModelFiles` reads `Harness.claude` and `Harness.codex` for its per-model fallbacks and
   `PiModelCatalog` reads `Harness.pi` for a thinking model's levels. Delete `ModelFiles.claudeEfforts`,
   `ModelFiles.codexEfforts` and `PiModelCatalog.thinkingLevels`.
7. Move `SkillCatalog.swift` and `ProjectFiles.swift` with `git mv` into `app/Sources/AiTermCore/Prompt/`.
   No symbol changes.
8. Fix the comments that name what moved: `AgentIntegrations.taskModel` (it named
   `HeadlessRun.modelArguments`), `OracleLaunch`'s header, `Harness`'s header (it now lists headless runs
   among what it describes).

## Keep

- Every command line, byte for byte: task, resume, worker, review tab, the Operator and its resume, and
  the Oracle's run for each agent. `compat/launch.json` is the record and must not change.
- `AgentCommand`'s Claude worker denials (`operatedClaudeDenials` today, or as 1j named them),
  `publishingClaudeDenials` and `reviewClaudeDenials`: what a worker may not do is the Operator's policy,
  not a fact about the CLI.
- `WorkerGuardLaunch` as it is: its shims and launch script are the worker guard's (2g owned them), and
  a byte of difference there breaks the guard.
- `ModelChoice.pair` and `AgentCommand.workerAgents`: Operator policy; 5h regrouped the Operator's
  files and owns them.
- `OracleLaunch`'s prompts and verdict parsing, and its `invocation`/`critique` entry points that
  `OracleRunner` and `CompatContractTests` call.
- `ModelListing` and its `.launch` case for PI's list.

## Decisions already taken

- The table gains only the read-only headless shape the Oracle uses. Do not add a general headless
  builder with tool and option parameters: there is one caller.
- A test that read `ModelFiles.claudeEfforts` and the like reads the table instead, through
  `AgentKind.<agent>.harness.efforts(for: nil)`.
- If `CompatContractTests.theLaunchTemplatesAreWhatTheAppRuns` fails, the move changed a byte: fix the
  code. Never re-record with `AITERM_RECORD_COMPAT=1` in this step.

## Tests

- No test is deleted. Adjust `ModelFilesTests` (the three effort constants) and `OperatorSettingsPaneTests`
  (PI's levels) to read the table. `OracleLaunchTests` (today `ChallengeLaunchTests`) keep their
  assertions unchanged; only an import or a helper name may move.
- No new test: the move is proven by the contract suites, which pin every built command line.

## Proof

These suites prove the command lines are byte for byte:

- `scripts/test.sh swift -- --filter CompatContractTests`: `theLaunchTemplatesAreWhatTheAppRuns`
  (every launch by agent and use against `compat/launch.json`), `eachHeadlessAnswerReadsAsTheAppReadsIt`
  (the answer readers against real captures) and `everyFlagTheAppPassesIsOneTheCLIKnows`.
- `--filter OracleLaunchTests` (or `ChallengeLaunchTests` if 1j kept the name):
  `theRunsAreWordForWordAsBefore`, `claudeReadsAndNothingElse`, `codexRunsInAReadOnlySandboxInTheRunFolder`,
  `piReadsAndNothingElse`, `piTakesOnlyTheLevelsItNames` and the critique tests.
- `--filter AgentCommandTests`, `SignalWorkerProfileTests` (worker and review words),
  `WorkerGuardLaunchTests`, `ModelFilesTests`, `PiDriverTests`, `SkillCatalogTests`, `ProjectFilesTests`.
- `git diff --exit-code -- compat/` exits 0.
- Plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "HeadlessRun\|codexReadOnlyLaunchWords\|claudeEfforts\|codexEfforts\|thinkingLevels\|piReadTools\|piQuiet" app/Sources app/Tests`
  returns nothing.
- `grep -rnE '"(claude|codex|pi)"' app/Sources/AiTermCore --include='*.swift'` lists only
  `Harness+Agents.swift` and `WorkerGuardLaunch.swift`.
- `grep -rnE 'case \.(claude|codex|pi)\b' app/Sources/AiTermCore --include='*.swift'` lists only
  `AgentKind.harness` in `Harness.swift`, `AgentCommand.workerWords` and `SidebarModel`'s short names.
- `ls app/Sources/AiTermCore/Agents` no longer lists `SkillCatalog.swift`, `ProjectFiles.swift` or
  `HeadlessRun.swift`; `app/Sources/AiTermCore/Prompt/` holds the first two.
- `git diff --exit-code -- compat/` exits 0, and the suites above and plain `scripts/test.sh` are green.

## Not in this step

- The Oracle's prompts and its consult: 5c. The worker guard: 2g. The Codex config editor: 2d.
- Transcript reading per agent (`WorkerTranscript`): not a launch.
- The hook port as a constant (PL F2): left out of the plan.
