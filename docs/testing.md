# Testing

Run checks through `scripts/test.sh`; it pins Swift 6.4 and admits one run at a time across all
worktrees. Start a long run in the background with its output redirected, then follow that run's
log. Do not bypass the queue or start a competing Swift build against sources being edited.

```sh
scripts/test.sh                                      # affected checks before a commit
scripts/test.sh all                                  # full gate before merging to main
scripts/test.sh daemon                               # pytest, mypy and ruff
scripts/test.sh swift -- --filter TaskWorkflowTests   # one Swift suite
scripts/test.sh swift -- --filter SignalSavedFormatTests -j 2
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
| `AiTermTests` | Main-actor owner lifetimes, store/daemon wiring, launch/adoption, user controls, focused observation, keyboard and AppKit behavior. |
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
not an owner's last-task handle. A task lifecycle operation (archive, restore, remove, remove from
the Archive) is awaited itself: it returns once its work is done; a race test holds it at a port
latch and runs it in a task of its own. When consolidating safety tests, establish which surviving test
detects the same failure rather than deleting by name or assertion sign.

Prefer deterministic work budgets for hot paths. Swift budgets use `WorkMeter`, a task-local a test
binds, or a recording git runner. Ceilings are asserted in `WorkBudgetTests`, `GitSpawnCountTests`,
`SignalStatusBudgetTests` and `ViewWorkBudgetTests`; the daemon's steady-tick budgets in
`test_tick_budgets.py` fix the scan's local and UTC dates. A change lowers a ceiling with the work
that earned it and never raises it.
`AITERM_MEASURE=1` prints fixture timings and asserts nothing; keep them separate from installed-app
latency claims.

`AiTermTestSupport/Builders.swift` holds the shared builders for `Project`, `TaskItem`,
`SessionInfo` and Signal values; tests build those values through them. Only tests of the
initialisers or of decoding call the initialisers directly. `ScratchFolder` hands out folders under
one root per test process, removed at exit, and sweeps dead processes' roots at the next start.
`GitFixture` copies one hermetic seed repository per process; each copy owns its refs and objects,
and an explicit runner still owns setup for fault and count tests. A test that runs git, a process,
a sleep or a semaphore off the main actor is marked `.blocking`; the window hook reports an unmarked
process launch. Keep `.serialized` for suites that touch application-wide state: of the controller
suites only `ControllerApplicationTests` is serialized.

## Current Operator contract

Current fixtures live under
`AiTermCoreTests/Operators/Fixtures/operator-signals/`; their `PROVENANCE.md` records the decision,
synthetic inputs and model proof. They are not regenerated to accommodate incidental refactors.

| Fixture | Always-on reader |
| --- | --- |
| `operator-signals/state.json` | `SignalSavedFormatTests`: save through `StateStore`, exact bytes and reload, pending stages, archive, reply intent, generation, the chat lifecycle, questions and idempotency. |
| `operator-signals/brief.md`, `tools.json` | `SignalOperatorContractTests`: the stable role prompt and fourteen-tool schema contract. |
| `daemon/tests/wire/` | Python producers and Swift `WireContractTests`: framing, generation, context size and field parity. |

Swift paths are relative to `app/Tests/`; verify exact fixture paths from the owning test when
adding coverage. Unknown associated enum kinds and sparse new optional fields have focused tests.
Pure rules and native/fake-host journeys own behavior; byte fixtures do not substitute for them.

`SignalOperatorEvalRunner` evaluates the current contract in three situations: unavailable app,
product question and hostile source text. Each is repeated three times with the same model and
effort, with twelve turns and six hundred seconds at most per repetition. These isolated stub
runs are opt-in with `AITERM_LIVE_OPERATOR=1` and spend quota. Keep full streams: a question
written before a tool call still counts as chat, and a quota error never counts as behavior.
Change the brief deliberately with provenance and rerun the capped evaluation.

`SignalWorld`/`SignalHarness` cover routing and stage/claim races. `SignalJourneyTests` drives one
signal from a Jira match through its worker's turn and done condition to its archived task, through
the controller's own entry points, with fakes only at the daemon, HTTP, git and the clock; it must
pass after every phase. Native adapter tests use scratch
homes/defaults, recorded daemon commands, hermetic Git repositories and synthetic HTTP responses.
They prove guard installation, conversation adoption, pause, actual command construction and
cleanup ownership. Watching/cache/row redraw tests assert work budgets rather than elapsed-time
speed claims. `SignalSnapshotTests` renders every source/event step; native hosted captures are
inspected for final AppKit controls. A live Jira-to-MR flow still requires the maintainer's go
through `scripts/run-dev.sh`; tests and snapshots do not claim that flow ran.

## Agent compatibility

Claude Code, Codex and PI update themselves; what AiTerm reads from them (hook and status-line
payloads, session files, transcripts and rollouts, model lists, the flags it launches with, headless
answers) can change in any release. Run `scripts/compat-check.sh` by hand, with iTerm2 open: it first
checks the public latest releases and updates outdated CLIs, then opens fresh windows and spends a
little of each CLI's quota, so no gate runs it. An optional list (`scripts/compat-check.sh codex`)
limits both updates and checks. Every selected CLI must be installed; a missing CLI, failed release
lookup, failed update or version mismatch stops before capture. Native Claude explicitly installs
`latest`, regardless of its configured update channel; other installations use their CLI's updater.
If a package manager or release channel leaves an older version installed, resolve it and rerun.
Each new capture, headless and delivery session uses an absolute launcher for the checked executable,
which verifies its version again before starting. Existing sessions keep running.

`daemon/tools/compat_capture.py` drives each CLI live on its cheapest model, in a scratch config with
AiTerm's driver installed from `compat/drivers/` and pointed at a listener of its own: nothing reaches
the running app, and nothing lands in the person's own CLI config or AiTerm's support folder. It
saves what the CLI sent and wrote into `daemon/tests/fixtures/compat/<agent>/` in place of the last
capture, once scrubbed of the home folder, user name, scratch folder and every account detail; a
capture still holding one is not written. The delivery check runs for Claude Code and Codex beside
it, and its verdict is read back from its file. Only when that passed and the contract suites below
pass does `compat/verified.json` record each CLI's major and minor: the line each Settings › Agents
card shows. Review the capture's diff, which is what the CLI changed, and commit both.

| Fixture | Always-on reader |
| --- | --- |
| `compat/launch.json`, `compat/drivers/` | `CompatContractTests`: every command line the app builds, and the Claude settings and Codex hook block it merges, as the capture runs and installs them. A deliberate change records them again (`AITERM_RECORD_COMPAT=1`), then a capture follows. |
| `daemon/tests/fixtures/compat/<agent>/` | `test_compat_captures.py`: the daemon's hook, status-line, session, transcript, rollout and title readers. `CompatContractTests`: model lists against the raw files (never the fallback), headless answers, every flag the app passes in the CLI's `--help` or a probe. `CompatTranscriptTests`: the Operator's transcript reader. |
| `compat/verified.json` | `CompatVerifiedTests` for its reading; the bundle check for its copy in the app. |

A contract failure after a new capture is a CLI change AiTerm must follow: fix the reader, or decide
the change on purpose. Never edit or regenerate a capture to make a suite pass.

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
captures before and after. The GitLab artwork in `marks.png` and `signal-jira-reviewRequested-1.png` has come out in
two exact variants across captures of the same commit; capture again before calling such a
difference a regression. Native WindowServer captures require screen
recording permission; a fallback capture does not establish VoiceOver behavior or multi-display
placement. `scripts/run-dev.sh` deliberately replaces the live app/helper and is a separate manual
switch.
