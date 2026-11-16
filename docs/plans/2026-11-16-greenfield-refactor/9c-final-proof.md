# 9c. Final proof: gate, bundle, snapshots, upgrade rehearsal, review and Record

Implementer: Opus 5.5 at high effort. Depends on: every other step, 9a and 9b included, merged.
Findings: the plan's Proof section (gate, bundle, visual, upgrade rehearsal, adversarial review).

## Why

Each phase merged on its own after a full gate, but nobody has yet looked at the whole: whether
the final build draws only the visible changes the plan agreed, whether a workspace saved by the
build before the refactor survives the release notes' reset and loads in the final code, and
whether the whole change holds up to an independent review. This step gathers that evidence and
completes the plan's Record, so the maintainer can decide on the release with everything in one
place. It writes no product code: anything it finds that is wrong is reported, with evidence, for
the orchestrator to turn into a fix.

## Today

- `## Record` in `docs/plans/2026-11-16-greenfield-refactor.md` holds an entry per phase, the first
  (`### Phase 0`) with the starting commit, the starting gate, the snapshot folder and the saved-state
  copy with its SHA-256.
- `build/refactor-before/` (ignored by git) holds the starting commit's snapshot PNGs, their
  `manifest.txt` (`shasum -a 256` lines with bare file names) and `state.json`, a copy of the
  saved-format fixture at the starting commit: one project `Shop`; one task "Make retries safe" on
  `feat/pay-1` with a `signalTask` and conversation `worker-conversation`; one archived task "Earlier
  work" with a `signalTask` and conversation `archived-conversation`; signals "Plan tickets" and
  "Build tickets"; one seen item, disposition `started`; an `operatorSession`; no terminals.
- `docs/release-notes/<YYYY-MM>-major-release.md` (9b) holds the reset command in a fenced block. It
  starts with a guard that refuses while a process named `AiTerm` runs; the rest copies `state.json`
  to a dated file beside it and removes `operatorSession` and each task's and archived task's
  `signalTask` through `osascript -l JavaScript`.
- `scripts/snapshots.sh <folder>` builds the debug app and renders every snapshot, deleting only the
  PNGs at the folder's top level first. `scripts/make-app.sh` builds `build/AiTerm.app`;
  `scripts/test-app-bundle.sh build/AiTerm.app` checks its resources and signing. Neither is queued,
  so run them only after your own test run has exited.
- `docs/testing.md` notes that `marks.png` and `signal-jira-reviewRequested-1.png` come out in two
  exact variants across captures of one commit.

## Change

1. Gate. Start plain `scripts/test.sh all` in the background (no `SWIFT`, `PYTEST` or
   `AITERM_TEST_PATHS` override), output to `build/refactor-after/gate.log`, and wait for your own
   command. Red: stop and report the failing tests.
2. Bundle. `scripts/make-app.sh`, then `scripts/test-app-bundle.sh build/AiTerm.app`. Note the
   closing lines.
3. Snapshots.
   - `scripts/snapshots.sh build/refactor-after` in default mode, then from inside that folder
     `shasum -a 256 *.png > manifest.txt`.
   - Sort every file name into four lists by comparing the two manifests: only before, only after,
     in both with different sums, in both with equal sums.
   - Open each pair that differs (and each file only on one side) and classify it: a listed change
     (name which one from Decisions) or unlisted. Check that a listed change shows that change and
     nothing else in the picture.
   - For `marks.png` or `signal-jira-reviewRequested-1.png`, capture once more into a new folder
     before calling a difference unlisted.
