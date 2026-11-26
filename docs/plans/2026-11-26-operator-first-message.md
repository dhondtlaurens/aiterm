# Operator: one-line first message, no snags, update scripts at any version

## Goal

A fresh or renewed Operator chat opens with a wall of pretty-printed JSON: the full status digest
(21.6 KB on the maintainer's machine). Then the brief has the Operator call `run_status`, which
returns the same digest again. Watching the chat start is confusing, and the chat reads its state
twice. About 70% of every status (the first message and each `run_status` without a task) is
`snags`. These are reports no screen has shown since broadcasts were removed (`6e8f89b8`), so the
only reader left is the Operator. Goal: the chat opens on one line and reads its state once, and
snags are gone.

## Approach

- **First message.** It becomes one fixed line telling the Operator to call `run_status`. There is
  no JSON and no temp file: `run_status` already returns everything the digest held, plus
  `appIssues`. The digest is no longer built for the launch. The brief's "Keep context durable"
  paragraph says the first message only asks for `run_status`.
- **Snags.** They are removed completely: the `report_snag` tool (fourteen tools become thirteen),
  `OperatorSnag`, the saved `operatorSession.snags`, the digest's `snags`, the activity line, and
  the brief's mentions. The brief's "report the snag if possible" line becomes "stop retrying it
  and ask in chat".
- **Update scripts at any version.** Grilling found that "major only" is policy and not something
  the mechanism needs: `WorkspaceUpdater` already orders scripts by full `major.minor.patch`, and
  `release.sh` only requires a release with a new format to be released as that format's version.
  The rule becomes: a format change needs a script, versioned as the release that ships it, at any
  level. The release note still says the workspace cannot go back.
- **Snags in the saved workspace.** Dropping them is a format change, so this branch adds
  `Update2_1_0`, which removes `operatorSession.snags`. The next release is 2.1.0.

Decided while grilling: one fixed line rather than a temp file or a summary line; snags removed in
total; scripts allowed at minor and patch versions, so snag removal ships as 2.1.0.

## Files

**First message**
- Modify `app/Sources/AiTermCore/Operators/Signals/OperatorLaunch.swift`: `firstMessage` returns
  the fixed line, and `prepare` no longer takes a digest. The brief changes: the "Keep context
  durable" sentence, "fourteen" becomes "thirteen", the report_snag sentence and "report the snag"
  wording go, and so does the doc comment that mentions "the first JSON message".
- Modify `app/Sources/AiTerm/Operators/OperatorSessionKeeper.swift` and the `open` port it calls,
  with its live implementation: stop building a digest for the open.
- Modify `app/Tests/AiTermTests/Operators/SignalSessionKeeperTests.swift`,
  `SignalOperatorLifetimeTests.swift` and `OperatorPauseTests.swift`: their `open` closures take
  the session only. The question-retention checks (`SignalSessionKeeperTests.swift:117–120`,
  `:144–145`) move from the digest to the saved session read inside the closure, which is what
  the fresh chat's first `run_status` reads.

**Snags**
- Modify `app/Sources/AiTermCore/Operators/OperatorModels.swift`: delete `OperatorSnag`.
- Modify `app/Sources/AiTermCore/Operators/Signals/OperatorSession.swift`: drop `snags` and its
  prune line.
- Modify `app/Sources/AiTermCore/Operators/Signals/OperatorDigest.swift`: drop `snags`.
- Modify `app/Sources/AiTermCore/Operators/Signals/OperatorTool.swift`: drop `.reportSnag`.
- Modify `app/Sources/AiTerm/Operators/SignalOperatorToolHandler+Calls.swift`: drop the
  `.reportSnag` case.
- Modify `app/Sources/AiTerm/Operators/OperatorActivity.swift`: drop "recording a snag".
- Modify `daemon/aitermd/signal_tools.json`: drop `report_snag`.

**Saved workspace and update scripts**
- Create `app/Sources/AiTermCore/Updates/Scripts/Update2_1_0.swift`: removes
  `operatorSession.snags`, idempotently.
- Modify `app/Sources/AiTermCore/Updates/UpdateScripts.swift`: register `.update2_1_0`; reword the
  "minor and patch releases never change the format" comment and the "1.5.0 or N.0.0" note.
- Modify `app/Sources/AiTermCore/Updates/UpdateScript.swift`: the doc comments no longer say
  "major" or "always a major's `.0.0`".
- Modify `scripts/release.sh`: reword the comment at lines 25–27. The check itself stays.
- Modify `docs/workflow/release.md` (lines 12, 46, 55) and `CLAUDE.md`'s workspace invariant: a
  script is versioned as the release that ships it, at any level. `CLAUDE.md` is the symlinked
  original; edit the target, not the link.
- Create `docs/release-notes/2026-11-operator-first-message.md`: the Operator opens on one line,
  snags are gone, and the workspace update cannot go back. Use the shape of
  `2026-11-update-scripts.md`.
- Modify `docs/architecture.md:139`: drop "one hundred snags".
- Modify the tool count, fourteen to thirteen, in `docs/architecture.md:125`,
  `docs/testing.md:103`, `docs/daemon-protocol.md:75` and `daemon/README.md:74`.

**Contract fixtures** (deliberate contract changes, each recorded in `PROVENANCE.md`)
- `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/brief.md`: the new brief.
- `…/operator-signals/tools.json`: a byte copy of the new `signal_tools.json`.
- `…/operator-signals/state.json`: re-recorded with
  `AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests`. It loses
  `snags` and is stamped `2.1.0`.
- `…/operator-signals/PROVENANCE.md`: a dated entry: thirteen tools, the one-line first message,
  snags removed, and the capped live evaluation not rerun.
- `app/Tests/AiTermCoreTests/Updates/Fixtures/state-1.5.0.json` stays frozen.

## Proof

**Tests**
- `SignalOperatorLaunchTests`: `prepare` writes `first-message.md` as exactly the one line, with
  no `{`.
- `SignalOperatorContractTests`: the tool count is 13, and the brief golden matches.
- `daemon/tests/test_operator_session.py:74` and `test_operator_surface.py:201`: the tool count
  is 13.
- New `Update2_1_0Tests`:
  - a 2.0.0 workspace with snags loses them, and nothing else changes;
  - running the step twice changes nothing more;
  - a workspace without `operatorSession` is untouched.
- `Update2_0_0Tests.the150GoldenBecomesThe200Golden` becomes "the 1.5.0 file becomes the current
  golden". Its plan expects steps `[2.0.0, 2.1.0]`, and the run ends byte for byte on the
  re-recorded `state.json`.
- `WorkspaceUpdaterTests.theShippedScriptsAreMajorsInOrder` becomes "in order, unique, after the
  baseline". The `.0.0` condition goes.
- Gate: `scripts/test.sh`. Before merging: `require-full`, or `scripts/test.sh all`.

**Live check** (for the maintainer; agents never run the app)
- With `scripts/run-dev.sh`, start the Operator fresh. The chat opens on the one line, and its
  first tool call is `run_status`.
- `first-message.md` in `~/Library/Application Support/AiTerm/operators/operator/` is that line.
- The live `state.json` says `"version" : "2.1.0"`, has no `snags`, and
  `state.json.before-update-2.0.0` exists.

## To-dos

- [ ] One-line first message. Change `firstMessage`, drop the digest from the open path, update
      the brief's first-message paragraph and the brief golden with a PROVENANCE entry, adapt the
      keeper, lifetime and pause tests' `open` closures, and add the launch test.
- [ ] Update scripts at any version. Relax the shipped-scripts test, the doc comments, the
      `release.sh` comment, `release.md` and the `CLAUDE.md` invariant.
- [ ] Remove snags from the tools and the status. Do the tool enum, handler, activity line,
      `signal_tools.json` and `tools.json` golden, the digest field, the brief wording and the
      golden, the tool counts in the Swift and daemon tests, and the docs that count tools
      (`architecture.md`, `testing.md`, `daemon-protocol.md`, `daemon/README.md`).
- [ ] Remove saved snags with `Update2_1_0`. Drop the model and the session field, add and
      register the script with its tests, update the 1.5.0→current golden test, re-record
      `state.json`, write the PROVENANCE entry and the release note.
- [ ] Gate green, then the maintainer's live check.
