# Remove Grok Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Grok Build as a harness from the app, daemon, scripts and docs, leaving Claude Code and Codex first-class and PI as the way to other providers.

**Architecture:** Grok is one row in each of two harness tables (`Harness+Agents.swift`, `daemon/aitermd/models.py`) plus its own files. Delete the row and the files, then delete every case, field and helper that only that row needed. Saved data keeps loading through the unknown-agent fallbacks `Workspace` and `TaskItem` already have.

**Tech Stack:** Swift 6.4 (via `scripts/swift.sh`, `scripts/test.sh`), Python daemon (`daemon/.venv/bin/pytest`).

**Spec:** `docs/superpowers/specs/2026-10-22-remove-grok-design.md`

## Global Constraints

- Build and test only through `scripts/swift.sh` / `scripts/test.sh`; never `swift` directly. Iterate with `scripts/test.sh swift -- --filter <Suite>` and `daemon/.venv/bin/pytest -k <expr>` from `daemon/`.
- `scripts/test.sh` queues machine-wide: run it in the background, not under a short timeout.
- Match the surrounding code: its comment density, naming and idiom. Comments that named Grok as an example are reworded, not left dangling.
- Do not regenerate `docs/desktop.png` or `docs/sidebar.png`. Leave `docs/superpowers/reviews/` as written.
- Copy rule wherever agents are explained: Claude Code and Codex are fully supported; other providers, such as Grok, work through PI.
- Commit on `chore/remove-grok-support-pi-is-the-path-for-other-pro` only; push nothing.

## Review Focus

- A workspace saved with a Grok task (agent `grok`, model `grok-4.7`, a `grok` conversation and a hand-opened `claude` one) loads, shows the task, and resumes the Claude conversation without `--model grok-4.7`.
- `lastAgentByProject` / `lastModelByAgent` naming `grok` load with that entry dropped.
- A daemon snapshot or delivery-policy reply that still carries `grok` (a daemon of the old build) decodes: the session as `.shell`, the policy entry dropped.
- An old daemon-side file (delivery policy) listing `grok` still loads in the new daemon.
- A post to `/hook/grok` or `/statusline/grok` from a leftover `~/.grok` install gets a 404 and changes nothing.

---

### Task 1: Saved Grok data falls back (Swift, TDD)

