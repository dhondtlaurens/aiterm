# 0a. Baseline: the starting gate, the before snapshots and a saved-state copy

Implementer: Opus 5.5 at high effort. Depends on: nothing; this is the first step. Findings: none;
it serves the plan's proof (gate, visual comparison, upgrade rehearsal).

## Why

The refactor moves a lot of code over nine phases, and each phase merges only after a full gate.
Three things are needed later that exist only before the first change. First, proof that the
starting commit is green, so a later red gate belongs to the refactor and not to what came before.
Second, the sidebar and sheet pictures as they are today: structural steps must draw the same
pixels, and the close-out (9c) compares the final pictures with these. Third, a copy of a workspace
file written by today's build: the close-out runs the upgrade's reset command on it and loads the
result with the final code. Phases 1, 4 and 5 re-record the saved-format fixture, so today's bytes
can only be copied now. This step changes no code and no test; it records.

## Today

- `scripts/test.sh all` runs the full gate. One run at a time machine-wide: it queues behind other
  worktrees' runs. Start it in the background and wait for your own command to exit. A plain run
  (no `SWIFT`, `PYTEST` or `AITERM_TEST_PATHS` override) is the only one that counts as proof.
- `scripts/snapshots.sh <folder>` builds the debug app through `scripts/build-app.sh debug`,
  deletes the PNG files at the top level of `<folder>` (nothing else there) and renders every
  debug snapshot into it, without connecting to the running app or its helper. It is not queued,
  so it must not run while this worktree's own test run is building.
- `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` is the saved-format
  golden that `SignalSavedFormatTests` writes through `StateStore`. Today it holds one project, one
  task with a `signalTask` and one conversation (`worker-conversation`), one archived task with a
  `signalTask` and one conversation (`archived-conversation`), two signals, one seen item, an
  `operatorSession`, and no terminals.
- `build/` is ignored by git (`.gitignore` has `build/`).
- The plan, `docs/plans/2026-11-16-greenfield-refactor.md`, ends with a `## Record` section that is
  empty except for its one-paragraph description. The plan file and this folder are untracked.

## Change

1. Confirm the starting point: `git status --short` lists only the untracked plan file and this
   folder. If it shows any other change, stop and report. Note `git rev-parse HEAD` and
   `git log -1 --format='%h %s'`.
2. Create `build/refactor-before/`. Start `scripts/test.sh all` in the background, plain, with its
   output redirected to `build/refactor-before/gate.log`. Wait until your own command exits.
3. Only after the gate has exited: run `scripts/snapshots.sh build/refactor-before` (default mode:
   leave `AITERM_SNAPSHOT_HOSTED` and `AITERM_SNAPSHOT_NATIVE_CAPTURE` unset).
4. Write a checksum manifest beside the pictures: from inside `build/refactor-before`, run
   `shasum -a 256 *.png > manifest.txt`, so each line names a bare file name. Count the PNGs.
5. Copy the fixture: `cp app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json build/refactor-before/state.json`,
   then note `shasum -a 256 build/refactor-before/state.json`.
6. Under `## Record` in the plan, add a heading `### Phase 0` and four bullets:
   - Starting commit: the short hash and subject from step 1.
   - Gate: the command, the runner's closing summary lines as printed, and the wall time.
   - Snapshots: `build/refactor-before/`, the PNG count, and that `manifest.txt` holds their
     SHA-256 sums.
   - Saved-state copy: `build/refactor-before/state.json`, copied from the `operator-signals`
     fixture at the starting commit, with its SHA-256.

## Keep

- `build/refactor-before/` is written once, here. Nobody runs `scripts/snapshots.sh` into it again:
  the script deletes the PNGs already there.
- The fixture itself is not touched; only its copy goes into `build/`.
- Nothing under `build/` is committed.

## Decisions already taken

- The gate is red on the starting commit: run `scripts/test.sh all` once more. If the same test
  fails again, stop and report its name and output; phase 0 changes no product code, so the
  orchestrator decides what follows. If it passes, record both runs and name the flaky test.
- The snapshot build fails: report its output and stop. Do not change code to make it build.
- `marks.png` and `signal-jira-reviewRequested-1.png` are known to come out in two exact variants
  across captures of one commit (GitLab artwork). Capture once; 9c handles the variance.
- `scripts/readme-picture.sh --check` is known to fail on `main` and is not part of this step.
- `main` moved after this worktree branched: not this step's concern. Record the HEAD you ran on.
- The plan file is untracked: edit it in place and leave it uncommitted. The orchestrator commits.

## Tests

None added, changed or deleted.

## Proof

The gate log's closing lines show a passing run; `build/refactor-before/` holds the PNGs,
`manifest.txt` and `state.json`.

## Done when

- `ls build/refactor-before/*.png | wc -l` equals the count recorded, and `manifest.txt` has as
  many lines.
- `shasum -a 256 build/refactor-before/state.json` equals the recorded sum and equals the sum of
  the fixture at the starting commit.
- The plan's Record has the `### Phase 0` entry with the four bullets.
- `git status --short` shows no change outside the plan file and this folder.

## Not in this step

- The signal journey test (0b) and the move onto shared builders (0c).
- Comparing snapshots and the upgrade rehearsal (9c).
