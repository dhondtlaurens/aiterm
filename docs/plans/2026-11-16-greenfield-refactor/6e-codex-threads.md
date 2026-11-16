# 6e. One owner for Codex thread identity

Implementer: Opus 5.5, high. Depends on: 6d. Findings: DM F5.

## Why

The daemon must know which Codex thread a tab runs: its rollout gives the CLI version that gates
delivery, the context fill and turn boundaries. The rule is incident-driven (0.45.0): a thread is
known only from a hook placed on the tab by evidence, it is valid only for the process that posted
it, and it is kept on the tab's iTerm2 variable `aiterm_codex_thread` (JSON with `pid` and
`thread`) so a helper restart recovers it without a new hook. Today six places share that rule: the
tag is parsed into the registry's `conversation_id`, the resolver rebuilds a binding from that
field, hooks bind through the resolver, the service writes the tag back with its own cache, and the
tick's readers re-check the thread. The end state: one `CodexThreads` owner restores bindings from
the raw tag at each snapshot, binds on hooks, answers `thread(session)`, and writes the tag back
after the tick. Behaviour and the tag's format do not change.

## Today

- `daemon/aitermd/models.py`: `CODEX_THREAD_TAG`. `iterm_bridge.py` reads it with every snapshot
  (`VARIABLES`, `_raw_session` puts it in `RawSession.user_vars`).
- `daemon/aitermd/sessions.py`: `_codex_conversation(raw)` (Codex command, a job pid, a tag whose
  JSON `pid` equals it and whose `thread` is a non-blank string); `_to_info` sets
  `conversation_id` from it; `apply_snapshot` copies an old process field over the new one unless it
  is a `None` `conversation_id`, so a tag-restored value survives.
- `daemon/aitermd/resolver.py`: `CodexBinding(thread_id, pid, pending_generation)`, `_codex`,
  `_generation`; `bind(...)` records the pin, and for Codex, when the post was placed by evidence
  and is not `SubagentStart`/`SubagentStop`, a binding (a `Stop` binds to the current pid; a new
  thread or a `SessionStart` binds pending until the next snapshot, since a replacement process can
  post before iTerm2 reports its pid); `snapshot_applied()` bumps the generation and validates every
  binding; `codex_thread(sid)` rebuilds a binding from a Codex tab's `conversation_id` when it has
  none, drops one for a closed or non-Codex tab or a changed pid, and settles a pending pid;
  `forget(sid)` drops the binding and the tab's pins.
- `daemon/aitermd/hook_router.py`: `_resolve_post` calls `resolver.bind(sid, agent, session_id,
  hook_event, authoritative=sid == direct)`.
- `daemon/aitermd/service.py`: `_after_snapshot` calls `resolver.snapshot_applied()` before
  announcing opened sessions; `_saved_codex_threads` and `_remember_codex_threads` write each
  changed `(pid, thread)` to the tag after the tick's observations; `_forget_session` calls
  `resolver.forget`.
- `daemon/aitermd/corroboration.py`: `CorroboratingReaders.snapshot` collects each Codex session's
  thread through `resolver.codex_thread`; the Codex plan's session key (6d) uses it as its extra.
  `CorroboratingReaders` takes the resolver only for this.
- Tests: `tests/test_resolver.py` (`test_a_codex_thread_waits_for_the_next_snapshot_to_learn_its_process`,
  `test_a_stop_binds_the_thread_to_the_process_it_came_from`, `test_a_codex_child_does_not_replace_its_parents_thread`),
  `tests/test_sessions.py` (`test_a_saved_codex_thread_belongs_only_to_its_process`),
  `tests/test_iterm_bridge.py` (`test_a_snapshot_recovers_the_codex_thread_saved_on_its_process`),
  `tests/test_service.py` (the Codex tests that read `resolver.codex_thread`, about lines 512 to
  580, and `test_codex_rollout_cannot_change_a_replacement_thread`), `tests/test_hook_router.py`
  (`test_resuming_an_older_codex_thread_makes_it_current_for_the_tab`),
  `tests/test_delivery_service.py` (`test_codex_delivery_recovers_its_checked_version_after_helper_restart`,
  the end-to-end proof of restart recovery and of refusing a replacement process).

Grep: `rg -n "codex_thread|CodexBinding|_codex_conversation|_saved_codex_threads|snapshot_applied|CODEX_THREAD_TAG" daemon`.

## Change

