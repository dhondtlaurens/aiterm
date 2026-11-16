# 2d. The Codex config editor owns its marked block and nothing else

Implementer: Opus 5.5, high. Depends on: phase 1 (all of 1a to 1j; 1g and 1h change the Claude half of
`HookConfigTests`, 1j renames names `CompatContractTests` uses), and 2a to 2c before it in phase 2.
Audit: PL F4.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The to-do says the editor "removes its own entries by marker". Read literally, everything between
the markers is AiTerm's. That would delete data Codex writes there: Codex edits `config.toml` with a
format-preserving editor that adds new tables at the end of the document, before a trailing comment,
and AiTerm's end marker is that trailing comment. Approval records (`[hooks.state."...:stop:0:0"]`,
present in a real config) and a server added with `codex mcp add` therefore land between the
markers. This brief defines AiTerm's own entries as AiTerm's tables between the markers (by table
path), keeps every other table found there, and keeps today's rule that the server table named
`aiterm_hooks` is AiTerm's wherever it stands. One input of one existing test (a block whose begin
marker is gone) stops being repaired; see Decisions.

## Why

AiTerm writes a block of hooks and one MCP server into the person's own `~/.codex/config.toml`. The
file is real user data: projects, servers, plugins and Codex's own approval records live there, so a
lossless statement splitter and a conflict scan are justified, and a regression writes a file Codex
refuses to load. Around that core, the 0.15 release added a parser for all four TOML string forms
(escapes, `\u`, TOML 1.1 forms), a reconciliation that hunts AiTerm hooks moved outside the markers
by reading their string values, and a model list read from the same file when Codex has no model
cache. None of the three traces to a seen case. The end state: the editor finds its marked block,
replaces it in place, or removes AiTerm's tables from it and appends a fresh block; it refuses an
unbalanced file and a user table that TOML forbids extending; every byte it does not own is kept.
No string value is ever parsed.

## Today

- `app/Sources/AiTermCore/Hooks/TOMLStatements.swift`. `scan` splits text into top-level
  statements losslessly (newlines inside strings, arrays and inline tables do not split; comments
  stay in `text`, out of `code`) and reports `balanced`. `parsed` and `tables` group statements into
  `Table`s at each header. `Statement` offers `header`, `keyPath`, static `path` (splits a dotted key
  and unquotes each part by calling `string`), private `equals`, and the string machinery: `value`,
  `key`, `assignment`, static `string` (about line 56), `lineEndingBackslash`, `escape`.
  `Table.values` (about line 138) collects `assignment`s.
- `app/Sources/AiTermCore/Hooks/CodexHookConfig.swift`. `events` (six), `begin`/`end` markers,
  `block(hookURL:)` (the canonical text, frozen in `compat/drivers/codex-hooks.toml`),
  `containsOwnedTables`, `conflict(in:tables:)`, `merge(_:hookURL:tables:)` (about line 68: a
  pristine-block shortcut that compares the span with the block rebuilt from the old URL read
  through `values["url"]`, then a reconciliation with `parents`, `hooks`, `children` maps over
  `[[hooks.<event>]]` entries), private `blockRange`, and private extensions `Statement.marker`,
  `Table.owned` (reads `type`, `server`, `tool`, `command` through `values` and regexes the
  command), `Table.textWithoutMarkers`.
- `app/Sources/AiTermCore/Harnesses/CodexDriver.swift`. `probe` refuses through `unmergeable`
  (unbalanced: "cannot be parsed"; conflict: "sets <key> in a form AiTerm cannot merge"), reports
  `.current` when `merge(text) == text`, else `.outdated` when `containsOwnedTables`, else
  `.missing`. `install` refuses the same way, backs up and writes through `UserConfigFile`.
- `app/Sources/AiTermCore/Harnesses/ModelFiles.swift`. `codexModels(modelsCacheJSON:configTOML:)`
  reads `models_cache.json`; when it yields nothing it calls `codexConfigModels(configTOML:)`
  (about line 139), the only user of `keyPath` plus `value` outside the editor, which reads `model`
  and `profiles.*.model`, falling back to `gpt-5.6`. `codexModels(home:)` reads both files;
  `codexSources(home:)` lists both. Caller: `Harness+Agents.swift` (the Codex `models:` row).
- Callers, proved by `rg -n "TOMLStatements|CodexHookConfig|codexConfigModels|codexModels|\.assignment\b|\.values\b" app/Sources app/Tests`:
  production users are `CodexDriver`, `CodexHookConfig`, `ModelFiles`, `Harness+Agents`. Tests:
  `HookConfigTests`, `TOMLStatementsTests` (two suites), `ModelFilesTests`, `HarnessDiagnosticsTests`
  (`ownedStaleClaudeAndCodexIntegrationsCanBeReinstalled`), `CompatContractTests` (`codexBlock`,
  `codexsModelCacheReadsAsItsOwnModelsAndEfforts`).

## Change

