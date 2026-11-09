# Make AiTerm and the Operator project-agnostic

## Goal

Nothing AiTerm injects into a worker, or watches on its behalf, may assume AiTerm's own development
setup. Two couplings remain: worker prompts in every project carry AiTerm's test-queue advice and
its /model probing advice, and the test-run signal reads a format only AiTerm's `scripts/test.sh`
writes, with no documentation.

## Approach

The sweep confirmed only those two couplings. Product code names none of this repo's scripts, docs,
toolchain or psg conventions anywhere else.

What we agreed:

- **Worker line.** Remove two pieces from `WorkerStarter.worktreeLine`, which every worker, extra
  tab and review tab gets:
  - "Queued tests are not stalled. Finish when your command exits; do not poll other test
    processes."
  - "Never type /model, /effort or /config into a live agent session: they save the person's
    defaults. To try a model or effort, use launch flags or a scratch CLAUDE_CONFIG_DIR."

  AiTerm's own `AGENTS.md` carries both instead: it already has the /model rule and half of the
  test advice. The generic "Keep each background command's handle/PID, log and exit status." stays.
  The Operator brief's own /model rule stays too, since `message_task` can send /model in any
  project.
- **Test signal: opt-in, documented.** Keep the reader, the `testActivity` wire field and every
  consumer. Today the signal drives the sidebar, board and Operator lines, the StallWatch and
  WorkerQuietWatch signs of life, still-at-work for pause and the watchdog, and `run_status`. It
  does not exempt the runtime cap; that was fix B, which was dropped. There is no industry standard
  for "a test run is queued or running in this checkout". The format already uses the standard
  Unix building blocks: an atomic rename to publish, and a kernel `flock` for liveness rather than
  a PID file. So we write it down as the contract:
  - **Readers.** Any project's runner can write it. AiTerm's daemon reads it.
  - **Writer.** `scripts/test-queue.py` is the reference writer.
  - **Version.** A `version: 1` field lets the format change later. A record without it still counts
    as version 1.
  - **Tests.** A test pins writer to reader.
- **Out of scope.** These product-wide defaults stay, listed as possible follow-ups: the no-files
  rule, the dash rule, feat/fix/chore, `--no-ff`, the `origin` remote name and GitHub's
  `merge_method`.

## Files

- `AGENTS.md`, modify: in the test.sh bullet, add that a queued run is not stalled, that you wait for
  your own command to exit, and that you don't poll or kill other test processes. The /model bullet
  stays as it is.
- `app/Sources/AiTerm/Operators/WorkerStarter.swift`, modify: drop the two pieces from
  `worktreeLine` and update its doc comment.
- `app/Tests/AiTermTests/Operators/WorkerStarterTests.swift` and `OperatorVerdictTests.swift`,
  modify: their pinned prompts follow. These are focused tests, not the frozen goldens.
- `docs/configuration.md`, modify: a new section, "Show your project's test runs". It covers:
  - the directory `/tmp/aiterm-test.lock.runs`, with one `<run_id>.json` per run, published by
    atomic rename;
  - the fields: `version`, `run_id`, `root`, `suite`, `state`, `queued_at`, `finished_at`,
    `exit_code`, `ticket`;
  - the `<run_id>.lock` flock, held for the run's whole life and inherited by its children;
  - how an unlocked record reads, the 5-minute result window, and where the signal shows;
  - that macOS has no `flock(1)`, so a writer needs a few lines of Python or Perl.
- `daemon/aitermd/test_activity.py`, modify: skip a record whose `version` is present and not 1, and
  point the docstring at the documented format instead of test.sh.
- `scripts/test-queue.py`, modify: write `version: 1`.
- `daemon/tests/test_test_activity.py`, modify:
  - one rule test that an unknown version is ignored;
  - one contract test that runs `scripts/test-queue.py` with a scratch lock on a command exiting 3,
    then reads it through `TestActivityReader` as completed with exit 3, and as running while a
    command is held;
  - one recipe test, in a scratch non-AiTerm repo, that writes a record the way the docs describe
    and reads it onto that repo's agent session (see Proof).
- `scripts/test-routes.tsv`, modify: route `scripts/test-queue.py` to the daemon as well, and record
  `test_test_activity.py=scripts/test-queue.py` on the line for daemon tests that read outside
  `daemon/`.
- `app/Sources/AiTermCore/Daemon/DaemonTypes.swift`, modify: the doc comment names the documented
  format, not test.sh.

## Proof

- **Unit and contract tests:**
  - `WorkerStarterTests` and `OperatorVerdictTests` pin the new line.
  - `test_test_activity.py` covers the version rule and runs the writer-to-reader contract.
  - `scripts/test-test-queue.sh` still passes.
  - Gate: `scripts/test.sh` before each commit, `scripts/test.sh all` once before merging.
