# 1d. Core Operator leftovers

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1b (it removes `ChallengeLaunch.threadPrompt`; this step
removes the other prompts) and 1a (both edit `operator-signals/PROVENANCE.md`). Comes from: OC F1, F3, F8;
RT F6 (the one port field below).

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

- The plan says `StallWatch`'s "one live rule moves into the transcript reader". It does not: the rule is
  `StallWatch.isCallRunning`, and its only caller is `WorkerTranscript.OpenCalls.pruned`, which belongs to
  the open-call reader that nothing calls (`grep -rn "openCalls(" app` finds no caller, no test). So nothing
  moves. This brief deletes `StallWatch.isQuietWhileWorking` (no caller) and keeps `isCallRunning` and
  `OperatorTiming.openCallMinutes` alive for exactly one more step; step 1e deletes the open-call reader,
  `StallWatch.swift` and `openCallMinutes` together.
- The plan lists "unread `OperatorTiming` constants". Four of the audit's eighteen are not unread:
  `wakeCoalesce` and `jiraSearchBudget` are read by `OperatorPorts` fields that step 1e deletes, and
  `finishReplyBudget` is read by an `OperatorPorts` field that this brief deletes with it (a single
  exception to "ports are 1e"). `jiraSearchBudget` stays for good: `JiraClientTests.searchHasAResourceDeadline`
  reads it.

## Why

