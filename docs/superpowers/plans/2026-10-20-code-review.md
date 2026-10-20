# Codebase review implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Resolve evidenced lifecycle, performance, duplication and dead-code findings across the codebase.
**Architecture:** Keep established component boundaries; consolidate repeated mechanics and make asynchronous ownership explicit. Independent subsystem tasks may run concurrently with disjoint file ownership; Swift test runs are serialized.
**Tech Stack:** Swift 6.4/macOS 26, Python 3.11+, AppKit/SwiftUI, asyncio.
**Spec:** `docs/superpowers/specs/2026-10-20-code-review-design.md`

## Global constraints

Stay in this worktree. No push, merge, publishing or live-service mutation. Use only scripts/swift.sh and scripts/test.sh for builds/tests. Preserve wire/data contracts and visual design. Regression tests must fail before behavioral fixes; pure consolidation uses existing characterization coverage. Commit coherent increments and record autonomous decisions.

## Review focus

- An old asynchronous result must not change a replacement conversation, stopped watcher, or acknowledged wake.
- Malformed or temporarily unreadable telemetry must neither crash polling nor poison caches indefinitely.
- Shutdown must own pending HTTP work; cancellation cleanup must remain bounded without busy loops.
- Shared UI machinery must preserve secure entry, focus, selection and undo/redo bindings.
- Test tooling must honor documented interpreter overrides and reject empty successful test runs.

### Task 1: Daemon lifecycle and parsing
**Files:** `daemon/aitermd/{service,claude_tokens,claude_sessions,hook_events,models,connection,sessions,resolver,hook_router,hooks_server,codex_sessions}.py`, corresponding tests; new internal JSONL helper only if extraction preserves reader semantics.
**Interfaces:** Preserve RPC and hook schemas, ItermPort, SessionRegistry public behavior. No Swift changes.
- [x] Record audit evidence and a focused task design before implementation.
- [x] Add regressions for stale Codex thread reads, unreadable transcript retry, no-owner cache release, invalid metadata shapes, long auth failure streak and HTTP shutdown.
- [x] Run `scripts/test.sh daemon`; confirm new regressions fail for the diagnosed reasons.
- [x] Fix ownership/parsing at their boundaries; replace repeated ranking/scanning with indexed or reused results. Share incremental reading mechanics where semantics agree; do not unify differing shim lifetimes.
- [x] Run `scripts/test.sh daemon` to green, inspect diff, commit coherent increments.
- [x] Report exact commands, counts, decisions and any residual findings for independent review.

### Task 2: Swift lifecycle, scheduling and dead code
**Files:** `app/Sources/AiTerm/ReviewThreadsWatcher.swift`, `Operators/OperatorWaker.swift`; `app/Sources/AiTermCore/{Fix/AgentProcess.swift,Operators/RunScheduler.swift,Sidebar/SidebarModel.swift,Daemon/JSONValue.swift}` and corresponding tests. Other core findings require evidence and a recorded task-design addition.
**Interfaces:** Preserve watcher accessors, operator delivery semantics, scheduler results and process cancellation result types. No UI primitive or script edits.
- [x] Record detailed audit and chosen implementation design.
- [x] Add gated regressions for overlapping watcher reads/stop, acknowledgment during operator delivery, and cancelled process cleanup.
- [x] Run filtered tests with `scripts/test.sh swift -- --filter ...`; confirm diagnosed failures.
- [x] Give reads and wake deliveries explicit generation ownership; prevent cancelled sleeps from spinning; build scheduler indexes once per pass; delete helpers only after source/test reference checks.
- [x] Run affected Swift tests, commit coherent increments, report validation and decisions.

