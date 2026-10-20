# Task 1: daemon lifecycle and parsing

## Focused design, recorded before implementation

Preserve RPC/hook shapes, supervisor retry progression and each shim's lifetime. Apply Codex worker results only while the resolver still identifies the same thread; prune Claude cache through its existing worker gate even after the last transcript disappears. Treat failed/short transcript reads as retryable, rather than caching success. Reject malformed metadata at parser boundaries and bound authentication backoff arithmetic before exponentiation.

Own every accepted hook connection synchronously at acceptance, close its writer and cancel/await its request task on stop. Stop listening first, then drain owned tasks. Retain the existing response-before-delivery contract for ordinary hook posts.

For pure refactors, reuse direct resolution within a hook, rank registry sessions with one index, and consolidate incremental JSONL byte cursors only if existing partial-line/inode/reset semantics agree. Review Codex descendant discovery for repeated scans and unbounded lineage; preserve immediate discovery of newly created children.

## Audit evidence

- `service._apply_codex_rollouts` awaits a worker then writes version/context/tokens without checking the resolver; Claude already checks transcript identity.
- `_apply_claude_tallies` exits before `retain` when no transcript remains.
- `ClaudeTranscriptTallies._read` swallows OSError, yet tally records the successful-looking stamp forever.
- `ClaudeSessionFiles._parse` calls `.get` on any valid JSON; `_claude_running_subagents` hashes arbitrary task types; frame validation calls `isfinite` on huge integers.
- `_retry_delay` calculates an unbounded floating exponent before capping.
- `HookServer.stop` closes its listener only; accepted sockets and delivery/route handlers outlive it.
- HookRouter resolves a Claude session twice per placed hook. Registry ranking repeatedly searches a list.
- Codex tally rescans overlapping day directories per parent, walks lineage repeatedly, and retains lineage forever.

## Decisions and validation

Pending implementation and test results.

### Increment 1: lifecycle and malformed input

Nine new regressions failed before fixes: unreadable transcript retry, non-object Claude metadata, huge frame coordinate, unhashable background-task type, 2,000 auth failures, stale Codex read after replacement, final Claude owner release, incomplete HTTP request shutdown and active HTTP delivery cancellation. Command: `PYTEST_ADDOPTS='-k "unreadable_transcript_is_retried or non_object_session or too_large_for_a_coordinate or unhashable_task_type or thousands_of_failures or cannot_change_a_replacement_thread or last_claude_transcript_owner or stop_closes_an_incomplete_request or stop_cancels_an_active_hook_delivery"' scripts/test.sh daemon`: **9 failed, 1111 deselected**. HTTP stop originally hung because Python 3.12+ `Server.wait_closed` waits for accepted transports; bounded regression timeouts exposed that ordering defect.

After fixes, `scripts/test.sh daemon`: **1119 passed, 1 skipped in 16.78s**, mypy **65 source files clean**, ruff **all checks passed**. HTTP shutdown may produce EOF or TCP reset for an incomplete request; both mean the socket is closed. Hooks are registered synchronously before their request coroutine starts so stop also owns accepted-but-not-yet-started work.

### Increment 2: retryable telemetry and shared read/index mechanics

Expanded the same unreadable-file finding to Claude session metadata and Codex context, totals and rate limits. These four tests failed with stale cached `None` before fixes. Two performance/retention regressions demonstrated repeated day-directory listings (two scans for two parents) and orphaned Codex lineage. The scan test first needed a Python 3.14 pathlib keyword-compatible wrapper; rerun then failed for the intended **2 versus 1 scans** assertion.

A shared `JsonlCursor` now owns offset/inode/partial-line mechanics for Claude token replies and Codex version metadata. Record interpretation stays with the callers, and Codex reverse token-count reading stays separate. Existing partial-line, rewrite, deduplication, resume-version and read-cache tests characterize the extraction. Failed reverse reads now propagate internally to cache boundaries so unchanged files are retried. Malformed JSON remains cacheable until the source changes; transient I/O failure does not.

Codex child discovery shares directory listings by inode/mtime, so new files invalidate a listing immediately. Descendant traversal builds an adjacency index once and visits reachable entries without repeated whole-list scans. Retain removes directory and lineage entries outside tracked parents' existing 31-day search windows. A hook now carries direct-placement evidence from its first resolution into conversation-reset decisions; it no longer scans Claude session files twice. Registry first-seen ranking builds one index.

