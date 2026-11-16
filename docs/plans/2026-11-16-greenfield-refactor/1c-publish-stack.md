# 1c. Delete the push and publish stack and its small leftovers

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 0 only. Comes from: CG F1, F2, F3.

## Why

AiTerm used to push a worker's commit and merge it locally on the Operator's word (`finish_task`). That
ended when broadcasts were removed on 15 Nov, but the code under it, written with every imaginable
git-configuration defence, was below the layer that was deleted and stayed: a push that refuses eight ways,
a local merge with five refusals, a branch-drift reader, a timeout helper nobody calls, dead metering cases
and a handful of test-only helpers. About 450 lines of source and 600 of tests guard a push AiTerm no longer
makes. Four small helpers inside that stack are still used by the worker guard (the pre-push hook that
protects branches from workers), so they move beside it. End state: no code in Core can push or merge a
branch; the worker guard owns the four helpers it needs.

## Today

Paths under `app/Sources/AiTermCore/`.

- `Git/Repository+Publish.swift` (191 lines): `PublishRefusal` (eight cases), `Repository.pushTimeout`,
  `tip(of:)`, `originTip(of:)`, `Landing` and `landing(of:in:)`, `contains(_:in:)`, `push(_:as:defaultBranch:noVerify:)`
  with the private `requireOneDestination` and `requireOriginsOwnDefaultBranchIsNot`, and, at the end, three
  internal statics that are live: `Repository.sameLocation(_:_:)`, `Repository.shortBranch(_:)` and
  `Repository.folded(_:)`. Re-run: `grep -rn "LocalMerge\|PublishRefusal\|pushTimeout\|\.tip(of\|\.landing(\|originTip(of\|\.contains(.*in:" app/Sources`:
  the only hits are comments, `Repository+Publish.swift`, `LocalMerge.swift` and tests. (`originTip` also
  names a stored property of `FixClone`, unrelated; `.contains(x, in:)` is distinct from
  `Sequence.contains`.) The live helpers are read at: `Operators/WorkerGuard/WorkerGuard.swift`
  (`pushDenial`: `folded`, `shortBranch`, `sameLocation`), `WorkerGuard+Commands.swift` (two `shortBranch`),
  `WorkerGuardCLI.swift` (`sameLocation` in the `push` case), and `Git/LocalMerge.swift` (`shortBranch`; goes).
- `Git/LocalMerge.swift` (85 lines): enum `LocalMerge` with `Refusal` and `merge(sha:into:in:)`. No caller in
  Sources.
- `Git/CommitId.swift`: struct `CommitId` (init, `description`), `isFull`, `isMergeable`, `isAbbreviation`.
  Only `CommitId.isFull` is used: twice in `WorkerGuard.pushes` (`WorkerGuard.swift`) and by the dead push and
  merge code. `CommitId(` is built only in `CommitIdTests`. `isMergeable` is `isFull` under another name;
  `isAbbreviation` served `record_review`, which is gone.
- `BranchDrift.swift` (top level of Core, 85 lines): `BranchDrift`, its `Head`, `Named`, `shaCandidates`, `find`.
  `grep -rn "BranchDrift\|shaCandidates" app daemon` hits only the file. No test.
- `BackgroundWork.swift`: `BackgroundWork.within` and `BackgroundWork.NoAnswer` (the extension at the end).
  `grep -rn "\.within(\|BackgroundWork\.within\|BackgroundWork\.NoAnswer" app` finds nothing. (The word
  "NoAnswer" also appears in unrelated test names such as `...IsNoAnswer`; only `BackgroundWork.NoAnswer`
  matters.)
- `Git/GitRunner.swift`: `GitError.pushReason` and `GitError.pushReasonLimit`. Used only by three tests in
  `GitErrorTests`.
- `WorkMeter.swift`: `WorkMeter.Work` has eleven cases; `WorkMeter.note(` is called only with `.stateSave`,
  `.stateWrite` (`StateStore`), `.workerTabs` (`WorkerTabs.swift`), `.archiveRank` (`ArchiveSheetModel`),
  `.reconcilerPass` (`WindowReconciler`). Never noted anywhere, nor read by a test: `statusBuild`,
  `oracleSettingsRead`, `requests`, `turnRead`, `activityDays`, `activityDayTitle`.
- `OptionalString.swift`: `Optional<String>.saidAsWritten`. `grep -rnw saidAsWritten app` finds only the
  definition.
