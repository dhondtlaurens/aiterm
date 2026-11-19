# A task's row shows its branch's merge request

## Goal

A task row shows the GitLab or GitHub merge request mark whenever its branch has a merge request,
not only once a review was opened on it. Before this change, `TaskItem.mr` was set in three places only: New
Review (on the review task and on the owner task it opens in, `TaskLauncher`), and a Signal
(`ItemRouter`, `RequestWatch`). A plain task whose agent pushed its branch and opened a merge
request carried none, so its row had no mark, no thread count and no merged check.

## Approach

A new app owner, `BranchRequestWatcher`, built like `ReviewThreadsWatcher` and `TicketDoneWatcher`:
a pass every 60 seconds while started, and a read of a row when it is selected. Each pass looks up
the merge request of every eligible task's branch with the existing `HostRepository.request(forBranch:)`
(the open request from that branch first, else the newest of any state, same-repository only), on
the repository `CodeHosts.repository` makes from the project's remote and the saved connections. An
accepted request is saved on `task.mr` as a `MergeRequestRef`. Everything that already reads
`task.mr` then follows without change: the row's mark (`TaskRowBadges`), the thread count and merged
check (`ReviewThreadsWatcher`), archive search.

Decided while grilling:

- **Which requests**: open or merged. A closed request that never merged is ignored, and the task
  keeps being looked up, so a new request on the same branch is found later.
- **Saved, and sticky.** The request goes on `task.mr`, as New Review's does, and once there it is
  not looked up again: a request that later closes stays on the row, as one New Review put there
  does today.
- **Eligible tasks**: a task or a review, with no `signalTask` (`RequestWatch` owns those), a
  checkout (`hasCheckout`), no `mr`, and a non-empty `branch` that differs from `baseBranch`. Reviews
  are included: New Review advances on a name and branch alone (`NewReviewSheet.canAdvance`), and
  `TaskCreator.createReview` and project import then save a review with no `mr`. A task without a
  checkout is not looked up, which keeps `TaskLauncher`'s reopen path (which branches on
  `task.mr != nil`) where it is.
- **No new failure surface.** A project whose host is not connected, whose remote is on another GitLab
  host or names no repository, or whose read fails is skipped silently (logged at info, as the
  threads watcher does). Nothing is written to either host.
- **Write guard.** The answer is saved only while the task still exists, still has the branch it was
  asked for, still has no `mr`, and its project still has the remote it was asked on: a review opened
  meanwhile wins, and a remote adopted anew (`AppState+Workspace`) never takes the old repository's
  request.
- **Signals unchanged.** `MatchDecision` already matches a Signal's merge request to a task by its
  branch, so a request now on `task.mr` changes no Signal decision.
- **Load**: per eligible task per minute, only while it has no request: one call when the branch has
  an open request; otherwise two on GitLab (open, then history) and three on GitHub (open, history,
  then the candidate by number). A branch whose newest request was closed unmerged pays that every
  pass until a new one opens; accepted, as such branches are few and stop once their task is
  archived. Binding a repository per ask costs no request.

No visual change: the mark, its label setting and its fits are the existing ones, so the design
system is untouched.

## Files

- **Create `app/Sources/AiTermCore/CodeHosts/BranchRequestReader.swift`:** a `BranchRequestReading`
  protocol (a project's remote URL and a branch in, an accepted `MergeRequestRef?` out, `nil` for a
  host that is not connected or not this one) and `BranchRequestReader`, which binds the repository
  through `CodeHosts.repository(for: ProviderDetector.detect(remoteUrl:))` and keeps only an open or
  merged answer. Core, so its rule is tested without the app.
- **Create `app/Sources/AiTerm/BranchRequestWatcher.swift`:** the poll loop (`PollLoop`), the
  selection read (`RowFocus.onSelectionChanged`), the eligibility filter, and the guarded write
  through `WorkspaceStore.mutate`. Its `Connect` port returns a `BranchRequestReading`, as the threads
  watcher's does.
- **Modify `app/Sources/AiTerm/AppController.swift`:** build the watcher beside `reviewThreads` with
  the saved GitLab and GitHub settings, start it at launch and stop it at quit with the others.
- **Modify `docs/architecture.md`:** one sentence in "Integration and platform owners" on reading a
  task branch's request, and a row in the data-sources table.
- **Create `app/Tests/AiTermCoreTests/BranchRequestReaderTests.swift`** and
  **`app/Tests/AiTermTests/BranchRequestWatcherTests.swift`.**

## Proof

- `BranchRequestReaderTests`: an open and a merged answer become a `MergeRequestRef` with the
  request's iid, title and web URL; a closed one and no answer give `nil`; a host without a saved
  connection or a remote on another GitLab host is not asked and gives `nil`.
- `BranchRequestWatcherTests`, with a fake reader recording what it was asked:
  - a pass asks for a task and for a review without `mr`, and not for a Signal task, a task without
    a checkout, one already carrying `mr`, or one on its base branch;
  - an accepted answer lands on `task.mr`, and the next pass no longer asks for that task;
  - a failed read or `nil` changes nothing and the task is asked again next pass;
  - an answer for a task whose branch changed, that got an `mr` meanwhile, or whose project's remote
    changed meanwhile, is dropped;
  - selecting an eligible row reads it at once while started, and not while stopped.
- `TaskRowBadges` needs no new test: it already draws the mark from `row.mr`.
- `scripts/test.sh` before the commit; `scripts/test.sh all` once before merging.
- By hand: `scripts/run-dev.sh` (only when no session needs the live app undisturbed) with a task
  whose branch has an open merge request and no review: its row shows the GitLab or GitHub mark
  within a minute, or at once when selected, then the thread count.

## To-dos

- [x] `BranchRequestReader` and its tests: the accepted states and the unconnected host.
- [x] `BranchRequestWatcher` and its tests: eligibility, the guarded write, failure, selection.
- [x] Wire it into `AppController` (build, start, stop); `scripts/test.sh` green.
- [ ] `docs/architecture.md` line; check by hand in the dev app.
