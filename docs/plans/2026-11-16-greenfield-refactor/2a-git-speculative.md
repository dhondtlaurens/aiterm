# 2a. Git: delete the per-key timeout back-off, reftable handling, the rebase scratch sweep and the `.worktrees` symlink refusal

Implementer: Codex `gpt-6.1-sol` high. Depends on: all of phase 1 (1c deleted the push stack and the unnoted `WorkMeter` cases). Comes from: audit CG F4, F6, F9.

## Why

Four things in the git layer handle cases that do not happen on one person's Mac. A git that times out is asked again after 30 seconds by four separate layers, three of them per key, though the project-level guard already refuses every command in a stalled project for that long. Reftable repositories are watched in four files, though nobody here has one and `git init` does not create one by default. A sweep removes rebase scratch checkouts that an app which died mid-rebase left behind. A symlinked `.worktrees` folder is refused though nobody links it. None of these followed an incident; the commits that added them (early October, "a dead mount", reftable) describe designs, not reports. After this step a timeout is handled once, by the project guard; a failure is still never stored; the code reads files-format repositories only.

## Today

- Per-key back-off, three places, all driven by `TimedOut` (`Git/TimedOut.swift`): `WatchedFileCache` (`State.timeout`, `failureBackoff` init parameter, the first lines of `answer(for:locate:read:)`), `RepositoryProbe` (`State.timeout`, `failureBackoff`, the first line of `locations(of:)` and its `catch`), `DiffStatResolver` (`Kept.timeouts`, the `failureBackoff` init parameter, the `stands` check and the `catch` in `diff(for:base:)`, the `timeouts` filter in `diffs(for:skipping:)`). `BranchResolver`, `RemoteResolver` and `DefaultBranchResolver` inherit it through `WatchedFileCache` and `RepositoryProbe`. Production builds all of them over `StallGuardedGit` in `AiTerm/CheckoutMonitor.swift` (init); nothing else constructs them. Check: grep `-rn "BranchResolver(\|RemoteResolver(\|DiffStatResolver(\|RepositoryProbe(" app/Sources`.
- The project-level guard is `StallGuardedGit` plus `TimedOut`; its tests are `StallGuardedGitTests` and, through a hung mount, `GitSpawnCountTests` (`aHungMountCostsOneTimeoutAndHoldsUpNoOtherProject`, `aProjectThatHangsKeepsWhatWasKnownOfIt`).
- Reftable, five places: `RepositoryProbe.Locations.reftableList` and the `reftable/tables.list` name in `probe`; `BranchResolver.locate`, `isReftableStub` and the stub line in `parseHead`; the `reftable/tables.list` entries in `DefaultBranchResolver.refs` and in `DiffStatResolver.refFiles` (the name list and the `files.append(shared + "/reftable/tables.list")` line); `RemoteResolver` watches `reftableList` in `answer(for:)`. Check: `grep -rniE "reftable" app/Sources app/Tests`.
- Scratch sweep: `Repository+DefaultBranch.swift`, `checkoutsLessAbandonedScratch` and its use in `pullDefaultBranch` and `rebaseOntoOrigin`. `scratchPrefix` is also used by `rebaseOntoOrigin` to name its own scratch checkout, and that checkout's `defer` removal is the normal path.
- Symlink refusal: `Repository+Worktrees.swift`, `prepareWorktree(at:)`, the loop that throws `WorktreeError.symlinkRefused` for `.worktrees` or the worktree path; the `symlinkRefused` case in `Git/WorktreeError.swift`. No test constructs it (`grep -rn symlinkRefused app`).

## Change

1. `WatchedFileCache`: drop `State`, `timeout`, `failureBackoff` and the init parameter. The per-key state is the optional `Entry` alone (`KeyedStates<Entry?>`). `answer` keeps its rule: if `locate` or `read` throws, the entry is left as it was; the known value, if any, is returned, else the error is thrown. Rewrite the doc comments that talk about `failureBackoff` and a hung mount.
2. `RepositoryProbe`: drop `timeout` and `failureBackoff`; a failed probe throws and stores nothing. Remove `reftableList` from `Locations` and its name from the `rev-parse` arguments; the answer is then `commonDirectory`, `HEAD`, `config` in that order, and the line-count check follows the shorter list.
3. `DiffStatResolver`: drop `timeouts`, `failureBackoff` and the init parameter; a timeout returns the last known diff (or nil) and leaves the entry's age alone, so the next pass asks again (the guard decides whether git runs). Remove the reftable name and the shared-stack append from `refFiles`.
4. `BranchResolver`: `locate` becomes the `HEAD` file; delete `isReftableStub` and the stub line in `parseHead`. `RemoteResolver`: watch `config` and `head` only. `DefaultBranchResolver` (deleted by 2b): remove `reftable/tables.list` from `refs` and fix its comment.
5. `TimedOut` stays, for `StallGuardedGit` alone. Rewrite its header and `StallGuardedGit`'s paragraph about "caches that back off per directory", which no longer exist.
6. `Repository+DefaultBranch.swift`: delete `checkoutsLessAbandonedScratch`; both callers use `worktrees()` directly. Keep `scratchPrefix` and the `defer` that removes a rebase's own scratch checkout and prunes.
7. `Repository+Worktrees.swift`: delete the symlink loop in `prepareWorktree(at:)` and the `symlinkRefused` case with its description.
8. Test support: `GitFixture.initRepo` and `makeRepo` lose `refFormat` once no test passes one (grep `refFormat` in `app/Tests`).

