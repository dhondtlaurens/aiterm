# A driven task that waits shows it is waiting

## Goal

Seen 16 Nov 2026 on mirai !102 and !103: an Operator-driven task whose workers all ended their turn, with no
Operator act running, drew the solid spinner and read `working`; a task watching its done condition drew the idle
ring with a terse line (`waiting on approval`). Neither works: one waits on the Operator, the other on someone
outside. Both should draw the dashed, slowly turning ring, say what they wait for (and on whom, where AiTerm knows),
and never count as working.

Why it read `working`: P3 1A (21 Oct 2026) keeps a worker's ended turn from showing the done ring while the Operator
holds the task, since that turn is the Operator's to read. `SignalSidebar.present` did it by forcing
`row.status = .working` and setting no line, so `SignalStatusLine` fell back to its quiet `working` and a folded
section counted the task as working. The intent stays; the state gets its own name.

## Approach

- **A new `TaskStatus.waiting`**, not `.background`: `.background` means the agent takes its turn up again by
  itself, and the chips, their label and VoiceOver count it as working. `.waiting` draws as `.background` does
  (`SpinnerArc` style `.dashed`; `DashedRing` still under Reduce Motion), labels `Waiting`, never needs attention
  (Focus View and the Dock badge pass it over), and has its own folded chip between working and needs-input, in the
  quiet wash with muted ink ("N waiting"). Decided with the user: its own chip, not folded into idle. Tabs never
  produce it; only `SignalSidebar.present` sets it.
- **`present()`**, order unchanged: phase `.working` with no busy tab → `.waiting` and
  `worker done · Operator to review`; phase `.watching(c)` with no busy tab → `.waiting` (`.unknown` stays idle) and
  the new wording. A busy tab keeps its own mark. needsInput, blocked, paused, windowClosed and done are unchanged.
- **Facts, no new host call.** The done check's read already fetches the request each pass
  (`SignalHostIO.request`); GitLab's merge request answer carries `reviewers` (display `name`, else `username`),
  GitHub's pull `requested_reviewers` (`login`). Decode them into `MergeRequest.reviewers` (nil when the answer
  lacked the key). Open threads are counted from `host.threads`, which the `.threadsResolved` and merge-when-ready
  reads already make. Both land in `DoneCheck.Facts`; `RequestWatch.check` saves them on the task as an optional
  `SignalTask.waitingOn`, in the same mutation as `watchedRequest`. A new stage clears it. Missing facts → the
  generic wording.
