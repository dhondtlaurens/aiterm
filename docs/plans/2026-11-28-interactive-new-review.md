# Restore interactive New Review

## Goal

Restore the user-facing New Review action's behavior from 63c44053, before manual-review merge
42730139: choose a vendor, model and effort, provide a prompt or installed skill, and start an
interactive agent that remains available for follow-up messages. Cover both an existing task's
checkout and a review's new checkout. Fix forward from current main; preserve subsequent work.

PSG's adversarial-review skill owns the decision to run a read-only, one-shot reviewer. AiTerm's
background-tab API continues to execute the caller's command without inferring review mode from
a prompt, skill, title or vendor. Preserve Operator worker and helper routing and Signal contracts.

## Approach

The user agreed to this approach on 28 November. The clean branch starts at main 0e09c34c;
the only change after the regression merge is the README image, which stays intact. Compare with
63c44053 to recover behavior, rather than reverting the merge wholesale.

Restore TaskWorkflow.reviewCommand to compose the selected draft's prompt and build the ordinary
interactive AgentCommand in the owner's checkout. Route new manual review checkouts through the
existing TaskWorkflow.createReview/checkOut path, keeping branch preparation, slug reservation,
.worktreeinclude copying, agent setup and launch warnings. Preserve ownership rechecks, missing
checkout errors, workspace persistence, task metadata, existing-window tab creation, absent-window
reopening and the stale-window not-found fallback. Keep the merge's useful command-delivery error
reporting even though request-file cleanup is no longer needed. Remove the manual-review-only
recovery wording in TaskLauncher.create and reportMade: a disconnected new review tells the user
to reopen its saved row and start the agent there once reconnected, and command preparation failure
tells them to start the agent manually in its window. Neither directs them to submit New Review
again. Cover these two new-checkout recovery branches explicitly.

Restore NewReviewSheet's normal skill-loading task and shared prompt help. Keep native Antigravity
plugin and Pi package discovery, the existing owner's checkout as discovery context, asynchronous
completion refresh, per-agent invocation syntax and @ file references. Preserve selected model and
effort plus the user's prompt and enabled ticket/MR descriptions, including the existing safe
handling of long prompts.

Audit every helper addition in 42730139 against current callers. Once interactive launches replace
its only production entry points, remove the manual-only pinned request, snapshot, isolated
Antigravity profile, headless runner and answer parsing, plus tests asserting that obsolete contract.
Remove capture/environment branches in shared process code only when no caller needs them. Keep
the normal AgentProcess/HeadlessRun paths used by the Oracle and query writer, and retain useful
general output-truncation reporting. Worker guards, read-only worker launch options and generic
background-tab command staging are independent and remain supported.

## Marketplace audit

The user also requested inspection of the separate marketplace source checkout. Its adversarial
review script builds its own read-only headless CLI invocation, calls sessions.list and tab.create
with background=true and a unique tabKey, appends an explicit shell exit, and reads its own
result/status files. It has no dependency on ManualReviewEntry or --manual-review. Existing tests
cover reviewer flags, pinned settings, prompt quoting and session lookup. Run its focused tests and
compare that caller with AiTerm's launch boundary. No marketplace source change is currently needed;
record any concrete mismatch discovered during proof before expanding the implementation scope.
Leave unrelated marketplace working-tree files untouched. Keep private source details outside this
public repository.

Audit result on 28 November: all 21 focused adversarial-review Node tests passed in the marketplace
source checkout. Its caller script is byte-identical to the installed copy used for this plan's
challenge. No related marketplace source fix was found; background API compatibility proof stays
in the AiTerm implementation. No marketplace files were changed.

The implementation review exposed a separate marketplace runner limitation: a diff above
Antigravity's argument budget is omitted from its brief, and the fallback git reads can fail when
the worktree's shared git directory lies outside its sandbox. This review used a full patch and
reference files exported into an ignored build directory. That runner limitation is a separate
follow-up; the marketplace's one-shot/background command ownership needs no change for this fix.

## Files

- Modify app/Sources/AiTerm/TaskLauncher.swift: restore both manual interactive launch paths and
  ordinary interactive recovery instructions in create/reportMade, while keeping current ownership,
  fallback, persistence and delivery-error behavior.
- Modify app/Sources/AiTermCore/Tasks/TaskWorkflow.swift: restore the ordinary review command and
  remove the manual-only creation path and pending-request field.
- Modify app/Sources/AiTerm/Views/NewReviewSheet.swift: restore shared prompt help and installed
  skills. Existing SheetSnapshots fixtures already exercise the affected states and stay unchanged.
- Remove app/Sources/AiTerm/ManualReviewEntry.swift,
  app/Sources/AiTermCore/Tasks/ManualReview.swift,
  app/Sources/AiTermCore/Git/Repository+ManualReview.swift,
  app/Sources/AiTermCore/Harnesses/ManualReviewAgy.swift and
  app/Sources/AiTermCore/Harnesses/ManualReviewAnswer.swift after the caller audit. Modify
  app/Sources/AiTerm/AiTermApp.swift, app/Sources/AiTerm/Operators/HeadlessRun.swift and
  app/Sources/AiTermCore/Harnesses/Harness+Agents.swift to remove only their manual-helper entry points.