## Keep

- "Never store a failure, the last known value stands" in every resolver (a real incident: a git that failed under load was taken for "no remote"). Only the waiting is deleted, not the rule.
- `StallGuardedGit`, `TimedOut`, `MonotonicDate`: the project-level stall guard stays; it is what makes the per-key waits redundant.
- `deleteLeftover`'s symlink check (it guards a delete) and `WorktreeInclude.firstSymlink`/`ThroughSymlink` (a tracked symlink out of the worktree is plausible in a monorepo; `neverWritesThroughASymlinkOutOfTheWorktree` pins it).
- The normal-path scratch cleanup in `rebaseOntoOrigin` and `rebase(_:onto:in:)`'s abort on conflict.
- `DiffStatResolver`'s untracked caps and `lstat` cache, the negative-answer TTL in `WatchedFileCache` and `RepositoryProbe`, and `SHA-256` handling in `BranchResolver.read`: each answers a real cost or case.

## Decisions already taken

- A reftable repository is not a case. It is read like any other; its `HEAD` stub would parse as a branch named `.invalid`. No handling.
- An abandoned rebase scratch checkout is not a case. If one exists, `git worktree prune` clears it once macOS has cleaned the temporary folder. No handling.
- A symlinked `.worktrees` folder is not a case. No handling.
- A resolver built without the guard (tests only) asks git on every call after a timeout. That is fine.

## Tests

- Delete, with the surviving detector: `WatchedFileCacheTests.aTimeoutIsNotAskedAgainUntilItsBackoffIsOver` (the guard's `StallGuardedGitTests.theProjectIsAskedAgainOnceTheBackoffIsOver` and the `GitSpawnCountTests` hung-mount test); the "within the backoff git is not asked" lines of `RepositoryProbeTests.aTimeoutIsNotKeptAndIsNotAskedAgainAtOnce` and `DiffStatResolverTests.aGitThatRanOutOfTimeLeavesTheLastDiffAndIsLeftAlone` (same survivors; the rest of both tests stays, rewritten without clock advances); `BranchResolverTests.aReftableRepositoryIsResolvedAndFollowsACheckout`, `aFailedReadKeepsTheLastBranchAndIsRetried` (it used a reftable repository to force a git read; survivors `WatchedFileCacheTests.theKnownValueStandsThroughTheBackoff` and `RemoteResolverTests.aFailedReReadKeepsTheLastAnswerAndIsRetried`), the reftable half of `headsGitIsAskedAboutResolveWithoutThrowing` and the stub assertion in `headIsReadAsABranchOrAShortSha`; `DiffStatResolverTests.aReftableMergeBaseIsRecomputedWhenARefMoves`; `DefaultBranchResolverTests.aReftableRepositoryIsReadAgainWhenOriginsHeadMoves`; the `"reftable"` argument of `RemoteResolverTests.followsTheCheckedOutBranchesUpstream`; `reftableList` in `RepositoryProbeTests` (two assertions). All of these test behaviour that is deleted, except where a survivor is named.
- Adjust: tests that advance `TestClock` by `TimedOut.backoff` after a failed lookup (`BranchResolverTests`, `RemoteResolverTests`, `DefaultBranchResolverTests`, `WatchedFileCacheTests.theKnownValueStandsThroughTheBackoff`, `DiffStatResolverTests`) keep their "not kept, known value stands, next call asks again" assertions and drop the clock advance. Rename those whose names speak of a backoff.
- No fixture is re-recorded.

## Proof

While iterating: `scripts/test.sh swift -- --filter WatchedFileCacheTests`, then `RepositoryProbeTests`, `BranchResolverTests`, `RemoteResolverTests`, `DiffStatResolverTests`, `DefaultBranchResolverTests`, `StallGuardedGitTests`, `GitSpawnCountTests`, `WorktreesTests`, `DefaultBranchPullTests`. Then plain `scripts/test.sh` in the background. The spawn counts in `GitSpawnCountTests` must not change in this step; if one does, stop and report.

## Done when

- `grep -rniE "reftable" app/Sources app/Tests` returns nothing.
- `grep -rn "failureBackoff\|checkoutsLessAbandonedScratch\|symlinkRefused" app` returns nothing.
- `grep -rn "TimedOut" app/Sources` hits only `TimedOut.swift` and `StallGuardedGit.swift`.
- Suites above and plain `scripts/test.sh` are green.

## Not in this step

`DefaultBranchResolver`, its map and its poll go in 2b. `StateStore`, budgets and `WorkMeter` are 2i. Whether to drop `StallGuardedGit` itself is not planned.
