# 1i. Remove Find a Fix

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1f (it left the Fix wiring in `SheetCoordinator` and
`AppController` for this step) and 1a to 1h. Comes from: PL F1 and the maintainer's decision of 16 Nov (removed, with
its Settings switch and its README line).

## Why

Find a Fix was built in one sweep on 14 Oct: when "Pull main" finds a diverged branch, when the banner's Rebase
conflicts, or when New Review's create is refused for the same reasons, a button asks Claude to inspect an isolated
clone, propose a fix, and land it after Apply. It is about 4,400 lines with its tests, behind a Settings switch
("Help with problems"), used on two surfaces, and guarded as if the agent were hostile. The maintainer decided it
goes. After this step a diverged pull shows its banner with its Rebase button and no Fix button; a conflicted rebase
and a refused review show their plain sentence, including "Rebase it by hand."; Settings has no switch; no clone is
made, no sandbox runs. `AgentProcess` and `RegularFile` are not Fix's: the Oracle and the worker guard use them.

## Today

All paths under `app/Sources/` unless stated. Re-run `grep -rniE "Fix[A-Z]|fixer|HelpWithProblems|Find a Fix|Help with problems|fixPipeline|fixSession|makesFixes|announceFix|announceBackup|FixClone|FixLanding" app daemon compat scripts docs/*.md README.md`.

**Core folder `AiTermCore/Fix/` (14 files).** Fix-only, all deleted: `FixClone.swift`, `FixerLaunch.swift`,
`FixerPrompt.swift`, `FixGuard.swift`, `FixPipeline.swift` (with `FixLookSession`), `FixProposal.swift`
(`FixLookAnswer`, `FixApplyAnswer`, `FixProposal`, `FixLook`), `FixRefusal.swift`, `FixRequest.swift`
(`FixRequest`, `FixRetry`), `HelpWithProblems.swift` (`FixerAgent`, `HelpWithProblems`, `FixerResolution`),
`Repository+FixLanding.swift` (`FixLanding`, `Repository.landFix`), `TaskWorkflow+FixLanding.swift`
(`landFix`), `VerifySandbox.swift`. Shared and kept: `AgentProcess.swift` (used by `Operators/SecondOpinionRunner.swift`
in the app target, and by `FixPipeline`/`VerifySandbox`), `RegularFile.swift` (used by `Operators/ChallengeLaunch.swift`
about line 396 and `Operators/WorkerGuard/WorkerGuardLaunch.swift` about line 31). `Agents/HeadlessRun.swift`
(`HeadlessRun`, `HeadlessInvocation`) is shared with the Oracle: keep it whole.

**App target.** `AiTerm/FixSession.swift` (whole), `AiTerm/Views/FixViews.swift` (whole: `FixOffer`,
`FixFooterPresentation`, `BannerFixPresentation`, `FixProposalBlock`, `FixBusyLine`).

**Wiring outside the folder, and what each becomes:**

1. `AiTermCore/Interface/OperationIssue.swift`: the `fix: FixRequest?` field and init parameter go; the stale check
   `if case .pullDefault(let id)? = fix?.retry ...` goes; `pullRefused` builds its issue without a fix (actions
   `[.rebaseDefault(project)]`, reason as today, `projectPath` parameter dropped); `rebaseRefused` keeps git's
   sentence whole, "Rebase it by hand." included, with git's words as `detail` and no fix (the stripping of that suffix
   existed only so the Fix button could stand in for it). The doc comments about the Fix go.
2. `AiTerm/Notices.swift`: delete `fixSession`, `makeFix`, `makesFixes(with:)`, `offerFix(for:)`, `cancelFix()`,
   `fixEnded()`, the `makeFix` init parameter, and every "a fix is at work" branch: `report` (the hold while a fix
   holds the surface), `dismissIssue` (the `.applying`/`.done` guard), `clearIssue` and `dropStale` calls to
   `offerFix`. What remains: one shown issue, one held issue (behind a question), the withdrawn and issue hooks, the toast.
3. `AiTerm/AppController.swift`: delete `fixPipeline` (property and `init` line), `makeFix(for:)`, the line
   `notices.makesFixes { ... }`, `FixClone.sweep()` in `start()` and its comment, `notices.fixSession?.stop()` and
   `if case .newReview(let model)? = sheet { model.fixSession?.stop() }` in `shutdown()`, the `fixPipeline:` argument to
   `SheetCoordinator`, and the comment lines about Fix on the `fixPipeline`/`makeFix` doc blocks. The `.rebaseDefault`
   branch of `perform(_:)` stays.
