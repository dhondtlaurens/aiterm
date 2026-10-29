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

## What belongs where

| Tests | Requirement and distinct detection |
| --- | --- |
| `AiTermCoreTests` | Pure state/policy alternatives and real adapters: Git/worktrees, processes, HTTP, persistence, agent configuration, platform value rules and geometry. |
| `AiTermTests` | Main-actor owner lifetimes, store/daemon wiring, launch/adoption, publication progress, user controls, focused observation, keyboard and AppKit behavior. |
| `AiTermUITests` | Primitive layout, appearance, token use, palette distinction and module boundaries. |
| `AiTermTestSupport` | Isolated repositories, scripted hosts/daemon, scratch defaults and current structured model fixtures. |
| `daemon/tests` | Registry/status/delivery decisions, telemetry placement, RPC/HTTP framing, iTerm adapter behavior, wire/schema contracts and bounded polling work. |
| Script guards/fixtures | Queue ownership/FIFO/crash recovery, route readers, compiler pin, result validation and bundle resources/signing. |

Keep one rule test for each meaningful alternative, plus enough owner/real-adapter integration to
prove wiring. Parameterize equivalent setup. A frozen complete contract replaces repeated paragraph
and punctuation assertions. Avoid tests that merely ban a removed word/symbol, mirror getters or
retain behavior solely because it existed. Negative tests remain valuable for current guarantees:
no unsaved-work deletion, foreign configuration overwrite, duplicate external write, delivery after
takeover, stale-result mutation or visible test windows.

Use latches/rendezvous to control asynchronous ordering; elapsed-speed assertions are poor evidence
of overlap. Prefer deterministic work budgets for hot paths. Keep fixture timing measurements
separate from installed-app latency claims. When consolidating safety tests, establish which
surviving test detects the same failure rather than deleting by name or assertion sign.

## Current Operator contract

These fixtures were captured once from unmodified product revision `f152f6e9`, before structural
changes. Their provenance files describe the synthetic data. They contain no private broadcast.

| Fixture | Always-on reader |
| --- | --- |
| `AiTermTests/Fixtures/operator-current/state.json` | `OperatorCurrentContractTests`: StateStore load, restart/reconnect, task/worker ownership. |
| Same directory's `contract.json` | The same suite's current journey: tool/status replies across tabs, pause, acceptance/publication, goal rounds and summary. |
| `AiTermCoreTests/Operators/Fixtures/operator-current/brief-*.md` | `OperatorCommandTests`: complete current brief variants, including resume. |
| `daemon/tests/fixtures/operator-current-tools.json` | `test_operator_mcp.py`: all 32 served schemas, preserving order and descriptions. |
| `daemon/tests/wire/` | Python producers and Swift `WireContractTests`: framing, event/reply decoding and protocol names. |

Swift fixture paths above are relative to `app/Tests/`. They are checkout-read fixtures, excluded
from source discovery and registered in routing. Do not regenerate them to make a refactor green.
A deliberate change to the model-facing contract requires a separate behavior decision and evidence.
Captured brief whitespace is part of those bytes; the fixture directory’s `.gitattributes` allows
its original end-of-line spaces without relaxing whitespace checks elsewhere.
Focused rules and fake-host journeys still own policy; the golden is not a substitute for them.

`OperatorEvalTests` uses current structured setup and deterministic grading preparation. Real-agent
runs are opt-in (`AITERM_LIVE_OPERATOR=1`), require the local stub and incur agent use. Preserve the
working brief/status wording unless capped before/after runs on the same model and effort prove an
intended change. No such wording rewrite is part of this refactor.

## Isolation

The normal suite uses fake iTerm2/HTTP, temporary repositories/homes and `ScratchDefaults.make()`.
It must not install hooks, use personal credentials, connect to live sessions or replace the app.
The runner rejects new AiTerm preference domains. The test-only window hook makes ordered windows
transparent and click-through; a visible test window is a bug. Real modal questions use a scripted
`Prompter`.

For daemon iteration, run `daemon/.venv/bin/pytest -k <expression>` from `daemon/` (adjust the
executable path to `.venv/bin/pytest` there). The full gate type-checks `aitermd tests tools` and
runs ruff. `AITERMD_LIVE=1` opts into iTerm2 integration tests; never set it during an isolated gate.

## Build and visual proof

```sh
scripts/make-app.sh
scripts/test-app-bundle.sh build/AiTerm.app
scripts/readme-picture.sh --check
```

Bundle checks do not launch the app. Debug snapshots enter before live app setup and use fixtures.
The README check requires a Retina main display. Native WindowServer captures require screen
recording permission; a fallback capture does not establish VoiceOver behavior or multi-display
placement. `scripts/run-dev.sh` deliberately replaces the live app/helper and is a separate manual
switch. Schedule real-account, VoiceOver, display and update checks using [releasing](releasing.md).