1. `TOMLStatements`: delete `Statement.value`, `key`, `assignment`, `string`, `lineEndingBackslash`,
   `escape` and `Table.values`. `Statement.path` keeps splitting at dots outside quotes; a part
   wrapped in matching `"` or `'` loses its quotes, with no escape decoding; other parts are
   trimmed of spaces. Keep `scan`, `parsed`, `tables`, `statements`, `header`, `keyPath`, `equals`,
   `Table.statements`, `path`, `array`, `text`. Update the type's doc comment to say it reads
   structure only, never values.
2. `CodexHookConfig`: rewrite ownership and `merge` as follows, with the doc comment saying exactly
   this.
   - A *marked span* runs from a begin-marker statement to the next end-marker statement; a begin
     marker with no end after it runs to the end of the file. An end marker with no begin before it
     belongs to no span. Markers are comment-only statements, as `marker` decides today, so a
     marker inside a string is data.
   - An *AiTerm table* is a table whose path is `mcp_servers.aiterm_hooks` or below it, anywhere in
     the file, or a table that starts inside a marked span and whose path is `hooks.<one of the six
     events>` or below it. Every other table is the person's or Codex's, wherever it stands.
   - *In place*: when the file has exactly one begin and one end marker, begin first, and every
     statement between them belongs to an AiTerm table or is blank, the text from the start of the
     begin marker's line to the end of the end marker's text is replaced by `block(hookURL:)`.
     Nothing outside that range changes.
   - *Rebuild*, otherwise: every marker statement is dropped; every AiTerm table is dropped except
     its standalone comment statements (today's rule: a comment after an owned table may document
     the next table); every other table is kept with its exact text; then, as today, a newline if
     the kept text does not end in one, a blank line if it is not empty, the block and a newline.
   - `containsOwnedTables` becomes "the file has a marker statement or a table at
     `mcp_servers.aiterm_hooks`" (rename it `hasAiTermEntries`); `CodexDriver.probe` uses it for
     `.outdated` versus `.missing`.
   - Delete `blockRange`'s old-URL comparison, `Table.owned`, the `parents`/`hooks`/`children`
     reconciliation and `textWithoutMarkers` if nothing else needs it.
3. `conflict(in:tables:)` keeps its logic and its strings; it now sees unquoted parts through the
   simplified `path`. `CodexDriver.unmergeable` and its two reasons are unchanged.
4. `ModelFiles`: delete `codexConfigModels`. `codexModels(modelsCacheJSON:)` loses `configTOML`;
   with no usable cache it returns one model, `gpt-5.6`, with `codexEfforts` and Codex's default
   effort, exactly as the old last resort built it. `codexModels(home:)` reads only
   `.codex/models_cache.json`; `codexSources(home:)` lists only that file. Fix the doc comment.

## Keep

- The lossless splitter and `balanced`: Codex refuses an unbalanced file, so the editor must not
  append to one (`unbalancedTOMLIsRefusedByTheCodexDriver`).
- `conflict`'s whole table of refusals, including a sub-table that implies an event table: TOML
  forbids `[[hooks.Stop]]` after `[hooks.Stop]`, `hooks.Stop = [...]` or `[hooks.Stop.x]`, so Codex
  would refuse the whole file.
- `block(hookURL:)` byte for byte: `CompatContractTests` freezes it in `compat/drivers/`.
- The Stop hook as an MCP tool and the other events as async curl posts: a worktree removed before
  Stop made curl fail to spawn.
- `UserConfigFile` (symlinks followed, dangling links refused, one backup, no write when unchanged).
- The server table named `aiterm_hooks` as AiTerm's anywhere: a copy left outside the markers plus
  the appended block would define the table twice, which Codex refuses.

## Decisions already taken

- A table Codex or the person put between the markers (an approval record, another MCP server, a
  profile) is kept; the repair moves it out of the span, before the appended block, with its bytes
  unchanged. The next merge then finds a pristine span and is stable.
- AiTerm hooks that sit outside any span are the person's: left in place. If Codex ever moves them,
  hooks fire twice; that has never been seen and is accepted.
- A file whose begin marker is gone (end marker only): its old hook tables are outside any span and
  stay; the server table is removed by name; the block is appended. Not seen; accepted.
- A key-value line inside the span that belongs to no AiTerm table, or a comment there other than
  a marker, sends the file to the rebuild, which keeps it.
- A child table of a removed AiTerm `[[hooks.<event>]]` entry, written by someone else after the end
  marker: cannot plausibly happen (nobody writes a child without its own parent); not handled.
- No new check of the merged output: the refusals run on the input as today.
- CRLF files: markers are compared trimmed, as today; the in-place block is written with `\n`.
- A Codex install without `models_cache.json` now offers only `gpt-5.6` in Settings; its config's
  `model` and profiles are no longer read.
- Quoted key parts with escapes are not decoded: no name AiTerm compares with (`hooks`, the six
  events, `mcp_servers`, `aiterm_hooks`) can be written with an escape in a real config.

## Tests

Every one of these must pass unchanged; they are the editor's guarantees:

