# 2e. Daemon readers: one Codex rollout cursor, no quiet window, no fallbacks

Implementer: Codex `gpt-6.1-sol`, high. Depends on: phase 1 (1g removed the Codex reader's
test-only methods, `tests/codex_reference.py`, the `settle_reads` seams, slash-command tracking and
`subagents_written_at`), and 2a to 2d before it in phase 2. Audit: DM F3, F9, F10.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The design note says the cursor "reads the first record once for the version". Today's rule,
written when the version read was added and pinned by
`test_the_cli_version_is_the_newest_the_threads_rollout_names`, is that a later `session_meta` for
the same thread (a resume under a newer Codex) wins. Nobody has verified whether Codex writes one on
resume. The version gates message delivery (`verdict_covers` in `delivery.py`), so reading only line
1 could let a resumed, newer, unchecked Codex keep an older version's pass. Keeping the rule costs
one more marker in the tail follow and no extra read, so this brief keeps it: line 1 on first sight,
and any later `session_meta` for the thread seen while following replaces it.

## Why

The daemon reads each Codex tab's rollout file for three facts: the CLI version (which gates
delivery of Operator messages), the last turn boundary (which recovers a lost Stop hook) and the
context fill. During the 10 Nov refactor the reader was hardened to match the old parser's failure
edges line for line: per-field error isolation, short-read recovery, a head re-read when the tail
lacks a fact, and a separate context cache. Beside it, a 45-minute quiet window releases Claude
subagents that die without a trace (never observed: every watchdog kill leaves an interruption), the
iTerm2 adapter falls back to reading variables one name at a time for an iTerm2 that refuses a batch
(none does), and the Claude pid scan retries when the config root moves mid-scan (only at app
attach). The end state: one cursor per rollout that reads line 1 once and then follows the tail; no
quiet window; one batched variable read; one pid scan attempt. No wire or contract change.

## Today

After phase 1:

- `daemon/aitermd/codex_sessions.py`, `CodexSessionFiles`. Public: `begin_tick`, `retain`,
  `reading(thread) -> CodexReading(context, version, turn)` (about line 181), `rate_limits`.
  Internals that this step collapses: `_LocatedRollout` with `after_cached_miss`, `_RolloutCursor`
  (a `JsonlCursor` with `version`, `latest`, `boundary_seen`, `stamp`, `version_error`,
  `turn_error`, `consume`), `_rollout` (about line 224: 8 MiB tail, short-read and head re-read
  paths), `_previous_version`, `_turn_at`, `_context_at`, `_read_context`, the `_context` dict.
  Kept: `LIST_SECONDS`, `RECENT_KEPT`, `READ_BYTES`, `CODEX_READ`, `_path_for`, `_list_all`,
  `_list_today`, `_newest_rollouts`, `_read_rate_limits`, `_token_counts`, `_mtime`, `_epoch`.
  Callers: `corroboration.py` `CorroboratingReaders.codex` (calls `reading`, then `retain`; applies
  `set_cli_version`, `apply_metadata(context=)`, `apply_codex_rollout`), `service.py`
  `_read_codex_usage` (calls `rate_limits`). Confirm with `rg -n "codex_files\.|CodexSessionFiles" daemon/aitermd`.
- `SessionRegistry.set_cli_version` keeps the last version when given None; `delivery.py` refuses
  a delivery whose `cli_version` the delivery check does not cover.
- `daemon/aitermd/status.py`: `SUBAGENT_QUIET_SECONDS` (about line 26), `_Child.stamp` and
  `quiet_since`, `Turn.deferred_since`, `_defer_done` stamping it, and in `release_dead_subagents`
  (about line 402) the stamp update and the `waited`/`quiet` computation. `TranscriptTail.stamp` in
  `claude_subagents.py` is read only there (`rg -n "\.stamp\b" daemon/aitermd`).
- `daemon/aitermd/iterm_bridge.py`: `_UNBATCHABLE`, `ItermBridge._batched_reads`, and in
  `_read_variables` (about line 702) the refusal and short-answer checks and the one-name-at-a-time
  path. Callers: `session_info`, `snapshot`.
- `daemon/aitermd/resolver.py` `resolve_directly` (about line 62): a `while True` loop that rescans
  when `claude_files.root` changed during the scan. `claude_sessions.py`: `pid_for_session` writes
  its index only `if root == self.root`; `known_pid` and `indexed_pid` filter `path.parent == root`.
  `configure` clears the index when the root changes.

## Change