- **Before/after evidence for the model-facing change (docs/testing.md).** A capped live probe in a
  scratch worktree of this repo:
  - **The holder.** It runs `scripts/test-queue.py` against a scratch `AITERM_TEST_LOCK` with
    `sleep`, so the machine-wide lock is never touched.
  - **The worker.** Its environment exports the same `AITERM_TEST_LOCK` as the holder, so its own
    `scripts/test.sh daemon` queues behind the holder.
  - **Its prompt.** The worktree line plus the brief "run `scripts/test.sh daemon` and report its
    exit".
  - **How it runs.** Headless: Claude through `claude -p` with launch flags only, Codex through
    `codex exec </dev/null`.

  A run counts only if the worker's own record in `<lock>.runs` showed `state: queued` with a
  ticket before the holder was released, about three minutes in. Each agent runs twice per arm,
  before and after, on the same model and effort, with a 10-minute cap per run. Record whether it
  polls or kills other test processes, whether it calls the queue stalled, and whether it reports
  the real exit. The bar: "after" (advice only from AGENTS.md) is no worse than "before". A unit
  test shows that a worker outside this repo gets no test or /model advice at all. Findings go in
  the plan's evidence note.
- **The documented format reaches the app:**
  - **Recipe to reader.** A daemon test sets up a scratch git repo that is not AiTerm, with an
    agent session registered in it. It writes a record exactly as the docs/configuration.md recipe
    says (the same field set and flock). `TestActivityReader.read`/`apply` then sets that session's
    `test_activity` to running, and to completed with its exit once the lock is gone.
  - **Reader to screen.** This needs no new code: `WireContractTests` already decodes
    `testActivity`, and `SidebarModelTests` and `StallWatchTests` already cover the consumers.
  - **Optional live check.** Run only with Laurens's go-ahead, because it shows in his live
    sidebar. Write a temporary record for a task of the installed app in a non-AiTerm repo, watch
    "running tests · <suite>", then remove the record.

## To-dos

- [x] Bring the branch up to `main` (fast-forwarded during planning).
- [x] Worker line: run the "before" probe, then move the advice to AGENTS.md, trim `worktreeLine`,
  update the pinned tests and run the "after" probe; gate green.
- [x] Run records: `version: 1` in the writer and the reader rule, the writer-to-reader contract
  test and its routing; gate green.
- [x] Document the run-record format in docs/configuration.md, re-point the two doc comments and
  prove a hand-written record shows up in a non-AiTerm repo (the recipe test; the optional live
  check was not run).
- [ ] `scripts/test.sh all`, then merge.

## Evidence: worker line, before and after (9 November 2026)

Probe as described in Proof, each run in a fresh scratch clone of this branch.

**Setup:**

- **Clones.** The "before" clone was at `9ce7514a`, with the old line and the old AGENTS.md. The
  "after" clone was the same commit plus this branch's AGENTS.md, and its prompt carried the new
  line.
- **Models.** Claude Code 2.1.321 on `claude-sonnet-5-5` at medium effort, and Codex CLI 0.166.0 on
  `gpt-6-astra` at medium effort. Each used a scratch config.
- **Queue.** The holder kept a scratch lock for about 180 s. The worker's own run read as queued
  with a ticket after about 12 s in every valid run.

**Sandboxing, unlike real workers.** The auto-mode classifier refused workers launched with full
bypass permissions, so both agents ran sandboxed:

- Claude used its Bash sandbox with `dontAsk`, and could write only in the clone, `$TMPDIR` and
  `/tmp/claude*`.
- Codex used `workspace-write`.

The sandboxes break the daemon suite's local sockets, so every run exits 1. That is the same in
both arms, and the exit code is the only thing the bar needs.

| Arm | Valid runs | Polled or killed other test processes | Called the queue stalled | Reported the real exit (1) |
| --- | --- | --- | --- | --- |
| before, Claude | 2 of 2 | 0 | 0 | 2 |
| before, Codex | 2 of 2 | 0 | 0 | 2 |
| after, Claude | 2 of 3 | 0 | 0 | 2 |
| after, Codex | 2 of 2 | 0 | 0 | 2 |

**The discarded run.** One "after" Claude run was set aside and rerun once. It ended after 27 s,
before its run was seen queued, asking for permission because the sandbox's `dontAsk` refused a
Read of its log in `/tmp`. That is a harness artefact. Its only process commands were `ps -p` and
`kill -0` on its own background PID, which the worker line asks it to keep.

**Result.** The bar is met: with the advice only in AGENTS.md, workers behave as they did with it
in the prompt. Every worker waited on its own command, with a foreground run or a run in the
background plus `wait` or reads of its own log. None of them looked at the holder.

**Unit side.** `WorkerStarterTests` pins the complete new first prompt in a fixture repository that
is not AiTerm, with no test-queue or /model sentence.
