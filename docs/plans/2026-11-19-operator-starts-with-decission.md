# The Operator starts without a trust question

## Goal

The Operator's chat opens straight into its first message. Today its launch adds every project
folder with `--add-dir`. Claude 2.1.328 asks whether to trust an added folder it has no saved trust
for ("Adding a new directory: … Yes, add it / No, exit", with No selected), and it never saves trust
for the home folder ("the home folder's trust is never recorded (its trust dialog's answer holds for
one session only)"). With the home folder as a project, every Operator launch waits on that
question before it reads its first message.

## Approach

The Operator's launch adds no folder: `--add-dir` goes. Its `--allowedTools` gains `Read`, `Grep`
and `Glob`, so it still reads any project's files without a permission prompt. Its tools are only
Read, Grep, Glob and a gated Bash, so an added folder gave it nothing else: no Skill or Edit tool
uses one, and its Bash is already allowed and can read anywhere through the gate.

Decided while grilling:

- Drop `--add-dir` entirely rather than keep it for trusted folders only. AiTerm would otherwise
  have to copy Claude's trust rules (parent folders, repository roots, the home exception), which
  change between versions.
- AiTerm does not answer the dialog on the screen, and does not save trust for project folders. It
  saves trust only for the Operator's own folder, as today.
- The Oracle's headless run keeps its `--add-dir`: a headless run skips the trust question.
- Workers are untouched. A worker's own trust dialog stays the person's to answer.

Checked before planning, with `claude -p` 2.1.328 from a scratch folder: without an allow rule, Read
of a file outside the working folders is refused (interactively, a permission prompt). With
`--allowedTools Read Grep`, both tools read it.

## Files

- **Modify `app/Sources/AiTermCore/Operators/Signals/OperatorLaunch.swift`:**
  - `launchWords` loses `projectPaths` and the `--add-dir` words.
  - `--allowedTools` gains `Read`, `Grep` and `Glob`, after `mcp__aiterm__*` and `Bash`.
  - `prepare` loses its `projects` parameter.
  - The doc comments that mention `--add-dir` change to match: the type's header, the note on
    options that take several values, and the "many projects" reason in `typed`. `launch.sh` stays
    as the fallback for a line past `AgentCommand.inlineLimit`; the denials alone keep the line
    long.
- **Modify `app/Sources/AiTerm/Operators/OperatorChat.swift`:** stop passing `projects` to
  `prepare`.
- **Modify `app/Tests/AiTermCoreTests/CompatContractTests.swift`:** the `operator` and
  `operatorResume` templates are built without `projectPaths`.
- **Modify `compat/launch.json`:** recorded again with `AITERM_RECORD_COMPAT=1`, a deliberate change
  (docs/testing.md). No new live capture follows, although docs/testing.md asks for one after a
  recorded change: the capture runs only Claude's `task` and `challenge` templates
  (`daemon/tools/compat_capture.py`, `capture_claude` and `claude_headless`), never `operator` or
  `operatorResume`, so it would capture nothing this change touches. What the capture proves for
  the Operator's line, that every flag is in `claude --help`, still holds: the launch gains no flag.
- **Modify `app/Tests/AiTermCoreTests/Operators/SignalOperatorLaunchTests.swift`:** the new test
  below; the existing calls drop `projects: []`.
- **Modify `docs/operators.md`:** one sentence saying the chat reads your project folders without
  adding them to its session, so it opens without a trust question.

## Proof

- **New test** in `SignalOperatorLaunchTests`, written against the new API (no project input): the
  launch words for a fresh and a resumed Operator (`launchWords(model:effort:folder:resuming:)`), and
  the command `prepare` returns, hold no `--add-dir`. The `--allowedTools` values are
  `mcp__aiterm__*`, `Bash`, `Read`, `Grep` and `Glob`, and `--strict-mcp-config` is still the last
  word. It failed on the code before this change, where every launch passed `--add-dir` per project
  and allowed only `mcp__aiterm__*` and `Bash`; written first against the new signature, it started
  as a compile failure.
- **Existing suites:** `CompatContractTests` passes on the recorded template, including its check
  that every flag the app passes is in the CLI's captured help.
- **Live check in an iTerm2 tab**, from a scratch folder inside this worktree (trusted through the
  repository):
  - `claude --model haiku --tools Read,Grep,Glob,Bash --add-dir ~ --allowedTools Read Grep Glob --strict-mcp-config "Use Read on ~/Library/Application Support/AiTerm/hook-port and print its first line"`
    shows "Adding a new directory" for the home folder: the bug.
  - The same line without `--add-dir ~` opens with no dialog and no permission prompt, and prints
    the port number.
  - Close the tab afterwards.
- **Test runs:** `scripts/test.sh swift -- --filter "SignalOperatorLaunch|CompatContract"` while
  iterating, plain `scripts/test.sh` before the commit, and `scripts/test.sh all` once before
  merging to `main`.

## To-dos

- [x] Write the new launch test and see it fail.
- [x] Remove `--add-dir` from the Operator's launch, allow Read, Grep and Glob, drop `projects` from
      `prepare` and its caller, and update the comments; the test passes.
- [x] Record `compat/launch.json` again; `CompatContractTests` passes.
- [x] Add the sentence to `docs/operators.md`.
- [x] Run the live iTerm2 check: the dialog with `--add-dir ~`, none without it.
- [ ] Plain `scripts/test.sh` passes (done); commit (the review step).