- Modify app/Sources/AiTermCore/Process/AgentProcess.swift and app/Sources/AiTermCore/PipeDrain.swift
  only as justified by the caller audit, preserving common process cancellation, draining and
  truncation behavior.
- Modify app/Tests/AiTermTests/ReviewInTaskTests.swift,
  app/Tests/AiTermTests/ReviewCreationModelTests.swift, app/Tests/AiTermTests/NewReviewSheetTests.swift,
  app/Tests/AiTermCoreTests/TaskWorkflowTests.swift and app/Tests/AiTermCoreTests/AgentProcessTests.swift.
  Replace one-shot assumptions with interactive launch, skill and delivery-error coverage.
  Reuse RaceFixture.swift without modifying it.
- Remove obsolete app/Tests/AiTermTests/ManualReviewRunTests.swift,
  app/Tests/AiTermCoreTests/ManualReviewTests.swift and
  app/Tests/AiTermCoreTests/ManualReviewAnswerTests.swift after mapping any still-relevant assertions
  to surviving tests.
- Create app/Tests/AiTermTests/ReviewLaunchTests.swift for hosted form submission, native skill/file
  selection, agent-switch discovery, and captured command execution with a same-session follow-up.
- Modify daemon/tests/test_service.py where needed to demonstrate an explicitly requested
  background helper's command, result and exit using the unchanged tab API. Preserve existing
  worker/helper identity, idempotency and isolation tests.
- Modify README.md and docs/configuration.md to describe interactive manual reviews and the same
  launch permissions as manual tasks, including Codex/Antigravity's explicit bypass flags.
  Historical plans remain historical; do not replace the current README image.

## Proof

1. Add regressions before changing the launch logic. Drive the hosted NewReviewSheet/model submit
   into TaskLauncher with hermetic repositories and a recording daemon. Cover an existing task's
   window, no saved window, stale closed window, and a new review checkout. Verify destination,
   row/window ownership, branch preparation and .worktreeinclude behavior. Preserve failure coverage;
   add new-checkout cases for a disconnected daemon and a failed command build that assert the
   restored interactive recovery instructions and retained row/checkout.
2. Inspect the actual daemon-bound command for each supported vendor, model and effort, initial
   prompt/skill, @ reference and optional descriptions. Assert ordinary interactive arguments and
   permissions, with no manual helper, print/exec mode or automatic exit. Include long or quoted
   prompts so the staged prompt reaches the receiver intact. Do not merely call the restored
   workflow directly: the tests must detect a manual sheet wired to the wrong launcher again.
3. Execute the captured manual commands with isolated CLI stand-ins in a persistent terminal/process
   harness. Record argv, cwd, first prompt and process/session identity; deliver a second message
   and require a response from that same still-running receiver. Clearly label this as isolated
   launch/session proof, not observation of a real vendor model.
4. Restore hosted editor coverage that types an installed skill and accepts the actual completion,
   then submits it. Cover vendor syntax, @ completion, late discovery refresh, agent changes and
   owner-checkout versus prospective-checkout context. Retain native Antigravity plugin and Pi
   package SkillCatalog/compat fixtures; do not regenerate them for this fix.
5. Separately submit an explicit keyed background helper command through tab.create. Execute the
   delivered shell command, require its expected result/status and exit, and verify role tagging
   precedes delivery. Keep same-key worker/helper retries and helper events isolated from the
   genuine worker's conversation, state, reply target and Operator wake behavior.
6. Run the marketplace adversarial-review script's focused Node tests, inspect its actual submitted
   command contract, and record whether a source change is necessary. No marketplace release,
   installation or personal profile changes are part of this plan.
7. Run focused Swift suites through scripts/test.sh, affected daemon tests, and the repository gate
   scripts/test.sh. Inspect before/after sheet captures under scripts/snapshots.sh because the
   restored help and suggestions are visible. Do not change Signal goldens or saved-workspace format.
8. Real app acceptance belongs to the maintainer under docs/workflow/verify.md: exercise New Review
   in both destinations with a real installed agent, observe the selected settings and immediate
   initial response, then get a follow-up response in that same conversation. Observe an explicit
   PSG background helper returning findings and exiting. Record what was actually observed; do not
   claim the isolated receiver establishes native agent behavior. Do not launch or replace the live
   app from an agent session.

## To-dos

- [x] Restore existing-task interactive review submission with red/green boundary tests; retain both
  closed-window fallbacks, metadata and command-delivery errors.
- [x] Restore new-checkout interactive submission and prove normal checkout preparation plus the
  selected settings/prompt through the same boundary, including a same-session follow-up and both
  recovery-message regressions. Rewire TaskLauncher to the existing workflow.createReview in this
  slice; keep createManualReview and Created.manualReview until the cleanup slice removes their
  callers and obsolete tests together, so each slice still compiles.
- [x] Restore installed skill/command and @ completion in the hosted sheet, including Antigravity
  and Pi native discovery and submission of the selected invocation.
