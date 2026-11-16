# 5h. Regroup Core `Signals/` by concept, with the same bytes on disk

Implementer: Codex `gpt-6.1-sol`, high effort. Depends on: phases 1 to 4 and steps 5a to 5g (in
particular 1d, 1j, 5a, 5b and 5f, which delete or reshape files listed here). Audit findings:
operator-core F7 part a, F10, F12, F13 and F14
(`docs/research/2026-11-16-greenfield-audit/operator-core.md`).

## Why

`app/Sources/AiTermCore/Operators/Signals/` grew one small file per type while signals were built:
fifteen files are under 30 lines, several hold one 3 to 9 line type, and the folder comes down to
about eight concepts. Six saved enums hand-write the same `{"kind": …, "value": …}` decode and
encode with an `unknown` fallback, and four open string enums repeat the same raw-value switch and
Codable lines. The activity log and the task journals are two one-line-per-record JSON files with
two different append and read rules. A few files live under `Operators/` though they are agent or
task facts (delivery checks, `ClosingWait`, the merged-branch check), the source readers sit in a
second top-level `Signals/` folder, and a driven task row's Operator wording is built in an app
view model. This step moves code to where a reader looks for it. It changes no type name, no
behaviour and no saved byte; `SignalSavedFormatTests` and a new per-case byte test prove the last.

## Today

Described as after 5g. By then 1d deleted `SignalBranchRef.swift`, the `branch` item and the
`baseline` seen state; 1h deleted the earlier choice-block upgrade; 1j merged `OperatorCommand`,
`SignalOperatorCommand` and `SignalOperatorCommand+Launch` into `OperatorLaunch` and renamed
`SignalOperatorTool` to `OperatorTool`; 5a deleted `SignalEdge.swift`; 5b made `SignalTask` hold its
current `SignalStage` whole; 5f deleted `OperatorHandover.swift` and added
`OperatorSession.Lifecycle` and `OperatorSession.chatIsIdle` to `OperatorSession.swift`. List the
folder first (`ls app/Sources/AiTermCore/Operators/Signals`) and stop and report if it differs
from this list by more than those changes.

Files in `app/Sources/AiTermCore/Operators/Signals/` then: `AgentChoiceNeed.swift`
(`AgentChoiceNeed`, `AgentChoiceRecord`), `AppState+Signals.swift`, `DoneCheck.swift` (`DoneCheck`,
`SignalWaitFacts`), `DoneWhen.swift`, `FreshStartPolicy.swift`, `ItemRef.swift`,
`JiraConditions.swift`, `JournalText.swift`, `JQL.swift`, `MatchDecision.swift`,
`OperatorDigest.swift`, `OperatorSession.swift`, `RequestConditions.swift`, `Signal.swift`,
`SignalAction.swift`, `SignalFinish.swift`, `SignalMatch.swift`, `SignalQuote.swift`,
`SignalRequestRef.swift`, `SignalSeen.swift`, `SignalSource.swift`, `SignalStage.swift`,
`SignalTask.swift` (`SignalTask`, `SignalWorkerReply`), `SignalTicketRef.swift`,
`SignalTransitionError.swift`, `SignalTransitions.swift`, `SignalWork.swift`,
`TaskItem+AgentChoice.swift`, `TaskJournal.swift`, `TaskPhase.swift`, and `OperatorLaunch.swift`
and `OperatorTool.swift` wherever 1j put them (`rg -ln 'enum OperatorLaunch|enum OperatorTool' app/Sources`).

Elsewhere:

- `app/Sources/AiTermCore/Operators/AgentChoice.swift` (`AgentChoice`) and `ModelChoice.swift`.
- `app/Sources/AiTermCore/Signals/Sources/`: the source readers (`JiraQueryReader`,
  `MyRequestReader`, `ReviewRequestedReader`, `ItemProjectMapper`, `SignalItem`, `SignalRead`,
  `SignalSourceReader`, `SignalAccountReading`, `SignalHostReading`, as phase 7 left them if it has
  merged). Nothing else is in `app/Sources/AiTermCore/Signals/`.
- `app/Sources/AiTermCore/Operators/DeliveryCheck.swift` (`DeliveryCheckFile`, `DeliveryReadiness`,
  `DeliveryCheck`, `DeliveryCheckWatch`), read by Settings › Agents, `MessagingChecks`,
  `SignalReadiness` and the harness files; `Operators/AgentDelivery.swift`, holding only
  `AgentVersions` after 1d.
