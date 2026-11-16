# 9b. Release notes for the major release, with the upgrade reset

Implementer: Opus 5.5 at high effort. Depends on: 9a, and every step of phases 0 to 8 merged.
Findings: plan review round 1, finding 1 (the upgrade left saved Operator records the new formats
cannot read) and round 2, finding 2 (the reset must not forget that a task was taken over).

## Why

This refactor ships as one major release with no migration and no compatibility code. The
Operator's saved records changed shape in phases 4 and 5 (Take Over ends the signal record, a task
holds its current stage whole, the chat's lifecycle is one saved enum), and nothing reads the old
shapes. Everything else in the workspace file loads as before: projects, tasks, terminals, the
Archive, conversations, signal configurations and seen items. So the person needs one action
before opening the new version: remove exactly the two Operator records from `state.json`, with a
dated copy kept beside it, using only what macOS ships. That command already exists as
`scripts/reset-operator-state.sh` (step 0d wrote and tested it, and the maintainer used it while
switching builds during the refactor); the note carries the same command for people who have only
the app. The release notes also tell a person, in
plain words, what changed for them. A right note is short, concrete and in the house style of the
existing notes; a wrong one narrates the refactor, promises a migration, or offers a command that
needs Homebrew, Python or `jq`.

## Today

- `docs/release-notes/` holds one note per release that needs one, named `<YYYY-MM>-<slug>.md`;
  `2026-11-operator-signals.md` is the model: a level-one title, the prerequisite as the first line,
  then a few short paragraphs. `scripts/release.sh` does not read these files; the maintainer pastes
  the text into the GitHub release.
- `docs/workflow/release.md` has a section `## Operator format` (about line 55 today) that describes
  the broadcasts-to-signals release and says release notes must state its prerequisite. 9a pointed
  `docs/architecture.md` and `docs/operators.md` at this section.
- The workspace file is `~/Library/Application Support/AiTerm/state.json`
  (`StateStore.defaultURL`, `AiTermPaths.supportDirectory`). `StateStore.save` writes it
  pretty-printed with sorted keys and ISO 8601 dates, and keeps `state.json.backup` as the file
  before the latest save. Installed and development builds share it. The app's process is named
  `AiTerm` in both.
- The two records, by their saved keys (verify in `AppState`, `ArchivedTask` and `TaskItem` coding
  keys): the top-level `operatorSession`; `signalTask` inside each element of the top-level `tasks`
  array; `signalTask` inside the `task` object of each element of the top-level `archive` array.
  `archive` is absent from a file with nothing archived. Unknown keys elsewhere round-trip
  (`PreservedFields`), so leaving them is safe.
- Settings › Agents shows **Repair** on an agent's card when its installed driver lacks something a
  merge would write (`HarnessSettingsPane`: "Reinstall" when ready, "Repair" otherwise). Phase 1g
  stopped installing the `PostModelSwitch` hook for Claude, but an install that still has it is not
  reported for Repair: the check only asks whether every listed entry is present, and the helper
  ignores the old hook's posts. Phase 1h stopped removing AiTerm's retired `PreToolUse` hook, which
  only an install from before 0.54 can still have.

## Change

1. Confirm the promise first. Diff the Core models from the starting commit recorded under
   `## Record`, `### Phase 0` in the plan to `HEAD`:
   `git diff <start> HEAD -- app/Sources/AiTermCore | grep -nE '^[-+].*(CodingKeys|forKey: \.|case [a-z][A-Za-z]*( =|,|$))'`.
   Every saved key that was renamed or restructured must sit inside `SignalTask` or
   `OperatorSession` (or the types only they hold). A dropped key or a new optional key elsewhere is
   fine. If any other saved key changed, stop and report it.
