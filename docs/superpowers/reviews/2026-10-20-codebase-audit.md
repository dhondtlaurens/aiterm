# Codebase audit

Base: `bb5fafd` on `chore/code-review-and-refactor`, forked from `feat/orchestration`.

## Coverage and method

Inventory and source-reference scans cover every production Swift/Python source, all hooks, build/release scripts and package definitions. Detailed reads followed state ownership, side-effect boundaries, cache invalidation, parsing, scheduling and view composition. Tests were inventoried across all targets and read in depth around findings; this is not a claim that every test body or every source line received equal scrutiny.

| Area | Starting inventory | Review emphasis |
|---|---:|---|
| AiTermCore | 175 Swift files | process/thread lifecycle, persistence, Git caches, daemon transport, operators, harnesses, host clients, updates, Backpack |
| AiTerm application | 122 Swift files | composition, monitor ownership, creation/removal/archive, operators, 47 view files and 7 snapshot files |
| AiTermUI | 18 Swift files | AppKit bridges, focus/undo, image identity, tokens, primitives |
| Daemon | 26 Python modules | service orchestration, session identity, JSONL caches, status, hooks, RPC/HTTP, iTerm adapter |
| Hooks | 3 files | Claude/Grok shims and PI lifecycle differences |
| Scripts/configuration | all tracked executable scripts, package manifests and GitHub issue templates | pinned toolchain, test completion, packaging resources, interpreter configuration |

Cross-source declaration scans found unused `SidebarModel.dependencyLabel` and `JSONValue.isNull`; framework callbacks were excluded after checking their dispatch mechanism. Exact twelve-line duplicate-block scanning found no cross-file Swift blocks meeting the substantive-code threshold; semantic duplication still exists and was examined separately. No entire daemon module was established as dead. Wire-contract constants, recovery paths, migration logic, framework callbacks and DEBUG snapshot entry points are retained deliberately.

## Architectural assessment

The codebase already has useful boundaries: core state transitions are separate from orchestration, ItermPort separates the adapter from daemon behavior, HTTPJSON centralizes transport policy, creation sheets share their workflow, and per-row observation limits redraws. Replacing these with a generic framework or rewriting every file would increase risk without addressing the observed failures.

The recurring weakness is asynchronous ownership: a result can remain structurally valid yet belong to an earlier conversation, publication, selection, or acknowledgment. Fix those at the owner, and share mechanical implementation only where semantics match. The analogous cache weakness is treating a failed read as a successfully cached absence.

## Baseline

`scripts/test.sh all` passed before production edits:

- Python: 1,110 passed, one live integration test skipped; mypy checked 65 files and ruff passed.
- Swift: 84 UI, 1,173 application and 1,738 core tests passed.
- Three known-issue assertions intentionally exercise test-helper failure recording.

## Decisions and remaining review limits

- Preserve the external wire protocol, saved state, feature set and visuals; change behavior only for demonstrated defects.
- Preserve remote URL parsers with intentionally different acceptance policies. Sharing syntax prematurely could alter repository identity checks.
- Preserve distinct Claude/Grok shim process lifetimes and Swift/Python contract constants.
- Keep persistence flush ordering: converting synchronous durable writes to asynchronous work would change the guarantee that state is saved before external side effects.
- Do not replace small SwiftUI array enumerations, localized AnyView menu content, or hand-expanded State storage without evidence of a problem. The latter is required by this toolchain setup.
- Do not generalize all pollers into one abstraction: selection, retries, shutdown and publication semantics differ.
- Verify performance changes using deterministic work-count/ownership checks and code-path complexity where possible. No live iTerm/account workload benchmark or hardware interaction is authorized or needed for these refactors; no measured end-user speedup is claimed.
- Keep the branch and worktree, with no pushes, merges or publishing.

Subsystem reports and final verification will record implemented findings, exact commands and further decisions.

## Remaining-flow coverage pass

A second source-reading pass covered Core Tasks (creation/workflow/removal, drafts, archive/search, publication/search/thread reading), WorkspaceScan/adoption, every harness driver/service/process/installer/model/settings implementation, hook configuration/TOML preservation, full GitHub/GitLab/Jira clients/settings, application creation/removal/archive/project/terminal flows, WorkspaceStore, creation models, and all six OperatorToolHandler files. This pass confirmed that WorkInFlight tokens, durable-before-side-effect saves, lossless foreign-configuration handling, shared HTTP transport and host-specific client behavior are active mechanisms worth retaining.

It found three further material defects, now covered by Task 5: lossy Jira recovery labels for distinct raw keys; concurrent reviewer assignment using stale state and overlapping host read/replace operations; GitLab MR payload conversion dropping the distinction between source and target project. No additional dead whole subsystem or substantive duplication was established. Existing small collection scans did not justify a new framework.

## Autonomous decision register

The spec and subsystem reports retain the implementation reasoning and regression evidence. This register collects the choices made without waiting for Laurens.

