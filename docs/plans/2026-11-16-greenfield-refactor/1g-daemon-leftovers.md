# 1g. Daemon leftovers

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1a (deleted `operator-current-tools.json` and the
daemon README paragraph about it), 1d and 1e (app leftovers). Comes from: DM F1, DM F7, DM F8, the
test-only part of DM F3, WD F5 (dead requests).

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- **A stale `PostModelSwitch` hook is not reported for Repair.** The design note says an install that still
  has the hook is reported by the "exactly what a merge writes" check. It is not: `ClaudeSettings.isInstalled`
  only asks that every event in `ClaudeSettings.events` is present, and a merge leaves unlisted events alone.
  After this step an old `PostModelSwitch` entry stays in a person's `settings.json` and keeps posting to the
  daemon, which ignores it. No code is written for it (no compatibility), and the release notes' Repair
  step does not remove it. If that matters, say so in the notes (9b); do not add cleanup code here.
- **`session.model` and `session.reasoning` go too.** The plan says "live model and effort attribution". The
  daemon keeps those two fields only to publish them, and nothing in the app reads them (`SidebarModel.rowRelevant`
  blanks them). So the attribution, the fields on the session, on the wire and in Swift all go, not just the
  hook. If the maintainer wants the Operator to see a worker's model later, that is new work.
- **`Deliverer.dismiss_startup` stays**, although nothing in the app can reach it once the
  `session.dismissStartup` request is gone: the maintainer's `daemon/tools/delivery_check.py` calls it
  (scenario `updatePaste`). It now checks a capability the app does not use. Leave it; say so in the report.
- The PI extension (`hooks/pi-aiterm-status.ts`) keeps posting `model`, `reasoning` and `model_select`. The
  daemon ignores them after this step. Removing them from the extension is a separate decision (it has its own
  test, `test_pi_extension.py`); not here.

## Why

Broadcasts were removed on 15 Nov, and the daemon kept five facts that only broadcasts read: what became of a
slash command AiTerm typed into a Claude tab, the tab's live model and effort, when its subagents last wrote,
the tab title, and two requests (`session.prompt`, `session.dismissStartup`). Every tick reads a Claude
transcript for slash records, every hook runs model attribution rules, and every session event carries fields
nobody reads. The wake line check still accepts an older prose form the app can no longer send, a test fixture
and a frozen copy of an older Codex parser guard code that has since changed, and two methods exist only for
tests. After this step the daemon computes and sends only what the sidebar and the Operator use, the wire says
so, and the tests detect the same failures through the surviving behaviour.

## Today

Greps run over `daemon`, `app`, `hooks`, `compat`, `scripts`, `docs`. Re-run them.

**Slash-command tracking.** `daemon/aitermd/slash_commands.py` (`SlashCommands`, `TranscriptReader`,
`TranscriptRecord`) is imported by `service.py` (`self.slash_commands`, `_h_deliver` stamps a typed slash command
and publishes `slash_commands.delivered`, the tick step "reading what became of the slash commands") and
`corroboration.py` (`CorroboratingReaders.__init__` takes `slash_commands`, method `slash()`). `models.py` has
`SlashState`, `SlashCommand`, `SessionInfo.slash_commands`, and its key in `SessionInfo.to_json`.
`sessions.py` has `SessionRegistry.set_slash_commands` and imports `SlashCommand`. Swift reads none of it except
the decode: `DaemonTypes.swift` (`SlashCommand`, `SessionInfo.slashCommands`) and `SidebarModel.rowRelevant`
(blanks it). Tests: `test_slash_commands.py` (whole file, 20 references; it also defines helpers `IDLE`, `Clock`,
`caveat`, `iso`, `output`, `ran`, `write` that `test_stop_failures.py` imports), the slash cases in
`test_sessions.py`, `test_models.py`, `test_service.py`, and `test_compat_captures.py`
(`test_claude_transcript_shows_the_slash_command_and_its_output`, which imports `TranscriptReader`).
`daemon/tools/compat_capture.py` has `slash_command()` and a `slashCommand` turn that exists to feed that reader.
`slash_commands.py` has no other consumer: `stop_failures.py` does not import it
(`grep -n "slash_commands" daemon/aitermd/stop_failures.py` is empty; its mention of slash commands is a comment).