Most of the top level of `AiTermCore/Operators/` was written for the broadcast Operator: it planned a run of
tasks, accepted commits, diffed them, judged a goal and relayed worker questions. Signals replaced all of
that on 15 Nov, but the types were left, so a reader cannot tell which Oracle prompts, turn rules, timing
constants and saved fields are live. About 900 source lines and 500 test lines have no caller in the signals
product. This step deletes them, plus the saved fields that nothing reads, so that the Operator's saved
records (`operatorSession`, each task's `signalTask`) carry only live data. End state: every remaining member
of these files has a production caller or a surviving test that pins a contract.

## Today

All source paths under `app/Sources/AiTermCore/` unless they start with `app/`. Re-run each grep first.

Oracle prompts, `Operators/ChallengeLaunch.swift` (403 lines). Live and staying: `GateVerdict`,
`gateInstructions`, `gatePrompt`, `fenced`, `Verdict`, `verdict(_:)`, `gateVerdict(_:)`, the private
`firstWord`, `readTools`, `writeTools`, `piReadTools`, `piQuiet`, `invocation(_:prompt:runFolder:projects:answerFile:)`,
`critique(_:output:answerFile:)`. Callers: `SignalShellGate`, `SignalOperatorController`
(`ChallengeLaunch.verdict`, `.fenced`), `SecondOpinionRunner`, `CompatContractTests`. Dead (no caller in
Sources; `grep -rn "ChallengeLaunch\." app/Sources` shows only the live names): `instructions`, `prompt(tool:...)`,
`vetoInstructions`, `vetoPrompt`, `reviewedMergeInstructions`, `MergeConditions`, `mergePrompt`,
`goalInstructions`, `goalPrompt`, `noVerifyInstructions`, `noVerifyPrompt`, `relayInstructions`,
`relayPrompt`, `RelayVerdict`, `relayVerdict`. (`threadPrompt` and its constants are deleted by 1b.) The doc
comment above `Verdict` and `verdict(_:)` says they answer `vetoPrompt`.

Turn rules, `Operators/WorkerTurn.swift`. Live: `WorkerTurn.endsWithQuestion` (internal), `question(_:)`,
`questionLimit`, the private `questionLines` and `trailing`. The only callers of `ending(lastMessage:commitsAhead:)`
are two lines of `app/Sources/AiTerm/Operators/SignalWorkerIO.swift` (the `busy` predicate, about line 51, and
`question(_:tab:)`, about line 62), which always pass `commitsAhead: nil` and compare with `.asks`. Dead:
`Ending` (its `.noCommit`), `ending`, `sameCommit`, `changedAfterAcceptance`, `Repository.worktreeFingerprint`,
`Repository.taskDiffBase`, `Repository.commitsAhead`, and the `import CryptoKit`. `Repository.mergeBase`,
`isAncestor` and `count` are used elsewhere (`TaskWorkflow`, `Repository+ReviewBranch`, `WorkerGuard`,
`Repository+DefaultBranch`) and stay.

Whole files with no source caller: `Operators/DiffDigest.swift` (153 lines; `grep -rn "DiffDigest" app/Sources`
finds only the file), `Operators/OperatedBranch.swift` (28), `Operators/TaskKeyReference.swift` (33),
`Operators/SavedDefaults.swift` (76; its two wrappers are used only by `ExtraTab.role` and
`ChallengeRecord.kind`, both deleted below). `Operators/AgentDelivery.swift`: the struct `AgentDelivery`
(first half of the file, with `AgentDelivery.of`) has no source caller; `AgentVersions` in the same file is
live (`OperatorPorts`, `SignalWorkerIO`). `DeliveryCheck.covers` and `versionLine` have other callers and stay.
`Operators/StallWatch.swift`: `isQuietWhileWorking` has no caller; see the note above.

`Operators/ModelChoice.swift`: `ModelChoice.row(agent:model:reasoning:in:)` has no source caller (test only).
`launchChoice(pinned:)` is called with `false` only; leave that for step 5g.

`Git/BranchType.swift`: `BranchType.init(title:)`. Its only source caller is `OperatedBranch.type`
(`grep -rn "BranchType(title" app/Sources` finds only that); after step 2 it has only a test.

`Operators/OperatorTiming.swift` (28 constants). Source readers per constant (`grep -rn "OperatorTiming\.<name>" app/Sources`):
none for `unsentWakeNotice`, `promptProbeInterval`, `promptAfterMessageDelay`, `stallAfter`, `landedFetchTimeout`,
`launchAdoptAfter`, `mergePoll`, `mergeWait`, `summaryWait`, `retries`, `runtimeMinutes`, `totalRuntimeHours`,
`reviewQuietMinutes`, `diffBaseFetchTimeout`, `diffBaseFetchInterval`, `quietWake`; only the dead `StallWatch.isQuietWhileWorking`
for `liveQuietMinutes`; only `OperatorPorts.finishReplyBudget` (which nothing reads) for `finishReplyBudget`.
`OperatorTimingTests.theTimingsAreTheContractsValues` pins `stallAfter`, `launchAdoptAfter`, `mergePoll`,
`mergeWait`, `liveQuietMinutes` among others. Live and staying: `reconcileInterval` (`OperatorPorts`, the
controller), `challengeTimeout` (`SecondOpinionRunner`), `firstWorkerOpening` (three readers),
`openCallMinutes` (until 1e), `hostReadTimeout` and `hostReadCache` (`SignalHostIO`), `gateTimeout` and
`operatorRequestTimeout` (compared with the daemon's `delivery.py` by `theDaemonAgreesOnTheSharedTimings`),
`wakeCoalesce` and `jiraSearchBudget` (see above).

`Operators/OperatorModels.swift`. Dead: `OperatorSnag.fixTask(broadcast:runId:)` (the struct and its live
fields stay), `ThreadCritique`, `LaunchRequest` (only `ExtraTab.requestedLaunch`, which nothing sets),
`ExtraTab.requestedLaunch`, `ExtraTab.agentPinned` (never read; always false), `ExtraTab.role` with
`TabRole` (`Operators/AgentChoice.swift`, `case work, review`; `.review` is never set and `role` never read),
`PeopleReview` and `SignalTask.peopleReview` (`Operators/Signals/SignalTask.swift`; never read or written),
`ChallengeKind`, `ChallengeStage.acted` (never set), and in `ChallengeRecord`: `kind`, `approved`, `askedSHA`,
`askedMerge`, `asksMerge`, `actedArguments`, the nested `Role` enum and three stray doc comments at the end
of the type. `ChallengeRecord.askedSHA` is set once (`RequestWatch`, about line 97) and `approved` once
(`OracleRoundLedger.ready`) and neither is read. Live and staying in `ChallengeRecord`: `id`, `tool`, `stage`,
`critique`, `askedArguments`, `askedEvidence`, `unchallengedReason`, `result`, `askedAt`, `round`, `reply`.
`ClosingWait`, `LaunchAttempt`, `GateRequest`, `OperatorSnag`, `PausedWorker` stay (step 5h moves `ClosingWait`).
`ChallengeRecord` keeps its name until 1j.

`Sidebar/OperatorLine.swift`. Dead: `checkingTheGoal`, `pausing`, `isAct` (`grep -rnw "pausing\|isAct\|checkingTheGoal" app`
finds only definitions and one doc mention) and an orphan doc comment block after `isAct` that describes a
function that no longer exists (the "A driven task's line" paragraph under a `// MARK`). `working`, `windowClosed`
and `paused` are live (`SignalSidebar`).

`Operators/WorkerTabs.swift`. Dead: `WorkerSessions` and `TaskItem.workerTabs(in: WorkerSessions, now:)` (the
overload; `grep -rn "WorkerSessions" app` finds only them), and two orphan doc blocks above `tabToBring`
that describe removed `isReadyForAcceptance` functions. `tabToBring` itself is live
(`AppController`, about line 555).

`Operators/ActivityLog.swift`. Dead: `ActivityEntry.isRead` and `showsAmongChanges` (readers: only
`ActivityLogTests`), `ActivityEntry.taskLabel` (every construction passes `nil`: three in
`SignalOperatorController`, two in `ActivityLogTests`), `Outcome.repeated` and `Outcome.challenged`
(never written). `ActivityLog.read` stays (tests read it; step 5h moves it).

Item identity. `Operators/Signals/ItemRef.swift`: the `.branch` case, its decode, encode and `identity` arms
and `ItemRef.branch(remote:name:)`; `Operators/Signals/SignalBranchRef.swift`; arms in `MatchDecision.swift`
(the `if case .branch` block inside `decide`, and the `.branch` case in `matchesItem`),
`Signals/Sources/ItemProjectMapper.swift`, and `app/Sources/AiTerm/Views/Operators/SignalStartsStep.swift`
(`key(_:)`). No reader produces a branch item: `grep -rn "ItemRef.branch\|\.branch(remote" app/Sources` finds
only the definition. `Operators/Signals/SignalSeen.swift`: `Disposition.baseline` (its enum case and its two
raw-value arms); only `started` and `skipped` are ever written (`ItemRouter`).

Port field. `app/Sources/AiTerm/Operators/OperatorPorts.swift`: `finishReplyBudget` (and its doc comment,
which names `finish_task`), whose only reader is itself.

Fixture. `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` is produced by
`SignalSavedFormatTests.theSignalWorkspaceKeepsItsAuthorityPendingStageAndArchive`, which builds a synthetic
state through the current models, saves it through `StateStore`, and compares the bytes with this file.
Two keys in it come from fields deleted here: `"kind" : "critique"` on the one Oracle round (always written,
because `kind` is a `@Defaulted` field) and `"agentPinned" : false` on the one extra tab (always written).
`ExtraTab.role` and `requestedLaunch` are omitted at their defaults, `peopleReview` and the dead
`ChallengeRecord` optionals are nil, so nothing else changes.

## Change

Do these in order; the compiler finds each leftover use.

1. Core files, whole: delete `DiffDigest.swift`, `OperatedBranch.swift`, `TaskKeyReference.swift`,
   `SavedDefaults.swift`, `Signals/SignalBranchRef.swift`. In `AgentDelivery.swift` delete the struct
   `AgentDelivery` and keep `AgentVersions`; rename the file to `AgentVersions.swift` (`git mv`) and fix the
   file's first doc comment, which describes the struct.
2. `WorkerTurn.swift`: delete `Ending`, `ending`, `sameCommit`, `changedAfterAcceptance`, the
   `Repository` extension (`worktreeFingerprint`, `taskDiffBase`, `commitsAhead`) and the `CryptoKit` import.
   Make `endsWithQuestion` public (it is `static func`, internal today) and change the two lines of
   `SignalWorkerIO.swift` to call `WorkerTurn.endsWithQuestion(_:)` where they compare `ending(...)` with
   `.asks`. Fix the file's doc comment so it says what remains: whether a worker's last message asks a
   question and the question itself.
3. `ChallengeLaunch.swift`: delete the dead members listed under Today; fix the doc comment of `Verdict` and
   `verdict(_:)` so it says what they are (the Oracle's yes or no, first word). Leave `gateInstructions`
   byte for byte (it is model-facing; step 1j rewrites it).
4. `OperatorTiming.swift`: delete the sixteen constants with no reader, `liveQuietMinutes` and
   `finishReplyBudget`; keep the rest. Delete `OperatorPorts.finishReplyBudget` and its doc comment.
   `StallWatch.swift`: delete `isQuietWhileWorking`; keep `isCallRunning` and add nothing.
5. `ModelChoice.swift`: delete `row`. `BranchType.swift`: delete `init(title:)` and its doc comment.
6. `OperatorModels.swift`, `AgentChoice.swift`, `SignalTask.swift`: delete the dead types and fields listed
   under Today. After this `ExtraTab` is `key`, `agent`, `model`, `reasoning`, `modelReason`, `brief`,
   `launch`, `sessionId`, `failure`, `conversation`, and its initialiser drops `agentPinned:` and `role:`
   (no caller passes them). `ChallengeStage` is `running, ready, delivered, unchallenged`. `ChallengeRecord`
   loses the listed fields and its initialiser the parameters `kind`, `approved`, `askedSHA`, `actedArguments`,
   `askedMerge`. Delete `peopleReview` from `SignalTask`.
7. Call sites of the deleted `ChallengeRecord` fields: `RequestWatch.swift` (about line 96: the merge veto
   record is built without `kind: .veto` and `askedSHA:`), `OracleRoundLedger.swift` (`ready` no longer sets
   `approved`), `Operators/Signals/OperatorSession.swift` (`prune` no longer removes `.acted` rounds),
   `Operators/Signals/OperatorDigest.swift` (`oracleRounds` is the session's list, not filtered by `.acted`).
8. `OperatorLine.swift`: delete `checkingTheGoal`, `pausing`, `isAct` and the orphan doc block. `WorkerTabs.swift`:
   delete `WorkerSessions`, the `WorkerSessions` overload and the two orphan doc blocks.
9. `ActivityLog.swift`: delete `isRead`, `showsAmongChanges`, `taskLabel` (stored property, initialiser
   parameter and assignment), `Outcome.repeated` and `.challenged`. Update the three
   `ActivityEntry(...)` calls in `SignalOperatorController.swift` to drop `taskLabel: nil`. An old log line
   that names a deleted outcome is skipped by the reader like any undecodable line; write no handling.
10. Item identity: delete `ItemRef.branch`, its three arms in `ItemRef`, `ItemRef.branch(remote:name:)`,
    the `.branch` arms in `MatchDecision.decide` and `MatchDecision.matchesItem`, `ItemProjectMapper` and
    `SignalStartsStep.key`. Delete `SignalSeen.Disposition.baseline` (case and both arms). A saved
    `"branch"` item or `"baseline"` disposition decodes into the existing `.unknown` case and is kept inert;
    write no code for it.
11. Rename the surviving tests per Tests, adjust the others, re-record the fixture (below), add the
    provenance line, then run the suites.

### Re-recording `operator-signals/state.json`

- Read `docs/testing.md` ("Current Operator contract") and the fixture's `PROVENANCE.md`: the fixture is
  re-recorded only on purpose, by the test's recording switch, never edited by hand.
- After the code compiles and every other suite is green, run
  `AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests`. The test writes
  the bytes it just saved over `Fixtures/operator-signals/state.json` and then compares them with the file.
  Start it in the background like any gate run.
- Run the same filter again without the variable: it must pass without rewriting anything.
- `git diff -- app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/state.json` must show exactly two
  removed lines and nothing else: `"agentPinned" : false,` in the extra tab and `"kind" : "critique",` in the
  Oracle round. If anything else differs, stop and report; do not keep the recording.
- Append to `Fixtures/operator-signals/PROVENANCE.md` a short section: on 16 Nov 2026 greenfield step 1d
  re-recorded `state.json` with `AITERM_RECORD_SIGNAL_STATE=1`; the Operator's saved records lost the dead
  fields `agentPinned` (extra tab) and `kind` (Oracle round); no key was added; no brief or tool bytes
  changed. `brief.md` and `tools.json` are not touched.

## Keep

- `ChallengeLaunch.gateInstructions`, `gatePrompt`, `fenced`, `verdict`, `gateVerdict`, `invocation`,
  `critique`: live; the gate prompt is model-facing and moves in 1j. `ChallengeRecord` and `ChallengeStage`
  keep their names and their saved keys (`oracleRounds` live keys: `askedAt`, `askedEvidence`, `id`,
  `round`, `stage`, `tool`, `critique`, `reply`, `result`, `askedArguments`, `unchallengedReason`).
- `WorkerTurn.question`, `questionLimit`, `endsWithQuestion` and `Fixtures/worker-last-messages.json`.
- `AgentVersions` and `DeliveryCheck` (Settings, `MessagingChecks`, `SignalWorkerIO` read them).
- `OperatorSession.Question`, `PausedWorker`, `GateRequest`, `LaunchAttempt`, `ClosingWait`,
  `SignalWorkerReply`: live.
- `ModelChoice.launchChoice`, `launchAgent`, `switchAt`, `pair`: live (the `pinned` argument is 5g's).
- `ItemRef.unknown`, `SignalSeen.Disposition.unknown`, `TaskPhase.unknown`, `PreservedFields`: forward
  compatibility on purpose.
- `StallWatch.isCallRunning` and `OperatorTiming.openCallMinutes` until 1e; `OperatorTiming.wakeCoalesce`
  and `jiraSearchBudget` (see the note at the top).
- `OperatorLine.working`, `windowClosed`, `paused`, `maxLength`, the whole `OperatorLine+Waiting.swift`.
- `ActivityLog.read`, `ActivityLog.append`, `ActivityEntry.resultLimit`.
- The `OperatorSnag.appVersion` field (read at `+Calls.swift` when the snag is saved).
- `Repository.mergeBase`, `isAncestor`, `count`.
- `docs/` text: no doc names any deleted symbol (`grep` for them in `docs/*.md` is empty), so no doc edit.

## Decisions already taken

- Dead saved fields are dropped from the Swift types and from what is written. A workspace saved by
  today's build that still carries `agentPinned`, `kind`, `peopleReview`, `edges` or a `branch` item must
  still load: `ExtraTab`, `ChallengeRecord` and `SignalTask` have synthesized decoders, which ignore keys they
  do not know, and `ItemRef` and `SignalSeen.Disposition` decode unknown values into `.unknown`. Check it
  once: before you re-record, copy the committed fixture (`git show HEAD:<path to state.json>`) into a
  scratch folder and load it with `StateStore(url:).load()` in a throwaway test; it must load with the same
  number of tasks. Delete the throwaway test afterwards. (The Operator's records are reset at upgrade
  anyway; the check protects the task rows around them.)
- `ChallengeStage.acted` goes: a saved `"acted"` stage would fail to decode `ChallengeStage` because it is a
  closed `String` enum. Real, then likely: it was never written (`grep -rn "\.acted" app/Sources` finds only
  the two filters you delete), so no saved record has it.
- `ActivityEntry.Outcome` cases likewise: never written.
- The merge veto record loses `kind: .veto`, `askedSHA` and `approved`; its identity is `tool`
  (`merge_when_ready`) plus `askedEvidence` (the task id), as `RequestWatch` already removes and finds it.
- `run_status` and the digest: the `oracleRounds` items no longer carry `kind` (was always `"critique"`,
  or `"veto"` for the merge record), `approved`, `askedSHA`, `askedMerge`, `actedArguments`. No test pins
  those keys (`SignalFreshDigestTests` and `SignalStatusBudgetTests` count items and bytes only); the
  `SignalOperatorContractTests` brief and tool schema bytes do not change. The Operator brief does not
  mention these keys (`grep -n "kind\|askedSHA" ` over `Fixtures/operator-signals/brief.md` finds no
  oracle-round reference).
- `SignalWorkerIO.busy` and `question(_:tab:)` behave as before: `endsWithQuestion` is what `ending(...) == .asks`
  meant.
- Cannot happen here: another reader of `OperatorTiming` in the daemon beyond the two constants
  `delivery.py` spells (`GATE_TIMEOUT`, `OPERATOR_REQUEST_TIMEOUT`); the Python file has no other copy.

## Tests

Delete whole files: `DiffDigestTests.swift`, `OperatedBranchTests.swift`, `TaskKeyReferenceTests.swift`,
`SavedDefaultsTests.swift` (the behaviour, a type that only the dead code used, is deleted).

Edit, with survivors named:

- `ChallengeLaunchTests`: delete `thePromptCarriesTheActAndTheRunAsData`, `aVerdictsPromptCarriesItsTasksBriefFenced`,
  `aNewMergeIsJudgedByTheReviewPromptAndTheVerdicts`, `aPersonsAcceptOutOfFixRoundsStandsInTheMergeCheck`,
  `theGoalPromptAsksWhetherTheVerdictIsRight`, `theNoVerifyPromptAsksEnvironmentOrCode` (prompts deleted).
  `theVetoAsksYesOrNoAndOnlyAYesPasses` mixes a dead `vetoPrompt` assertion block with live `verdict`
  assertions: keep the `verdict` assertions (from `typealias V` on) as a test named
  `theOraclesAnswerIsReadByItsFirstWord` and delete the `vetoPrompt` lines. Survivors for the gate:
  `theGateAsksTheThreeQuestions`, `theGateNeverSaysYesToPushesMergesRequestChangesOrCommits`,
  `theCommandAndTheReasonAreFencedAsData`, `gateVerdictsAreRead`.
- `WorkerTurnTests`: delete `workAfterAcceptanceIsChangedContentOrAnotherHead`,
  `contentFingerprintSurvivesStagingAndDetectsEditsWithIdenticalStatus`,
  `fingerprintsReadSymlinksWithoutFollowingThemAndNoticeExecutableChanges`. Keep the question tests
  (`WorkerTurn.endsWithQuestion`, `question`) and the shared table. Fix the file's doc comment.
- `AgentDeliveryTests.swift`: delete the suite `AgentDeliveryTests` (five tests of the struct), keep
  `AgentVersionsTests`; rename the file `AgentVersionsTests.swift`. Survivor of the delivery rule:
  `DeliveryCheckTests` (`covers`, `versionLine`).
- `ModelChoiceTests`: delete `rowsMatchAgentModelAndReasoningInListOrder`; keep the other tests.
- `BranchTypeTests`: delete `testATitleSaysTheTypeWhenNoIssueTypeDoes...` (title rule deleted); keep the
  issue-type and split tests.
- `OperatorTimingTests.theTimingsAreTheContractsValues`: remove the rows for `stallAfter`, `launchAdoptAfter`,
  `mergePoll`, `mergeWait`, `liveQuietMinutes`; keep `wakeCoalesce`, `reconcileInterval`, `challengeTimeout`,
  `gateTimeout`, `operatorRequestTimeout`. The daemon-agreement tests stay.
- `ActivityLogTests`: delete `whatOnlyLookedWaitsBehindShowEverything`; remove `taskLabel: nil` from its two
  constructions; remove `#expect(made.isRead)`.
- `SignalDomainTests`: `idleStageContinuesInSameTask` uses a branch item; give it a ticket item
  (`ItemRef.ticket(site: "https://jira.example", key: "PAY-1")`). In
  `identityContinuesOrdinaryTaskByTicketRequestOrProjectBranch` remove the third list element (the branch item)
  and rename it `identityContinuesOrdinaryTaskByTicketOrRequest`. Survivors for the mapper and decision:
  the other tests in that file.
- `SignalSavedFormatTests`: no code change; its fixture is re-recorded as described.

Fixtures re-recorded: `operator-signals/state.json`, by `AITERM_RECORD_SIGNAL_STATE=1`, with the provenance
section above. Expected digest or saved shapes that change: the Oracle round loses `kind`; the extra tab
loses `agentPinned`; no `run_status` expectation in any test names these keys.

## Proof

- Iterate: `scripts/test.sh swift -- --filter ChallengeLaunchTests`, `WorkerTurnTests`,
  `AgentVersionsTests`, `OperatorTimingTests`, `ActivityLogTests`, `SignalDomainTests`,
  `SignalSavedFormatTests` (after recording), `SignalFreshDigestTests`, `SignalStatusBudgetTests`,
  `SignalWorkerIOTests`, `SignalWatchTests`, `SignalFreshSessionTests`, `SignalForwardCompatibilityTests`,
  `BranchTypeTests`, `ModelChoiceTests`, `SignalSidebarPresentTests`, `SignalOperatorContractTests`.
- Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rnwE "DiffDigest|OperatedBranch|TaskKeyReference|SavedDefaults|Defaulted|OmittedWhenDefault|SignalBranchRef|WorkerSessions|AgentDelivery|ThreadCritique|LaunchRequest|PeopleReview|peopleReview|TabRole|ChallengeKind|vetoPrompt|mergePrompt|goalPrompt|noVerifyPrompt|relayPrompt|relayVerdict|worktreeFingerprint|taskDiffBase|changedAfterAcceptance|checkingTheGoal|isQuietWhileWorking|showsAmongChanges|askedSHA|askedMerge|actedArguments|agentPinned|requestedLaunch" app`
  returns nothing.
- `grep -rn "\.baseline\b\|ItemRef.branch\|case branch" app/Sources/AiTermCore/Operators` returns nothing.
- `grep -rn "BranchType(title" app` returns nothing.
- `git diff` of the fixture is exactly the two lines above, and the suites are green with the recording
  variable unset; plain `scripts/test.sh` is green.
- `OperatorTiming.swift` holds only the constants named under Keep.

## Not in this step

- Dead `OperatorPorts` fields other than `finishReplyBudget`, the open-call reader, `StallWatch.swift`,
  `openCallMinutes`, `wakeCoalesce` (1e).
- The `ChallengeRecord` to `OracleRound` rename, `OperatorCommand` merge, the shell gate wording and the gate
  prompt (1j); `ClosingWait`, `DeliveryCheck` and `ActivityLog.read` moves (5h); the `.stopped` phase and
  `edges` (5a); `peopleReview`-style fields are done here, but `currentAct` (5f) and `configuration` (5b)
  are not.
- `TaskItem.takenOver` and the `SignalAction.takeOver` cleanup (4e).
