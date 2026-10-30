# Correctness: one GitHub check table, one timestamp parser

## Goal

A /simplify review found two places where AiTerm reads the same input two ways.

1. `GitHubClient.mergeReadiness` (merge gating) and `GitHubClient.mergeRequestState` (`pipeline` in `run_status`
   and `read_task`) each classify a pull's check runs and statuses with their own table, and disagree on neutral,
   skipped, stale and unknown conclusions.
2. The daemon's ISO timestamp readers disagree on a timestamp with no zone: `claude_subagents.py` and
   `slash_commands.py` read it as local time, `codex_sessions.py` as UTC.

## Approach

**Checks.** One private classifier, `checkSummary(runs:statuses:)`, returns `.failed(why)`, `.running` or `.green`;
failed wins over running, running over green. Both methods derive from it: readiness maps failed → `.blocked(why)`,
running → `.waiting("its checks are running")`, green → the `mergeable_state` switch as now; the pipeline word is
`failure` / `pending` / `success`, and stays nil when a list was not read to its end or there are no checks at all.

Decided with Laurens (2026-10-30), following GitHub's own branch-protection rule ("required status checks must have a
`successful`, `skipped`, or `neutral` status"):

| Check run | Summary |
|---|---|
| not completed | running |
| success, neutral, skipped | green |
| failure, timed_out, startup_failure | failed: "its check X failed" |
| cancelled | failed: "its check X was cancelled" |
| action_required | failed: "its check X needs someone to act" |
| stale (set only by GitHub, the run took too long; it never finishes) | failed: "its check X went stale" |
| any other or no conclusion on a completed run | running (not green) |

| Commit status | Summary |
|---|---|
| success | green |
| failure, error | failed: "its status X failed" |
| anything else | running |

Behaviour changes: merge gating now passes neutral and skipped (skipped was passed only on a draft, so that special
case goes; the draft is still what stops it, so marking a draft ready is unchanged); stale reads "went stale" instead of
"did not pass (stale)". `pipeline` reports stale as `failure` (was `pending`) and an unknown conclusion as `pending`
(was `success`). The 2×30 s ready debounce in `TaskPublisher` still guards checks that register late after a draft is
marked ready.

No frozen Operator golden is touched: `contract.json`, `state.json` and the briefs carry no pipeline (their journeys
script `MergeRequestState` through `FakeMergeHost`), and the tool schemas' prose ("pipelines green", "a failed
pipeline … blocks it") stays true.

**Timestamps.** Every record timestamp in 1,864 Claude Code transcripts (main, subagent, queue-operation) and 1,126
Codex rollouts on this machine is UTC with `Z`; none lacks a zone. Decided: a timestamp with no zone is UTC (both
producers write UTC; a missing zone is a dropped `Z`). One `iso_seconds(value) -> float | None` in
`daemon/aitermd/text.py`: None for a non-string or a malformed value (an aware time never overflows).

## Files

- Modify `app/Sources/AiTermCore/GitHub/GitHubClient.swift`: the classifier, both methods derived from it, doc comments.
- Modify `app/Sources/AiTermCore/CodeHost.swift`: `MergeRequestState.pipeline`'s comment, if its wording no longer fits.
- Modify `app/Tests/AiTermCoreTests/GitHubPublishTests.swift`: neutral/skipped ready, stale failed, unknown pending in
  both readings; one parameterized table drives readiness and pipeline so they cannot drift again.
- Modify `daemon/aitermd/text.py`: `iso_seconds`.
- Modify `daemon/aitermd/claude_subagents.py`, `slash_commands.py`, `codex_sessions.py`: use it; drop the local parsers.
- Modify `daemon/tests/test_text.py` (create if absent), `test_claude_subagents.py`, `test_slash_commands.py`,
  `test_codex_sessions.py`: the rule once, and a record with no zone read as UTC at each site.

## Proof

- `scripts/test.sh swift -- --filter GitHubPublishTests` while iterating; `.venv/bin/pytest -k
  "text or subagent or slash or codex"` from `daemon/`.
- Plain `scripts/test.sh` before each commit; `scripts/test.sh all` once before merging.

## To-dos

- [ ] Checks: classifier, both methods from it, tests; commit.
- [ ] Timestamps: `iso_seconds`, three sites, tests per source; commit.
- [ ] `scripts/test.sh all`, then merge to `main`.