4. `AiTerm/AppPorts.swift`: the `fixPipeline` field, its init parameter and the sentence about it. `AppController.live`
   passes `fixPipeline: nil` (about line 614): delete that argument.
5. `AiTerm/SheetCoordinator.swift`: the stored `fixPipeline`, its init parameter, and in `makeReviewModel` the
   arguments `fixer:`, `pipeline:`, `fixLanded:`, `backupKept:`. The `workflow` property and parameter stay if anything
   else reads them (check: `grep -n "workflow" AiTerm/SheetCoordinator.swift`); if `TaskWorkflow` was only for the Fix
   lane, remove the property.
6. `AiTerm/ProjectActions.swift`: `pullDefault(project:after:)` loses its `after` parameter, the `keptSentence`
   joins in the success and failure closures, and the `pull == nil, let fix` toast. `rebaseDefault` passes
   `rebaseRefused(error, in: project.id)` without `projectPath`. `AppController.perform(.rebaseDefault)` is unchanged.
7. `AiTerm/TaskLauncher.swift`: delete `announceFix` and `announceBackup`.
8. `AiTerm/AgentIntegrations.swift`: delete `helpWithProblems` (property, `didSet`, the `HelpWithProblems.load` in
   `init`), `fixer`, `fixModel`, `fixPipeline(for:git:workflow:)`; rewrite the comments on `operatorProfile` and
   `taskModel` that name the Fix. `operatorProfile` itself stays (the Operator reads it).
9. `AiTerm/CreationModel.swift`: `CreationFailure` loses `fix`, `byHand`, `afterFix`, `shownReason`, `reasonByHand` and
   the `request(...)` helper; its `init(_ error:projectPath:)` keeps `recovery` (`.switchProjectFolder`, `.rebase`,
   `.initializeRepository`) and sets `reason` to the sentence whole (for a conflicted rebase that means the
   sentence still ends "Rebase it by hand."; for a diverged branch it is the sentence plus `rebaseOffer`, as today);
   the `projectPath` parameter is dropped if nothing else needs it. `CreationKind.fixApplies` and its default go.
   `CreationModel` loses `fixSession`, `createdAfterFix`, the `fixer`, `pipeline`, `fixLanded`, `backupKept` stored
   properties and init parameters, `PrimaryAction`/`primaryAction()` (only `.applyFix` distinguished it), `applyFix()`,
   `makeFixSession`, `landedWithoutCreate`; `show(_:)` becomes "set `error`"; `dropFailure()` clears the error when
   there is one. `recoverAndCreate`, `create(after:)` and `refuse(_:)` stay.
10. `AiTerm/ReviewCreationModel.swift`: `fixApplies`, the init parameters `fixer`, `pipeline`, `fixLanded`,
    `backupKept` and what they forward, the comment about "its Fix". `AiTerm/TaskCreationModel.swift` has none.
11. `AiTerm/Views/SheetChrome.swift` `CreationFooter`: parameters `fix`, `canApply`, `applyFix` go; the body draws
    `Notice` for the failure (`error.reason`; tooltip `error.detail`), the "no agent can run" note, the waiting notice,
    then `SheetFooter` with the failure's `recovery` button when there is one, the sheet's own Cancel/Back and
    primary. The helper functions `canSubmit(_:)`, `submit(_:)`, `primaryTitle(_:)` and the `Applying…` text go. The
    doc comment loses its Fix paragraphs.
12. `AiTerm/Views/CreationSheet.swift`: the `fix:`, `canApply:`, `applyFix:` arguments, the
    `.interactiveDismissDisabled(model.fixSession?.state == .applying)` modifier (keep any other dismissal guard the
    modifier chain has while `creating`), the `.onChange(of: model.createdAfterFix)` block, the `model.fixSession?.cancel()`
    in `.onDisappear`, and the `model.primaryAction() == .applyFix` branch in the submit path.
13. `AiTerm/Views/SidebarView.swift`: `IssueBanner` loses `fix`, `cancelFix` and `BannerFixPresentation`: it draws
    `Notice(title: issue.title, description: issue.reason, help: issue.detail)` with links
    `issue.actions` (each `Button(action.title) { perform(action) }`) then Dismiss, exactly the layout the
    "unavailable" state has today. `FixOfferLabel` goes. The call site stops passing `fix` and `cancelFix`.