1. New module `daemon/aitermd/codex_threads.py` (6f moves it into the Codex module) with
   `CodexThreads`, built with the registry and the iTerm2 port. It owns the binding type, the
   generation, the bindings and the cache of what was last written. Its operations:
   - restore, given the raw sessions of a snapshot just applied: bump the generation; for each Codex
     tab with a job pid and no binding, parse its tag by today's rule and, when it holds, bind that
     thread to that pid (settled, not pending) and count it as already written; when the tab's
     registry `conversation_id` is None, set it to that thread. Then validate every binding as
     `snapshot_applied` and `codex_thread` do today, in the same order. Return the session ids whose
     conversation it set.
   - bind, given a session, a thread and the hook's event name: today's Codex half of
     `SessionResolver.bind`, unchanged.
   - thread, given a session: the bound thread or None, with today's checks.
   - forget, given a session: drop its binding and its written entry.
   - remember, given the tick's sessions: today's `_remember_codex_threads`, each write logged on
     failure on its own.
2. `sessions.py`: delete `_codex_conversation` and its use in `_to_info`; `apply_snapshot` copies
   every process field of the same agent and process, `conversation_id` included, with no
   exception.
3. `resolver.py`: delete `CodexBinding`, `_codex`, `_generation`, `snapshot_applied`,
   `codex_thread` and the Codex half of `bind` and `forget`; `bind` records the pin only (drop its
   `hook_event` and `authoritative` parameters). The module docstring says it places posts.
4. `hook_router.py`: `HookRouter` takes the `CodexThreads`; `_resolve_post` records the pin, then,
   for a Codex post placed by evidence (`sid == direct`), calls its bind.
5. `service.py`: build `CodexThreads` beside the resolver and hand it to the hook router and the
   readers. `_tick` passes the raw snapshot to `_after_snapshot`, which calls restore where it
   called `resolver.snapshot_applied()` (before opened sessions are announced, so their first
   payload carries the conversation) and adds its returned ids to `changed`. After the
   observations, call its remember. `_forget_session` calls its forget. Delete
   `_saved_codex_threads` and `_remember_codex_threads`.
6. `corroboration.py`: `CorroboratingReaders` takes the `CodexThreads` instead of the resolver and
   asks it for each session's thread.

## Keep

- The tag's name and JSON format, read and written as today: the release keeps tags on open tabs.
- `pending_generation`'s rule and "a `Stop` binds to the process it came from": incident-driven
  (0.45.0, `docs/plans/2026-11-13-worker-status-snags.md`).
- `SubagentStart`/`SubagentStop` never bind; a post placed by a pin or by directory never binds.
- The resolver's pins, `_may_run` and directory placement: they rely on the registry's
  `conversation_id`, which a restored Codex tab still gets in step 1.
- `CODEX_THREAD_TAG` in `models.py`: the iTerm2 adapter reads every tag from there.

## Decisions already taken

- A binding restored from its tag counts as already written, so the first tick after a restart
  does not rewrite every Codex tab's tag with the same value. Nothing else changes.
- A Codex tab whose registry conversation was set by a hook keeps it; the tag only fills a None, as
  today's copy rule did.
- A tab another process now runs (a different pid) gets no thread and no conversation from an old
  tag, as today.
- `thread(session)` between snapshots returns what restore and bind left: the registry's pids only
  change at a snapshot, so no check is lost by validating there.

## Tests

- Move `test_a_saved_codex_thread_belongs_only_to_its_process` (its whole table) to a new
  `tests/test_codex_threads.py`, asserting the thread and the registry conversation after restore.
- Move the three Codex tests from `test_resolver.py` to that file, driving bind, restore and
  thread; same expectations. The resolver's pin and pid-scan tests stay where they are.
- Add: restore after a helper restart, with a valid tag, writes no tag on the first remember.
- `test_iterm_bridge.py`: `test_a_snapshot_recovers_the_codex_thread_saved_on_its_process` asserts
  the raw session's `user_vars` carry the tag; the registry no longer parses it (the recovery
  itself is the new restore test and `test_codex_delivery_recovers_its_checked_version_after_helper_restart`).
- `test_service.py` and `test_hook_router.py`: read `codex_threads.thread(sid)` where they read
  `resolver.codex_thread(sid)`; expectations unchanged.
- `test_delivery_service.py` passes unchanged: it is the end-to-end proof.
- No fixtures change.

## Proof

- From `daemon/`: `.venv/bin/pytest -k "codex or resolver or sessions or hook_router or delivery_service or iterm_bridge"`,
  then mypy and ruff as `daemon/README.md` says.
- Plain `scripts/test.sh`.

## Done when

- `rg -n "codex_thread\b|CodexBinding|_codex_conversation|_saved_codex_threads|snapshot_applied" daemon/aitermd`
  returns nothing outside `codex_threads.py`.
- `rg -n "CODEX_THREAD_TAG" daemon/aitermd` shows only `models.py`, `iterm_bridge.py` and
  `codex_threads.py`.
- The daemon suite and plain `scripts/test.sh` are green.

## Not in this step

- Moving `CodexThreads`, the rollout cursor and Codex hook parsing into `aitermd/agents/codex.py`
  (6f).
- Retiring the Codex title as a source: left out of the plan.
