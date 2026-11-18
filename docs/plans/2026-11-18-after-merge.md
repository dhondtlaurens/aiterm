# After AiTerm merges, hand the stage back to its worker

Branch `feat/after-merge`.

## Goal

Make it possible for one Ship signal to both merge and deploy. Today, when a stage with **Merge it when it's ready** is
merged by AiTerm, `RequestWatch.check` treats the confirmed merge as done (`DoneCheck.reached`): the stage
finishes, Then runs, and the worker never hears about it. Workers may not merge (`WorkerGuard`), so a skill like
`/psg:ship` can't merge and then follow the release itself.

After this change, AiTerm's own merge hands the stage back: the worker gets one line, `AiTerm merged !<n> at
<short sha>; carry on.`, and the stage ends on its Done query. A merge by anyone else still ends the stage, as
does a merge request closed without merging. Separately, a pending stage whose signal no longer matches its item
is dropped instead of launched.

## Approach

**Recognising AiTerm's merge across a lost read or a restart.** The merge intent (`SignalTask.merge`: the request
reference and the head being merged) is saved and flushed immediately before the host merge call, after
`SignalHostIO.merge`'s binding, local-head, pause and authority checks. The merge port is given a closure for this,
and nothing awaits between it and `host.merge`. A failure known to come before the call (any of those checks) leaves
no intent. A
later read that shows that request merged at that head counts as AiTerm's merge, whether the confirming read in the
same pass succeeded or the app restarted in between. The merge port returns the host's answer (`MergeReadiness`,
today dropped in `SignalHostIO.merge`). On `.merged`, the intent is marked accepted. A refusal (`.blocked`, or
`.ready`, meaning nothing was merged) clears the intent, so a later merge by someone else is not taken for AiTerm's.
`.waiting` is a merge the host has not finished (as `GitLabPublishTests.aMergeGitLabHasNotRunYetIsWaitingNotMerged`
shows), so it keeps the intent unconfirmed, as does a thrown host call or a restart during it, and a later read showing that request merged at that head
counts as AiTerm's: the host's own `.merged` also covers "an earlier call whose answer was lost". Without an intent,
`merged` keeps today's meaning: done. A new stage clears the intent (`continueStage`).

**Handing back.** When a read sees AiTerm's merge and the hand-back is still owed, `RequestWatch` takes these steps:
- It saves the merge commit (`MergeReadiness.merged(commit:)`, carried on `Snapshot`; the head when the host gives
  no commit) and resets the stage's Done baseline to "not matching" (`doneMatched = false`).
- It sends the line through a new `handBack` port, wired to `SignalWorkerIO.message(tab: "main")`. That is the path
  the Operator's answers take: `.workRequested` moves the stage to working, a pending reply is saved with its
  transcript fingerprint, and the daemon's delivery checks apply.
- It records the line in the task journal and calls `changed`.

The request number uses the host's own notation (`CodeHost.reference`: `!n` on GitLab, `#n` on GitHub). The sha is
the merge commit, shortened to 7 characters.

**Once at most.** The owed flag is cleared in the same saved change that marks the reply pending (`markPending`
gets a hook for it), so a retry can't send the line twice. If delivery fails after that change, the existing
"has not replied to the saved message" block shows it. A worker that is busy, or a paused Operator, leaves the
hand-back owed, and the next host pass tries again. With no main worker tab at all, the stage blocks with
`AiTerm merged !n at abc1234; its worker is gone.` Resuming it (`StageRunner.run`) sends the carry-on line instead
of the stage prompt. The owed flag is cleared only together with the pending reply that `SignalWorkerIO.launch`
saves (the same `markPending` hook), not with the launch intent: a resume that fails its CLI or Messaging checks
before then keeps the line owed for the next resume.

