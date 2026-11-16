# 6f. Telemetry grouped by agent

Implementer: Opus 5.5, high. Depends on: 6a to 6e (and 1g, 2e before them). Findings: DM F4.

## Why

What the daemon knows about Claude, Codex and PI is spread by the order it was added: Claude
across seven modules, Codex across four, and the status engine has one method per corroborating
source (`apply_claude_file_status`, `apply_codex_title`, `apply_codex_rollout`,
`apply_claude_progress`), each holding an agent's mapping before it calls the one neutral function
`_apply_state`. Changing one agent's evidence touches a parser, a reader, a plan, the engine and a
`Harness` flag. The end state: three concrete modules chosen by agent kind, `aitermd/agents/claude.py`,
`codex.py` and `pi.py`, each turning its own readings into evidence; the engine has one public
evidence entry point and no agent-specific method. This is a move. What each source can change, and
the freshness ordering between sources and against hooks, must not change at all. The Codex tab
title stays a source.

## Today

After 1g, 2e and 6a to 6e, in `daemon/aitermd/`:

- `hook_events.py`: `HookEvent`, `StatusLine`; shared helpers (`_subagent`, `_session_start`,
  `_submitted`, `SIMPLE_EVENTS`); Claude parsing (`parse_claude_hook`, `_claude_event`,
  `NEEDS_INPUT_NOTIFICATIONS`, `_session_field`, `_claude_subagent_transcript`, the
  `background_tasks` readers and their constants, `parse_claude_statusline`, `_object_field`,
  `_context_percent`, `_context_tokens`); `parse_codex_hook`; `parse_pi_hook`, `PI_EVENTS`,
  `PI_NEW_CONVERSATION_REASONS`; the tables `HOOK_PARSERS` and `STATUSLINE_PARSERS` (read by
  `hooks_server.py` and `hook_router.py`).
- `status.py`: `StatusEngine` with `CLAUDE_FILE_STATUS`, `_has_spinner`, `apply_claude_file_status`,
  `apply_codex_title`, `apply_codex_rollout`, `apply_claude_progress`, all funnelling into
  `_apply_state(session_id, target, at, source)`, whose source is one of hook, Claude file, Codex
  title, rollout. Neutral parts: `apply_event`, `apply_metadata`, trust prompt, children,
  `release_dead_subagents`, `apply_shell_reading`, PI prompt bracketing, `agent_exited`, `mark_seen`.
- Claude readers: `claude_sessions.py` (`ClaudeSessionFiles`, `ClaudeSessionFile`),
  `claude_subagents.py` (`SubagentTranscripts`, `TranscriptTail`, the end rules),
  `claude_background.py` (`BackgroundTranscripts`, `ShellReading`, `ShellTask`),
  `stop_failures.py` (`StopTranscripts`, `StopReading`, `LIMIT_ERRORS`, `RESET_READ_SECONDS`).
  `models.CLAUDE_TERMINAL_TASK_STATUSES`; `usage.parse_claude_rate_limits`.
- Codex: `codex_sessions.py` (the one rollout cursor from 2e, rate limits, `CODEX_READ`),
  `codex_threads.py` (6e), `usage.parse_codex_rate_limits` with `FIVE_HOUR_MINS`, `WEEK_MINS`.