- `ClosingWait` in `Operators/OperatorModels.swift`, used by the teardown owner (4c) and
  `ThenRunner`: `rg -ln 'ClosingWait' app/Sources`.
- `Operators/MergedBranchCheck.swift`, called once from `SignalHostIO.deleteMergedBranch` (or
  wherever 4c moved that call): `rg -n 'MergedBranchCheck' app/Sources`.
- Kind-tagged saved enums, each with a hand-written decode and encode and an `unknown(JSONValue)`
  case: `SignalSource`, `DoneWhen`, `TaskPhase`, `ItemRef`, `JournalText`,
  `OperatorSession.Lifecycle` (`rg -ln 'raw\["kind"\]' app/Sources`). Open string enums with an
  `unknown(String)` case, a raw-value switch both ways and single-value Codable:
  `SignalFinish.Then`, `RequestConditions.Event`, `SignalSeen.Disposition`,
  `AgentChoiceRecord.Decided` (`rg -ln 'case unknown\(String\)' app/Sources`).
- `Signal.encode(to:)` with its `CodingKeys` (`Signal.swift`): identical to the synthesized encoder.
- `ActivityLog.append(_:folder:)` and `ActivityLog.read(…)` (`Operators/ActivityLog.swift`; `read`
  has no source caller, only tests) and `TaskJournal.append(_:task:folder:)` and
  `TaskJournal.read(task:folder:)`. The journal repairs an incomplete trailing record before it
  appends and throws on a corrupt complete record when it reads; the activity log does neither.
  Both encode with a plain `JSONEncoder` and ISO 8601 dates, one record and a newline per line.
- `SignalSidebar.present(_:task:state:)` in `app/Sources/AiTerm/SignalSidebar.swift`: from a task's
  ordinary `TaskRow`, its signal record, the pause, its first current question and its runtime act
  (5f), it sets the row's `operatorLine`, `status` and `paused`. `TaskRow`, `OperatorLine` and
  `TaskStatus` are Core (`Sidebar/`).

Tests: `SignalSavedFormatTests` (exact bytes of `operator-signals/state.json`),
`SignalForwardCompatibilityTests`, `SignalDomainTests`, `SignalJournalRecoveryTests`,
`ActivityLogTests`, `SignalSidebarTests`, `SignalSidebarPresentTests`, `DeliveryCheckTests`,
`AgentDeliveryTests`, and the Operator app suites.

## Change