| Decision | Reason and tradeoff |
|---|---|
| Approve the spec, plan, follow-up scope and final keep-as-is workflow autonomously | Explicit user instruction; no push, merge, publication or live account mutation. |
| Use disjoint audit/implementation lanes with independent reviews and serialize Swift verification | Broad coverage without concurrent edits to the same subsystem or shared Swift build directory. Final combined verification remains necessary. |
| Track spec, plan and review reports despite the ignored documentation directory; move worker reports out of scratch | Keep evidence and decisions reviewable in the branch; adds documentation to history. |
| Preserve features, visual design, protocols and saved-state decoding; fix demonstrated behavior defects | Avoid speculative redesign during a code review. No design-system publication is needed because tokens and component appearance are unchanged. |
| Retain established architecture, distinct URL acceptance policies, host clients, poller semantics, hook lifetimes, migrations and durable write ordering | Similar-looking code does not always have the same contract; forced unification would change behavior. No new dependency or generic framework is introduced. |
| Share forward JSONL cursor mechanics, but retain reverse-reader final-line semantics | Consolidate equivalent logic without changing newest-record behavior. Preserve Codex's existing 31-day search window, day handling and 30-second full discovery interval. |
| Cache successful directory listings by directory identity/mtime and prune inactive lineage | Avoid repeated scans while discovering new local files promptly. This depends on normal filesystem metadata updates; network-mount performance is not measured. |
| Keep Python worker gates and daemon-thread filesystem work | Shutdown owns async work but cannot interrupt an already-running filesystem call. Daemon threads cannot prevent process exit. |
| Replace parallel wake bookkeeping with one per-run owner; invalidate stale asynchronous publications at their owner | Centralize lifecycle invariants without generalizing unrelated watchers. Forgotten in-flight delivery keeps only a sentinel to prevent overlap. |
| Fetch the current review-host user on each fresh check | There is no stable credential identity in the interface; correctness costs an extra host request instead of retaining an unsafe project-lifetime cache. |
| Use short-lived archive projections and per-pass scheduler indexes | Reduce repeated work without stale persistent caches. Single-run scheduling intentionally stops leaking another run's task when corrupt state repeats a UUID across runs. |
| Use an independent bounded process-cleanup task and existing cancellation/group characterization | Two attempted CPU tests did not reliably reproduce the spin and were discarded. Avoid a production injection seam solely for a benchmark; no measured CPU reduction is claimed. |
| Keep secure-field construction/caret handling and SearchField command handling separate around shared editing mechanics | Their behavior differs, while binding refresh, focus and undo synchronization agree. Retain a narrow shared-test spelling adapter to avoid unrelated churn. |
| Require positive test counts instead of exact pinned counts; retain the unfiltered expected-host check | Detect empty successful runs while allowing test growth. Respect configured Swift/Python executables and validate exact dependency pins against bundled metadata only. |
| Verify packaging boundaries with controlled fixtures | No assembled signed application or live iTerm session was tested. These checks do not claim to replace real signed-release validation. |
| Extend the plan with Jira identity, reviewer serialization and GitLab fork fixes | The remaining-flow audit demonstrated wrong-ticket recovery, lost assignments and potentially wrong checkout code; these warranted regression-backed fixes. |
| Serialize reviewer writes by published repository/request, then revalidate ownership and merge fresh local state | Multiple task records can refer to the same remote request; per-task locking would not protect GitLab's remote read/replace sequence. |
| Version Jira recovery labels using the complete run UUID and a SHA-256 digest of the NFC-normalized key | Avoid lossy punctuation/run-prefix collisions while matching Swift String canonical equality. New pending markers distinguish the new identity without a state schema change. |
| Preserve completed legacy Jira replays but refuse automatic recovery of legacy pending writes | Old lossy labels cannot safely identify their original key. Keep the pending marker and require manual reconciliation; never silently adopt a match or create another ticket. This deliberately removes unsafe automatic legacy recovery. |
| Search all frozen allowed Jira projects for a pending v2 key and refuse multiple matches | A retry with changed project arguments still refers to the original key. Do not adopt an arbitrary first ticket or evade uncertainty with another key. |
| Represent GitLab fork source identity using the existing fork-refusal signal | Reuse existing protection before checkout, with host-neutral wording and no schema/view redesign. Equal or missing project IDs retain existing behavior. |
| Defer asynchronous external-path prompt completion | The ../, ~/ and absolute-path completion code can synchronously read a slow filesystem on the main actor. Correct conversion requires query/caret ownership, cancellation and loading behavior; a stale cache would compromise freshness. Ordinary project-relative completion is already in memory. This is a documented remaining performance risk, not a claimed fix. |
| Use source references, deterministic work counts and lifecycle regressions rather than claim exhaustive dead-code absence or measured user speedups | Two proven-unused helpers and obsolete archive getters were removed. No workload benchmark or proof of every dormant path is asserted. |

## Subsystem evidence

- [Daemon implementation and review](2026-10-20-daemon-report.md)
- [Swift lifecycle and scheduling](2026-10-20-swift-report.md)
- [UI and tooling](2026-10-20-ui-tooling-report.md)