- `corroboration.py`: `ReadPlan`, `SessionKey` (6d), `logged`, and `CorroboratingReaders` with
  `snapshot` (a shell tab's exit; a Codex tab's title), `claude` (session files, and which idle
  tabs' screens to read), `trust_prompts`, `codex`, `subagents`, `background`, `stops`, `tests`.
  It switches on `HARNESS_BY_AGENT[...].corroboration`.
- `models.py`: `Harness.corroboration` (`claude_file`, `codex_title` or None) with a comment naming
  `Service._corroborate`, which no longer exists.
- `service.py`: builds the readers; `_after_snapshot` runs, in this fixed order, the snapshot pass,
  the Claude file read, the trust screens, the Codex rollouts, the subagent transcripts, the
  background shells, the stopped workers' transcripts, test activity, then the Codex tag write;
  `_read_codex_usage` runs before the iTerm2 check.
- `resolver.py` places Claude posts by pid file through `ClaudeSessionFiles`.

Callers of the engine's agent methods: `rg -n "apply_claude_file_status|apply_codex_title|apply_codex_rollout|apply_claude_progress" daemon`
(the plans in `corroboration.py`, and tests in `test_status.py`, `test_stop_failures.py`,
`test_service.py`). Importers of the modules that move: `rg -n "claude_sessions|claude_subagents|claude_background|stop_failures|codex_sessions|codex_threads|hook_events" daemon scripts`.

## Change

1. Create the package `daemon/aitermd/agents/` with an `__init__.py` (the setuptools
   `include = ["aitermd*"]` pattern bundles it).
2. `agents/claude.py` receives, unchanged in behaviour: the Claude hook and status-line parsing and
   their helpers and constants from `hook_events.py`; `CLAUDE_TERMINAL_TASK_STATUSES`;
   `parse_claude_rate_limits`; all of `claude_sessions.py`, `claude_subagents.py`,
   `claude_background.py` and `stop_failures.py`; the file-status table and its mapping to evidence
   (step 5); and the four Claude read plans from `corroboration.py` as functions (the session-file
   plan with its list of idle tabs whose screens to read, the subagent-transcript plan, the
   background-shell plan, the stopped-worker plan), each given the registry, the engine and its
   reader.
3. `agents/codex.py` receives `parse_codex_hook`; all of `codex_sessions.py` and
   `codex_threads.py`; `parse_codex_rate_limits` with its two constants; the spinner rule and its
   mapping to evidence (step 5); the rollout read plan, whose turn boundary becomes evidence.
4. `agents/pi.py` receives `parse_pi_hook`, `PI_EVENTS` and `PI_NEW_CONVERSATION_REASONS`.
   `agents/__init__.py` builds `HOOK_PARSERS` and `STATUSLINE_PARSERS` from `models.HARNESSES` and a
   plain dict from agent to the parser in its module (a route without a parser still fails at
   import). `hooks_server.py` and `hook_router.py` import them from there.
5. Evidence. In `status.py` add `Evidence`: the state the evidence claims (working, needs input or
   done), the wall-clock time it speaks for, and its source (Claude session file, Codex title or
   Codex rollout). `StatusEngine.apply_evidence(session_id, evidence)` is the one public entry
   point for tick evidence; it is today's `_apply_state` with the per-source rules that the four
   methods applied before calling it moved inside, keyed by source: a Claude-file "done" on a
   session that is neither working nor asking and counts no child changes nothing (today the method
   passed the session's own state, which was a no-op); a Codex-title "working" marks the turn
   spun, and a Codex-title "done" lands only on a working session whose turn has spun. Hooks keep
   entering through `apply_event`, which calls the same function with source hook. The agent
   modules map raw readings: Claude's file status (unknown status: no evidence; busy, thinking,
   running: working; waiting: needs input; idle, shell: done; time: the file's mtime), Codex's title
   (spinner: working, else done; time: the tick's clock), Codex's rollout boundary (working or done
   at the record's time).
6. Rename `apply_claude_progress` to `apply_progress(session_id, at)`: "the session's agent carried
   on at `at`", which clears what stopped its turn. Drop its agent check; only the Claude stop plan
   calls it. Delete `apply_claude_file_status`, `apply_codex_title`, `apply_codex_rollout`,
   `CLAUDE_FILE_STATUS` and `_has_spinner` from `status.py`. The engine imports Claude's reading
   types (`TranscriptTail`, `ShellReading`) for annotations only, so no runtime import cycle.
7. `corroboration.py` keeps `ReadPlan`, `SessionKey`, `logged` and the neutral steps: the snapshot
   pass (a shell tab's exit; for a Codex tab, its title's evidence from `agents/codex.py`), the
   trust-screen read and the test-activity plan. `CorroboratingReaders` keeps only these, or becomes
   plain functions; either way nothing agent-specific stays. Selection is by `session.agent`.
8. Delete `Harness.corroboration` from `models.py`, with its stale comment; nothing reads it after
   step 7. `usage.py` keeps `UsageStore`, `finite_number`, `clamped_percent` and the one-window
   reader both parsers use (make it public).
9. `service.py` imports from the new modules and runs the same observations in the same order;
   `_read_codex_usage` stays where it is and calls `codex.parse_codex_rate_limits`. `resolver.py`
   imports `ClaudeSessionFiles` from `agents/claude.py`; its placement logic does not move.
10. Delete `claude_sessions.py`, `claude_subagents.py`, `claude_background.py`, `stop_failures.py`,
    `codex_sessions.py` and `codex_threads.py`. `hook_events.py` keeps `HookEvent`, `StatusLine`,
    the shared helpers and the parser type aliases.
11. Docs, a sentence each: `daemon/README.md` (where agent telemetry lives); `docs/status-model.md`
    ("Which harness has which is its `corroboration` in the `HARNESSES` table" becomes a pointer to
    the agent modules); `docs/architecture.md` if it names `CorroboratingReaders` for agent reads.

## Keep

- Freshness ordering, exactly: a Claude file no newer than the last hook says nothing; a rollout
  boundary lands only after the last hook and the last boundary; a Codex title's absence ends a
  turn only after a spinner was seen since the last hook; a busy Claude file with children cannot
  clear what stopped the parent; progress counts only after the failure and the last hook. These
  live in the engine because they compare sources; only the raw-to-evidence mapping moves.
- The tick's observation order and the one-second off-loop deadline per read.
- The Codex title as a source (`Turn.spun`, the spinner rule): retiring it needs a live probe, left
  out of the plan.
- PI's prompt bracketing (`promptStart`/`promptEnd`, `Turn.before_prompt`) in the engine: those
  transitions are neutral turn state.
- The resolver's pid-file placement for Claude: placement is neutral by `Harness.placement`.
- The `Harness` table's other fields: delivery and screen recognition read them.
- No wire change: frames stay byte for byte.

## Decisions already taken

- Three modules, no registry, no protocol per agent: a dict from agent to parser for the hook
  routes, and the service calling each agent's plan functions by name.
- `agents/claude.py` will be about 850 lines; that is accepted (one owner for Claude's knowledge).
  Do not split it further.
- Test files keep their names; only their imports and the calls of deleted engine methods change.
- If an implementer finds a source rule that cannot move into `apply_evidence` without changing a
  test's expectation, stop and report: the expectation wins.

## Tests

- No test's expectations change. Calls change: tests that called `apply_claude_file_status`,
  `apply_codex_title` or `apply_codex_rollout` map the raw reading through the agent module and call
  `apply_evidence` (a small helper in `test_status.py` that applies nothing for an unmapped status
  keeps them short); `apply_claude_progress` becomes `apply_progress`.
- Imports move in `test_hook_events.py`, `test_claude_sessions.py`, `test_claude_subagents.py`, `test_claude_background.py`, `test_stop_failures.py`,
  `test_codex_sessions.py`, `test_codex_threads.py`, `test_status.py`, `test_service.py`,
  `test_resolver.py`, `test_hook_router.py`, `test_operator_session.py`, `test_tick_budgets.py`,
  `conftest.py`, `test_compat_captures.py` (it imports the file-status table and the spinner rule)
  and `daemon/tools/compat_capture.py` (the maintainer's capture tool: fix its imports, never run
  it).
- The tests that pin freshness ordering, which must pass with unchanged assertions:
  `test_status.py` `test_a_session_file_older_than_the_last_hook_does_not_override_it`,
  `test_a_session_file_written_after_the_last_hook_still_moves_the_row`,
  `test_claude_file_status_mapping`, `test_claude_file_status_tracks_resume_after_input`,
  `test_an_unknown_claude_file_status_is_ignored`, `test_claude_idle_file_waits_for_background_subagent`,
  `test_claude_idle_file_does_not_hide_needs_input_while_child_runs`, `test_codex_title_spinner`,
  `test_codex_title_without_spinner_waits_for_background_subagent`,
  `test_codex_spinner_restores_working_after_input`, `test_codex_title_without_spinner_keeps_needs_input`,
  `test_a_codex_prompt_is_not_ended_before_its_spinner_first_appears`,
  `test_the_previous_turns_spinner_does_not_end_the_next_prompt`,
  `test_a_spinner_after_an_answered_prompt_lets_its_absence_end_the_turn`,
  `test_codex_rollout_completion_recovers_missed_stop_and_spinner`,
  `test_resumed_codex_ignores_completion_from_before_session_start`,
  `test_rollout_start_clears_the_previous_turns_deferred_completion`; `test_stop_failures.py`
  `test_the_session_file_saying_it_works_again_clears_it`,
  `test_a_busy_file_cannot_distinguish_a_stopped_parent_from_its_running_child`,
  `test_resumed_activity_is_published_after_a_failure_with_a_child_still_running`,
  `test_a_recovery_read_overtaken_by_new_evidence_cannot_clear_the_stop`; `test_service.py`
  `test_a_hook_cwd_change_during_a_claude_file_read_is_not_overwritten`,
  `test_a_codex_permission_hook_during_a_claude_file_read_survives_the_snapshot_title`,
  `test_tick_uses_claude_file_status_and_agent_exit`; all of `test_compat_captures.py`.
- Add one test per new mapping function: every Claude file status to its evidence (or none), the
  spinner and no-spinner titles, and a rollout boundary record.
- Add: a Claude-file "done" on an idle session that counts no child changes nothing (the rule that
  moved into the engine).
- `test_wire_contract.py` and `test_tick_budgets.py` pass with no fixture change.

## Proof

- From `daemon/`: `.venv/bin/pytest` (the whole daemon suite: this step touches every telemetry
  path), `.venv/bin/mypy aitermd tests tools`, `.venv/bin/ruff check aitermd tests tools`.
- `scripts/test.sh swift -- --filter WireContractTests` and `--filter CompatContractTests`.
- `scripts/make-app.sh` then `scripts/test-app-bundle.sh build/AiTerm.app`: the bundle must contain
  `aitermd/agents/` and import `aitermd.service` (this is phase 6's bundle check).
- Plain `scripts/test.sh`.

## Done when

- `rg -n "apply_claude_file_status|apply_codex_title|apply_codex_rollout|apply_claude_progress|CLAUDE_FILE_STATUS|_has_spinner" daemon/aitermd/status.py`
  returns nothing.
- `ls daemon/aitermd` shows no `claude_sessions.py`, `claude_subagents.py`, `claude_background.py`,
  `stop_failures.py`, `codex_sessions.py` or `codex_threads.py`, and `daemon/aitermd/agents/` holds
  `__init__.py`, `claude.py`, `codex.py`, `pi.py`.
- `rg -n "corroboration=|\.corroboration\b|_corroborate" daemon` returns nothing.
- The daemon suite, the contract suites, the bundle check and plain `scripts/test.sh` are green;
  `daemon/tests/wire/` is unchanged.

## Not in this step

- Placing Claude's hooks by the tab header instead of the pid scan (DM F11) and retiring the Codex
  title: left out of the plan, each needs a live probe first.
- The docs sweep beyond the sentences named in step 11 (9a).