Verification command: `scripts/test.sh daemon`: **1125 passed, 1 skipped in 17.27s**, mypy **66 source files clean**, ruff **all checks passed**. The deliberately different Claude fire-and-forget and Grok waited statusline shim lifetimes were inspected and preserved.

### Increment 3: bounded shutdown and shared tick ownership

A real client leaving an 8 MiB operator response unread demonstrated that `writer.close()` alone could keep `Server.wait_closed()` waiting for buffered output. `PYTEST_ADDOPTS='-k "stop_is_bounded_when_a_client"' scripts/test.sh daemon` failed with the expected shutdown timeout. Shutdown now aborts owned transports after closing them, before waiting for request tasks/listener closure. Full suite afterward: **1126 passed, 1 skipped in 16.58s**, mypy **66 source files clean**, ruff **all checks passed**.

Final lifecycle tracing found another owned task behind HTTP delivery: unplaced hooks shield a shared retry tick from per-request cancellation. `PYTEST_ADDOPTS='-k "service_stop_drains_the_shared_tick or cancelling_a_hook_wait"' scripts/test.sh daemon` produced **1 failed, 1 passed, 1127 deselected**: stopping the service left the shared tick running, while the characterization confirmed ordinary request cancellation must preserve it. HookRouter now tracks both pending and running retry ticks and cancels/drains them when Service stops. Service stops accepting/delivering hooks and drains shared ticks before closing iTerm2; per-request shield semantics remain intact.

Final command `scripts/test.sh daemon`: **1128 passed, 1 skipped in 16.59s**, mypy **66 source files clean**, ruff **all checks passed**. `git diff --check -- daemon hooks` is clean. An unrelated concurrent Swift EOF whitespace finding was passed to the parent rather than edited across ownership boundaries.

## Audit coverage and retained limits

All task production modules were read: `service`, `claude_tokens`, `claude_sessions`, `hook_events`, `models`, `connection`, `sessions`, `resolver`, `hook_router`, `hooks_server`, `codex_sessions`, and the new `jsonl` helper. Supporting modules read for ownership/contracts: `claude_subagents`, `protocol`, `rpc_params`, `publisher`, `offload`, and `usage`. All three hook resources were read (`claude-statusline-shim.sh`, `grok-statusline-shim.sh`, `pi-aiterm-status.ts`). Broader daemon modules outside this task's production list remain covered by the parent codebase audit; this report does not claim a second complete review of those files.

Tests: manually read complete token/session parser, Codex rollout, model and resolver test modules; examined relevant portions of service, HTTP, connection, router and registry tests plus shared conftest/fake interfaces. Other daemon tests were inventoried/executed by the full suite, not all manually reviewed line by line. The one skipped test is the opt-in live iTerm integration test; no live-service action was performed.

Decisions/deferred candidates:

- Keep Codex reverse token-count reader separate from the forward complete-line cursor: reverse lookup intentionally supports newest records and different final-line semantics. Only equivalent offset/inode/partial-line mechanics were shared.
- Preserve the existing 31-day Codex descendant search window, local/UTC day handling, and 30-second full-tree discovery interval. Changing those product/performance tradeoffs was unnecessary for the evidenced repeated scans and retained lineage fixes.
- Keep independently installed shell shims with their established lifetime differences. An extraction would introduce a shared deployment dependency for a very small amount of shell code.
- Keep existing worker gates and detached-thread semantics; shutdown cannot interrupt filesystem calls inside Python threads, but those threads are daemon threads and cannot hold process exit open. No second cache reader races a still-running worker.
- Directory listing reuse depends on filesystem directory inode/mtime changing when entries change, as normal local macOS filesystems do. New-child regression confirms immediate refresh on the tested filesystem; no live network-mount benchmark was attempted.
- No known confirmed task finding remains deferred after the shared-tick fix. Public wire formats, harness behavior, ItermPort and SessionRegistry interfaces remain unchanged.

## Commit record

- `eee310a` — lifecycle ownership, malformed input and retry regression fixes.
- `1c9d774` — shared incremental reads, retryable telemetry boundaries, hook placement evidence and indexed descendant/ranking lookups.
- Final bounded-transport/shared-tick ownership commit is supplied in the implementation handoff (a commit cannot contain its own resulting SHA).