- `LoginShellLocator.swift`: `LoginShellLocator.refresh()`. Its only caller is
  `LoginShellLocatorTests.aRefreshReplacesTheKnownPathOnlyWhenTheShellAnswers`; production uses `forget()`
  (`HarnessProcess`). `callersWaiting` and `forget()` stay.
- `Git/WorktreeError.swift`: case `notARepository(String)` and its `errorDescription` arm. Never
  constructed (`grep -rn "WorktreeError.notARepository\|\.notARepository(" app` finds only the arm).
  `WatchedFileCache.Answer.notARepository` and `RemoteResolver.notARepository` are different types and stay.
- Tests: `PublishPushTests` (321 lines), `LocalMergeTests` (173), `CommitIdTests` (70), three tests of
  `GitErrorTests`, one of `LoginShellLocatorTests`.
- Docs: `docs/architecture.md` says `CommitId` is the one rule for "Git publication and guarded merge heads"
  and lists local merge among the lane's work.

## Change

1. Delete `Git/Repository+Publish.swift` after moving its three live statics (step 3), `Git/LocalMerge.swift`,
   `Git/CommitId.swift`, `BranchDrift.swift`.
2. Delete `BackgroundWork.within` and `NoAnswer` (the whole second extension; keep `BackgroundWork.run` and
   the doc comment of the enum). Delete `GitError.pushReason` and `pushReasonLimit` with the lines that
   document them. Delete the six unnoted `WorkMeter.Work` cases with their doc lines. Delete
   `saidAsWritten` with its doc line. Delete `LoginShellLocator.refresh()` with its doc comment. Delete
   `WorktreeError.notARepository` and its description arm.
3. New file `Operators/WorkerGuard/WorkerGuard+Names.swift`: an `extension WorkerGuard` holding four internal
   statics, bodies unchanged: `isFullCommit(_:)` (a commit id is 40 or 64 ASCII hexadecimal digits: the rule
   of `CommitId.isFull`, with its private ASCII-hex helper), `sameLocation(_:_:)`, `shortBranch(_:)` and
   `folded(_:)` (as in `Repository+Publish.swift`, with their doc comments). Point every user at them:
   `WorkerGuard.pushes` uses `isFullCommit`; `pushDenial`, `WorkerGuard+Commands` and `WorkerGuardCLI` use
   `WorkerGuard.sameLocation`, `WorkerGuard.shortBranch`, `WorkerGuard.folded`. Change the doc comment in
   `Git/RemoteURL.swift` that names `Repository.sameLocation` to `WorkerGuard.sameLocation`.
4. Docs: `docs/architecture.md`: rewrite the sentence that begins "Commit ids, remote URLs, real paths and file
   stamps each have one Core home" so `CommitId` is replaced by "the worker guard's commit-id rule" and
   `RemoteURL`'s clause says "the worker guard's same-location key"; in the paragraph about repository
   lanes delete "local merge,". No other doc names these.
5. Do not touch `GitRunner.runRemote`, `GitRunner.stallGuard`, `Repository.ask`, `isAncestor`, `mergeBase`,
   `count`, `commit`: other code uses them (`Repository+ReviewBranch`, `Repository.swift`, the guard).

## Keep

- `WorkMeter` itself and its five noted cases (`workerTabs`, `reconcilerPass`, `stateSave`, `stateWrite`,
  `archiveRank`): budget tests read three of them (`WorkBudgetTests`, `ViewWorkBudgetTests`,
  `WindowReconcilerTriggerTests`). Step 2i and phase 3 decide on budgets; not here.
- `WorkerGuard` rules and its tests; `RemoteURL.location(of:)` (the key `sameLocation` compares); the
  `check-ref-format` use in `BranchNaming`.
- `GitRunner.remoteTimeout`, `stallGuard`, `runRemote`, `ask(none:)`.
- `SingleFlight`, `ThreadWork`, `SerialThread`, `GitLanes`: audited and sound.
- `WatchedFileCache`, the resolvers and `StallGuardedGit`: step 2a and 2b.
- `LoginShellLocator.forget()` and `callersWaiting`; the other tests of the locator.
- `GitFixture.withOrigin` and `GitFixture.folder`: other suites use them; do not delete test-support code
  because two deleted suites used it.

## Decisions already taken

- Where the helpers go: onto `WorkerGuard`, with the new names above, and the callers change in this step.
  Do not leave `Repository` statics behind "for compatibility".