2. Find out whether any driver needs Repair after upgrading: `git diff <start> HEAD -- compat/drivers/`
   shows what the drivers install now. An agent needs Repair only when its driver gained or changed
   an entry (then today's install lacks it and its card shows Repair). An entry that was only
   removed needs nothing. Name the agents that need it in your report; expect none.
3. Write `docs/release-notes/<YYYY-MM>-major-release.md`, with the year and month in which you write
   it. Shape:
   - Title: `# Major release`. First line, bold: quit AiTerm and run the reset command in
     **Upgrade** before opening this version.
   - `## Upgrade`, numbered:
     1. Let each driven task reach a point you are happy to pick up yourself. Quit AiTerm, the
        installed app and any development build. iTerm2 and its windows can stay open.
     2. In Terminal, run the reset command (a fenced shell block in the note; the exact text is
        below). It saves a dated copy of `state.json` beside it, then removes the Operator's saved
        records and nothing else. If AiTerm is still running, it says so and changes nothing.
     3. Install the new version and open it.
     4. Open Settings › Agents. If a card shows **Repair**, press it (name the agents step 2 found; if
        it found none, say the cards need nothing). Add one sentence: an install from before 0.54 may
        still have AiTerm's old `PreToolUse` entry in Claude's `settings.json`; AiTerm no longer
        removes it, so delete that entry by hand.
     5. What to expect: projects, tasks, terminals, the Archive, conversations, signals and their
        seen items are all there. Tasks the Operator drove are ordinary tasks of yours, and a task
        you had taken over stays yours: no signal continues it. A worker
        still running keeps its branch guard until it ends. The Operator starts a fresh chat at its
        next match; close the old chat's window in iTerm2 yourself. Items a signal already started
        are not started again.
   - `## What changes` with short groups (Windows, Tasks, Sidebar, Sheets and keys, Operator,
     Removed), one plain sentence per item, from the list under Decisions.
   - `## Going back`: the dated copy is for the previous version only. Quit AiTerm, copy the dated
     file over `state.json`, install the previous version.
4. Rewrite `## Operator format` in `docs/workflow/release.md` for this release: the Operator's
   saved records changed shape with no migration; the release notes carry the reset command, which
   removes `operatorSession` and every task's and archived task's `signalTask` after a dated copy;
   every other saved key loads unchanged; Repair only for an agent whose driver gained an entry. Drop the
   broadcast paragraphs; keep the sentence that current fixtures carry explicit provenance.

The reset command is the one line in `scripts/reset-operator-state.sh` (0d). Copy it from the script
into the note's fenced block verbatim; do not retype or reword it. For reference, it reads:

`F="${1:-$HOME/Library/Application Support/AiTerm/state.json}"; if [ $# -eq 0 ] && pgrep -qx AiTerm; then echo "Quit AiTerm first."; else cp -p "$F" "$F.before-reset-$(date +%Y%m%d-%H%M%S)" && osascript -l JavaScript -e 'function run(argv) { ObjC.import("Foundation"); const path = argv[0]; const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null); if (text.isNil()) throw new Error("Cannot read " + path); const state = JSON.parse(text.js); const reset = task => { if (task.signalTask && task.signalTask.takenOver === true) task.takenOver = true; delete task.signalTask; }; delete state.operatorSession; (state.tasks || []).forEach(reset); (state.archive || []).forEach(entry => reset(entry.task)); const saved = $(JSON.stringify(state, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null); if (saved === false) throw new Error("Cannot write " + path); return "Removed the Operator records from " + path; }' "$F"; fi`

It uses only `pgrep`, `cp`, `date` and `osascript` with JavaScript for Automation, all part of
macOS. Before it removes a task's `signalTask` it copies one fact out of it: a task whose record
says `takenOver` gets the task's own `takenOver` mark (the key step 4e reads), so no signal
continues a task a person took over. It was tried on scratch files while the plan was written:
exactly `operatorSession` and every `signalTask` are removed, a taken-over task and a taken-over
archived task carry `takenOver`, other tasks gain nothing, and `null` values, nested arrays and
key order survive; a file without `archive` works. If the script's line differs from the one
above, the script wins: report the difference.

## Keep

- `docs/release-notes/2026-11-operator-signals.md` unchanged.
- The rest of `docs/workflow/release.md` (pipeline, signing, the "When the run stops" steps).
- The reset command's three guards: the running-app check, the dated copy before any write, and the
  atomic write.

## Decisions already taken

- What changes, for the note (rewrite each as one plain sentence for a person):
  - Windows: closing a task's window asks nothing; the row stays and choosing it reopens the window
    with its conversations resumed. Closing a terminal's window keeps its row; choosing it opens a
    fresh shell. After iTerm2 restarts, nothing reopens by itself; a window opens when you choose
    its row. Moving the selection with the arrow keys never opens a window. The iTerm2 banner says
    when iTerm2 isn't running, with Open iTerm2.
  - Tasks: Remove asks everything before it acts, including whether to delete a branch with commits
    not on its base; without the helper it refuses, as Archive does. Take Over makes the task fully
    yours: an ordinary task, restored and removed like one, its resumed conversations without the
    worker branch guard.
  - Sidebar: Return on an empty heading runs its main command (New Task… for a project, Edit
    Signal… for a signal). "Pull <branch>" names the default branch git reports, asked when the project's heading appears and after each pull. Pause and
    Resume live on the Operator heading's menu with one wording. A switched-off signal offers
    "Switch On". The selection follows its row: a row that disappears is deselected and a row hidden
    by a fold hands the selection to its heading.
  - Sheets and keys: Cancel on every step; Escape closes an open list, then cancels. Return commits
    Rename, Add Divider and New Terminal. Add Project shows the chosen folder as a line with
    Choose…. New Task's Base branch is a filtered field, as in New Review. The "isn't installed"
    note shows once, only when no agent can run. New Signal shows agent readiness as advice and
    never disables Create for it. One wording for a saved model that is no longer offered, and a
    disabled Continue says why.
  - Operator: an Oracle check whose settings changed mid-way is discarded and run again, for every
    use. Workers may run `git merge` locally. The Operator's shell gate names tools that exist.
  - Removed: Find a Fix and its Settings switch Help with problems. A failed rebase or a diverged
    pull still shows its banner with its own recovery.
- The note does not mention internal changes (owners, wire fields, test fixtures) or the version
  number; the maintainer adds the version when releasing.
- `state.json.backup` needs no step: the app only reads it when the primary is missing or damaged,
  and the first save after the upgrade replaces it with the reset file.
- A driven task that becomes ordinary can still be continued later by a different signal whose item
  matches it, as any task of yours can; the same signal does not start it again because its seen
  item is kept. A task that was taken over is never continued: the reset carries its mark. No note line is needed beyond "items a signal already started are not started
  again".
- The Operator's journals and activity log under Application Support stay on disk; nothing needs
  them removed.
- If step 1 or step 2 finds something this brief does not expect, stop and report; do not widen the
  reset command.

## Tests

None. The command is rehearsed in 9c against the copy kept in `build/refactor-before/`.

## Proof

- Plain `scripts/test.sh` reports a docs-only change and exits.
- The fenced block in the note is byte-identical to the command line in
  `scripts/reset-operator-state.sh` (compare them with a shell one-liner and say how in your report;
  `grep -F 'pgrep -qx AiTerm' docs/release-notes/*-major-release.md` finds it once).

## Done when

- `docs/release-notes/<YYYY-MM>-major-release.md` exists with Upgrade, What changes and Going back.
- `docs/workflow/release.md`'s Operator format section describes this release and no broadcasts.
- Your report lists step 1's result (no saved key changed outside the two records, or what did) and
  the agents step 2 named.
- No em dash in either file.

## Not in this step

- Running the command on the rehearsal copy and loading it with the final `StateStore` (9c).
- The docs sweep (9a) and the release itself (`scripts/release.sh` is the maintainer's).