- Refusal: `aCodexEventSetInAFormTOMLCannotExtendIsRefused` (all six arguments, including the quoted
  `"hooks" . 'UserPromptSubmit'`), `aSubTableThatImpliesTheEventIsATableIsRefused`,
  `unbalancedTOMLIsRefusedByTheCodexDriver`, `bracketsInStringsAndCommentsAreBalanced`,
  `aCodexConfigThatIsNotUTF8IsLeftAloneAndReported`, `aDanglingSymlinkIsLeftAloneAndReported`.
- No false refusal: `otherHookAssignmentsStillMerge`, `aSubTableAfterItsArrayParentIsNoConflict`.
- Lossless and stable: `testCodexMergeAppendsOnceAndReplacesOwnBlock`,
  `codexRepairDoesNotInterpretStringsOrCommentsAsOwnedHooks`,
  `codexRepairAcceptsCRLFAndMultilineStringsEndingInQuotes`,
  `codexContentAfterTheBlockNeitherOutdatesNorMovesIt`,
  `testCodexMergeHandlesEndMarkerBeforeBeginWithoutCrashingAndKeepsUserContent`,
  `testCodexMergeStripsOrphanBeginMarkerAndKeepsUserContent`,
  `symlinkedConfigFilesStaySymlinksAndTheirTargetsAreMerged`,
  `testClaudeAndCodexInstallersAreIsolatedAndIdempotent`,
  `testPerHarnessInstallationProbesReadOnlyTheirOwnConfiguration`; in `HarnessDiagnosticsTests`,
  `ownedStaleClaudeAndCodexIntegrationsCanBeReinstalled`; in `CompatContractTests`,
  `theCodexDriverTemplateIsWhatTheAppMerges`.

Adjust:

- `codexRepairRemovesDuplicateBlocksAndHooksWithMissingMarkers`: drop the third input (begin marker
  removed); keep two blocks and the missing end marker.
- `codexRepairFindsMovedHooksAndPreservesApprovalRecords`: rename to
  `anApprovalRecordBetweenTheMarkersSurvivesARepair`; its input loses the moved-out
  `[[hooks.SessionStart]]` entry; keep the approval-record, single-`[[hooks.Stop]]` and stability
  expectations, and add that the record's text appears unchanged before the new block.
- `TOMLStatementsTests`: `tablesSplitAtHeadersOnly` keeps its paths and lossless-join checks, drops
  the `values` lines; `keyIsTheAssignedNameEvenForNonStringValues` becomes a `keyPath` check
  (`[["type"], ["command"], ["padding"], ["note"]]`); `aHeaderMayCarryATrailingComment` and
  `aMultiLineLiteralStringMayHoldQuotesOfItsOwn` check paths and statement split instead of values;
  `anInlineTableSpanningLinesIsOneStatement` uses `keyPath`.
- `ModelFilesTests.testCodexModelsFallBackToConfigProfiles` becomes "no cache, or an empty one,
  offers gpt-5.6 alone"; `CompatContractTests` calls `codexModels(modelsCacheJSON:)`.

Delete (behaviour deleted by this step): `codexRepairKeepsForeignChildrenAfterInterveningTables`
(reconciliation outside the markers), `stringReadsEveryTOMLForm`,
`stringRejectsWhatIsNotOneTOMLString`, `keyIsNilForADottedKeyButValueStillReadsIt`,
`testCodexConfigModelIdsStopAtTheirQuotes`, `testCodexConfigModelsAreReadByKeyPath`.

Add, test first: "a server added between the markers is kept and the block is still replaced once"
(a `[mcp_servers.other]` table inside the span survives, one block results, a second merge changes
nothing); "a stale block is replaced in place" (an old block text with one event missing between
intact markers, followed by a profile, is replaced where it stands and the profile stays after it).
No fixture is re-recorded: the block's text does not change.

## Proof

- `scripts/test.sh swift -- --filter 'HookConfigTests|TOMLStatements|ModelFilesTests|HarnessDiagnosticsTests|CompatContractTests'`
- Then plain `scripts/test.sh`, started in the background.
- Not yours: `scripts/compat-check.sh` after phase 2 is the maintainer's.

## Done when

- `rg -n "func string\(|lineEndingBackslash|\.assignment\b|var values|codexConfigModels|configTOML|\bowned\b|children\[" app/Sources/AiTermCore/Hooks/TOMLStatements.swift app/Sources/AiTermCore/Hooks/CodexHookConfig.swift app/Sources/AiTermCore/Harnesses/ModelFiles.swift app/Sources/AiTermCore/Harnesses/CodexDriver.swift` returns nothing.
- `rg -n "codexConfigModels|configTOML" app` returns nothing.
- `rg -n "\.values\[" app/Tests/AiTermCoreTests/TOMLStatementsTests.swift app/Tests/AiTermCoreTests/HookConfigTests.swift` returns nothing.
- Every test listed as a guarantee above passes unchanged; plain `scripts/test.sh` is green.
- `compat/drivers/codex-hooks.toml` is untouched (`git diff --stat compat` is empty).

## Not in this step

- The hook port as a constant: left out of the plan.
- The Claude driver (`ClaudeSettings`) and its `PostModelSwitch` and retired-hook cleanup: 1g, 1h.
- Headless launches and effort constants in the agent table: 8i.