### Task 3: UI and tooling consolidation
**Files:** `app/Sources/AiTermUI/{Input,SearchField,Logos}.swift`, UI test files and shared test support; `scripts/{test,test-swift-toolchain,test-app-bundle}.sh`, `scripts/README.md`.
**Interfaces:** Keep public UI initializers/appearance. Shared editing behavior must cover both Input and SearchField without obscuring secure-field differences. Tool wrappers retain CLI compatibility.
- [x] Record focused design and audit coverage.
- [x] Add SearchField undo-binding and logo winding identity regressions, verify failure through scripts/test.sh.
- [x] Extract shared field synchronization and correct image identity; remove demonstrated duplicated utilities without broad test churn.
- [x] Make toolchain/interpreter validation respect configured executables; remove dead exact-count argument and reject zero tests with a fixture-based guard test.
- [x] Read dependency pins from pyproject for bundle checks and compare bundled hook resources; update inaccurate tooling documentation.
- [x] Run affected tests, commit coherent increments, report decisions and validation. Design-system sync stays local under user's no-publish constraint.

### Task 4: Integration, review and handoff
**Files:** audit record under `docs/superpowers/`, this plan and ledger.
- [x] Account for every production source area in audit coverage; distinguish inspected code from tests only inventoried.
- [x] Run `scripts/test.sh all` and release build via `scripts/swift.sh build --package-path app -c release`; inspect output.
- [x] Independent whole-branch review against `bb5fafd`, resolve material findings with focused regression tests and rerun affected suites.
- [x] Use finishing-a-development-branch, choose already-authorized keep-as-is, commit audit results and leave a clean worktree.

## Autonomous process decisions

Approve this plan without waiting, as requested. Use three disjoint implementation lanes with independent review after integration; avoid concurrent Swift builds. Keep audit artifacts tracked despite the repository's ignored docs/superpowers default so decisions remain reviewable in commits. Cost: additional documentation in branch history. No new dependencies or external research are needed to diagnose the local behavior; consult primary documentation only if an API question cannot be resolved from source/tests.

### Task 5: Findings from the remaining-flow audit

**Files:** `app/Sources/AiTerm/Operators/OperatorToolHandler{,+Review,+Jira}.swift`, related operator/Jira state if migration tracking is needed; `app/Sources/AiTermCore/GitLab/GitLabClient.swift`; corresponding operator Jira/review, GitLab payload and creation-model tests.
**Interfaces:** Preserve tool result schemas and saved-state decoding. New Jira idempotency identity must distinguish raw keys and runs; preserve or explicitly refuse ambiguous legacy pending recovery rather than silently linking another ticket. Review assignment must serialize the host's read/replace mutation per published request. Existing fork-review refusal must cover GitLab source/target project differences.
- [x] Verify concurrent request_review calls can interleave through the real tool dispatch; add gated regression showing reviewers lost in host/local state. Add per-request ownership for the full host mutation and re-read local state at commit.
- [x] Reproduce Jira label collision (`a/b` vs `a_b`) after ambiguous create failure/retry. Choose collision-resistant labels and record compatibility strategy before implementation; add pending-state upgrade/recovery tests. Do not duplicate tickets or silently reuse an unrelated key's ticket.
- [x] Reproduce GitLab fork payload with different source_project_id/target_project_id accepted as an origin branch. Populate existing fork metadata/refusal signal, preserving nonfork behavior and existing view behavior.
- [x] Run failing focused tests through scripts/test.sh swift, implement smallest cohesive changes, verify affected suites and commit.
- [x] Independent review and final full integration verification follow this additional task.

Ruling: extend implementation with these confirmed remaining-flow findings — they can lose reviewer assignments, attach the wrong Jira ticket, or select the wrong code for review — cost: additional internal identity/serialization logic and tests. No live host writes are needed; all regressions use existing fake clients.

## Completion

Reviewed code/test HEAD: `42570ce`. Full suite: Python 1,130 passed / 1 live test skipped; mypy 66 files and ruff clean; Swift 3,021 passed. Release build passed. Independent whole-branch review approved with no unresolved findings. The first integrated run's existing tight cancellation timing assertion was replaced with a mutation-verified completion check. Details and all autonomous decisions are in `docs/superpowers/reviews/2026-10-20-codebase-audit.md`. Keep the branch/worktree locally; no push or merge.
