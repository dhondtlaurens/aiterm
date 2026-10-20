# Complete codebase review and refactor

## Intent and constraints

Laurens requests a complete architectural, code-pattern, dead-code, duplication and performance review, followed by substantive refactoring. Work stays on `chore/code-review-and-refactor`, forked from `feat/orchestration` at `bb5fafd`. Do not push, merge, publish, or change the main checkout. Build and test only through `scripts/swift.sh` and `scripts/test.sh`. Preserve the dark-only UI and the code-defined design system.

## Approach

Review production Swift, Python, hooks and build/release scripts, with tests and documentation as evidence of intended behavior. Select cohesive improvements where ownership, repeated work, stale asynchronous results, malformed input, or unused code can be demonstrated. Preserve working feature boundaries and external protocols. Existing migrations and recovery behavior are not dead merely because their trigger is rare.

Alternatives considered: a wholesale rewrite would increase regression risk and discard already sound boundaries; cosmetic cleanup alone would not address lifecycle and performance problems. Choose evidence-driven refactoring across independently testable subsystems, with characterization tests for unchanged behavior and failing regression tests for bugs.

## Workstreams

1. Daemon and hooks: asynchronous read identity, cache retention and retry, malformed session metadata, bounded reconnect arithmetic, repeated lookups, and connection ownership.
2. Swift application/core: lifecycle ownership of review polling, latest-result semantics, repeated scheduler indexing, duplicated repository parsing where semantics match, and proven unreachable helpers.
3. UI/tooling: cache identity, native text-field coordination, shared test utilities, and validation scripts respecting supported configuration.
4. Cross-cutting verification: full baseline and final suites, independent review of resulting changes, documented coverage and residual limits.

## Success criteria

Every production source area is accounted for in the audit record. Each accepted finding has a concrete implementation and verification record; rejected or deferred candidates have reasons. Existing automated suites pass, no known introduced regression remains, changes are committed in coherent units, and all autonomous product/process decisions are recorded. Automated review cannot prove absence of every dead path or establish real-world latency without a live workload; report those limits accurately.

## Decisions made for Laurens

- Treat this as architectural work, with a written spec/plan. Approve both autonomously as explicitly requested; no interactive gates.
- Preserve existing behavior, data formats, wire protocol, visual design and feature set except for demonstrated defects. Cost if wrong: a desired redesign remains future work.
- Use parallel read-only audit domains, then subsystem-sized implementation tasks and independent review. Cost if wrong: cross-domain issues require final integration review.
- Prefer evidence-driven changes over wholesale rewrites or generalized frameworks. Cost if wrong: some broader simplification opportunities remain.
- Existing tests may characterize pure refactors and removals; behavioral fixes require demonstrated failing regressions. Cost if wrong: characterization can preserve an undiscovered bug.
- Keep the branch and worktree at completion, with no remote or live-service writes. This follows the explicit request.
