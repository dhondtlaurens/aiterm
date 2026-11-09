# Show the pause sign on an idle task waiting for review

## Goal

An Operator task waiting for human review keeps spinning after the person pauses its broadcast.
Keep its review text, including who it is waiting for, and display the existing pause sign once
its workers are idle. This is the behaviour the person selected on 9 November 2026.

## Evidence

The reported screenshot shows a paused broadcast with two completed tasks and one task in
people's review. A read-only check of the saved workspace confirmed the remaining task's state
was `inReview`. The daemon's `sessions.list` showed all four of its tabs idle, with no background
jobs, active tests or stopped-on error. The Operator's turn had also ended.

`OperatorLine.task` correctly produces the quiet review line. In `SidebarModel.taskRow`, however,
`TaskRow.paused` is true only when that line equals the literal `paused` line. Only a `working`
task receives that line today. The review task therefore goes through `heldStatus`, which returns
`working` for any held, unfinished line even if every tab is idle. The spinner is synthesized by
the sidebar; it is not evidence of a worker continuing to run.

## Approach

Extend the sidebar's paused-mark decision to include an idle, Operator-held `inReview` task of a
broadcast paused by the person. Keep `OperatorLine.task` and its review text unchanged. Determine
the mark separately from the text using the run, task, current line and session facts already
available in `taskRow`. Reuse `TaskRow.paused`, its idle row status and `TaskRowMark.pauseSign`.
Update the documentation of that flag so it no longer implies that a pause mark requires the
literal `paused` text.

The additional case applies only while the review line is quiet, the task remains the Operator's,
and the existing aggregate of all its sessions is idle or done. This includes manually opened tabs
that inherit the task tag but are not in its worker list: working, input, background work and active
tests in any task tab prevent the pause mark. Also check the existing worker-tab facts for an
opening extra worker that has no session yet. A permission prompt or a holding request still
produces the attention indicator. An Operator act in flight keeps its activity indicator. The
existing `working` task's `pausing` to `paused` behaviour stays as it is. Resuming the broadcast
restores the ordinary held spinner without changing the review state or text.

This follow-up is scoped to the reported review state. It does not change other lifecycle states,
pause/resume delivery targets, publication, worker turns, persistence or the frozen Operator and
daemon contracts. It uses the existing pause glyph and tokens; no UI primitive or token changes
are needed. A closed Operator window by itself is not a pause by the person.

## Files

- **Modify** `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: derive the review task's paused
  mark from its paused broadcast, the aggregate of all its tabs and pending worker openings,
  independently of its review text; document the expanded meaning of `TaskRow.paused`.
- **Modify** `app/Tests/AiTermCoreTests/Operators/BroadcastSectionTests.swift`: reproduce the
  reported combination through the real broadcast-section projection and cover the alternatives
  where the pause sign must not replace activity or attention.
- **Modify** `app/Sources/AiTerm/Snapshots/OperatorSnapshots.swift`: include a synthetic task
  waiting on a reviewer in both sides of `broadcast-paused.png`, alongside paused workers and
  completed work. Keep this task idle in both scenes, so it keeps its review text and pause sign
  even while another task is still pausing; include it in both scenes' ended-turn fixture sets.
  Update the fixture's descriptive comments too.
- **Modify** `docs/operators.md`: explain that an idle task in people's review keeps its review
  text while the mark changes to the pause sign during a pause by the person.
- **Create** this plan file, `docs/plans/2026-11-09-paused-review-task-mark.md`.

## Proof

- Add a failing regression through `SidebarModel.broadcastSection`: one `inReview` task with a
  named reviewer and an idle first worker plus idle review tabs, alongside completed tasks. While
  paused by the person, its line and tooltip retain their full review detail, `paused` is true
  and its row status is idle. Preserve the same behaviour for plain `in review` without a named
  reviewer and for ended worker turns.
- Exercise the same review task in an active run, with pause intent before the state settles,
  and after resume. Only a pause by the person enables the additional mark; an offline Operator
  without pause intent, takeover and End do not. Existing completed checks and queued marks stay.
- Cover a working tab, an opening extra tab, ended-turn background work and queued/running tests:
  none may be hidden by the new pause mark. Cover a tab at a permission prompt, a holding question
  or request, and an Operator act in flight; their attention/activity indicators still win.
  Include inherited, manually opened non-worker tabs with activity or a prompt, alongside idle
  main/registered review workers, so a worker-only check fails this regression.
- Reuse `TaskRowMarkTests`' existing coverage of the pause flag and removal precedence; the mark
  renderer already ignores the line when paused. Keep `OperatorLineTests`' review-line expectation
  unchanged. The new coverage belongs in the projection tests, where the decision changes.
- During implementation, run the focused suites with
  `scripts/test.sh swift -- --filter 'BroadcastSectionTests|TaskRowMarkTests|OperatorLineTests'`
  in the background and verify they execute. Run `scripts/snapshots.sh build/paused-review-snapshots`
  after tests/builds have finished, then inspect `broadcast-paused.png` directly. Synthetic
  fixtures must show the retained review detail and pause glyph without contacting the live app.
- Run plain `scripts/test.sh` before each commit. Once before any merge, run
  `scripts/test.sh all`. Do not regenerate contract goldens. Do not use `scripts/run-dev.sh` or
  modify the running broadcast to prove this display change.

## To-dos

- [ ] Add the review-state projection regression, implement the separate paused-mark decision and
      prove pause, resume, activity and attention through the focused suites.
- [ ] Extend and inspect the paused snapshot with the retained review line and existing pause sign,
      and document the resulting behaviour.
- [ ] Run the affected gate and review the finished change before committing; run the full gate
      before merging.

## Plan review

Claude challenged this plan through the psg adversarial-review workflow in two rounds.
Round one raised one Important finding and two Minor findings. All were verified and fixed:
check every task session rather than only registered workers, reuse existing mark-renderer
coverage, and specify the review task's idle state in both snapshot scenes and their comments.
Round two reported no findings and confirmed all previous findings settled. No open findings
remain. Implementation and its tests have not started.