**Live model and effort.** `models.py` `SessionInfo.model` and `.reasoning` (both `process` fields) and their
`to_json` keys; `sessions.py` `set_model`, `set_reasoning` and `model=None` in `_to_info`; `status.py`
`apply_metadata(model=, reasoning=, clear_reasoning=)`; `hook_router.py` (`handle_hook`: the status-line branch
tests `tick.model or tick.reasoning or ...`; `_place_and_apply` passes `model`, `reasoning`, `clear_reasoning`
and computes `own` for them); `hook_events.py` (`HookEvent.model`, `HookEvent.reasoning`, the Claude
`SessionStart` model, the `PostModelSwitch` branch of `_claude_event`, the Codex `SessionStart` model, the PI
`model` and `reasoning` fields, `StatusLineTick.model` and `.reasoning`, the `"model_select": None` row of
`PI_EVENTS`, helper `_session_field` only for model). `grep -rn "\.model\b\|\.reasoning\b" daemon/aitermd`
shows no other reader. Swift: `DaemonTypes.swift` `SessionInfo.model`, `.reasoning`, `liveModel`, `liveReasoning`;
`Harnesses/ClaudeSettings.swift` `events` includes `PostModelSwitch`; `compat/drivers/claude-settings.json` has
the block for it (about lines 37-53); `HookConfigTests` expects it (about line 18).

**`subagentsWrittenAt`.** `models.py` field and key; `sessions.py` `set_subagents_written_at`; `status.py`
`_Child.written_at`, `_show_children` (computes the newest `written_at` and sets it), `release_dead_subagents`
(assigns `child.written_at`), `agent_exited` (clears it). `TranscriptTail.written_at` in `claude_subagents.py`
stays: tests read it and the same read gives `stamp`. Swift: `DaemonTypes.swift` field, `SidebarModel.rowRelevant`.

**`title` on the wire.** `SessionInfo.title` in `models.py` is internal (compared `compare=False`, read by the
status engine for the Codex spinner) and is sent as `"title"`. Swift `SessionInfo.title` is read nowhere (the
`SessionTitle` and `setTitles` request are the other direction and unrelated).

**Dead requests.** Daemon: `service.py` registers `session.prompt` (`_h_prompt`) and `session.dismissStartup`
(`_h_dismiss_startup`); `delivery.py` `Deliverer.prompt_details` and `screens.py` `PromptDetails`.
`Deliverer.dismiss_startup`, `shows_update_offer`, `Harness.update_prompt` and `ESC` stay (see above).
`PromptKind`, `open_prompt` and `_session_prompt` stay (`Deliverer` uses `_session_prompt` for refusals). Swift:
`DaemonProtocol.swift` cases `sessionPrompt` and `sessionDismissStartup`; `DaemonCommands.swift` `prompt`,
`promptDetails`, `dismissStartup`; `DaemonClient.swift` the three implementations plus `PromptResult` and
`DismissResult`; `DaemonTypes.swift` `PromptKind` and `PromptDetails`; `RecordingDaemon.swift` `prompts`,
`dismissible` and the three methods; `DaemonOperatorWireTests` (about lines 48-90 and 131-135);
`WireContractTests` (two `case` lines about 101-102). `grep -rnF 'promptDetails(' app/Sources` and
`grep -rnF 'dismissStartup(' app/Sources` outside `AiTermCore/Daemon/` return nothing.

