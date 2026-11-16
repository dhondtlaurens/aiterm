# 2i. The workspace backup is a plain second write; spawn budgets become ceilings; two unread work notes go

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 1 (1c deleted the unnoted `WorkMeter` cases and 1h the old-format readers in `StateStore` callers) and on 2a to 2c (they move spawn counts). Comes from: audit TL F8, TS F5.

## Why

`StateStore` keeps its backup as an APFS clone of the file it replaces, reads the clone back to compare, renames it over the backup, and falls back to a plain write. It was added to bring the files-written-per-save count from 2 to 1; the record that measured it says `StateStore.save` at 500 archived tasks took 7.27 ms before and 7.32 ms after, "no speed-up claimed". One write of about 100 KB, coalesced to one save per 200 ms, costs nothing on one Mac, and a count is not a goal. Separately, the git-spawn budgets assert exact numbers, though `docs/testing.md` already says a change may only lower them; every lifecycle restructure in phases 3 and 4 would break them for no reason. And two `WorkMeter` notes are counted by nothing that reads them. After this step the backup is a second write, the budget for files per save goes from 1 back to 2 on purpose, spawn budgets are ceilings, and the unread notes are gone.

## Today

- `AiTermCore/StateStore.swift`: `save` encodes, validates, takes `previousData()` (the bytes this store last saw there, or the file read and decoded), then `keepBackup(previous)` and writes the primary atomically. `keepBackup` clones the primary with `copyfile` (`clone(_:to:)`), reads the clone back, renames it over the backup, and writes `previous` plainly when the clone is not the validated bytes or cannot be made. `WorkMeter.note(.stateWrite)` is called for the primary write, for a clone that copied, and for the fallback write. `save` also notes `.stateSave` first. The type's doc comment says the backup is a clone and a save writes one file.
- `AiTermCore/WorkMeter.swift`: after 1c the cases are `workerTabs`, `reconcilerPass`, `stateSave`, `stateWrite`, `archiveRank`. `workerTabs` is noted at `Operators/WorkerTabs.swift` (about line 148 today, in the function that matches a task's tabs to sessions) and `stateSave` in `StateStore.save`. Nothing reads either: `grep -rn "workerTabs\]\|\.stateSave\|\[.stateSave" app/Tests` returns nothing. Read by tests: `reconcilerPass` (`WorkBudgetTests`, `WindowReconcilerTriggerTests`), `stateWrite` (`WorkBudgetTests.aSaveOverAnEarlierOneWritesItsFiles`), `archiveRank` (`ViewWorkBudgetTests`).
- Backup tests: `StateStoreTests` (`theBackupIsTheValidatedSnapshotEvenWhenTheFileChangedUnseen`, `previousBytesBecomeBackup`, `failedBackupWriteLeavesPrimaryUntouched` and others around restore). `WorkBudgetTests.aSaveOverAnEarlierOneWritesItsFiles` asserts `stateWrite == 1`.
- Spawn budgets with exact numbers: `AiTermTests/WorkBudgetTests.swift` (`shelvingAndRestoringATaskSpawnsGit`: archive count and its `worktree list` count, restore count and its `worktree list` count; `removingATaskSpawnsGit`: remove count and `worktree list` count) and `AiTermCoreTests/GitSpawnCountTests.swift` (`theFirstPassSpawnsWhatEachDirectoryNeedsOnce`: total and the `rev-parse` count; `aSteadyStatePassSpawnsNothingUntilADiffExpires`: the expired-pass total, the `diff --numstat` and `ls-files --others` counts; `aFixCloneInTheTemporaryDirectory...` (renamed or deleted by 1i): its two totals; `aProjectThatIsNotARepository...`, `refQueriesAreSingleCalls`, `aRemovalListsTheWorktreesOnce`). 2b already changed the first-pass numbers.
- `docs/testing.md`, the paragraph beginning "Prefer deterministic work budgets": "assert exact numbers ... A change lowers a number with the work that earned it and never raises it". It names `OperatorWorkBudgetTests`, which does not exist (check `grep -rn "OperatorWorkBudget" app/Tests`).

## Change

1. `StateStore.save`: replace `keepBackup(previous)` and its clone helper with `previous.write(to: backupURL, options: .atomic)` when there is a previous file, before the primary is written (as today). Delete `keepBackup`, the static `clone(_:to:)`, the staging file logic, and the `Darwin` import if nothing else uses it. `previousData()` is unchanged: the backup is still the bytes this store validated, never merely what the primary holds now. Note `.stateWrite` once for each of the two writes. Rewrite the type's doc comment ("a clone ... a save writes one file") to say the backup is the validated bytes written beside the primary.
2. `WorkMeter`: delete the `workerTabs` and `stateSave` cases, their doc lines, and the two `note` calls. Fix the type's header comment, which lists "how often a status was built, the requests derived, a file saved".
3. Budgets as ceilings. In `WorkBudgetTests` and `GitSpawnCountTests`, every assertion that a spawn or command count equals a number becomes "at most" that number, using the number the code spawns now (measure after 2a to 2c; report them). That covers the archive, restore and remove totals, each `worktree list` count, the first-pass and expired-pass totals, the `rev-parse` count, the `diff --numstat` and `ls-files --others` counts, and the single-call counts in `refQueriesAreSingleCalls`, `aRemovalListsTheWorktreesOnce` and `aProjectThatIsNotARepository...`. Leave as they are: an assertion that nothing was spawned (`isEmpty`, a ceiling of zero already), the `hung.timeouts` assertions (they count the stall guard's behaviour, not a budget), the comparison `with == without` in the clone test if it survives, `reconcilerPass == 0`, the archive rank, the status frame limit and the daemon's tick budgets (`daemon/tests/test_tick_budgets.py`). Rewrite the doc comments that say "Each number is exact and is today's" and the history in them ("9 before phase 7", "6 before phase 2") to say what the ceiling is and why.
4. `WorkBudgetTests.aSaveOverAnEarlierOneWritesItsFiles`: the ceiling is 2 files per save (the workspace and its backup), on purpose; the comment says the backup is written as bytes. Keep its assertions that the backup equals the save before and the primary is the new bytes.
5. `docs/testing.md`: the budgets paragraph says budgets are ceilings: a change lowers a ceiling with the work that earned it and never raises it. Fix the test names it lists to the ones that exist.

## Keep

- `previousData()` and `lastKnown`: they stop a save from replacing a primary it cannot read and make the backup the validated snapshot (`theBackupIsTheValidatedSnapshotEvenWhenTheFileChangedUnseen`).
- `restoreBackup`, `hasValidBackup`, `Failure.missingPrimary`, the `.recovered-` copy of a damaged primary.
- `reconcilerPass`, `archiveRank` and their budgets (3a decides whether `reconcilerPass` survives, not this step), `SignalStatusBudgetTests`, the daemon's tick budgets.
- The measure-only timing test `savingTheFrozenWorkspaceWith500ShelvedTasks` (prints, asserts nothing, only runs with `AITERM_MEASURE`).
- `WorkMeter` itself and its three remaining counts.

## Decisions already taken

- A volume that cannot clone no longer matters: there is no clone. The backup is always written.
- The backup is written before the primary, as today, so a failed backup write leaves the primary untouched (`failedBackupWriteLeavesPrimaryUntouched`).
- A ceiling is the measured number, not a rounded-up allowance.
- The count of files written per save is 2 here deliberately. Nothing else in the repository may be changed to hide that.

## Tests

- Delete: none by name. `aSaveOverAnEarlierOneWritesItsFiles` changes its number (above).
- Adjust: the exact-count assertions listed in Change 3, the `stateWrite` expectation, and any `StateStoreTests` assertion about a staging file or a clone (grep `staging` and `clone` in `app/Tests`; none is expected).
- Add: none; this is a deletion and a loosening.
- No fixture is re-recorded.

## Proof

While iterating: `scripts/test.sh swift -- --filter StateStoreTests`, `WorkBudgetTests`, `GitSpawnCountTests`, `ViewWorkBudgetTests`, `WorkspaceStoreTests`. Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "keepBackup\|COPYFILE\|copyfile" app/Sources/AiTermCore/StateStore.swift` returns nothing.
- `grep -rn "stateSave\|workerTabs" app/Sources/AiTermCore/WorkMeter.swift app/Sources/AiTermCore/StateStore.swift` returns nothing, and the `WorkerTabs.swift` note is gone.
- No assertion in `WorkBudgetTests` or `GitSpawnCountTests` compares a spawn or command count with `==` except the ones named under Change 3 as kept.
- `docs/testing.md` says ceilings and names only suites that exist.
- Suites above and plain `scripts/test.sh` are green.

## Not in this step

The lifecycle restructure that will lower the spawn ceilings (4b to 4d). Whether `reconcilerPass` and its budget survive (3a). The rest of the audit's `StateStore` findings (old-format readers went in 1h).
