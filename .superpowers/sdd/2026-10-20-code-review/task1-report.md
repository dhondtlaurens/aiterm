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