**Prose wake rule.** `delivery.py` `wake_text_problem` accepts the fixed grammar (`[AiTerm] <event> <uuid>; call
run_status`, event in `WAKE_EVENTS`), and otherwise applies "the older prose form's" digit, one-letter-word and
length rules, with `_QUOTES`. The app sends only the grammar (`OperatorWakeEvent`, sole caller the Operator
controller's wake). `tests/fixtures/wake-lines.json` is read only by `test_delivery.py`
(`test_the_daemon_and_the_app_agree_on_which_wake_lines_are_plain`; its comment about the app's tests is false:
`grep -rn "wake-lines\|isPlain" app` is empty) and named in `scripts/test-routes.tsv` (line about 31).
The test constants `WAKE` and `SNAG_WAKE` in `test_delivery.py` are prose lines.

**`operator_token.py`** (8 lines, `well_formed`): imported by `operator_session.py` only; `operator_mcp.py` line
about 16 re-exports it and nothing imports it from there (`grep -rn "well_formed" daemon` shows both).

**Test-only seams.** `Service.settle_reads` (`service.py`, about line 407) and `SessionResolver.settle_reads`
(`resolver.py`, about line 42): callers are `tests/test_service.py` (three) and `tests/test_resolver.py` (one).

**Codex reader.** `codex_sessions.py` `CodexSessionFiles.context_percent`, `cli_version`, `turn_state` have no
production caller (production uses `reading()`, from `corroboration.py`); `tests/test_codex_sessions.py` calls them
about forty times. `tests/codex_reference.py` (`MainCodexReference`, "copied unchanged") is imported only by
`test_codex_sessions.py`.

## Change

Daemon, in this order (run the daemon suite after each group):

1. **Slash tracking.** Delete `slash_commands.py`, `SlashState`, `SlashCommand`, `SessionInfo.slash_commands` and
   its `to_json` key, `SessionRegistry.set_slash_commands`, the `slash_commands` constructor parameter and
   `slash()` method of `CorroboratingReaders`, `Service.slash_commands`, its tick step, and the stamping in
   `_h_deliver` (which then just calls `deliverer.deliver` and returns `result.to_json()`). Delete the `slash`
   comments in `hook_events.py` (about line 45), `stop_failures.py` (keep the code, reword only if it names the tracker).
   In `daemon/tools/compat_capture.py` delete `slash_command()` and the `slashCommand` turn (the `turns` list
   and the "claude: a slash command" step); the saved capture note under `daemon/tests/fixtures/compat/claude/`
   is never edited and keeps listing it.
2. **Live model, effort, PostModelSwitch.** Delete `SessionInfo.model` and `.reasoning`, their `to_json` keys,
   `set_model`, `set_reasoning`, `model=None` in `_to_info`. `apply_metadata` loses `model`, `reasoning` and
   `clear_reasoning` (what remains: `context`, `cwd`, `context_tokens`, `clear_context_tokens`, `conversation`,
   `transcript`). In `hook_events.py` remove `HookEvent.model` and `.reasoning` (this changes `HookEvent`'s positional
   order: fix every constructor call, including in tests), the `PostModelSwitch` branch, the model argument of Claude
   and Codex `SessionStart`, the PI `model` and `reasoning` reads, `StatusLineTick.model` and `.reasoning`, the
   `model_select` row of `PI_EVENTS` (an unknown event name parses to nothing, which is right), and `_session_field`
   if `transcript_path` is its only remaining use (keep the "post from inside a subagent says nothing of the
   session" rule for `transcript_path`). In `hook_router.py` the status-line branch applies when the tick carries a
   context percentage or the body has `context_window`; `_place_and_apply` keeps `own` for `context_tokens`,
   `conversation` and `transcript`. Keep `context_percent`, `context_tokens`, `transcript` on both paths.
   Swift: drop `PostModelSwitch` from `ClaudeSettings.events`; re-record `compat/drivers/claude-settings.json`
   (Tests).
3. **`subagents_written_at`.** Delete the field, key, `set_subagents_written_at`, `_Child.written_at`, the
   `written_at` computation in `_show_children` (it still sets `background` and builds `display_work`), the
   assignment in `release_dead_subagents` (it still sets `stamp` and `quiet_since`) and the clear in
   `agent_exited`.
4. **`title` off the wire.** Remove `"title"` from `SessionInfo.to_json`. The dataclass field, its
   `compare=False`, the snapshot copy in `apply_snapshot` and the status engine's read stay. Update the comment on
   the field ("clients do not use it" becomes true by construction).
5. **Dead requests.** Delete the two `r(...)` registrations, `_h_prompt`, `_h_dismiss_startup`,
   `Deliverer.prompt_details` and `screens.PromptDetails` (and its re-export in `delivery.py`). Update the module
   docstring of `delivery.py` or `service.py` if it names them, and the comment above `ESC` ("what declines
   Codex's update offer") to say it is the delivery check's.
6. **Wake rule.** `wake_text_problem` becomes the grammar `fullmatch` and nothing else: it returns `None` for a
   line of the grammar and one fixed reason for any other, "a wake line is the app's fixed wake line or nothing"
   (the code stays `wakeText`). Delete `_QUOTES`, the `string` import if unused, and the digit, letter and length
   branches. Delete `tests/fixtures/wake-lines.json` and the `scripts/test-routes.tsv` row for it.
7. **`operator_token.py`.** Move `well_formed` (and its compiled pattern) into `operator_session.py`, delete the
   file and the re-export line in `operator_mcp.py`.
8. **`settle_reads`.** Delete both methods. Tests drain through helpers they own: in `tests/conftest.py` add
   `settle(svc)`, which awaits `svc._checks.values()` with `asyncio.gather(..., return_exceptions=True)` and then
   drops the finished entries (the body of today's method); in `test_resolver.py` a local helper that awaits
   `resolver._scan` the same way. The four test call sites use them.
9. **Codex reader.** Delete `context_percent`, `cli_version`, `turn_state` as public methods. `_previous_version`
   and `_turn_at` stay (`reading()` uses them; step 2e removes them). Delete `tests/codex_reference.py`.

Swift:

10. `DaemonTypes.swift`: delete `SessionInfo.model`, `reasoning`, `title`, `subagentsWrittenAt`, `slashCommands`,
    `liveModel`, `liveReasoning`, and the types `SlashCommand`, `PromptKind`, `PromptDetails`. Remove the same
    lines from the hand-written `SessionInfo.init(from:)` (step 1h deletes that initialiser entirely; do not
    delete it here). `SidebarModel.rowRelevant` loses its assignments for them (it still blanks `contextPercent`,
    `conversationId`). The memberwise initialiser loses `model`, `reasoning`, `title`: fix every caller in
    `app/Sources` and `app/Tests` (Builders' `make`, the files that call `SessionInfo(` directly: grep it).
11. `DaemonProtocol.swift`, `DaemonCommands.swift`, `DaemonClient.swift`, `RecordingDaemon.swift`: delete the two
    methods' cases, requirements, implementations and fakes as listed under Today. Rewrite the doc comment of
    `RecordingDaemon`'s remaining members only where they mention them.
12. Docs, only the lines this makes false: `docs/daemon-protocol.md` (rows for `session.prompt` and
    `session.dismissStartup` and the paragraph after the table about `session.prompt`; the `session.opened/.changed`
    row's "new model" and `subagentsWrittenAt` text), `docs/status-model.md` (rows for `PostModelSwitch` and
    `model_select`; the section "What a Claude worker runs, and what became of a slash command" is deleted whole;
    the `subagentsWrittenAt` sentence about line 245), `docs/architecture.md` (the two table rows about a worker's
    live model and slash commands), `daemon/README.md` (route table: "Session/turn/subagent/..." without "model",
    the `/statusline` row without "model", the `/hook/pi` row without "model/reasoning"). Do not rewrite other
    paragraphs: phase 9 does.

## Keep

- `SessionInfo.stopped_on`, `transcript`, `your_prompt`, `cli_version`, `context_percent`, `context_tokens`,
  `conversation_id`, `display_work`, `background`, `test_activity`: live. `transcript` is read by
  `corroboration.py` for stopped workers.
- `title` inside the daemon: the status engine reads it for the Codex spinner. Only the wire key goes.
- `Deliverer.dismiss_startup`, `shows_update_offer`, `ESC`, `update_prompt`, `open_prompt`, `PromptKind`,
  `DeliveryCode.prompt` (Swift) and the refusal code `prompt`: the delivery check and refusals use them.
- `WAKE_EVENTS`, the manifest's `wakeEvents`, and `OperatorWakeEvent`: the grammar is unchanged.
- `TranscriptTail.written_at`, `ClaudeSessionFile.written_at`, and the Codex `service.py` `written_at` for rate
  limits: other readers. `SUBAGENT_QUIET_SECONDS` and the quiet window: step 2e.
- `CodexSessionFiles.reading()`, `_previous_version`, `_turn_at`, `_RolloutCursor` and its error isolation: 2e
  rewrites them to one cursor; today's behaviour is the proof until then.
- `run_id`/`runId` vocabulary in `operator_mcp.py`, "spec §" comments, `GATE_TIMEOUT` placement: 1j.
- `compat/launch.json`: unchanged by this step. Captures under `daemon/tests/fixtures/compat/` are never edited.
- `hooks/pi-aiterm-status.ts` and its test.

## Decisions already taken

- **How a worker's model is seen now:** it is not. No other surface shows it.
- **A statusline post with only a model** (no `context_window`): no longer applies anything. The real captures
  carry `context_window` on every post, so nothing is lost; the compat test is adjusted (below).
- **Wake line refused:** the reply is the existing refusal shape with code `wakeText` and the one sentence in step 6.
  The app already treats a refused wake like any other refusal. The wire frame
  `reply.session.deliver.refused.json` is a PI refusal that happens before the text check: its bytes do not change.
  Still, change its script text in `test_wire_contract.py` to a grammar line (event `worker_ended`, a fixed uuid)
  so the script sends what the app can send.
- **Tests whose fixtures are Claude, Codex and PI captures** keep reading the captured payloads that remain parsed.
  A test that read a field the parser no longer parses is deleted with the parser, never fixed by editing a capture.
- **`PromptDetails` consumers in tests** (`test_delivery.py` about 441-445, 1060-1178; `test_delivery_service.py`
  about 166-171, 202-203, 229-238): see Tests.
- A tab opened before this change has no per-session model on the wire: the app never read it, so nothing needs
  handling. An older helper left running is stopped by the app as today; no version handling is added.
- Nothing in the daemon needs a guard for "the app still sends `session.prompt`": the app does not.

## Tests

**How the wire frames are produced and re-recorded.** `daemon/tests/test_wire_contract.py` scripts one run of a
real `Service` over `FakeIterm` (cookie refused, then accepted, a task window with a PI tab, a worker tab and a
terminal, hooks, a status-line post, an Operator request, a Claude worker's background work) and writes every
event, reply and error frame the app would receive, plus `manifest.json`, to `daemon/tests/wire/`. The test fails
while the files differ from what the script emits. To re-record, from `daemon/`:
`AITERM_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py` (it also deletes frames no longer
produced, which removes `reply.session.prompt.json` and `reply.session.dismissStartup.json`), then run it again
without the switch, then `scripts/test.sh swift -- --filter WireContractTests`: Swift decodes each frame with the
production decoders and requires that the fields of `SessionInfo` equal the frame's keys, so both sides must lose
the same keys. Add to `daemon/tests/wire/PROVENANCE.md` a dated paragraph: this step removed `model`,
`reasoning`, `title`, `subagentsWrittenAt` and `slashCommands` from every session, and the requests
`session.prompt` and `session.dismissStartup` from the manifest, no live account used. In the script delete the
`session.prompt` and `session.dismissStartup` calls, the `/effort high` deliver and its transcript and
`apply_metadata` lines that only fed the slash tracker (keep `context_tokens=39239`, and keep the
transcript registration only if a remaining frame needs it), the `os.utime` line and its comment about the
review transcript's write time, and the `"model"` and `"reasoning"` keys of the PI hook post. Every frame other
than the sessions' shapes and the manifest must come out byte for byte the same: check `git diff --stat daemon/tests/wire`
lists only `event.session.*`, `reply.sessions.list`, `reply.workspace.snapshot`, `manifest` and the two deleted files.

**How the driver fixtures are produced.** `compat/launch.json` and `compat/drivers/claude-settings.json`,
`codex-hooks.toml` are written by `CompatContractTests` from what the app builds. Re-record only after the Swift
change is done: `AITERM_RECORD_COMPAT=1 scripts/test.sh swift -- --filter CompatContractTests` (a plain test
run; it opens no window and spends no quota, unlike `scripts/compat-check.sh`, which is the maintainer's and
which you never run). Expect exactly one change: the `PostModelSwitch` block leaves `claude-settings.json`.
`launch.json` and `codex-hooks.toml` must not change. `compat/` has no `PROVENANCE.md`; do not create one, and
name the change in your report. Captures under `daemon/tests/fixtures/compat/` are not touched.

**Delete (with survivor or "behaviour deleted")**
- `test_slash_commands.py` whole: behaviour deleted. First move the helpers `test_stop_failures.py` imports
  (`IDLE`, `Clock`, `caveat`, `iso`, `output`, `ran`, `write`) into `tests/builders.py` or into
  `test_stop_failures.py` itself, then fix its import. `test_stop_failures.py` is the survivor for the transcript
  parts that remain (stopped workers).
- In `test_compat_captures.py`: `test_claude_transcript_shows_the_slash_command_and_its_output` and the
  `TranscriptReader` import (behaviour deleted); replace `assert last.model and last.transcript` (about line 122)
  with `assert last.context_percent is not None and last.transcript`; delete the `.model` assertions on Codex
  `SessionStart` (about 197) and PI (about 234-235).
- `test_hook_events.py`: the `PostModelSwitch` and model columns (about lines 14-37, 45); `test_hook_router.py`
  the model, reasoning and PostModelSwitch tests (about 60-152, 200-208); `test_models.py` the model, reasoning,
  title, slash and subagentsWrittenAt keys of the expected session JSON (about line 71; keep the test, shrink the
  expected dict); `test_sessions.py` (slash and `set_subagents_written_at` cases, about 298-303),
  `test_status.py` (the `subagents_written_at` assertions about 509 and 840-856: keep each test, drop the assertion
  lines on that field; the quiet-window assertions stay), `test_service.py` (slash, `PostModelSwitch` and
  `subagents_written_at` cases), `test_iterm_bridge.py` about 1150-1157 (keep the test of "a reused tab does not
  keep the old agent's context", drop the `model` part).
- `test_delivery.py`: the prose wake tests and the plain-lines table (about 930-975, `wake-lines.json` reader,
  `test_plain_wake_lines_pass`): behaviour deleted. Add one parametrized test, a wake line outside the grammar
  (prose, a digit, a wrong event, a malformed uuid, a trailing word) is refused with code `wakeText` and nothing
  is typed, and one that the grammar line passes. Change `WAKE` and `SNAG_WAKE` to grammar lines (any event, a
  fixed uuid), and the literal `"wake"` texts of the tests at about lines 809 and 832 likewise if a refusal for
  the wrong reason appears. `test_a_wake_line_never_goes_through_a_message_file` goes (a grammar line is short).
- `prompt_details` (`test_delivery.py` about 441-445, 1060, 1080-1178; `test_delivery_service.py` about 166-171,
  202-203, 229, 235-240): the service tests for `session.prompt` and `session.dismissStartup` and the not-found and
  blank-screen cases are behaviour deleted. The recognition cases (permission, menu, none; a trust dialog is not an
  update offer) survive by reading the open prompt through a helper in the test file that calls
  `screens._session_prompt(session, screen)` on the rig's registered session and its fake screen. The
  `dismiss_startup` tests stay, they call the deliverer directly. `test_delivery_service.py`'s module docstring
  loses the two names.
- `test_codex_sessions.py`: add three local helpers (`context_percent`, `cli_version`, `turn_state` of a
  `CodexSessionFiles` and a thread id) that return the matching field of `files.reading(thread)`, and call them
  where the methods were. A test that relied on the method raising (about lines 265-290, which asserts an
  `OSError` is raised and then retried) is rewritten to the reading's own behaviour (the failure is logged and
  the field is `None`, the next reading is right) or, if it cannot be, deleted with
  `test_a_failed_combined_cursor_read_retries_without_a_file_change` (about 477) as the survivor. Remove every
  `MainCodexReference` use: where a test also states the expected value (the parametrized `expected`, the final
  literal such as `(50, "0.162.0", ("working", 103.0))`), keep it with the literal and drop the reference
  comparison; a test whose only oracle was the reference gets the literal from its own final assertion. Delete
  `tests/codex_reference.py`.
- `test_service.py` and `test_resolver.py`: the four `settle_reads` calls use the new helpers.
- `test_tick_budgets.py`: a steady tick no longer has the slash step (it read nothing when no command was
  typed, so no number should move). Do not change a number; if one fails, report it.

**Add:** the grammar test above. A `test_models.py` assertion that `to_json` carries none of the five removed keys.

**Swift:** `DaemonTypesTests` (about eight decode checks of the removed fields: delete them, keep the others);
`DaemonOperatorWireTests` cases for `prompt`, `promptDetails`, `dismissStartup` and the unknown prompt kind
(behaviour deleted; the `DeliveryCode` cases stay); `WireContractTests` two `case` lines; `HookConfigTests`
(expect the event set without `PostModelSwitch`); every file that builds `SessionInfo` with `model:` or `title:`
(`SidebarModelTests` about line 9, `TaskConversationsTests` about 16, `Builders.swift`, and the others grep finds).

## Proof

From `daemon/`: `.venv/bin/pytest -k "wake or delivery"`, then `-k "hook or status or sessions or models"`,
`-k "codex"`, `-k wire` (after re-recording), `-k compat_captures`, then the whole `.venv/bin/pytest`. Then
`scripts/test.sh swift -- --filter DaemonTypesTests`, `WireContractTests`, `DaemonOperatorWireTests`,
`HookConfigTests`, `CompatContractTests` (without the record switch it must now pass) and `SidebarModelTests`. Last, plain `scripts/test.sh` in the background (it runs `ruff` and `mypy` on
`aitermd tests tools`; the removed imports must leave none behind). No snapshot capture: no view changes.

## Done when

- `grep -rniE "slash_commands|SlashCommand|slashCommands|PostModelSwitch|subagentsWrittenAt|subagents_written_at|liveModel|liveReasoning|settle_reads|operator_token|wake-lines|codex_reference|MainCodexReference|PromptDetails|prompt_details|sessionPrompt|sessionDismissStartup|session\.prompt|promptDetails" app daemon compat scripts hooks docs/*.md README.md`
  returns nothing, except `session.dismissStartup`/`dismiss_startup` in `daemon/tools/delivery_check.py` and
  `Deliverer.dismiss_startup` with its tests, and the untouched captures under `daemon/tests/fixtures/compat/`.
- `grep -rn "\"title\"\|\"model\"\|\"reasoning\"" daemon/tests/wire` returns nothing.
- `daemon/tests/wire/` regenerated, `PROVENANCE.md` paragraph added, `compat/drivers/claude-settings.json` changed
  only by the `PostModelSwitch` block.
- Daemon suite, `mypy`, `ruff` and plain `scripts/test.sh` green. The report lists each deleted test with its
  survivor and names the planner points above that held.

## Not in this step

- The one-cursor Codex reader, the quiet window, the batched-read fallback: 2e.
- `run_id` to `operatorId` (wire too), "spec §" comments, `operated`: 1j.
- Old-helper decoding forms (`SessionInfo.init(from:)`, `BackgroundJob` bare string, "daemon too old" defaults,
  `background ? true : nil`): 1h.
- `background` plus `displayWork`, the work list, `DaemonCommands` return shapes and `snapshot()`: 6a and 6c.
- The PI extension's payload fields: not planned.