4. Upgrade rehearsal.
   - Make `build/refactor-rehearsal/Library/Application Support/AiTerm/` and copy
     `build/refactor-before/state.json` into it as `state.json`.
   - Run `scripts/reset-operator-state.sh` with that copy's path as its argument (with an argument
     it skips the running-app check, so the maintainer's AiTerm may stay open). First confirm the
     command line in the script and the fenced block in the release note are byte-identical; if they
     differ, stop and report.
   - Check a `state.json.before-reset-<stamp>` file sits beside it, byte-identical to the copy.
   - Compare the reset file with the original as JSON (for example with the daemon's virtual
     environment, `daemon/.venv/bin/python -I`): equal once `operatorSession` and both
     `signalTask` objects are removed from the original, and nothing else differs.
   - Load it through the final code with a temporary test file,
     `app/Tests/AiTermCoreTests/UpgradeRehearsalTests.swift`, which finds the file from its own
     `#filePath` (the repository root is four folders up) and loads it with
     `StateStore(url:).load()`. Expect: one project `Shop`; one task "Make retries safe" on
     `feat/pay-1` whose conversations hold `worker-conversation` and which has no `signalTask`; one
     archived task "Earlier work" whose conversations hold `archived-conversation` and which has no
     `signalTask`; two signals by those names; one seen item, `started`; no `operatorSession`; no
     terminals. Then save the loaded state through a `StateStore` in a scratch folder and load it
     again: equal.
   - The fixture holds no task a person took over, so rehearse that case too. Make a second copy of
     `build/refactor-before/state.json` under a second scratch `HOME`, set `takenOver` to true inside
     the `signalTask` of its driven task (edit the JSON; that is where today's build keeps the fact),
     and run the same command on it. Expect: that task has no `signalTask` and carries its own
     `takenOver: true`; the archived task gained no such key. In the same temporary test file, load
     this second file through `StateStore`, check the task carries the mark, and check that
     `MatchDecision` gives no decision for an item that matches it (build the item from the task's
     ticket, as the Core match tests do), while the same item still continues the unmarked task of
     the first file.
   - Run `scripts/test.sh swift -- --filter UpgradeRehearsalTests`, keep its closing lines, then
     delete the file. It is never committed.
5. Review. Run the `psg:adversarial-review` skill on the whole change from the starting commit to
   `HEAD` (`git diff <start> HEAD`), read-only, and triage its findings as the skill says. If the
   skill is not available in your session, say so in your report so the orchestrator runs it.
6. Record. Add `### Close-out` under `## Record` with one bullet each for the gate, the bundle
   check, the snapshots (the four counts, each listed difference with its change, every unlisted one
   with its file names), the rehearsal (each check and its result, the skipped guard), and the
   review (verdict and each finding with its triage). Then list what is still owed by hand, by the
   maintainer, unless the Record already shows it done: `scripts/compat-check.sh` after phases 1
   and 2; the Operator eval with `AITERM_LIVE_OPERATOR=1` after phases 1 and 5; one smoke run
   through `scripts/run-dev.sh` (create a task, close its window, choose the row, archive, restore,
   remove; a signal from match to done). Name any phase without a Record entry. Tick `9c` in the
   plan's to-do list.

## Keep

- `build/refactor-before/` is read, never written: snapshots go to `build/refactor-after/`.
- The rehearsal works on copies under `build/` only. Never point it at
  `~/Library/Application Support/AiTerm/`.
- No product or test change survives this step; the rehearsal test file is deleted.

## Decisions already taken

- Listed visible changes, and the pictures they are expected to move:
  - Find a Fix removed: `banner-find-a-fix-*.png` and `review-fix-*.png` exist only before; a
    Settings picture of the Agents pane loses Help with problems.
  - Closed view: debug snapshot poses of rows being restored or "Couldn't reopen" exist only before
    or no longer show that state; a row without a window draws as it did before in that state.
  - The iTerm2 banner wording: `sidebar-banners.png`, and `settings-iterm-off.png` if it shows it.
  - Stepped sheets: Cancel on every step (task, review and signal step pictures:
    `step1-*.png`, `step2-*.png`, `step3-agent.png`, `review-step*.png`, `signal-*.png`).
  - The "isn't installed" note once, only when no agent can run: `step3-agent.png` and review
    agent steps.
  - Add Project's folder as a line with Choose…: `add-project.png`, possibly `edit-project.png`.
  - New Task's Base branch as a filtered field: New Task step 1 pictures.
  - New Signal readiness as advice; one unavailable-model wording; a disabled Continue's reason:
    signal sheet pictures.
  - A removed signal's heading without a pause mark; Pause and Resume only on the Operator
    heading's menu: Operator sidebar pictures, if they draw either.
  Any other difference is unlisted. Structural steps were to keep pixels equal.
- An unlisted difference: find the commit that changed the view involved (`git log` on its file),
  record both file names and the commit, and report it. Do not fix it here.
- `build/refactor-before/` is missing: recover `state.json` with
  `git show <start>:app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` and
  check its SHA-256 against the Record; the before snapshots cannot be recovered without another
  worktree, so report that the comparison could not run. Do not create a worktree.
- The rehearsal load fails, or a check differs: that is a release blocker. Report the failing
  check and the error; do not change the command or the code.
- The review asks for changes: report them with their triage; fixing is the orchestrator's call.
- The gate or bundle check is red: stop at that point and report; later checks wait.

## Tests

None kept. One temporary test file for the rehearsal, deleted before you report.

## Proof

The gate log, the bundle check's output, both manifests and the four lists, the rehearsal's
filtered run and JSON comparison, and the review's output, each summarised in the Record.

## Done when

- `### Close-out` in the Record holds all six results and the list of what the maintainer still
  owes, and 9c is ticked.
- `git status` shows only the plan file changed; `UpgradeRehearsalTests.swift` does not exist.
- Every snapshot difference is classified as listed or unlisted, and every unlisted one is in your
  report.

## Not in this step

- Fixing any finding (a new step, at the orchestrator's call).
- The release itself (`scripts/release.sh`), `scripts/run-dev.sh`, `scripts/compat-check.sh` and
  the live Operator eval: the maintainer's.
- Doc and release-note edits (9a, 9b), except the plan's Record.