**Ending after the hand-back** (decided: match after hand-back). While a stage carries AiTerm's merge,
`DoneCheck.reached` ignores `merged`. Because the hand-back set the baseline to not matching, and reads skip a
worker at work, the stage ends at the first complete read after the worker's follow-up turn where the Done query
matches. A Done query of `state:merged` therefore ends the stage after that one turn, and a release-status query
waits for the release. When the stage finishes, Then runs as it does today. A request closed without merging, or
merged without AiTerm's intent, still ends the stage at once.

**Stale pending stages.** The check sits at the launch boundary, in `StageRunner.run`: after the Done baseline
read, and in the same synchronous span as saving the launch intent, with no await between them. A full read the
poller publishes while the baseline is read is therefore seen. The same check also runs when the baseline read is held (back-off) or
fails, before `run` returns, so a stale stage whose Done source is unreadable doesn't hold up later stages or Then. It applies to a stage that came after the task's first one and whose worker has not launched yet
(`stage > 1`, `launch == nil`): a stage taken from the queue, or one continued by a later match. That covers a
stage that waited in choosing, or was held by an unreadable Done baseline, while its item stopped matching. A first
stage, a resumed stage, and the handed-back Ship stage (whose own signal no longer matches once merged) all have a
launch and are never dropped. The stage is stale when the latest *full* read of its signal no longer matched its
item (`signalSeen[].isMatching == false`, which `ItemRouter` already maintains). A pair with no seen entry, or one
seen only through incremental reads, is kept: there's no evidence it stopped matching.