- [x] Complete the helper caller audit, remove obsolete manual-only machinery and assertions, and
  prove explicit background result/exit and unchanged Operator worker/helper routing. Delete
  createManualReview, Created.manualReview and their obsolete tests in this same compiling slice.
- [x] Correct user documentation, record the marketplace audit/test outcome, compare snapshots and
  run the gate. Record maintainer acceptance separately from isolated proof.
- [x] Challenge this plan with the selected external reviewer(s), triage every finding and record
  the review outcome before implementation handoff.

## Plan review

One round with Antigravity · gemini-4-neon · high, selected by the user. The review completed
successfully with one Important finding and two Minor findings. All three were verified against
the source and corrected in this plan: explicitly restore the new-checkout recovery messages and
test both failure branches, name the helper/process/test files by their actual target paths, and
keep obsolete workflow symbols until their tests are removed in the same compiling cleanup slice.
No findings remain open. The review's verdict was ready with these fixes.

The reviewer could not inspect git history or the separate marketplace checkout from its sandbox.
The primary agent verified the reference/merge/current-main history and the marketplace caller
directly, and ran the 21 marketplace tests recorded above. Native app acceptance remains unrun.

## Implementation proof on 28 November

The existing-task/recovery regressions first failed with nine issues on the released implementation.
The new command-boundary regression then failed in all eight vendor/destination combinations:
the submitted command was the manual-review helper rather than the selected interactive CLI.

ReviewLaunchTests now passes 19 cases: two real SheetCoordinator/form submissions with Command-Return
and disabled descriptions, eight hosted skill/file selection submissions (including native
Antigravity plugins and Pi packages), one agent-switch reload in the open review prompt, and eight
submitted commands executed on isolated PTYs.
Each PTY receiver records the selected model/effort, exact argv and composed prompt, then answers a
follow-up from the same process on the same terminal. Both inline and staged long prompts are
exercised. These are synthetic CLI receivers, not real vendor model conversations.

The focused existing-task, closed-window, delivery-error and recovery tests passed. The migrated
branch-preparation tests pass for local and remote-only branches. The common process tests pass,
including cancellation, process-group cleanup and truncation reporting. The restored keyboard test
proves a late Pi catalogue refreshes the open editor in the owner's checkout. ReviewLaunchTests is
serialized because its form submissions exercise native window keyboard handling.

All 16 focused daemon helper/routing cases passed. The explicit background command carries a long
quoted argument, writes its result and status, and exits with either 0 or 23 in ordinary and driven
windows. It verifies the role on the iTerm session before delivery. The complete daemon gate then
passed with 1,733 tests, one opt-in live test skipped, and clean type checking/lint.

Native hosted captures were taken before and after and inspected for review-step3, review-in-task
and review-step3-ticket. The shared prompt placeholder and slash/@ hint are restored; destination,
description controls and layout remain intact. Existing SheetSnapshots fixtures already cover these
states and needed no source edit. The current README image is unchanged.

The caller audit removed only the obsolete ManualReview request/snapshot/answer/profile pipeline,
its app entry point, its HeadlessRun factory and the capture-only AgentProcess/PipeDrain branches.
Common output truncation reporting remains. Harness read-only/headless support still serves the
Oracle, query writer and workers; generic background-tab command staging and Operator worker/helper
routing are untouched. Signal goldens, native skill compatibility captures and saved-workspace
format are unchanged. No marketplace files were modified.

The initial repository gate scripts/test.sh passed: 1,733 daemon tests, all 3,145 selected Swift tests
(UI, app, core and Signal snapshots), type checking and lint. The Swift summaries include four
deliberate known issues from existing test-harness self-checks; there were no unexpected failures.
All test and snapshot processes have ended. Implementation remains uncommitted for review.

Native real-agent desktop acceptance remains a maintainer check under docs/workflow/verify.md;
no live app was launched or replaced and no real agent was exercised. This manual acceptance is
separate from the completed isolated launch-boundary proof.

## Implementation review corrections

Antigravity · gemini-4-neon · high found one Important documentation issue and two Minor findings.
The permission warning now explicitly includes manual reviews for both Codex and Antigravity,
and New Review is described as using New Task's launch permissions rather than the CLI's defaults.
The Files list names the actual new test and omits unused fixture edits. A hosted regression now
switches Antigravity to Pi while the prompt is open and proves the newly discovered skill is
accepted with Pi's syntax. Redundant before/after git assertions left over from the removed pinned
snapshot test were deleted. The focused launch/workflow suites passed after these corrections;
the repeated full gate also passed with 1,733 daemon tests, 3,146 selected Swift tests, type checking,
lint and Signal snapshots. A second Antigravity pass confirmed all three findings settled and
reported no remaining findings. Its verdict was Ready. One earlier attempt was superseded before
findings because the full patch needed to be supplied as a local artifact; it is not counted as a
completed review round. No Critical, Important or Minor findings remain open.

The reviewer read the exported full patch, new tests and referenced source files. Its sandbox could
not run repository-wide git queries or inspect the separate marketplace checkout; the primary
agent performed the status/reference/caller audits and test/snapshot verification. All review
processes have stopped. The implementation is ready for local commit approval; there is no PR in
this repository's workflow.
