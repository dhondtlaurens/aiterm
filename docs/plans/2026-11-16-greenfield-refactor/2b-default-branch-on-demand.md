# 2b. The default branch is asked from git when it is needed, not polled

Implementer: Codex `gpt-6.1-sol` high. Depends on: 2a (the resolvers are already free of per-key back-off and reftable). Comes from: audit CG F5.

## Why

The checkout monitor reads every project's default branch on every two-second pass, through `DefaultBranchResolver`, which stats eight ref files per project to keep a cache fresh. That cache has three readers: the project menu's "Pull main" label and two sheet pre-fills, one of which already falls back to asking git itself. A continuously maintained cache for a label read when a menu opens is the wrong shape. After this step nothing polls the default branch. A project's name is asked once when its heading row appears and again after a pull or rebase of that project; the Pull item reads "Pull Default Branch" until git has answered, then "Pull <branch>". New Task asks git when it prepares its draft, and Edit Project asks when its sheet opens.

## Today

- `Git/DefaultBranchResolver.swift`: the resolver, built in `AiTerm/CheckoutMonitor.swift` (init, `defaultBranches`), handed to the scanner (`Scanner` typealias, last parameter), and used by `WorkspaceScan.run` (`defaultBranches` parameter, `retain`, the `defaultBranch` map). `WorkspaceScan.defaultBranch` is a public field and an init parameter. `CheckoutMonitor.defaultBranch` is the observed copy, set in `applyScan` and by `seedSnapshotFixture` indirectly through the scan.
- Readers of `checkouts.defaultBranch`: `Views/SidebarRows.swift` (the project row's context menu, `Button("Pull \(… ?? "Default Branch")")`), `SheetCoordinator.presentJiraProjects(for:)` (passes it into `ProjectPreparation.defaultBranch` for the Edit Project sheet's header) and `SheetCoordinator.presentNewTask(project:)` (passes it as `known` to `TaskDraft.initial(... defaultBranch:)`). Check: `grep -rn "defaultBranch\b" app/Sources/AiTerm app/Sources/AiTermCore/Workspace app/Sources/AiTermCore/Tasks/TaskCreator.swift`.
- `TaskDraft.initial` already asks `Repository(project.path, git:).defaultBranch()` when it is given none; the draft is built inside `BackgroundWork.run` in `prepareSheet`, off the main actor.
- `ProjectActions` owns the project row's Pull state (`defaultBranchRows`, `isChangingDefaultBranch`, `pullDefault`). `Repository.detectDefaultBranch()` throws when git cannot be asked and answers nil when no name is found; `Repository.fallbackDefaultBranch` is "main"; `pullDefaultBranch()` uses `detectDefaultBranch() ?? fallbackDefaultBranch`.
- Tests: `DefaultBranchResolverTests`, `UnbornRepositoryTests.theCachedDefaultFollowsAnUnbornBranchRename`, `RepositoryProbeTests` (two uses), `WorkspaceScanTests`, `GitSpawnCountTests`, `CheckoutMonitorTests`, and every test that passes a scanner closure with seven parameters or builds `WorkspaceScan.run(... defaultBranches:)` (`ScratchController`, `RaceFixture`, `RestoringRowTests`, `AppControllerTests`, `WorkBudgetTests.noScan`, `SidebarProjectionTests`, `ControllerRaceTests`, `OperationIssueTests`, `Snapshots/Fixture.swift`).

## Change

1. Delete `DefaultBranchResolver.swift`. Delete `CheckoutMonitor.defaultBranch`, `defaultBranches`, the `defaultBranch` comparison in `applyScan`, and the last scanner parameter (the typealias, the call in `startPass`, the doc comment). Delete `WorkspaceScan.defaultBranch`, its init parameter, the `defaultBranches` parameter of `run` and its `retain` and loop lines. Update every scanner closure and `WorkspaceScan.run` call (list under Today) to six parameters.
2. If nothing reads `RepositoryProbe.Locations.commonDirectory` once the resolver is gone (check with grep), delete the field and the `--git-common-dir` question from the probe; the probe then asks for `HEAD` and `config` only. The tests' probe counter in `RepositoryProbeTests` matches on `--git-common-dir` today; make it match on `--git-path`.
3. `ProjectActions`: add a `PerRow<String?>` beside `defaultBranchRows` holding the name last read for each project (default nil), and one method, `loadDefaultBranchName(of:)`, that asks git off the main actor with `Repository.detectDefaultBranch()` and stores `result ?? Repository.fallbackDefaultBranch` when git answered. When git throws (a timeout, not a repository) it stores nothing and leaves a name already known standing. It reads at each call. Add a read accessor for the row's value. After a pull or a rebase of a project finishes (`pullDefault` and the rebase path, whatever their result), call it again for that project.
4. `Views/SidebarRows.swift`, project row context menu: the Pull button's title is "Pull " plus the stored name, else "Pull Default Branch". Call `loadDefaultBranchName(of:)` from a `.task(id:)` keyed by the project's id on the project heading row itself (an ordinary view, so the task runs when the row appears), not from inside the context menu: a task attached to a menu item is not known to run on macOS. Leave the rest of the menu, including `isChangingDefaultBranch`, as it is.
5. `SheetCoordinator.presentNewTask`: drop `known`; the draft always asks git inside the background preparation. `TaskDraft.initial` loses its `defaultBranch` parameter and the doc sentence about the monitor. `presentJiraProjects` builds `ProjectPreparation` with no default branch, and the Edit Project sheet asks git itself when it opens: give `ProjectSheetModel` one method that reads `Repository.detectDefaultBranch()` off the main actor for the edited project and stores the name, called from a `.task` on the sheet. The editing header keeps its `· branch` text and draws it once the name is known; until then, and when git cannot be asked, the header shows the folder alone. The add path still sets `defaultBranch` from its preparation and still shows it in the Folder help line.
6. Delete the "The monitor reads each project's default branch on every pass" comment in `presentNewTask`, and the doc lines in `CheckoutMonitor`, `WorkspaceScan` and `Repository+DefaultBranch.swift` that say a poll feeds the label.

