# Testing

Run checks through `scripts/test.sh`; it pins Swift 6.4 and admits one run at a time across all
worktrees. Start a long run in the background with its output redirected, then follow that run's
log. Do not bypass the queue or start a competing Swift build against sources being edited.

```sh
scripts/test.sh                                      # affected checks before a commit
scripts/test.sh all                                  # full gate before merging to main
scripts/test.sh daemon                               # pytest, mypy and ruff
scripts/test.sh swift -- --filter TaskWorkflowTests   # one Swift suite
scripts/test.sh swift -- --filter OperatorCurrentContractTests -j 2
```

Arguments after `--` go to Swift Package Manager; `-j 2` limits compiler jobs on a busy machine.
Swift Testing case parallelism defaults to four through
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`; an explicit value overrides it. This bounds
main-actor fixture contention without widening product timeouts. It is independent of compiler jobs.

The default changed gate considers branch commits, staged/unstaged changes and untracked files
since `main`. `scripts/test-routes.tsv` maps paths to targets/suites; an unknown path runs the full
gate. Documentation-only paths run nothing. `AITERM_TEST_PATHS` supplies newline-separated paths
for routing probes. Reader/toolchain guards prove routing and the pinned compiler. A Swift pass
requires closing results from its test hosts, and a filtered run must execute at least one test;
process exit alone is not a green result. Intentional known issues are labelled by Swift Testing.

The runner retains completed runs' suite timings and failing test names for seven days in
`<AITERM_TEST_LOCK>.history.jsonl`, normally `/tmp/aiterm-test.lock.history.jsonl`. Duration excludes
queue wait. The history sits beside the queue's activity records, which keep their existing schema
and retention; the daemon does not read the history. The supervisor inherits both output streams
directly and collects history from result files after the command exits. Optional history I/O
failures warn without changing the gate verdict or activity record.

## What belongs where

| Tests | Requirement and distinct detection |
| --- | --- |
| `AiTermCoreTests` | Pure state/policy alternatives and real adapters: Git/worktrees, processes, HTTP, persistence, agent configuration, platform value rules and geometry. |
| `AiTermTests` | Main-actor owner lifetimes, store/daemon wiring, launch/adoption, publication progress, user controls, focused observation, keyboard and AppKit behavior. |
| `AiTermUITests` | Primitive layout, appearance, token use, palette distinction and module boundaries. |
| `AiTermTestSupport` | Isolated repositories, scripted hosts/daemon, scratch defaults and current structured model fixtures. |
| `daemon/tests` | Registry/status/delivery decisions, telemetry placement, RPC/HTTP framing, iTerm adapter behavior, wire/schema contracts and bounded polling work. |
| Script guards/fixtures | Queue ownership/FIFO/crash recovery, route readers, compiler pin, result validation, gate history and the release precondition, and bundle resources/signing. |

Keep one rule test for each meaningful alternative, plus enough owner/real-adapter integration to
prove wiring. Parameterize equivalent setup. A frozen complete contract replaces repeated paragraph
and punctuation assertions. Avoid tests that merely ban a removed word/symbol, mirror getters or
retain behavior solely because it existed. Negative tests remain valuable for current guarantees:
no unsaved-work deletion, foreign configuration overwrite, duplicate external write, delivery after
takeover, stale-result mutation or visible test windows.

Use latches/rendezvous to control asynchronous ordering; elapsed-speed assertions are poor evidence
of overlap. `TestLatch` and `eventually` are bounded by `TestDeadline`, so a missing signal fails
rather than hangs. Join Operator work with `settled()` (or `settled(leaving:)`) on its `OperatorWork`,
not an owner's last-task handle. When consolidating safety tests, establish which surviving test
detects the same failure rather than deleting by name or assertion sign.

Prefer deterministic work budgets for hot paths. Swift budgets count through `WorkMeter`, a
task-local a test binds, and assert exact numbers in `WorkBudgetTests`, `OperatorWorkBudgetTests`
and `ViewWorkBudgetTests`; the daemon's steady-tick budgets in `test_tick_budgets.py` fix the scan's
local and UTC dates. A change lowers a number with the work that earned it and never raises it.
`AITERM_MEASURE=1` prints fixture timings and asserts nothing; keep them separate from installed-app
latency claims.

`AiTermTestSupport/Builders.swift` holds the shared builders for `Project`, `TaskItem`,
`SessionInfo`, `OperatedTask` and `OperatorRun`; new tests use them, and older tests still call the
initialisers directly. `ScratchFolder` hands out folders under
one root per test process, removed at exit, and sweeps dead processes' roots at the next start.
`GitFixture` copies one hermetic seed repository per process; each copy owns its refs and objects,
and an explicit runner still owns setup for fault and count tests. A test that runs git, a process,
a sleep or a semaphore off the main actor is marked `.blocking`; the window hook reports an unmarked
process launch. Keep `.serialized` for suites that touch application-wide state: of the controller
suites only `ControllerApplicationTests` is serialized.

## Current Operator contract

The operator-current fixtures were captured once from unmodified product revision `f152f6e9`, before
structural changes. The saved-format fixtures have their own provenance files. Each provenance file
describes the synthetic data. None contains a private broadcast.

| Fixture | Always-on reader |
| --- | --- |
| `AiTermTests/Fixtures/operator-current/state.json` | `OperatorCurrentContractTests`: StateStore load and a byte-for-byte save back, restart/reconnect, task/worker ownership. |
| `AiTermTests/Fixtures/operator-records/sparse.json`, `full.json` | The same suite: an Operator run and task with only required fields, and with every field set, save to these bytes and load back equal. A new stored field goes into `full` by decision. |
| `AiTermTests/Fixtures/operator-saved-format/state.json` | The same suite: the saved format with `problemKind` saves to its own bytes; without the key, each problem's kind is read from its wording. |
| Same directory's `contract.json` | The same suite's current journey: tool/status replies across tabs, pause, acceptance/publication, goal rounds and summary. |
| `AiTermCoreTests/Operators/Fixtures/operator-current/brief-*.md` | `OperatorCommandTests`: complete current brief variants, including resume. |
| `daemon/tests/fixtures/operator-current-tools.json` | `test_operator_mcp.py`: all 37 served schemas, preserving order and descriptions. |
| `daemon/tests/wire/` | Python producers and Swift `WireContractTests`: framing, event/reply decoding and protocol names. |
| `daemon/tests/codex_reference.py` | `test_codex_sessions.py`: the rollout parser from before the tail-window reader, which large-rollout answers are compared with. |

Swift fixture paths above are relative to `app/Tests/`. They are checkout-read fixtures, excluded
from source discovery and registered in routing. Do not regenerate them to make a refactor green.
A deliberate change to the model-facing contract requires a separate behavior decision and evidence.
Captured brief whitespace is part of those bytes; the fixture directory’s `.gitattributes` allows
its original end-of-line spaces without relaxing whitespace checks elsewhere.
Focused rules and fake-host journeys still own policy; the golden is not a substitute for them.

`OperatorEvalTests` uses current structured setup and deterministic grading preparation. Real-agent
runs are opt-in (`AITERM_LIVE_OPERATOR=1`), require the local stub and incur agent use. Preserve the
working brief/status wording unless capped before/after runs on the same model and effort prove an
intended change. Neither refactor round rewrote that wording.

## Isolation

The normal suite uses fake iTerm2/HTTP, temporary repositories/homes and `ScratchDefaults.make()`.
It must not install hooks, use personal credentials, connect to live sessions or replace the app.
The runner rejects new AiTerm preference domains. The test-only window hook makes ordered windows
transparent and click-through; a visible test window is a bug. Real modal questions use a scripted
`Prompter`.

For daemon iteration, run `.venv/bin/pytest -k <expression>` from `daemon/`. The full gate
type-checks `aitermd tests tools` and runs ruff. `AITERMD_LIVE=1` opts into iTerm2 integration
tests; never set it during an isolated gate. An audit hook in `daemon/tests/conftest.py` fails any
test, and the session, that opens or lists the live test-run records; service fixtures take a scratch
records folder. Session files, transcripts and rollouts are built through `daemon/tests/builders.py`.

## Build and visual proof

```sh
scripts/make-app.sh
scripts/test-app-bundle.sh build/AiTerm.app
scripts/readme-picture.sh --check
```

Bundle checks do not launch the app. Debug snapshots enter before live app setup and use fixtures.
The README check requires a Retina main display. It compares a fresh drawing with `docs/desktop.png`
and fails when they differ, which it does on `main` today: the committed picture is out of date and
the next `scripts/release.sh` redraws it. A visual change is proven by comparing `scripts/snapshots.sh`
captures before and after. The GitLab artwork in `marks.png` and `new-broadcast-1.png` has come out in
two exact variants across captures of the same commit; capture again before calling such a
difference a regression. Native WindowServer captures require screen
recording permission; a fallback capture does not establish VoiceOver behavior or multi-display
placement. `scripts/run-dev.sh` deliberately replaces the live app/helper and is a separate manual
switch.
