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