- The default-branch refusal in the guard is case-folded and accepts `refs/heads/` spellings; this is the
  behaviour `PublishPushTests` pinned for the push and is the guard's too. Keep the bodies exactly.
- `OperatorTiming` mentions nothing of this; no timing constant goes in this step.
- A deleted test whose behaviour lives on in the guard has a survivor: see Tests.
- Cannot happen here: another caller for `PublishRefusal` or `LocalMerge.Refusal` in the daemon. The daemon
  never calls Swift types; `grep -rn "LocalMerge\|PublishRefusal" daemon` returns nothing.

## Tests

Delete whole files: `LocalMergeTests.swift` (the behaviour, a local merge end, is deleted) and
`PublishPushTests.swift` apart from the same-location table, which moves (below). The push behaviours it
pinned are deleted with the push, except these, whose survivors are the guard's tests:

- Never pushing a default branch under another spelling (`noSpellingOfTheDefaultBranchIsPushed`,
  `aDefaultBranchWithSlashesIsCaseFoldedToo`): add one test to `WorkerGuardRulesTests`,
  `aDefaultBranchIsRecognisedUnderAnySpelling`: with a scope whose branch is `main`, `pushDenial` refuses
  when `defaultBranch` is `Main`, `MAIN`, `refs/heads/main` and `refs/heads/Main`, and `WorkerGuard.shortBranch`
  of `refs/heads/feat/x` is `feat/x`. It pins existing behaviour and passes at once.
- Two URLs that name the same place (`twoUrlsAreTheSamePlaceWhenHostAndPathAre`, twelve rows): move the whole
  parameterised test into `WorkerGuardRulesTests`, calling `WorkerGuard.sameLocation`.
- A full commit id only (`onlyACommitIdIsPushed`): the guard's rule is now `WorkerGuard.isFullCommit`.
  Reduce `CommitIdTests.swift` to one test, `aFullCommitIdIsFortyOrSixtyFourAsciiHexDigits`, over the existing
  `rows` table checking `WorkerGuard.isFullCommit(text)` against the reference rule `pushRule`; delete the
  merge and review rules, the `changed` table and the other two tests. Rename the file and struct to
  `WorkerGuardNamesTests`; it holds that one test.

Delete from `GitErrorTests`: `pushReasonKeepsTheHooksWholeOutput`, `pushReasonKeepsTheLast200Lines`,
`pushReasonAddsThePorcelainRejections` (the behaviour is deleted). Delete from `LoginShellLocatorTests`:
`aRefreshReplacesTheKnownPathOnlyWhenTheShellAnswers` (behaviour deleted; `forget()` is covered by the
locator's other tests). No test reads the six `WorkMeter` cases, `BranchDrift`, `within` or `saidAsWritten`.

No fixture is re-recorded.

## Proof

- Iterate: `scripts/test.sh swift -- --filter WorkerGuard` (rules, CLI, launch, host and Codex suites),
  `--filter GitErrorTests`, `--filter LoginShellLocatorTests`, `--filter WorkerGuardNamesTests`,
  `--filter WorkBudgetTests`, `--filter ViewWorkBudgetTests`, `--filter DefaultBranchPullTests`.
- Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rnwE "LocalMerge|PublishRefusal|CommitId|BranchDrift|pushTimeout|pushReason|pushReasonLimit|saidAsWritten|Repository.sameLocation|Repository.shortBranch|Repository.folded" app daemon docs/architecture.md docs/testing.md`
  returns nothing (whole-word match: `CommitIdentity` in an unrelated Fix test is not a hit), and
  `grep -rn "BackgroundWork.within" app` returns nothing.
- `grep -rn "statusBuild\|oracleSettingsRead\|turnRead\|activityDay" app/Sources` returns nothing, and
  `grep -rn "case requests" app/Sources/AiTermCore/WorkMeter.swift` returns nothing.
- `grep -rn "func refresh()" app/Sources/AiTermCore/LoginShellLocator.swift` returns nothing.
- Suites above and plain `scripts/test.sh` green; `Repository+Publish.swift`, `LocalMerge.swift`,
  `CommitId.swift`, `BranchDrift.swift`, `PublishPushTests.swift`, `LocalMergeTests.swift` are gone.

## Not in this step

- Per-key git timeout back-off, reftable, abandoned rebase scratch cleanup, the `.worktrees` symlink
  refusal (2a); the default-branch resolver (2b).
- Worker guard behaviour changes such as allowing local `git merge` and one shared argument table (2g).
- Old-format readers and migrations (1h); `finish_task` words in comments (1j).
