# Step briefs for the greenfield refactor

Each file in this folder is the brief for one to-do of
[the plan](../2026-11-16-greenfield-refactor.md). The implementing agent for a step gets this page
and that step's brief, nothing else. Read both completely before changing anything.

## What you are working on

AiTerm is a native macOS sidebar (projects, tasks, tabs) that drives real iTerm2 through a Python
daemon. `app/` is the Swift package, `daemon/` the daemon. One **task** is one branch, one git
worktree, one iTerm2 window and its agent conversations. The **Operator** automates those same
tasks: a **signal** watches Jira, GitLab or GitHub; each matching **item** starts or continues
exactly one task as a **stage** with a prompt, a done condition and a Then (keep, archive, remove).
A **worker** is the agent in a driven task. One Operator chat (a Claude Code session with tools) is
woken only for judgment; the **Oracle** gives second opinions.

The code went through several phases in six weeks. Before signals there were "broadcasts": one
brief planned into tasks, a board, runs, verdicts, fix rounds, a finisher, and an Operator that
published merge requests and wrote to Jira itself. Signals replaced them on 15 Nov 2026 and reused
most of the machinery. Much of what you will read was built for a phase that no longer exists.
This refactor moves the code to the shape it would have if built today knowing the end state.

## Words

Use only these: signal, item, task, stage, worker, Operator, Oracle, Archive. Never write, in code
names, comments or copy: broadcast, run (for the Operator), board, Shelf, operated, challenge (for
the Oracle), finisher, verdict, slice, or a reference to a spec section. A comment says what the
code does now, never how it got there.

## Decisions that bind every step

- **No compatibility and no fallbacks.** This ships as a major release. Do not write or keep a
  migration, a second decoding of an older shape, or handling for an older install, helper or agent
  driver. The saved workspace, the app/daemon wire and the Operator's contracts may change when a
  brief says so.
- **The Operator's saved records are not readable across builds**, and that is intended. Only
  `operatorSession` and each task's `signalTask` may change shape; every other saved key must keep
  loading from a workspace saved by today's build. A step that changes one of those two records
  re-records the fixtures and adds nothing that reads the old shape: a workspace holding old
  records is cleared with `scripts/reset-operator-state.sh`, which the maintainer runs with AiTerm
  quit before switching builds. Phases 1 to 3 do not rename or restructure anything saved in either
  record (a Swift name may change; its saved key and raw value stay; a key nobody reads may stop
  being written), so those phases still open a workspace the installed app wrote. The first step
  that changes a record's shape is 4e.
- **One exception:** the workspace file tolerates what it does not know (`PreservedFields`,
  `.unknown` enum cases, lenient raw decoding). Keep it. The installed app and development builds
  share one `state.json`.
- **Real, then likely.** Before you handle an edge case, ask whether it can really happen in this
  app on one person's Mac, and whether it plausibly will. If either answer is no, do not handle it.
  The same holds for code you find: a brief that deletes a guard has already asked this.
- **No frameworks.** No reducer framework, event store, plugin architecture, protocol per class or
  generic job engine. Use a concrete owner for stable behaviour and a protocol only at a real I/O
  seam that a test needs to fake.
- **Closed view** (from phase 3 on): a row's window is a view of it. Closing it asks nothing and
  removes nothing; choosing the row opens it again. Nothing reopens by itself.
- **Find a Fix, broadcasts' eval baseline and every old-format reader are gone** after phase 1. Do
  not bring any of them back to make something compile; delete the caller's use.

## How to work

1. Read the brief. Re-run its evidence (the greps under **Today**) before you change anything:
   `main` moves, and a line number in a brief may have drifted. Symbols are the anchor.
2. A brief's **Today** describes the code as the planner expected to find it after the earlier steps.
   Small differences are normal (a name an earlier step chose, a member already gone): the code
   decides what exists, the brief decides where the step ends. Carry on and say what differed.
3. If the evidence no longer holds in a way that changes the step, or the brief turns out to be
   wrong, stop and report what you
   found. Do not quietly build something else, and do not widen the step.
4. Do exactly the step. Things you notice outside it go in your report, not in the diff.
5. New logic gets its test first. A deletion needs no new test.
6. When you delete a test, say in your report which surviving test detects the same failure, or
   that the behaviour itself is deleted by this step.
7. A sentence in `docs/` that your change makes false is fixed in the same commit when it is a
   line or two. Larger rewrites are named in the brief or left to the close-out.
8. Leave the change uncommitted unless the brief says otherwise; the orchestrating session reads
   the diff, runs the gate and commits.

## Rules of the repository

- Work only in the worktree you were started in. Never touch the main checkout, another worktree,
  or `git stash`.
- Build and test only through `scripts/swift.sh` and `scripts/test.sh` (they pin Swift 6.4). Never
  call `swift` directly.
  - While iterating: `scripts/test.sh swift -- --filter <Suite>`, or for the daemon
    `daemon/.venv/bin/pytest -k <expr>` run from `daemon/`.
  - Before you report: plain `scripts/test.sh`. It queues behind other worktrees' runs, so start it
    in the background and wait for your own command to exit. A queued run is not stalled; never
    poll, kill or bypass another run.
- Never run `scripts/run-dev.sh`, `scripts/release.sh`, `scripts/compat-check.sh`, the delivery
  check, or anything behind `AITERM_LIVE_OPERATOR` or `AITERMD_LIVE`. They replace the running app,
  open windows or spend quota; they are the maintainer's.
- Never type `/model`, `/effort` or `/config` into a live Claude Code session.
- Visual values (colours, sizes, spacing, text sizes) come from `app/Sources/AiTermUI/README.md`,
  `Palette.swift` and `Metrics.swift`. A step that is not listed as a visible change in the plan
  must render the same pixels. The app is dark-only. Copy uses no em dashes.
- Frozen fixtures (`app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/`,
  `daemon/tests/wire/`, `compat/launch.json`, `compat/drivers/`) change only when the brief says
  so, by the recording switch the brief names, with a line added to the fixture's `PROVENANCE.md`
  saying which step changed it and why. Never edit `daemon/tests/fixtures/compat/<agent>/`
  captures.
- The repository is public. No private paths, user names, company names, internal hosts or real
  ticket keys in code, tests, fixtures or docs.

## How a brief is laid out

- **Why**: the problem in product terms and the end state this step reaches.
- **Today**: the modules involved, by file and symbol, what each does and who calls it, with the
  greps that prove it.
- **Change**: the ordered actions and the shape that results. No code; names and responsibilities.
- **Keep**: nearby code that looks related and stays, with the reason.
- **Decisions already taken**: edge cases and their answers, so you do not have to invent one.
- **Tests**: what is deleted (with its survivor), what is added or adjusted, fixtures to re-record.
- **Proof**: the commands to run and what they must show.
- **Done when**: the conditions that make the step complete.
- **Not in this step**: what belongs to another step, by its id.

## Your report

When you finish, report: what you changed (by file), tests deleted with their survivors, fixtures
re-recorded, the result of plain `scripts/test.sh` with its closing lines, anything in the brief
that did not hold, and anything you noticed and left alone.