1. `codex_sessions.py`: one `_RolloutCursor` per rollout path (a `JsonlCursor`) holding `version`,
   `turn` (the last boundary as today: working or done with its time, None after an abort or an
   unstamped boundary) and `context`. `reading(thread)`:
   - finds the path (`_path_for` now returns a `Path` or None; `_LocatedRollout` goes); stats it;
   - with a cursor whose inode matches and whose offset equals the size, returns the cached facts
     without opening the file;
   - without a cursor, or when `rewritten(inode, size)` says the file was replaced or shrank,
     starts a fresh cursor: if the file is larger than `READ_BYTES`, reads its first line with one
     `readline` bounded by `READ_BYTES` and applies it as below (a complete line only), then starts
     at `size - READ_BYTES` and drops the clipped first line there; otherwise starts at 0;
   - reads the new complete lines through `JsonlCursor.read_lines` and, for each line that contains
     one of `"session_meta"`, `"task_started"`, `"task_complete"`, `"turn_aborted"`,
     `"token_count"` as bytes, parses it: a `session_meta` whose payload id is the thread sets the
     version; a boundary sets `turn` as `consume` does today; a `token_count` whose numbers give a
     percent (the rules in `_read_context`) sets `context`, so the last usable count wins;
   - a line that `json.loads` rejects with `ValueError` is skipped and logged once at warning,
     naming the thread; the cursor never reads it again, so it is never logged again;
   - an `OSError` from stat, open or read answers `CodexReading(None, None, None)` for this tick
     and leaves the cursor as it was, so the next tick tries again.
   Delete `_LocatedRollout`, `_rollout`, `_previous_version`, `_turn_at`, `_context_at`,
   `_read_context`, `_context`, `version_error`, `turn_error`, `boundary_seen`, `stamp`. `retain`
   drops cursors for paths no tracked thread uses.
2. `status.py`: delete `SUBAGENT_QUIET_SECONDS`, `_Child.stamp`, `_Child.quiet_since`,
   `Turn.deferred_since` and the quiet branch; `_defer_done` only sets `deferred_done` (inline it if
   that reads better). A child is released by its interruption or `SubagentStop` attachment (the
   `ended_at` rule), by a missing transcript after a `SubagentStop` that came before the read began,
   by the turn's next Stop, a new SessionStart or a pid change, exactly as today. Fix the comments
   that mention the quiet window, including the `monotonic` note in `StatusEngine.__init__`.
   Delete `TranscriptTail.stamp` and its computation in `SubagentTranscripts.read` (the cache keeps
   its own identity tuple).
3. `iterm_bridge.py`: `_read_variables` sends one request for all `VARIABLES` and returns
   `_variable_values(response)`. Delete `_UNBATCHABLE`, `_batched_reads` and the per-name path. A
   refused status still raises `_SessionGone` or `RPCException` through `_variable_values`.
4. `resolver.py`: `resolve_directly` runs one scan attempt under `SCAN_SECONDS`, as now (single
   in flight, `known_pid` while a scan runs, the done-callback logging), without the loop and the
   root comparison. `claude_sessions.py`: `pid_for_session` always stores its index;
   `known_pid` and `indexed_pid` drop the `path.parent == root` filter.
5. Docs: in `docs/status-model.md`, delete the quiet-window bullet in "The tick" section and its
   sentences about the 45 minutes, and rewrite the rollout paragraph ("A Codex rollout grows without
   bound...") to say: each tracked rollout is followed from where the last read stopped; on first
   sight only its first line and its last 8 MiB are read; only lines naming a session start, a turn
   boundary or a token count are parsed; a line that cannot be parsed is skipped.

## Keep

- `READ_BYTES` (8 MiB first-sight cap) and `LIST_SECONDS` discovery, the today-directory lookup and
  the shared tree listing per tick: they bound I/O on a rollout tree that only grows.
- `rate_limits` and the newest-rollouts scan with its `(path, mtime)` cache: account usage comes
  from whichever rollout was written last, not from the tracked threads.
- The thread-id check on `session_meta`: a rollout can carry another thread's record
  (`test_another_threads_session_meta_is_not_its_version`).
- `JsonlCursor.rewritten`: shared with the Claude readers; a replaced or shrunk file reads afresh.
- In `corroboration.py`, `codex`'s per-thread try and the identity recheck in `apply`: a hook can
  land during the off-loop read (DM F6 changes their form, in 6d).
- The interruption, attachment and hand-back rules for subagents (observed 22 Oct), and the
  stood-`SubagentStop` rule with `_asked_at`.
- The pid scan's deadline and single in-flight scan (a dead mount must not hold a hook post), and
  `known_pid` (answers while a scan is still running).
- `iterm_bridge`'s library patches and `_SessionGone` handling: each verified live.

## Decisions already taken

- A rollout's last boundary more than 8 MiB back on first sight is not found: `turn` is None until a
  new boundary is written. Hooks remain the primary source.
- A `session_meta` beyond the first line and outside the first-sight tail is not seen; line 1 gives
  the creator's version.
- A same-size rewrite of a rollout with the same inode is not detected. Codex only appends.
- A short read needs no handling: `read_lines` advances by what it read and keeps a partial line.
- `json.loads` raising anything but `ValueError` on a rollout line cannot happen in practice; such an
  error reaches `corroboration.codex`'s per-thread `except`, as any bug would.
- A rollout found only through today's directory in the same tick now reports its context in that
  tick too.
- A Claude child that dies without any trace now keeps its row working until the parent's next
  Stop, a new session or the process ending. Accepted (never observed).
- An iTerm2 that answers a batched read with fewer values than names raises in `_raw_session`; the
  snapshot fails as for any refusal. No supported iTerm2 does this.
- A scan of the old root that finishes after the app moved the root may store old-root entries.
  Their pids still name live processes; harmless. The root moves only at app attach.

## Tests

- `test_codex_sessions.py` (as 1g left it, calling `reading`): keep and pass unchanged the context
  tests (latest valid count, unusable and non-finite numbers, overflow clamp, token-count skipping
  without parsing every line, a line mentioning `token_count`), every rate-limit and listing test,
  the version tests (newest `session_meta`, another thread's meta, half-written meta, rewritten
  rollout), the turn tests (completion then start, plain text, unstamped later boundary),
  `test_unreadable_rollout_is_retried_without_a_file_change`,
  `test_one_thread_read_looks_up_its_path_once`,
  `test_a_failed_combined_cursor_read_retries_without_a_file_change`,
  `test_a_version_stat_failure_after_the_path_check_returns_no_version`, and
  `test_matching_lines_are_found_whichever_block_they_straddle` (rate limits still read backwards).
- Adjust: `test_context_is_not_reparsed_until_its_rollout_changes` counts opens of the rollout
  instead of `_lines_reverse` calls (one open, none while unchanged, one after an append);
  `test_large_rollout_first_sight_read_budget` expects, for both shapes, the version and
  `("done", 101.0)`, at most two opens, and at most `READ_BYTES` bytes returned by `read` (the first line
  comes through `readline`);
  `test_a_rollout_created_after_the_tick_listing_matches_the_reference` expects context 50 on the
  first reading too (rename it without "reference").
- Delete (behaviour deleted): `test_rollout_cursor_detects_a_same_size_same_date_rewrite`,
  `test_a_short_rollout_read_is_retried_without_a_stamp_change`,
  `test_a_short_rollout_read_keeps_the_last_complete_boundary`,
  `test_a_failed_context_does_not_discard_the_other_corroboration`, and any test 1g left that pins
  per-field error isolation, head re-reading or a parser `RecursionError`.
- Add, test first: "an unparsable line is skipped and logged once, and the facts before and after
  it still read" (a broken complete line between a version and a later boundary; two readings, one
  warning record).
