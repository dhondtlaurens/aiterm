# 0d. The reset script

Implementer: Codex `gpt-6.1-sol` high. Depends on: nothing (it can run beside 0a to 0c). Comes from:
plan review rounds 1 and 2, and the drafting of 5b (an unreadable Operator record fails the whole
workspace load).

## Why

This refactor changes the shape of the Operator's two saved records, `operatorSession` and each
task's `signalTask`, and by the maintainer's decision nothing migrates them and nothing reads an
older shape. The installed app and development builds share one workspace file,
`~/Library/Application Support/AiTerm/state.json`, and a record that does not decode fails the
whole load. So from the first step that changes one of those records, a build of this branch and
the installed app cannot open each other's file while it holds Operator records. The answer is one
small command that clears exactly those two records and keeps everything else: the maintainer runs
it, with AiTerm quit, before switching builds in either direction during the refactor, and the
release notes (9b) carry the same command for the upgrade. This step writes that command as a
script and a guard that proves it on scratch files. It changes no product code.

## Today

- The workspace file is JSON written by `StateStore`: pretty-printed, sorted keys, ISO 8601 dates.
  Top-level keys that matter here: `operatorSession` (the Operator's chat record), `tasks` (an
  array of task objects) and `archive` (an array whose elements hold an archived task under `task`;
  the key is absent when nothing is archived). A task driven by a signal carries `signalTask`, an
  object with, among others, a Boolean `takenOver`. Verify the key names in
  `app/Sources/AiTermCore/Models.swift` (`AppState`, `TaskItem`), the archive model in
  `app/Sources/AiTermCore/Tasks/` and `app/Sources/AiTermCore/Operators/Signals/SignalTask.swift`.
  If a name differs from this brief, stop and report.
- Step 4e will add an optional Boolean key `takenOver` on the task itself: its mark that a person
  took the task over, which keeps signals from continuing it. Today's builds ignore and keep an
  unknown key, so writing it now is harmless.
- `scripts/` holds the project's scripts; `scripts/README.md` describes each. Script guards are
  shell scripts named `scripts/test-<what>.sh` (for example `scripts/test-test-history.sh`); read
  `scripts/test.sh` and `scripts/test-routes.tsv` to see how a guard is run by the gate and how a
  path is routed to it. A saved-state fixture with a driven task, an archived driven task and an
  `operatorSession` is at
  `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json`.

## Change

1. Create `scripts/reset-operator-state.sh` (executable, `#!/bin/zsh` like its neighbours, or
   `/bin/sh` if nothing in it needs zsh). After a short header comment that says what it does and
   when to run it, it holds the command as **one line**, so the release notes can carry that same
   line for people who have only the app. The line does this:
   - The file is the first argument, or `$HOME/Library/Application Support/AiTerm/state.json` when
     none is given.
   - With no argument, if a process named exactly `AiTerm` is running (`pgrep -qx AiTerm`), print
     "Quit AiTerm first." and change nothing. With an argument (a scratch file) it does not check.
   - Otherwise copy the file beside itself as `<file>.before-reset-<YYYYmmdd-HHMMSS>` keeping its
     dates (`cp -p`), and only if the copy succeeded run the edit.
   - The edit is one `osascript -l JavaScript` program given the path: read the file as UTF-8, parse
     it, and for every element of `tasks` and for the `task` of every element of `archive` (each
     array may be absent): if the task has a `signalTask` whose `takenOver` is exactly true, set the
     task's own `takenOver` to true; then delete the task's `signalTask`. Delete the top-level
     `operatorSession`. Write the result back atomically as JSON indented by two spaces, and print
     one line saying the Operator records were removed from that path. A file it cannot read or
     write is an error with a non-zero exit, and nothing is written.
   - It uses only what macOS ships: the shell, `pgrep`, `cp`, `date`, `osascript`. No Python, `jq`
     or Homebrew tool.
   The planner tried this exact program on scratch files; the working text is in
   `9b-release-notes.md` in this folder if you were given it, but you do not need it: build the
   line from the description above and prove it with the guard.
2. Create the guard `scripts/test-reset-operator-state.sh`, in the style of the other guards. In a
   scratch folder it creates (with a space in its path) and removes at exit, it runs the script on
   copies and fails loudly on any difference:
   - the saved-state fixture named under Today: afterwards no `operatorSession`, no `signalTask`
     anywhere, and every other key and value equal to the original;
   - a small file it writes itself with a driven task, a taken-over driven task (its `signalTask`
     has `takenOver` true), a task without a signal record, an archived taken-over task, an archived
     plain task, a `null` value and a nested array: afterwards only the two taken-over tasks carry
     `takenOver: true`, no other task gained a key, and everything else is equal;
   - a file without `archive` and without `operatorSession`: unchanged apart from formatting, exit 0;
   - each run left exactly one dated copy beside the file, byte for byte the original;
   - a path that does not exist: non-zero exit and no file created.
   The guard may compare JSON with `python3` (the gate already needs Python for the daemon); the
   script itself may not.
3. Wire the guard into the gate the way the existing guards are wired (read how
   `scripts/test.sh` runs `test-test-history.sh` and which `scripts/test-routes.tsv` rows select
   it): a change to either new file, or to the saved-state fixture the guard reads, must run the
   guard. Keep `scripts/test-test-select.sh` passing; run it.
4. `scripts/README.md`: add the script with two sentences: what it clears and keeps, and when to
   run it (AiTerm quit; before switching between the installed app and a development build while
   their Operator records differ in shape; once when upgrading to the major release).

## Keep

- Everything else in the workspace file, exactly: projects and dividers, tasks and their
  conversations, terminals, the archive, signal configurations, seen items, the sidebar frame, last
  used agents and models, and any key the script does not know.
- The three guards of the command: the running-app check for the real file, the dated copy before
  any write, and the atomic write.

## Decisions already taken

- Key order and indentation may differ from what the app writes; the app rewrites the file on its
  next save. Values must not differ.
- The script never touches `state.json.backup`: the app reads it only when the primary is missing
  or damaged, and its next save replaces it.
- A task whose `signalTask` has `takenOver` false or absent becomes an ordinary task with no mark:
  a signal may continue it later, as it may any task of the person's. That is intended.
- No option to keep the Operator session, no dry run, no undo command: going back is copying the
  dated file over `state.json` by hand, which the header comment says in one line.
- The Operator's journals and activity log under Application Support are left alone.
- Cannot happen here, no handling: two AiTerm processes, a workspace file larger than memory, a
  file in another encoding.

## Tests

The guard in step 2 is the test. No Swift or daemon test is added, and no fixture changes.

## Proof

- `scripts/test-reset-operator-state.sh` passes; `scripts/test-test-select.sh` passes.
- Plain `scripts/test.sh`, started in the background, selects and runs the guard and is green.
- Do not run the script without an argument: that would edit the maintainer's real workspace.

## Done when

- Both scripts exist and are executable; the command is one line in the script.
- `grep -n "python\|jq " scripts/reset-operator-state.sh` returns nothing.
- `scripts/README.md` describes the script; the guard is selected for a change to the script.
- Plain `scripts/test.sh` is green.

## Not in this step

- The release notes that carry the command (9b) and the rehearsal on the pre-refactor fixture (9c).
- The `takenOver` mark's reader in the app (4e).