- **Wording**, one pure function in AiTermCore: the line at most `OperatorLine.maxLength` (40), the tooltip the
  full sentence.

  | Condition | Line | Fallback |
  |---|---|---|
  | `.approved` | `waiting on approval · Sam` (first names, `Sam +2` when they don't fit) | `waiting on reviewer approval` |
  | `.hasReviewer` | `waiting for a reviewer` | |
  | `.threadsResolved` | `waiting on 3 open threads` (`1 open thread`) | `waiting on review threads` |
  | `.merged` | `waiting for the merge` | |
  | `.mergedOrClosed` | `waiting for merge or close` | |
  | `.ticketStatus(s)` | `waiting for ticket to reach <s>`, cut with `…` | |
  | `.myReviewPosted` | `waiting for you to post the review` | |
  | `.operatorJudges` | `waiting for the Operator` | |
  | phase `.working`, turns ended | `worker done · Operator to review` | |
  | condition met, merge when ready still holding it | `waiting to merge · checks, threads` (what `canMerge` lacks) | `waiting to merge` |

  A stage whose done condition is met (a judged `.operatorJudges`, an approved `.approved`) stays watching while
  merge when ready waits to merge it; its line names what the merge lacks, not the met condition. `RequestWatch`
  saves it (`SignalWaitFacts.mergeBlockers`) from the snapshot it already reads: approval as the request has it,
  green checks, resolved threads, the local head pushed, and the host's own hold (`host check`) only when none of
  those explains it.

- **Operator row, Dock badge**: the Operator row's line comes from its own session and current act; the Dock badge
  counts needs-attention only. Pinned by tests; no change expected.

## Files

- modify `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: the case, label, `statusOrder`, `statusCounts`,
  `statusCountsLabel`; fix the stale `taskRow` comment and remove `heldStatus`, which nothing called and which
  still stated the old rule (a held task at work whatever its tabs say).
- create `app/Sources/AiTermCore/Sidebar/OperatorLine+Waiting.swift`: the wording and the 40-character cut.
- modify `app/Sources/AiTermCore/Operators/Signals/DoneCheck.swift`, `SignalTask.swift`: facts and `waitingOn`.
- modify `app/Sources/AiTermCore/CodeHost.swift`, `GitLab/GitLabClient.swift`, `GitHub/GitHubClient.swift`:
  reviewers from the payloads already read.
- modify `app/Sources/AiTerm/Operators/SignalHostIO.swift`, `RequestWatch.swift`, and where a stage starts: fill,
  save and clear the facts.
- modify `app/Sources/AiTerm/SignalSidebar.swift`: `present()`.
- modify `app/Sources/AiTerm/SidebarProjection.swift`: copy `waitingOn` into the reduced `SignalTask` that
  `refresh()` compares, so a change to the names or count alone redraws the row.
- modify `app/Sources/AiTerm/Views/StatusMark.swift`, `StatusCountChips.swift`, `SidebarRows.swift`
  (`TaskRowMark`): draw the new status.
- modify `app/Sources/AiTerm/Snapshots/SignalSidebarSnapshots.swift` (and `SidebarSnapshots.swift` if the marks
  column belongs there): poses for worker done, approved with reviewers, open threads, folded with the waiting chip;
  a marks column on a plain row, a selected row, the accent and Reduce Motion.
- modify `docs/design/ui-patterns.md`, and `app/Sources/AiTermUI/README.md` if it lists the status marks: what the
  dashed ring means now (waiting on a turn, the Operator or a person).

## Proof

- New `app/Tests/AiTermTests/SignalSidebarPresentTests.swift`: every DoneWhen line; reviewer names, fallback and
  several names cut; the 40-character cut with the full tooltip; thread count known and unknown; `.working` with
  idle workers → `.waiting` and `worker done · Operator to review`; busy workers keep the spinner; needsInput,
  blocked, paused, windowClosed, done unchanged; a folded count says waiting, not working; the Dock badge and the
  Operator row do not count a waiting task.
- A facts-only update through `SidebarProjection.refresh()` (a reviewer or thread count changes, nothing else)
  redraws the row with the new line.
- Updated: `SignalSidebarTests.signalRowsDescribeActsQuestionsWatchingAndTheirOwnPause`, `SidebarModelTests` counts,
  the GitLab/GitHub client decoding tests (reviewers), a `RequestWatch` test that the facts are saved.
- `scripts/test.sh` before each commit, `scripts/test.sh all` before merging;
  `AITERM_SNAPSHOT_HOSTED=1 scripts/snapshots.sh`, before and after, and the new pictures looked at.

## To-dos

- [x] `TaskStatus.waiting`: mark, chip, counts, label; tests in `SidebarModelTests`.
- [x] Wording function with its cut; unit tests.
- [x] Reviewers decoded from the existing request answers; open-thread count; `DoneCheck.Facts`,
      `SignalTask.waitingOn`, saved by `RequestWatch`, cleared on a new stage; tests.
- [x] `SidebarProjection` carries `waitingOn`; integration test of a facts-only update.
- [x] `present()` uses all of it; `SignalSidebarPresentTests`; existing test updated.
- [x] Snapshots: fixtures, regenerate, look at plain, selected, accent and Reduce Motion.
- [x] `docs/design/ui-patterns.md` (and the AiTermUI README if needed).
- [x] `scripts/test.sh`, commit; `scripts/test.sh all` before the merge.