14. `AiTerm/Views/HarnessSettingsPane.swift`: delete `HelpWithProblemsGroup` and its place first in the pane; the
    `agents: AgentIntegrations` parameter if nothing else in the pane reads it (check and fix `SettingsView`); in the
    closing `HelpText` delete "The install and Help with problems both take effect immediately; Cancel does not undo
    them." and say "The install takes effect immediately; Cancel does not undo it." (the plan's step 8h lists this copy: it is done here).
    `Views/SettingsView.swift` (about line 60 comment), `Views/SettingsCard.swift` (about line 120 comment on a group
    that is its heading's switch alone: check whether another group still is; if none, delete the special case, else
    reword the comment), `Views/Notice.swift` (doc comment mentions Find a Fix's states).
15. `AiTerm/Snapshots/SheetSnapshots.swift` (about lines 113-160: New Review's footer through a Fix, `fixProposal`,
    `fixFooter`), `Snapshots/SidebarSnapshots.swift` (about lines 108, 131-145, 190-200: the banner's Fix states,
    `mainProposal`, `fixBanner`), `Snapshots/SettingsSnapshots.swift` (about line 41 comment): delete the Fix
    snapshots and every image name they produce (`review-fix-*.png`, the banner Fix images); keep the plain
    "unavailable" and issue banner images. `scripts/snapshots.sh` needs no change unless it names them (check).
16. `AiTerm/Operators/SecondOpinionRunner.swift` comments "as a fix's agent is" (about lines 21, 57),
    `AiTermCore/Operators/ChallengeLaunch.swift` header (about lines 8-9) and `AiTermCore/Tasks/TaskWorkflow.swift`
    (about line 34): reword to say what the code does. `AiTermUI/Metrics.swift` and `Tests/AiTermUITests/MetricsTests.swift`
    (about line 6) mention the Find a Fix button as a user of `Size.inlineMark`: reword; do not change a token.
17. Compat: `compat/launch.json` has the entries `fixerApply` and `fixerLook`;
    `app/Tests/AiTermCoreTests/CompatContractTests.swift` builds them (about lines 32-60, a `FixClone`, `FixRequest`,
    `FixProposal`, `fixer(_:)`) and has `theFixersSchemaAnswerReadsAsTheAppReadsIt` (about line 180);
    `daemon/tools/compat_capture.py` (about lines 719-731) runs the fixer's look and saves `headless/fixer-look.json`.
18. Docs: `README.md` lines about 104-105 (the "Recover from Git problems" bullet), `docs/configuration.md`
    (line 6 mentions Help with problems; the `### Help with problems` section about lines 39-46; check the anchor is not
    linked elsewhere with `grep -rn "help-with-problems" .`), `docs/architecture.md` (about lines 48, 61, 136: "the Fix
    pipeline", "Fix landing", "`FixSession` owns an isolated clone ..."), `docs/design/ui-patterns.md` (about lines 44, 58,
    100: names `FixOfferLabel`, "Fix recovery", `FixProposalBlock`, `FixBusyLine`). `docs/design/design-system.html`
    (29 mentions) is the published mirror synced from code by the `design-system` skill on request: do not edit it by hand.
19. Defaults: `HelpWithProblems.key` is `operator.helpWithProblems`. The value stays in a person's defaults, unread. No
    cleanup code.

**Tests.** Whole files that only test Fix: `FixSessionTests`, `FixerSettingsTests`, `BannerFixTests`,
`FixPresentationTests`, `ReviewFixTests`, `FixPipelineStub.swift` (AiTermTests); `FixLiveTests`, `FixerLaunchTests`,
`FixCloneTests`, `VerifySandboxTests`, `FixerChoiceTests`, `FixPipelineTests`, `FixLandingTests`, `FixGuardTests`,
`FixProposalTests`, `Support/FixPipelineFake.swift` (AiTermCoreTests). Mixed files (edit, do not delete): `NoticesTests`
(`fixing(_:_:)` helper and the tests about a Fix: `aNewIssueWaitsWhileAFixIsBusy`, `anIssueWithAFixGetsASessionOfItsOwn`,
`aProposalHoldsTheBannerUntilItIsCancelled`, `dismissingStopsTheLook`, `whileAFixIsAppliedTheBannerCannotBeDismissedOrReplaced`,
`anEndedFixLetsTheBannerGo`, `dismissingDeclinesAProposalAndRemovesItsClone`, `clearingTheIssueLetsALookGo`, and the
Fix halves of `aHeldQuestionOutlastsAPlainReport` and `aHeldQuestionReplacedByAnotherIsWithdrawn` if they build a session);
`OperationIssueTests` (`aDivergedPullOffersRebaseAndAFix`, `aConflictedRebaseOfMainOffersTheFix`,
`anyOtherRebaseFailureOffersNoFix`, `aPlainGitFailureOfAPullKeepsItsWordsAsDetailButOffersNoFix`,
`anIssueWhoseFixRetriesAGoneProjectIsStale`); `ReviewCreationModelTests` (`aRefusalTheFooterCanFixCarriesTheFix`,
`theFixRunsAndThenTheCreateItStopped`, `aFixThatFailsSaysWhyAndCreatesNothing`); `PullDefaultTests` (about lines 85
and 135: the `fix:` expectation and the comment); `GitSpawnCountTests.aFixCloneInTheTemporaryDirectoryCostsAPassNothing`;
`CompatContractTests`; `ScratchController` and `RaceFixture` (`fixPipeline:` parameters, about 78-87 and 29-83);
`AgentProcessTests` stays untouched; `FixerLaunchTests` also holds the only direct tests of `RegularFile.read` (about
lines 170-195).

## Change

1. **Move the two survivors.** `git mv` `AiTermCore/Fix/AgentProcess.swift` and `AiTermCore/Fix/RegularFile.swift` into a new
   `AiTermCore/Process/` folder, content unchanged except `RegularFile`'s doc comment, which becomes: a file AiTerm
   reads that an agent can write, only a regular file, never through a symlink, never by waiting on a FIFO, and only up to
   a limit; read for the Oracle's answer file and the worker guard's scope file. Move the direct `RegularFile.read`
   tests (symlink, FIFO, limit, absent) out of `FixerLaunchTests` into a new `RegularFileTests.swift` in `AiTermCoreTests`,
   assertions unchanged.
2. **Delete the Core folder files, `FixSession.swift` and `FixViews.swift`** listed above, then work outward through
   wiring points 1 to 15 in that order, building (`scripts/swift.sh build` is not allowed alone: use the filtered test
   commands under Proof) after each group until it compiles.
3. **Banner.** `IssueBanner` and `OperationIssue` as in points 1 and 13: the shown banner for a diverged pull is the
   title, the reason, a Rebase link and Dismiss; for a conflicted rebase the title, the sentence ending "Rebase it by hand.",
   git's words as tooltip, and Dismiss.
4. **New Review footer.** As in points 9 to 12: the failure as a `Notice` (reason as title, git's words as tooltip, as
   the footer drew them with no fix offered), the recovery button for a diverged branch (Rebase) or the folder switch,
   then the sheet's buttons.
5. **Settings.** The pane starts with the first agent card; the closing help line as in point 14.
6. **Compat and snapshots.** Delete the Fix snapshots (point 15) and handle compat (point 17). Remove `fixerApply` and `fixerLook` from what
   `CompatContractTests` records and the test `theFixersSchemaAnswerReadsAsTheAppReadsIt`; re-record `compat/launch.json`
   (Tests). In `compat_capture.py` remove the fixer's look run and its `headless/fixer-look.json` output and reword its
   docstring ("the Oracle's challenge ... and"); the saved capture `daemon/tests/fixtures/compat/claude/headless/fixer-look.json`
   is never edited: it stays, unread (say so in the report).
7. **Docs** as in point 18.

## Keep

- `AgentProcess`, `RegularFile`, `HeadlessRun`, `HeadlessInvocation` (`sessionID`, `answerFile` fields), `SecondOpinionRunner`,
  `WorkerGuard`, `ProcessRunner`, `PipeDrain`.
- The banner's other actions (`keepBranch`, `deleteBranch`, `rebaseDefault`), `OperationIssue.disconnected`,
  `branchKept`, `rebaseOffer`, `WorktreeError.rebaseByHand`, `Repository` rebase and pull code, `CreationFailure.Recovery`.
- `OperatorProfile`, `AgentIntegrations.operatorProfile`, `taskModel`, `ModelSettings`.
- The held-behind-a-question rule in `Notices`: a report with nothing to offer waits behind a shown question.
- `TaskWorkflow`'s lanes and creation, removal and pull: only the `landFix` extension goes.
- The `operator.helpWithProblems` defaults value.
- `docs/design/design-system.html`, `docs/reviews/`.

## Decisions already taken

- **A diverged Pull:** banner with Rebase and Dismiss. **A conflicted Rebase of the default branch:** banner with Dismiss
  and the whole sentence, "Rebase it by hand." included. **A refused review:** its failure and, for a diverged branch,
  Rebase, as today minus Find a Fix. No replacement feature; no pointer to an agent.
- **A banner about a project that is then removed:** an issue with no actions and no subject (the conflicted rebase)
  no longer goes stale when its project is removed; it stays until dismissed. Real but harmless (a sentence); no code.
- **Quit while a fix would have run:** nothing to stop; `shutdown()` loses those two lines.
- **A leftover `aiterm-fix-*` clone in the temporary folder from an earlier crash:** macOS cleans the temporary folder;
  no sweep is kept.
- **`CreationFooter` callers:** New Task's and New Signal's footers never passed a fix; they compile unchanged.
- **Tests that used `FixPipelineStub`/`FixPipelineFake` for something besides Fix** (a stub pipeline passed to build a
  controller): they pass nothing now.
- **Visible change** (planned, agreed): no Find a Fix button on the banner or in New Review's footer, no Help with problems
  switch. Nothing else moves; the remaining banner and footer draw with today's sizes.

## Tests

Delete every file and test named under Today, each as "behaviour deleted". Survivors for what the Fix tests happened to prove
about code that stays: `AgentProcessTests` (process groups, timeouts), the moved `RegularFileTests`, `ChallengeLaunchTests` and
the Oracle's own tests (headless answers), `WorkerGuard` tests. Adjust:
- `OperationIssueTests`: keep `onlyADivergedPullOffersTheRebase`; replace the Fix tests with: a diverged pull's issue has
  one action `.rebaseDefault` and its reason ends with `rebaseOffer`; a conflicted rebase's issue has no action, the reason
  ends "Rebase it by hand." and its detail is git's words; any other failure is plain; an issue about a gone
  task or `rebaseDefault` project is stale.
- `PullDefaultTests`: the diverged-pull and conflicted-rebase tests assert those two issues.
- `NoticesTests`: keep every non-Fix test; add none.
- `ReviewCreationModelTests`: add one test: a conflicted-rebase refusal shows its reason whole with no recovery, a diverged
  branch shows Rebase; both through `CreationFailure`'s error initialiser.
- `ScratchController`, `RaceFixture`: drop the `fixPipeline` parameter and its passing.
- `CompatContractTests`: recording and checking `launch.json` without the two entries.
**Re-record** `compat/launch.json` and, if it changes, `compat/drivers/*`: `AITERM_RECORD_COMPAT=1 scripts/test.sh swift -- --filter CompatContractTests`
(a plain test run; it never opens a window or spends quota; `scripts/compat-check.sh` is the maintainer's and you never run it),
then run it again without the switch. Expect only the removal of `fixerApply` and `fixerLook` from `launch.json`; `drivers/` must not
change. `compat/` has no `PROVENANCE.md`: do not create one; name the change in your report.

## Proof

`scripts/test.sh swift -- --filter OperationIssueTests`, `NoticesTests`, `PullDefaultTests`, `ReviewCreationModelTests`,
`RegularFileTests`, `AgentProcessTests`, `ChallengeLaunchTests`, `SignalWorkerProfileTests` (the worker guard),
`SheetHeaderTests`, `HarnessSettingsLayoutTests`, `CompatContractTests`, `AppControllerTests`, `SidebarProjectionTests`;
then plain `scripts/test.sh` in the background. Snapshot capture: `scripts/snapshots.sh build/refactor-1i`, then compare with
`build/refactor-before`: New Review's footer states, the banner states for a diverged pull and a conflicted rebase, and Settings ›
Agents differ only by the missing Find a Fix button and Help with problems group; the unavailable-state banner and footer are pixel
equal. If `build/refactor-before` is missing, say so.

## Done when

- `grep -rniE "FixSession|FixClone|FixRequest|FixRetry|FixLanding|FixRefusal|FixGuard|FixPipeline|FixProposal|FixerAgent|FixerResolution|FixerLaunch|FixerPrompt|VerifySandbox|HelpWithProblems|makesFixes|announceFix|announceBackup|fixSession|fixPipeline|createdAfterFix|FixOfferLabel|FixBusyLine|BannerFixPresentation|FixFooterPresentation" app daemon compat scripts docs/*.md docs/design/ui-patterns.md README.md`
  returns nothing.
- `grep -rniE "Find a Fix|Help with problems" README.md docs/*.md docs/design/ui-patterns.md app/Sources app/Tests` returns nothing.
- `AiTermCore/Fix/` no longer exists; `AiTermCore/Process/` holds `AgentProcess.swift` and `RegularFile.swift`.
- `compat/launch.json` has no `fixer*` entry; `compat_capture.py` has no `fixerLook`.
- Plain `scripts/test.sh` green; the report lists the deleted files (counts of lines and tests), the survivors named above, the
  snapshot comparison and the stale `fixer-look.json` capture.

## Not in this step

- The `operator.helpWithProblems` default cleanup: never. The design-system page sync: on request, after the phase.
- Shared headless-run constants and effort tables: 8i. The Oracle's rename: 1j (its comments about "as the Fix's look" are reworded here only where
  they name Fix).
- The Operator profile save and other Settings tidy items: 8h (its Help with problems copy item is already done here).
