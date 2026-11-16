# 6d. Readings carry one session key

Implementer: Codex `gpt-6.1-sol`, high. Depends on: 1g (slash reader gone), 2e (one rollout cursor), 6a. Findings: DM F6.

## Why

Each tick, the daemon captures a request per session on the event loop, reads files off the loop
for up to a second, and applies the result on the loop. A hook can land during that second (hooks
arrive every few seconds), so a reading must apply only to the process and conversation it was
taken for. Each reader grew its own check for that rule: a tuple compared field by field, an object
identity, a generation counter salting dictionary keys, a whole-registry comparison.
`Turn.generation` exists only to salt the background reader's keys, which already check the turn's
`work_since`. The end state: every per-session read plan captures one session key per session (its
agent, process id and conversation, plus the reader's own extra fields), and `Service.observe`
drops, generically, the readings of sessions whose key changed. The per-reader checks and
`Turn.generation` go. The guard itself stays: it is real.

## Today

`daemon/aitermd/corroboration.py` (after 1g and 2e): `ReadPlan(name, read, nothing, apply)`; each
`apply` re-checks identity itself:

- `CorroboratingReaders.claude`: captures `(agent, job_pid, conversation_id, agent_cwd)` per Claude
  session and the files' `root`; `apply` skips a session whose tuple changed, and skips everything if
  `files.root` moved.
- `codex`: captures sid to thread; `apply` skips a session whose `resolver.codex_thread(sid)` is no
  longer that thread. The reading is keyed by thread.
- `background` (the Claude shell reader): captures `(agent, pid, conversation, transcript, turn)`;
  the request and recovery keys are `f"{sid}:{owner.generation}"`; `apply` skips a session whose
  tuple changed, whose turn object is not the captured one, or whose `work_since` moved.
- `stops`: captures `(stopped_on, transcript)`; `apply` skips a session whose `stopped_on` is not
  the same object or whose transcript moved. The reading is keyed by transcript path.
- `tests`: captures copies of every session; `TestActivityReader.apply`
  (`daemon/aitermd/test_activity.py`) returns nothing when the session count differs, a session is
  missing, or any session's `(agent, job_pid, conversation_id, agent_cwd, cwd)` changed.
- `subagents`: keyed by transcript path; the engine matches children itself; no identity check.

`daemon/aitermd/status.py`: `Turn.generation`, `StatusEngine._generation`, set in `_turn()`.
`daemon/aitermd/claude_background.py`: `BackgroundTranscripts.read_all(requests, recoveries)`
caches one cursor per request key. `daemon/aitermd/service.py`: `Service.observe(plan)` runs
`plan.read` through `run_check`, then `plan.apply`; `observe_background` and `observe_codex` wrap it.

Tests that pin the guard: `tests/test_service.py`
`test_background_read_cannot_attach_to_replaced_identity` (process, conversation, generation,
closed), `test_a_hook_cwd_change_during_a_claude_file_read_is_not_overwritten`,
`test_a_codex_permission_hook_during_a_claude_file_read_survives_the_snapshot_title`,
`test_codex_rollout_cannot_change_a_replacement_thread`; `tests/test_stop_failures.py`
`test_a_recovery_read_overtaken_by_new_evidence_cannot_clear_the_stop`; `tests/test_test_activity.py`.

Grep: `rg -n "generation|identities|is not owner|is not stopped_on|len\(sessions\) != len" daemon/aitermd/corroboration.py daemon/aitermd/status.py daemon/aitermd/test_activity.py`.

## Change

1. `corroboration.py`: add a frozen `SessionKey` holding a session's agent, process id,
   conversation id and a tuple of the reader's extra values, built from a session plus those
   extras.
2. `ReadPlan` gains the captured keys (session id to `SessionKey`), a function that computes a
   session's current key with the same extras, and a `whole` flag. A per-session plan's `read`
   returns a dict from session id to that session's reading; its `apply` receives only the entries
   still current. A whole plan's reading is applied only when the set of live sessions equals the
   captured set and every key is unchanged. A plan without keys (the subagent transcripts) is
   applied as read.
3. `Service.observe`: after the read, look up each captured session in the registry; drop the
   entries of sessions that closed or whose key changed (for a whole plan, drop the reading), then
   call `apply`. This is the only place the rule lives.
4. Each reader keeps only its own extras: the Claude file reader `agent_cwd` (a hook's newer
   directory must not be overwritten; keep its `root` check as is); the Codex reader the thread the
   session runs (re-key its reading by session id: read each distinct thread once and hand each
   session its thread's reading); the shell reader the transcript path and the turn's `work_since`
   (requests and recoveries keyed by session id); the stop reader the transcript path and the
   `at` of the captured `stopped_on` (a new StopFailure with the same error has a new `at`; re-key
   its reading by session id); the test-activity reader `agent_cwd` and `cwd`, as a whole plan.
5. Delete each `apply`'s own identity comparison, the `is not owner` and `is not stopped_on`
   checks, and the count and tuple checks at the top of `TestActivityReader.apply`.
6. `status.py`: delete `Turn.generation`, `StatusEngine._generation` and their use in `_turn()`.
   `BackgroundTranscripts` keys its cursors by session id; a changed `since` (a new `work_since`)
   already starts a new cursor.

## Keep

- Capture on the loop, read off the loop under `run_check`'s deadline, apply on the loop; the fixed
  order of the tick's observations (hooks arriving during a read supersede what that reader
  captured).
- The Claude file reader's `root` check (the app can name another Claude folder at attach) and its
  rule that a file no newer than the last hook says nothing (that is the engine's, not identity).
- `StatusEngine.apply_claude_progress`'s own `at <= max(stopped_on.at, hook_at)` rule and
  `release_dead_subagents`' `_asked_at` rule: they are freshness, not identity.
- The subagent transcript plan unkeyed: children are matched by transcript in the engine.
- `TestActivityReader`'s own retention state (`_results`, `_identity`, `_replaced_at`): it decides
  what a replaced session may still show, which is not the read guard.

## Decisions already taken

- `work_since` replaces the turn's object identity and generation: every way a turn is replaced
  either changes the process id or conversation (in the key) or sets a new `work_since` (a
  SessionStart sets the clock; a reset turn has None until one).
- A session with no turn at capture and a fresh turn at apply has the same key; it gets the shell
  reading for an unrequested session (none), which marks shells unavailable, exactly what the next
  tick does anyway.
- Two tabs running one Codex thread cannot really happen; reading each thread once is still kept.
- No change to what any reader reads, how often, or what it applies.

## Tests

- `test_background_read_cannot_attach_to_replaced_identity`: build its reading keyed by session id;
  keep all four cases (process, conversation, a SessionStart during the read, closed).
- `test_codex_rollout_cannot_change_a_replacement_thread`: its stand-in reading is keyed by session
  id; same expectation.
- `test_a_recovery_read_overtaken_by_new_evidence_cannot_clear_the_stop`: go through
  `Service.observe` with a `run_check` stand-in that makes the change during the read (as the
  background test does), since `apply` no longer checks; keep both cases.
- Add: one per-session plan with two sessions, one replaced during the read, applies the other's
  reading and drops the replaced one's.
- Add: the test-activity reading is dropped when a session opens, closes or moves its directory
  during the read, and applied otherwise.
- `test_tick_budgets.py` must pass unchanged (the steady-tick ceilings stay).
- No fixtures change.

## Proof

- From `daemon/`: `.venv/bin/pytest -k "service or status or test_activity or stop_failures or claude_background or tick_budgets"`,
  then `.venv/bin/mypy aitermd tests tools` and `.venv/bin/ruff check aitermd tests tools`.
- Plain `scripts/test.sh`.

## Done when

- `rg -n "generation" daemon/aitermd/status.py daemon/aitermd/corroboration.py daemon/aitermd/claude_background.py`
  returns nothing.
- `rg -n "is not owner|is not stopped_on|identities" daemon/aitermd` returns nothing.
- Identity is compared in one place, `Service.observe`; the daemon suite is green.

## Not in this step

- Who owns Codex thread identity (6e); the Codex reader asks it from then on.
- Moving the readers into per-agent modules (6f).