- `test_status.py`: delete `test_a_quiet_child_past_the_window_releases_it`,
  `test_a_childs_quiet_counts_from_the_stop_that_leaves_the_turn_waiting_on_it`,
  `test_the_quiet_window_ignores_the_wall_clock`, `test_a_child_still_being_written_keeps_the_row_working`
  (behaviour deleted). `test_a_quiet_child_of_a_turn_under_way_is_left_to_the_turns_stop` keeps its
  first half and loses the stopped-then-quiet half. `test_a_missing_transcript_keeps_it_working`
  advances the clock by a plain hour. `_tail` loses its `stamp`; fix `_claude_engine`'s docstring.
  `test_claude_subagents.py` drops its `tail.stamp` assertion.
- `test_iterm_bridge.py`: delete `test_an_iterm_that_refuses_a_batched_read_is_read_a_name_at_a_time`
  and `test_a_batched_answer_short_of_a_value_is_read_a_name_at_a_time` (behaviour deleted); remove
  the `multi_get_refusal` and `unset_omitted` parameters from `_variables_bridge`.
  `test_only_a_session_iterm_no_longer_has_is_left_out` and `test_session_info_reads_one_session_where_it_is`
  stay unchanged.
- `test_service.py::test_closed_sessions_leave_nothing_behind`: replace `_context` with the cursor
  map's new name.
- No fixture changes. Never edit `daemon/tests/fixtures/compat/`.

## Proof

- From `daemon/`: `.venv/bin/pytest tests/test_codex_sessions.py tests/test_compat_captures.py tests/test_status.py tests/test_claude_subagents.py tests/test_iterm_bridge.py tests/test_resolver.py tests/test_claude_sessions.py tests/test_service.py tests/test_delivery_service.py tests/test_tick_budgets.py`.
- The compat captures are the proof for the cursor:
  `test_compat_captures.py::test_codex_rollout_gives_version_context_turn_and_rate_limits` must
  pass with the captured 0.167.0 rollouts, unchanged. `test_tick_budgets.py` must pass with its
  ceilings unchanged (a steady tick opens no rollout).
- Then plain `scripts/test.sh`, started in the background.

## Done when

- `rg -n "version_error|turn_error|_previous_version|_turn_at|_context_at|_read_context|_LocatedRollout|after_cached_miss" daemon` returns nothing.
- `rg -n "SUBAGENT_QUIET|quiet_since|deferred_since|_batched_reads|_UNBATCHABLE|MULTI_GET" daemon docs/status-model.md` returns nothing.
- `rg -n "root == self|path\.parent == (self\.)?root" daemon/aitermd` returns nothing.
- The suites above and plain `scripts/test.sh` are green; `docs/status-model.md` updated.

## Not in this step

- Codex thread identity in one owner: 6e. One session key for readings: 6d.
- Regrouping readers by agent and the engine's agent-specific entry points: 6f.
- The root guard in `corroboration.py`'s Claude plan (`files.root != root`): not in this step.
- Placing Claude hooks by tab header instead of the pid scan: left out of the plan.