**Files:**
- Modify: `app/Sources/AiTermCore/Daemon/AppState+Conversations.swift` (`TaskItem.resumeCommands`)
- Test: `app/Tests/AiTermCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write the failing tests** in `ModelsTests`:
  - `savedGrokTaskLoadsAsClaudeAndKeepsItsAgent`: decode a `Workspace` JSON whose one task has `"agent": "grok"`, `"model": "grok-4.7"`, conversations `[{"agent":"grok","id":"g1"},{"agent":"claude","id":"c1"}]`, `lastAgentByProject` `{<project>: "grok"}`, `lastModelByAgent` `["grok","grok-4.7","codex","gpt-5.6"]`. Assert the task's `agent == .claude`, `unrecognizedAgent == "grok"`, re-encoding writes `"agent":"grok"`, `conversations == [TaskConversation(agent: .claude, id: "c1")]`, `lastAgentByProject.isEmpty`, `lastModelByAgent == [.codex: "gpt-5.6"]`.
  - `formerGrokTaskResumesClaudeOnItsDefaults`: the same task's `resumeCommands == [AgentCommand.resume(agent: .claude, conversation: "c1", model: nil, reasoning: nil)]`.
- [ ] **Step 2: Run** `scripts/test.sh swift -- --filter ModelsTests`; expect both to fail (`grok` is still a case).
- [ ] **Step 3:** In `resumeCommands`, `launched` also requires `unrecognizedAgent == nil`: a task whose saved agent this build does not know was not launched with any agent it can resume on that model. Do not remove `.grok` yet; the tests pass once Task 2 removes it.
- [ ] **Step 4:** Commit together with Task 2 (the tests only pass once the case is gone).

### Task 2: Remove Grok from the Swift app

**Files:**
- Delete: `app/Sources/AiTermCore/Harnesses/GrokDriver.swift`, `GrokHooksFile.swift`, `GrokModelCatalog.swift`, `GrokStatusLineConfig.swift`; `app/Tests/AiTermCoreTests/GrokDriverTests.swift`, `GrokHarnessServiceTests.swift`, `GrokHooksFileTests.swift`, `GrokModelCatalogTests.swift`, `GrokStatusLineConfigTests.swift`
- Modify: every other file `git grep -il grok -- app` lists.

**Interfaces:**
- Produces: `AgentKind` = `claude, codex, pi`; `SessionAgent` = `claude, codex, pi, shell`. No `Harness.grok`, `Palette.grok`, `Logos.grokPath`, `LogoFit.grok`, `AiTermPaths.grokStatusLineOriginalURL`.

- [ ] **Step 1:** Remove the cases, the `Harness.grok` row and the Grok files; fix each switch.
- [ ] **Step 2: Simplify what only Grok used** (verify each with `git grep` before removing):
  - `HarnessCheckID.context` and `DriverProbe.checks` (Grok's Context check); keep `HarnessCheck.repairable` (Messaging and Setup use it).
  - `SkillRoot.Kind.commands(depth:)` if only Grok passed `depth: 0`; `AgentCompletion.Source.builtIn` only if nothing else produces it.
  - `Brand.evenOdd` and its rendering path (only Grok's mark set it).
  - `StatusLineOriginal`, `TOMLStatements`, `ShimPort`, `ClaudeSettings.isInstalled` comments that compare with Grok: reword; delete any helper Grok alone called.
  - `FixerChoice`, `CLIInstaller`, `SidebarModel.usageVendorRows`, `ProjectFiles`, `SkillCatalog`, `HarnessDiagnostics`, `AgentCommand.workerWords`, `ChallengeLaunch`, `WorkerTranscript`, `OperatorToolHandler+Gate` comments and switches: drop Grok.
- [ ] **Step 3: Snapshots:** `Fixture.grokTask` becomes a Codex task (`codexTask`, model `gpt-5.6`, reasoning `medium`, session agent `"codex"`); `ReadmeDesktop`'s orphan task becomes a PI task; `SidebarSnapshots.marks` lists `.claude, .codex, .pi, .shell`; `HarnessSettingsModel.previewSnapshots` drops Grok.
- [ ] **Step 4: Settings copy:** the Agents pane's `HelpText` (HarnessSettingsPane.swift:95) gains: “Claude Code and Codex are fully supported; other providers, such as Grok, work through PI.”
- [ ] **Step 5: Tests:** remove Grok rows and cases from every test `git grep -il grok -- app/Tests` lists, keeping each test's point for the remaining agents; `DaemonOperatorWireTests` keeps an unknown agent key (rename it `"gemini"` or similar) so the drop-unknown path is still proven.
- [ ] **Step 6: Run** `scripts/swift.sh build`, then `scripts/test.sh swift -- --filter <touched suites>`; then plain `scripts/test.sh`. Expect all pass, Task 1's tests included.
- [ ] **Step 7:** `app/Sources/AiTermUI/README.md`: drop Grok (Context check, mark, palette), and say other providers such as Grok work through PI where it lists the agents.
- [ ] **Step 8: Commit** “Remove Grok Build from the app; a saved Grok task loads as Claude's and resumes Claude on its defaults”.

### Task 3: Remove Grok from the daemon and the bundle

**Files:**
- Delete: `hooks/grok-statusline-shim.sh`, `daemon/tests/test_grok_statusline_shim.py`
- Modify: `daemon/aitermd/{models,hook_events,hooks_server,resolver,status,service}.py`, `daemon/tests/*`, `daemon/tests/wire/{manifest.json,reply.delivery.policy.json}`, `daemon/README.md`, `scripts/make-app.sh`, `scripts/test-app-bundle.sh`, `scripts/fixtures/check-bundle-verifier.sh`, `scripts/test-routes.tsv`, `scripts/README.md`

**Interfaces:**
- Produces: daemon `AgentKind = Literal["claude", "codex", "pi", "shell"]`; routes `/hook/grok` and `/statusline/grok` gone; the delivery-policy reply has keys `claude, codex, pi`.

- [ ] **Step 1: Tests first** (`test_delivery.py`): `load_policy` of a file that still lists `grok` returns only `claude`, `codex`, `pi`; `test_hooks_server.py`: a POST to `/hook/grok` is a 404 and changes no session. Run; expect failure while Grok is still served.
- [ ] **Step 2:** Remove the Grok row, parsers (`parse_grok_hook`, `parse_grok_statusline`, `GROK_*`), and the mechanisms only Grok used: `HookEvent.turn_id`/`starts_turn`/`nested` and their handling in `status.py`/`hook_router.py`; `Harness.title_pattern`/`AGENT_TITLE_PATTERNS`; `Harness.end_of_turn_survives_cwd_loss` with `settle_orphans`/`orphan_paths`/`ORPHAN_SETTLE_SECONDS` and its service tick, since Claude, Codex and PI all survive a lost cwd; the status-line parser table if one route remains. Keep Claude's `hookEventName` guard only if it still protects against something other than Grok.
- [ ] **Step 3:** Bundle scripts stop copying and checking `grok-statusline-shim.sh`; `test-routes.tsv` drops its shim route.
- [ ] **Step 4: Run** `daemon/.venv/bin/pytest` from `daemon/`, then plain `scripts/test.sh`. Expect all pass.
- [ ] **Step 5: Commit** “Remove Grok Build from the daemon and the app bundle”.

### Task 4: Docs and issue template

**Files:** `.github/ISSUE_TEMPLATE/bug_report.yml`, `README.md` (Grok lines only), `docs/{ai-install,architecture,keyboard,status-model}.md`, `docs/design/design-system.html`

- [ ] **Step 1:** Remove Grok; where agents are listed, add that other providers such as Grok work through PI. `status-model.md` loses the Grok states and turn-id rules. `design-system.html` drops the Grok mark and palette swatch.
- [ ] **Step 2:** Add to `docs/ai-install.md` (or wherever installing a harness is described) the hand clean-up for an earlier install: delete AiTerm's hooks file in `~/.grok` and reset `[ui.status_line]` in `~/.grok/config.toml`.
- [ ] **Step 3:** `git grep -i grok` lists only `docs/superpowers/` and the intended “through PI” sentences.
- [ ] **Step 4: Run** plain `scripts/test.sh` (docs-only exits at once); commit “Say in the docs that other providers work through PI, not Grok Build”.

### Task 5: Whole-branch check

- [ ] `scripts/test.sh all` in the background; expect every suite to pass.
- [ ] `git diff --shortstat main...HEAD` for the hand-off.