1. **Pin the bytes first.** Before moving anything, add `SavedEnumBytesTests` in
   `app/Tests/AiTermCoreTests/Operators/`: for every case of the ten enums above, including each
   `unknown` and every case with a value (`ticketStatus`, `watching`, the readers' request events,
   the lifecycle's `open`, `closing` and `revoking`), encode it with `StateStore`'s settings (pretty
   printed, sorted keys, ISO 8601 dates) and compare with a literal expected string written from
   the current code; decode each string back to the same value; and check that a kind that needs a
   value but has none still throws with its type's "Missing … value" message. It must pass on the
   unchanged code; it must not change afterwards.
2. **Add the two helpers** in `app/Sources/AiTermCore/SavedEnums.swift`, beside `JSONValue.swift`
   and `LenientRawDecodable.swift`:
   - An open-string-enum protocol: an enum lists its known cases with their saved names once and
     has `unknown(String)`; the protocol supplies `rawValue`, an `init(rawValue:)` that never fails,
     and Codable as a single string. Convert the four open string enums; each keeps its own case
     list and any `CaseIterable` it has.
   - A kind-tagged helper: decoding reads the object, takes `kind`, asks the enum for the case of
     that kind and its value (an unrecognised kind is `unknown(raw)`), and throws today's
     "Missing <Type> value" error when a value is required and absent; encoding writes `kind` and,
     when the case has one, `value`, through `JSONValue` as today. Convert the six kind-tagged enums;
     each keeps one switch from case to kind and value and one from kind and value to case.
   This is one shared protocol and one shared helper, not a protocol per enum.
3. **Delete `Signal.encode(to:)` and `Signal.CodingKeys`.** The synthesized coder writes the same
   keys; sorted output is byte-identical.
4. **One JSON-lines appender.** Add `JSONLines` in `app/Sources/AiTermCore/JSONLines.swift`: append
   one encodable value as a line to a file (the first write atomic, later ones appended, an
   incomplete trailing record truncated first, as `TaskJournal.append` does today), and read the
   complete lines of a file into values (a missing file is empty, an incomplete last line is
   ignored, a corrupt complete line throws), both with the shared encoder settings (plain, ISO 8601
   dates). `TaskJournal` keeps its file name and folder creation and calls it; `ActivityLog.append`
   calls it. Move `ActivityLog.read` (offset reading, skipping bad lines) to
   `app/Tests/AiTermTestSupport/` unchanged; it is a test reader.
5. **Regroup the files** with `git mv` where a file survives and plain moves of declarations into
   the target, keeping every type name, member, access level and doc comment. Target
   `app/Sources/AiTermCore/Operators/Signals/`, fourteen files:

| Target file | Folds in today's |
| --- | --- |
| `Signal.swift` | `Signal.swift`, `SignalWork.swift`, `SignalFinish.swift`, `DoneWhen.swift` |
| `SignalSource.swift` | `SignalSource.swift`, `JiraConditions.swift`, `RequestConditions.swift`, `JQL.swift` |
| `Item.swift` | `ItemRef.swift`, `SignalTicketRef.swift`, `SignalRequestRef.swift` |
| `MatchDecision.swift` | `MatchDecision.swift`, `SignalMatch.swift`, `SignalSeen.swift` |
| `SignalTask.swift` | `SignalTask.swift`, `SignalStage.swift`, `TaskPhase.swift` |
| `StageMachine.swift` | `SignalTransitions.swift`, `SignalAction.swift`, `SignalTransitionError.swift` |
| `DoneCheck.swift` | unchanged |
| `AgentChoice.swift` | `AgentChoiceNeed.swift`, `TaskItem+AgentChoice.swift`, `Operators/AgentChoice.swift`, `Operators/ModelChoice.swift` |
| `TaskJournal.swift` | `TaskJournal.swift`, `JournalText.swift`, `SignalQuote.swift` |
| `OperatorSession.swift` | `OperatorSession.swift` (with its `Lifecycle` and `chatIsIdle`), `FreshStartPolicy.swift` |
| `AppState+Signals.swift` | unchanged |
| `OperatorDigest.swift` | unchanged |
| `OperatorLaunch.swift` | moved here if 1j put it elsewhere |
| `OperatorTool.swift` | moved here if 1j put it elsewhere |

   Then move the readers: `git mv app/Sources/AiTermCore/Signals/Sources app/Sources/AiTermCore/Operators/Signals/Sources`
   with no content change, and delete the empty `app/Sources/AiTermCore/Signals/`.
6. **Move to real homes** (`git mv`, no content change beyond a stale comment):
   `Operators/DeliveryCheck.swift` to `app/Sources/AiTermCore/Agents/DeliveryCheck.swift`;
   `Operators/AgentDelivery.swift` to `app/Sources/AiTermCore/Agents/AgentVersions.swift`;
   `ClosingWait` out of `OperatorModels.swift` into `app/Sources/AiTermCore/Tasks/ClosingWait.swift`;
   `Operators/MergedBranchCheck.swift` to `app/Sources/AiTermCore/Tasks/MergedBranchCheck.swift`.
7. **The task row's Operator wording in Core.** Move the body of `SignalSidebar.present` into a
   Core function on `TaskRow` in `app/Sources/AiTermCore/Sidebar/OperatorLine+Task.swift`: given
   the row, the task, the workspace state and the task's runtime act, it returns the row with its
   Operator line, status and pause mark. Every string, look and status stays as it is.
   `SignalSidebar.present` calls it and nothing else.

## Keep

- Every type name, including `SignalTransitions`, `SignalAction`, `SignalTransitionError`,
  `SignalTicketRef` and `SignalRequestRef`: callers and tests name them; this step moves files only.
- Each enum's `unknown` case and the workspace's tolerance of what it does not know: the
  installed app and development builds share one `state.json`.
- The "Missing <Type> value" errors: a corrupt known kind must fail loudly, not turn unknown.
- The journal's tail repair and its throw on a corrupt complete record: a crash during an append is
  real, and `note`'s key check must not read past a corrupt record.
- `ShellGate*`, `WorkerGuard/`, `OperatorIssues`, `OperatorTiming`, `OperatorWakeEvent`,
  `OperatorProfile*`, `ActivityLog`'s `ActivityEntry`, `OperatorModels.swift`'s remaining records
  and the Oracle's Core file: other concepts, not regrouped here.
- `SignalOperatorRowValue` (the Operator row's own line) stays in the app.
- Test files stay where they are; suite names do not change.

## Decisions already taken

- **Byte identity is proven under `StateStore`'s sorted-key encoding** (the saved workspace).
  Journal and activity lines were never written with sorted keys; their JSON content stays equal,
  and their key order inside a line was never fixed.
- **The activity log gains the journal's tail repair.** A torn last line is now truncated before
  the next append instead of being glued to it. Only a crash mid-append writes one.
- **Two files may not share a name in one target.** `Operators/AgentChoice.swift` is folded into
  `Signals/AgentChoice.swift` and deleted in the same commit.
- **Phase 7 running beside this step** edits `SignalHostReading.swift` and the readers. Move the
  `Sources` folder with `git mv` and no edits in the same commit, so git's rename detection carries
  phase 7's changes when either merges. If phase 7 has an open branch with a different folder
  layout, stop and report instead of guessing.
- **`MergedBranchCheck`'s interface** (its always-equal `acceptedSHA` and `mergedHead`, its `kind`
  check) is not narrowed here; the plan moves it only.
- **A file that has already gone** (for example `MergedBranchCheck` absorbed by 4c) is skipped and
  named in your report.

## Tests

- Add `SavedEnumBytesTests` first (action 1).
- Rewrite `ActivityLogTests.appendsAndReadsInOrder` and `fiveHundredAppends` against `JSONLines`.
  Delete `aMalformedLineIsSkipped`, `aTornLastLineWaits` and `aMissingFileIsEmpty`: they tested the
  activity reader that is now test support only (the product never reads the log); the shared
  rules are covered by new `JSONLines` tests (missing file empty, incomplete last line ignored,
  corrupt complete line throws) and `SignalJournalRecoveryTests` (tail repair), which stays.
- Point test call sites of `ActivityLog.read` at the moved test-support reader.
- Do not re-record any fixture. `SignalSavedFormatTests`, `SignalForwardCompatibilityTests`,
  `SignalSidebarTests` and `SignalSidebarPresentTests` pass unchanged.

## Proof

- Iterate: `scripts/test.sh swift -- --filter 'SavedEnumBytesTests|SignalSavedFormatTests|SignalForwardCompatibilityTests|SignalDomainTests|SignalJournalRecoveryTests|ActivityLogTests|JSONLinesTests|SignalSidebarTests|SignalSidebarPresentTests|DeliveryCheckTests|AgentDeliveryTests'`.
- Snapshots: `scripts/snapshots.sh build/5h-after`, then read the Operator section poses against
  `build/refactor-before`: equal pixels.
- Then plain `scripts/test.sh`, started in the background; it builds every target, which proves no
  caller lost a moved type.

## Done when

- `ls app/Sources/AiTermCore/Operators/Signals` shows the fourteen files of the table and the
  `Sources` folder, and `app/Sources/AiTermCore/Signals` does not exist.
- `rg -n 'raw\["kind"\]' app/Sources` returns only the kind-tagged helper.
- `rg -n 'init\(from decoder' app/Sources/AiTermCore/Operators/Signals` finds none of the ten
  enums.
- `rg -n 'func encode\(to' app/Sources/AiTermCore/Operators/Signals/Signal.swift` returns nothing.
- `rg -ln 'FileHandle\(forUpdating|FileHandle\(forWritingAtPath' app/Sources/AiTermCore/Operators`
  returns nothing (the line mechanics live in `JSONLines`).
- `rg -n 'OperatorLine\(' app/Sources/AiTerm/SignalSidebar.swift` finds only the Operator row's
  lines.
- `git diff --stat` shows `operator-signals/` fixtures untouched; all suites above and plain
  `scripts/test.sh` are green.

## Not in this step

- The Operator row's line and `SignalOperatorRowValue`: phase 8 (8b) decides marks in the projection.
- Narrowing `MergedBranchCheck`, or the readers' and host protocols' shapes: phase 7.
- Any rename of a type: none is planned for these files.