## Keep

- `Repository.defaultBranch()`, `detectDefaultBranch()`, `fallbackDefaultBranch`, `pullDefaultBranch()`, `rebaseDefaultBranch()`: live, used by Pull, New Task, Add Project and the Operator.
- `BranchResolver`, `RemoteResolver`, `RepositoryProbe`, `WatchedFileCache`: the branch and remote reads stay polled.
- `ProjectActions.defaultBranchRows` and the Pull item's disabled state while a pull or rebase runs.
- "Never store a failure": a git that cannot be asked must not write "main" into the label.

## Decisions already taken

- A name that git answered stays until a later read replaces it. A project whose first read fails shows "Pull Default Branch" until one succeeds (the next time its row appears, or after a pull).
- The label read costs one `for-each-ref` per project each time its heading row appears, and one after each pull or rebase. No debounce and no timer.
- A default branch renamed on the host while AiTerm runs shows its old name until the row appears again or a pull runs. Real but rare, and the pull itself always asks git, so nothing wrong is pulled.
- The Edit Project header may show its branch a moment after the sheet opens. That is the one visible difference of this step, and it is accepted.
- A project that is not a repository has no Pull item in the first place (the item is only for GitLab and GitHub projects).
- No new saved state; the stored names live in memory only.

## Tests

- Delete `DefaultBranchResolverTests` as a suite. Survivors: move `namesOriginsDefaultBranch` and `resolvesALinkedWorktreeToTheRepositorysDefault` to a `Repository.detectDefaultBranch()` suite (`DefaultBranchPullTests` or `WorktreesTests`), calling `detectDefaultBranch` instead of the resolver; the cache, reftable, negative-answer and timeout tests test the deleted cache. `UnbornRepositoryTests.theCachedDefaultFollowsAnUnbornBranchRename` goes (the unborn branch is already covered by `theUnbornBranchIsOfferedAsTheBase`).
- `RepositoryProbeTests`: remove the `DefaultBranchResolver` lines from `theThreeResolversShareOneSpawn` (it becomes two, `spawns(shared: false) == 2`) and from `aFolderThatIsNotARepositoryIsProbedOnceForAllThree` (rename: for both). If `commonDirectory` went, drop it from the two `Locations` assertions in that file.
- `WorkspaceScanTests`, `CheckoutMonitorTests.aPassHandsWhatItFoundToTheWorkspace` (drop the `defaultBranch` argument and assertion), `GitSpawnCountTests` (drop `defaultBranches` and the `scan.defaultBranch` assertions; the two `for-each-ref` reads per pass disappear, so `theFirstPassSpawnsWhatEachDirectoryNeedsOnce` and `aFixCloneInTheTemporaryDirectory...` first-pass numbers fall by two: set them to what the code now spawns, and report the numbers; 2i turns them into ceilings).
- `TaskCreatorTests.aDraftTakesTheDefaultBranchItIsGivenWithoutAskingGit`: delete the "given" half, keep the "asked" half under a name that says the draft asks git.
- Add, for `ProjectActions`: loading the name stores what git says, a later failing load leaves it standing, a first failing load leaves nil, and a finished pull reads it again. Add, for `ProjectSheetModel`: editing a project reads its default branch when asked and leaves it nil when git cannot answer. Use `FlakyGitRunner` (times out while `failing` is set) and `ScratchController`.
- No fixture is re-recorded.

## Proof

While iterating: `scripts/test.sh swift -- --filter RepositoryProbeTests`, `WorkspaceScanTests`, `GitSpawnCountTests`, `CheckoutMonitorTests`, `TaskCreatorTests`, `DefaultBranchPullTests`, `AppControllerTests`, `SidebarProjectionTests`. Snapshot capture is not needed: the menu is not drawn in a snapshot. Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "DefaultBranchResolver\|defaultBranches\|checkouts.defaultBranch" app` returns nothing.
- `grep -rn "defaultBranch:" app/Sources/AiTermCore/Workspace app/Sources/AiTermCore/Tasks` returns nothing.
- No test constructs a scanner closure with seven parameters.
- Suites above and plain `scripts/test.sh` are green.

## Not in this step

Per-key back-off and reftable (2a). Turning spawn-count equalities into ceilings (2i). The Pull menu's later wording and grouping (8d).