A new core transition, `.dropped`, gives the task back to the earlier stage as it was left (`previousStage`), with the
task's agent row restored too, and starts the next pending stage. `StageRunner` journals `Dropped stage <n> from
<signal>: <item> no longer matches it.` and checks the next stage the same way. With nothing left, an earlier stage
that was done is done again and the tick's existing `canRunThen` path runs its Then. One that was still watching its
Done trigger (the Operator's `finish_stage` done starts pending stages at once) goes back to watching, and Then waits
for its Done. `ItemRouter` and `startPending` are unchanged.

## Files

- **Modify** `app/Sources/AiTermCore/Operators/Signals/SignalTask.swift`: add `merge: SignalMerge?` (the request,
  the head, the commit once known, and whether the hand-back is owed), cleared by a new stage. Added during the
  build: `previousStage: EarlierStage?`, the earlier stage as it was left (its phase, Done baseline, merge record, launch
  and choice), set when a stage continues and cleared once its worker starts. A dropped stage gives the task back to
  that stage exactly: still watching its Done trigger when `finish_stage` done had started the pending stage, or done
  with its own Then rather than the dropped signal's.
- **Modify** `app/Sources/AiTermCore/Operators/Signals/DoneCheck.swift`: `reached` takes whether AiTerm merged it;
  if so, `merged` alone doesn't end the stage.
- **Modify** `app/Sources/AiTermCore/Operators/Signals/StageMachine.swift`: a `.dropped` action (launching or
  choosing → the earlier stage as it was left, watching or done, then the next pending stage); `continueStage` saves
  that earlier stage and clears `merge`.
- **Modify** `app/Sources/AiTerm/Operators/RequestWatch.swift`: save the merge intent before merging, recognise
  AiTerm's merge, hand back with `handBack`/`hasWorker` ports, block when the worker is gone, pass the flag to
  `DoneCheck`.
- **Modify** `app/Sources/AiTerm/Operators/SignalHostIO.swift`: `Snapshot` carries the merge commit from
  `.merged(commit:)`; `merge` returns the host's `MergeReadiness` instead of dropping it.
- **Modify** `app/Sources/AiTerm/Operators/SignalWorkerIO.swift`: `message`, `launch` and `markPending` accept a
  change saved together with the pending reply (clearing the owed flag).
- **Modify** `app/Sources/AiTerm/Operators/StageRunner.swift`: drop a stale stage before its launch and journal
  it; resume with an owed hand-back sends the carry-on line.
- **Modify** `app/Sources/AiTerm/Operators/SignalOperatorController.swift`: wire the new ports.
- **Modify** `app/Sources/AiTermCore/Operators/Signals/OperatorLaunch.swift`: one sentence saying that after
  AiTerm's own merge the worker gets one line and works on, and its Done trigger ends the stage, plus the stale-stage
  drop. Its contract fixture `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/brief.md` is edited to
  match on purpose, and the change is recorded in that folder's `PROVENANCE.md`.
- **Modify** `docs/operators.md`: the "Publishing, done and merging" section (merged is done only when someone
  else merged it, plus the hand-back, the line, and the worker-gone block) and the pending-stages paragraph (stale
  stages are dropped and journaled).

## Proof

- `SignalWatchTests` (RequestWatch):
  - `mergeWhenReadyMergesWithoutADoneMatchAndTheMergeEndsTheStage` and `aMergeIsConfirmedFromTheHostBeforeThenRuns`
    become hand-back tests: after the merge, the stage is working, the worker got exactly the line, and Then has not
    run.
  - New: two passes deliver the line once.
  - New: the stage waits while the Done query doesn't match, and ends with Then once it matches after the turn.
  - New: a Done query already matching before the merge ends the stage after the follow-up turn.
  - New: a lost confirming read, or a thrown merge call, followed by a pass that sees the merge at the saved head,
    still hands back.
  - New: a merge by someone else (no intent) ends the stage, as does a close. So does a merge by someone else after
    AiTerm's attempt was refused, or after `SignalHostIO.merge` failed a check before calling the host.
  - New: a `.waiting` answer followed by a read that shows the merge hands back.
  - New: with no worker tab the stage blocks with the reason, and resume sends the line. A resume that fails its
    Messaging check keeps the line owed, and the next resume sends it.
- `SignalDomainTests` (core): `.dropped` gives a launching or choosing stage's task back to the earlier stage as it
  was left (done, or still watching with its baseline and merge) and starts the next pending stage; it is refused
  from other phases.
- StageRunner and engine tests (`SignalEngineTests` or `SignalJourneyTests`):
  - A stale pending stage is dropped and journaled; the next pending stage launches, or Then follows.
  - After `finish_stage` done, a stale pending stage is dropped and the earlier stage keeps watching, with its agent
    row restored.
  - A stage whose item stops matching while it waits in choosing, or held by its baseline, is dropped at its launch.
    So is one whose item stops matching in a full read published while its baseline read is suspended.
  - A stale stage whose Done baseline stays unreadable is dropped, and the next pending stage or Then follows.
  - A pair with no full-read evidence launches.
  - A first stage and a resumed stage are never dropped.
- `SignalWorkerIOTests`: a message or a launch saves the hand-back as made together with its pending reply, and a
  busy worker leaves it owed.
- `SignalHostIOTests`: a merge that fails its local-head check before calling the host never calls `intend`.
- `SignalDomainTests` also covers the new optional fields round-tripping and staying absent while nil, so the saved
  state fixtures are unchanged (`SignalSavedFormatTests` still decodes them).
- Run `scripts/test.sh swift -- --filter SignalWatch` while iterating, `scripts/test.sh` before each commit, and
  `scripts/test.sh all` once before merging. No live run: the merge path is proven through the harness's fakes,
  since a live merge needs a real request.

## To-dos

- [ ] Merge intent saved before merging, settled by the host's answer, and recognised on a later read (Core field,
      `RequestWatch`, `SignalHostIO.merge`), with tests for the lost read, the refused attempt, and a merge by
      someone else.
- [ ] Hand-back: the merge commit on `Snapshot`, the `handBack` port wired to `message`, the owed flag cleared with
      the pending reply, the baseline reset, and `DoneCheck` ignoring AiTerm's merge; tests for the line delivered
      once, waiting for Done, and Then afterwards.
- [ ] Worker gone: block with the reason, and resume sends the line; tests.
- [ ] Stale stages dropped at the launch boundary (`.dropped`, `StageRunner.run`), journaled; core and runner
      tests.
- [ ] Operator prompt sentence and `docs/operators.md`.
