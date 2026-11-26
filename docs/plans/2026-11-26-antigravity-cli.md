# Antigravity CLI support, and the full and basic tiers

## Goal

Add Google's Antigravity CLI (`agy`) as AiTerm's fourth agent, at the full tier. Make "full" and
"basic" support explicit tiers in code and in the docs, so the next agent only has to pick one.
Findings: `docs/research/2026-11-26-antigravity-cli.md`.

## Approach

**The tiers.**

- **Basic** (PI today): launch tasks and tabs, and resume them; model catalogue and skill
  completions; status from the agent's own hooks or events; context fill; the Oracle; the
  Settings card (install, repair, test); compatibility capture.
- **Full** (Claude Code and Codex): basic, plus status checked against a tick (needs-input
  included), verified messaging (the delivery check), and the Operator worker: agent choice, the
  worker guard, and replies read from its transcript.
- Account usage and background work show where a CLI reports them. Neither is a tier requirement.

**Decided while grilling.**

- The tier lives in code: each Swift `Harness` and each daemon `Harness` gets a `support` value.
  `AgentCommand.workerAgents` and `OperatorSkills.agents` (the Signal sheet's skill completions) are
  derived from it. The delivery check's agents, and the compat script's messaged list, are the CLIs
  whose screen AiTerm reads: the app's `Harness.messagingChecked`, the daemon's `MESSAGING_CHECKED`
  (a harness row with an input-box marker). The full tier is a subset of them: an agent is checked
  before it is full, and a pass is what makes it full. A contract test keeps the Swift and daemon
  tiers, and the two messaging lists, equal. `ModelChoice.pair` stays
  `[claude, codex]`: it is about weekly usage, and agy reports none on the account tested, so agy
  never takes part in the 80% switch.
- Every agy launch uses `--dangerously-skip-permissions`, as Codex tasks use their bypass flag. The
  New Task sheet shows the command before it runs.

**Decided from the code and the spike.**

- The raw value is `agy`, because the daemon recognises an agent by its binary's name
  (`classify_agent`). The display name is "Antigravity".
- Launch: `agy --dangerously-skip-permissions --model <id>`, and a launch prompt after `-i`
  (`Harness.promptFlag`): given alone it lands in agy's input unsent. Resume: `--conversation <id>`.
- Models come from `agy models`, a launched list as with PI. Its ids already carry the effort
  (`gemini-4-neon-high`), so models publish no reasoning levels and no reasoning flag is sent.
  `PiModelCatalogError` becomes `ModelListError`, which names the agent whose launched list failed.
- The driver owns one named hook, `aiterm`, in `~/.gemini/config/hooks.json`, registering
  SessionStart, PreInvocation and Stop. Named hooks merge, so the person's own entries stay. It
  never registers PreToolUse: a `{}` answer there denies the tool. Each handler is a `curl`
  command, as Codex's hooks are, that posts its stdin to `/hook/agy` with the `ITERM_SESSION_ID`
  header and answers `{}`. It waits for the post (at most a second) rather than backgrounding it,
  since agy may stop a hook's process group once it answers. The port is in the command, so a
  daemon on another port reads as outdated and Repair rewrites it.
- A status-line shim set in `~/.gemini/antigravity-cli/settings.json` posts the payload and runs the
  person's own status-line command, reusing `StatusLineOriginal`, which keeps one record per agent:
  Claude's stays `statusline-original.cmd`, agy's is `statusline-original-agy.cmd`, and installing
  either never touches the other's.
- Status: hooks give start, working and done. The status-line tick checks them (`agent_state`,
  `tool_confirmation_pending` → needs-input), gives the context percentage and gives the CLI
  version that messaging needs. The trust dialog is read from the screen, as for PI. The hooks'
  `transcriptPath` is used, never the status line's, which points at a folder that doesn't exist.
- Oracle: `agy -p --output-format json`, with deny rules (`command`, `write_file`, `mcp`, `url`,
  `unsandboxed`) and the folder as trusted, both in an unsaved `--settings`, plus `--add-dir`. The
  answer is the JSON `response`. Web search stays possible, and the docs say so.
- Worker: the worker guard's PATH shims and pre-push hook, as Codex has, with `agy` added to the
  shim list. A worker's reply comes from its `transcript.jsonl` (last `PLANNER_RESPONSE`).
  `WorkerTranscript`'s Codex-or-else-Claude ternary gets an explicit arm per agent.
- The vendor mark is proposed on the design-system page's Proposals tab before Swift changes.

**Out of scope:** an agy usage footer (quota format unproven), agy subagents as background work,
agy in `QueryWriter`.

## Files

Tier and agent tables
- modify `app/Sources/AiTermCore/Models.swift`: `AgentKind` and `SessionAgent` gain `agy`.
- modify `app/Sources/AiTermCore/Harnesses/Harness.swift`: the `support` tier, the `agy` arm, a
  generic launched-list error.
- modify `app/Sources/AiTermCore/Harnesses/Harness+Agents.swift`: the agy row.
- modify `app/Sources/AiTermCore/Agents/AgentCommand.swift`: `workerAgents` from the tier; agy's
  worker words.
- modify `app/Sources/AiTermCore/Agents/DeliveryCheck.swift`: agents from the tier.
- modify `app/Sources/AiTerm/Operators/OperatorSkills.swift`: agents from the tier.
- modify `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: agy's name.
- modify `app/Sources/AiTermCore/Harnesses/HarnessTestClient.swift`, `HarnessService.swift`,
  `app/Sources/AiTerm/HarnessSettingsModel.swift`: agy's Test, driver and card.
- modify `daemon/aitermd/models.py`: the `support` tier and agy's harness row (screen markers).
- modify `daemon/aitermd/agents/__init__.py`: agy's parsers.

Driver and status
- create `app/Sources/AiTermCore/Harnesses/AgyDriver.swift`: install, probe and repair the named
  hook and the status-line shim.
- create `hooks/agy-statusline-shim.sh`: the bundled status-line shim (the hooks need no script).
- modify `app/Sources/AiTermCore/Hooks/StatusLineOriginal.swift`, `AiTermPaths.swift`: one saved
  status-line command per agent, Claude's file name unchanged.
- modify `app/Sources/AiTermCore/Harnesses/UserConfigFile.swift`: a rewritten file keeps its
  permissions (agy writes its `settings.json` 0600; an atomic write would open it up).
- modify `daemon/aitermd/hook_events.py`, `hook_router.py`, `status.py`: a status line can carry tick
  evidence (`agy_statusline`).
- modify `scripts/test-app-bundle.sh`, `scripts/fixtures/check-build-scripts.sh`,
  `scripts/fixtures/check-bundle-verifier.sh`: the bundled agy shim.
- create `daemon/aitermd/agents/agy.py`: hook and status-line parsing, trust screens.
- modify `daemon/aitermd/service.py`, `corroboration.py`, `hook_router.py`, `status.py`,
  `resolver.py`, `screens.py`: the agy route, its tick and its screens.
- modify `scripts/make-app.sh`: bundle the scripts.

Model list
- create `app/Sources/AiTermCore/Harnesses/AgyModelCatalog.swift`: read `agy models`.
- create `app/Tests/AiTermCoreTests/SupportTierTests.swift`, `AgyDriverTests.swift`, `daemon/tests/test_agy.py`;
  modify `scripts/test-routes.tsv` (SupportTierTests reads `daemon/aitermd/models.py`).
- modify `app/Sources/AiTermCore/Harnesses/PiModelCatalog.swift`, `ModelCatalogue.swift`: the
  shared launched-list error.

Worker
- modify `app/Sources/AiTerm/Operators/WorkerTranscript.swift`: agy's transcript, explicit arms.
- modify `app/Sources/AiTermCore/Operators/WorkerGuard/WorkerGuardLaunch.swift`: the `agy` shim.
- modify `daemon/tools/worker_guard_check.py`: check an agy worker.
- agy's review tab (`readOnlyLaunchArguments`): `--dangerously-skip-permissions` with deny rules for
  file writes and git's write commands, in an unsaved `--settings`, as Claude's review denials are.
  Like Claude's review denials and Codex's read-only sandbox, it is the read-only launch no
  production caller asks for yet (`readOnly`): today a review worker is kept from publishing by the
  worker guard (`allowsPush` is false for a review), for every agent alike.

Messaging
- modify `daemon/aitermd/delivery.py`, `daemon/tools/delivery_check.py`: agy's markers, version and
  check.

Compat
- modify `scripts/compat-check.sh`, `daemon/tools/compat_capture.py`, `compat_preflight.py`: agy,
  and the messaged list from the tier.
- modify `compat/verified.json`, `compat/launch.json`; create `daemon/tests/fixtures/compat/agy/`.
- modify `app/Tests/…/CompatContractTests.swift`: agy's launch contracts.

Vendor mark and snapshots
- modify `app/Sources/AiTerm/Views/VendorMark.swift`, `AiTermUI` `Palette.swift`/`Logos.swift`, and
  the design-system page through the `design-system` skill.
- modify the README and Settings snapshot fixtures.

Docs
- modify `docs/configuration.md`: the tier table and agy's card.
- modify `README.md`, `docs/ai-install.md`, `docs/status-model.md` (an agy section),
  `docs/architecture.md`.

## Proof

- Tests: unit tests for each new parser (hook, status line, transcript, model list); the driver's
  ownership of `hooks.json` and `settings.json` (person's entries kept, backup written, Repair
  idempotent); Claude's and agy's saved status-line commands surviving each other's install, with
  and without a command of the person's; the tier derivation and the Swift and daemon tiers agreeing; `WorkerTranscript` for
  agy; agy's launch, resume and Oracle contracts.
- `scripts/test.sh` green on each slice, and a recent green full suite before merging.
- In the app (the `run` skill): an agy task goes working → done, shows needs-input at a permission
  prompt and at the trust dialog, and fills the context ring; Settings installs, tests and repairs
  the driver.
- Messaging's Run check passes for agy; `worker_guard_check` blocks an agy worker's `git push`
  outside a publishing stage; a signal runs one stage on agy end to end.

## To-dos

- [x] 1. Tier in code and docs: `support` on both harness tables, the lists derived from it, the
      parity test, the docs table. No behaviour changes.
- [x] 2. Vendor mark proposal on the design-system page's Proposals tab, picked by the person: the
      white disc.
- [x] 3. agy as an agent: agent kind, harness row, launch, resume, model list, skills, sidebar name,
      Settings card, the vendor mark, and every exhaustive switch the new case reaches. The vendor's
      install command is `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
- [x] 4. agy driver and daemon status from hooks, with the trust-dialog screen and Test.
- [x] 5. Status-line tick: per-agent saved status-line commands, the shim, needs-input and context.
      (The CLI version the status line carries moved to step 9, which is what needs it.)
- [x] 6. Oracle for agy through deny rules.
- [x] 7. Design-system page synced to the Swift mark (`design-system` skill).
- [x] 8. Worker transcript and worker guard; prove the shims hold under
      `--dangerously-skip-permissions`. Proven live by the opt-in `WorkerGuardAgyTests`
      (`AITERM_AGY_GUARD_PROBE=1`, `worker_guard_check.py --cli agy`): a guarded agy worker's
      `git push` lands, its `git push --no-verify` is refused by the guard, read from agy's transcript.
- [x] 9. Messaging: agy's screen markers, the status line's `version` as the tab's `cli_version`, and
      the delivery check, whose agents are the CLIs AiTerm reads the screen of (`MESSAGING_CHECKED`,
      `Harness.messagingChecked`); the full tier is a subset of them. The check passed every scenario
      for agy 1.5.18, and agy is full: it types into agy and the Operator can give it tasks.
- [x] 10. Compat capture, `verified.json`, fixtures, and the README, install and architecture docs.
      agy's latest release comes from its changelog (not npm); its capture installs the `aiterm` hook in
      the scratch workspace and posts to the capture's listener; its own data folders are named
      `/AGY_HOME/` in the capture, any other home path still refuses it. `verified.json`: agy 1.5.
