# 7c. One status read per request, merge readiness as a pure rule

Implementer: Opus 5.5 high (merge safety rests on it). Depends on: 1b, 7a, 7b. Comes from: audit HO F3.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

Two points where the code is slightly different from the plan's wording.

- The plan says `state`, `readiness` and `signalReviewers` become one read. `signalReviewers` is only ever asked
  whether it is empty, and the request answer already carries the reviewers (users and, on GitHub, teams in
  `requested_teams`). So there is no reviewers read at all after this step: `MergeRequest` gains the GitHub teams,
  and "someone is asked to review" is read off the request. This also removes the repeated fetch of the same
  request on the non-merge watch path (GitLab fetched the merge request four times in one merge-when-ready read).
- Threads stay a separate read (`threads(of:)`, 7b). The merge floor needs them, but they are a GraphQL or
  discussions listing, not a fact of the request fetch, and the audit's count of repeated fetches does not include
  them.

## Why

For one task that merges when ready, one watch read fetches the same pull request or merge request several
times: once to find it, again for `state`, again for `readiness`, again for the reviewers, and the check lists
twice on GitHub. That is about twelve requests on GitHub and four fetches of one merge request on GitLab, every
minute for every watched task, and again after the Oracle round and after the merge. The facts can also disagree:
the head named by `state` and the head named by `readiness` come from different fetches, and a push between them
makes the merge floor compare one head against another. The end state: one status read per request that names a
single head and takes every fact about it from that one fetch, and merge readiness decided by a pure function per
host that table tests can drive without a stubbed network.

## Today

The code as it is after 1b, 7a and 7b.

- `AiTermCore/CodeHosts/HostRepository.swift`: `HostRepository` has, in its watch group, `readiness(of:)`,
  `state(of:)` (takes the request, returns `MergeRequestState`: after 1b only `pipeline`, `approvedBy`, `head` are
  read by anyone), `reviewers(of:)` (today `signalReviewers`), `approvals(of:)`, `threads(of:)`, `request(number:)`,
  `request(forBranch:)`, `merge(_:at:)`.
- `AiTermCore/CodeHost.swift`: `MergeRequest` (number, title, branches, author, state word, draft, url, fork head,
  description, `reviewers` as display names), `MergeRequestState`, and `MergeReadiness` with `.ready(head:)`,
  `.waiting`, `.blocked`, `.merged(commit:head:target:)` and `draftReason`.
- `GitHubClient` (`AiTermCore/GitHub/GitHubClient.swift`):
  - `readiness(of:)`: GET the pull, then if it is merged return `.merged` (commit is `merge_commit_sha` else the
    head, target is the base ref), if not open `.blocked("the pull request is closed")`; read the check runs and the
    commit statuses of the head concurrently (private `listed`, which reads pages of 100 until it holds the host's
    own `total`, gives up after `listedPages`, and answers nil when it cannot read the list whole), nil means
    `.waiting("GitHub has not listed all its checks")`; then the check table (`checkSummary`: failed before running,
    which conclusions pass, `stale` and `action_required` fail, an unknown conclusion is running); then a draft
    (`.blocked("it has conflicts")` when `mergeable == false`, else `.blocked(draftReason)`); then the table over
    `mergeable_state` (`clean` and `has_hooks` ready only when `mergeable == true`, else waiting; `dirty`, `behind`,
    `blocked`, `draft`, `unstable`, anything else waiting).
  - `state(of:)`: GET the pull again and `approvals(of:)` concurrently, then the check lists again, then the
    pipeline word from the same `checkSummary` (`failure`, `pending`, `success`; nil when a list was not read whole
    or both lists are empty).
  - `approvals(of:)`: reviews listed until an empty page, the latest review per user of APPROVED, CHANGES_REQUESTED or
    DISMISSED counts, a page limit throws `IncompleteRead`.
  - `reviewers(of:)`: GET `/pulls/N/requested_reviewers`, users by login and teams as `team:<slug>`.
  - The private `PullPayload` (the request: number, title, url, draft, user, head, base, merged, state, body,
    `requested_reviewers`) and `PullStatusPayload` (state, draft, merged, mergeable, `mergeable_state`, merge commit,
    head sha, base ref) are two decodes of the same pull response.
  - `merge(_:at:)` sends only the sha and maps 409 to `.blocked("the branch moved past the accepted commit")`, 405
    and 422 to `.blocked("GitHub refused to merge it (HTTP n)")`, and an answer that does not say merged to
    `.waiting`.
- `GitLabClient` (`AiTermCore/GitLab/GitLabClient.swift`):
  - `readiness(of:)`: GET the merge request as `MergeStatusPayload` and apply its `readiness` property: merged, not
    open, then the head pipeline table (`failed`, `canceled`, running states, `manual`, `skipped` which passes only
    while a draft, none or `success` pass, anything else waits), then a draft (conflicts, else the draft reason),
    then `detailed_merge_status` (`mergeable` needs a sha, the checking family waits, `ci_must_pass` and `not_approved`
    wait, `conflict`, `need_rebase`, `draft_status`, `discussions_not_resolved` block, anything else blocks with
    GitLab's words).
  - `state(of:)`: GET the same merge request again plus `approvals(of:)`; pipeline is the raw head pipeline status.
  - `merge(_:at:)` decodes the merge reply as `MergeStatusPayload` and reuses its `readiness` to say merged (commit,
    head, target, each falling back to the sha asked), waiting or blocked.
  - `reviewers(of:)` in `GitLabClient+SignalReview.swift` GETs the merge request a fourth time for the reviewers.
- `AiTerm/Operators/SignalHostIO.swift`, `read(_:)`, for a merge-when-ready signal: `request(task, host:)` (a fetch by
  number, or `request(forBranch:)` when no number is known), then `state(of:)`, `readiness(of:)`, `threads(of:)`,
  `reviewers(of:)`, optionally `myReviewPostedAt`, then the local head. It builds a `RequestWatch.Snapshot` with
  `head` (the state's head, replaced by the merged head when readiness says merged), `approvals` (someone approved
  and the host says ready), `greenChecks` (pipeline word is exactly `success`), `hostReady`, the facts
  (`merged`, `closed`, `hasReviewer`, `approved`, `threadsResolved`, `openThreads`, `reviewers`) and the request link.
  For other done conditions it reads only what the condition needs: `.hasReviewer` calls `reviewers(of:)`,
  `.approved` calls `approvals(of:)`, `.threadsResolved` calls `threads(of:)`, `.myReviewPosted` calls
  `myReviewPostedAt`. `deleteMergedBranch` calls `readiness(of:)` only to learn the merged head.
- `AiTerm/Operators/RequestWatch.swift`: reads each request once per pass through `ports.read`, again after the Oracle
  round, and again after the merge; it never calls a host itself. It needs no change.
- Tests: `GitHubPublishTests` (readiness table, state, "merge and run status read every check the same way", paging
  of check runs and statuses, unreadable readiness), `GitLabPublishTests` (readiness table and the draft and
  pipeline cases, state, merge replies), `SignalHostIOTests` (request counts), `SignalReviewActivityTests`
  (`reviewersIncludeGitHubTeamsAndGitLabPeople`). `RequestWatch` is tested through fake ports and needs no host.

Greps to re-run: `grep -rn "readiness(of\|state(of\|reviewers(of\|MergeRequestState\|signalReviewers" app/Sources
app/Tests`.

## Change

Types, in `AiTermCore/CodeHosts/` unless said:

1. `RequestStatus` (new, public): what one status read says. Fields in words: the request (a `MergeRequest`, as that
   one response describes it, including its state word, draft flag, url, branches, description and the reviewers
   by display name); the head commit that response names (optional: GitLab may send none); the merge readiness
   decided from that response by the host's pure rule; who approved (usernames); and the pipeline word (GitHub's
   checks as `success`, `failure` or `pending`, nil when there are none or they could not be listed whole; GitLab's
   head pipeline status as it says it). Delete `MergeRequestState`.
2. `MergeRequest` gains `reviewerTeams`, a list of team slugs (default empty), filled from GitHub's
   `requested_teams` only, and a computed `hasReviewer`: true when `reviewers` is non-empty or `reviewerTeams` is
   non-empty. It does not change `reviewers` (the sidebar line keeps showing display names and no teams).
3. Pure rules. For GitHub, a facts struct (the pull's state, merged, draft, mergeable as true, false or unknown,
   `mergeable_state`, head sha, merge commit sha, base ref; and the checks: either both lists, as runs with name,
   status and conclusion and statuses with context and state, or "not listed whole") and two pure functions: the
   check summary (today the private `checkSummary`, moved without change) and the readiness (today the body of
   `GitHubClient.readiness` after its reads). The pipeline word is a third pure function of the same checks. For
   GitLab, the facts struct is today's `MergeStatusPayload` fields (state, detailed merge status, sha, draft,
   has-conflicts, target branch, merge commit, squash commit, head pipeline status), made `Decodable` in Core, and
   one pure function of it (today's `readiness` property). Expose both rules as `MergeReadiness.gitHub(_:)` and
   `MergeReadiness.gitLab(_:)`. Wording of every result is byte for byte what it is today.
4. `HostRepository` (7a): add `status(of number: Int) -> RequestStatus`; delete `readiness(of:)`, `state(of:)` and
   `reviewers(of:)`. `request(number:)`, `request(forBranch:)`, `approvals(of:)`, `threads(of:)`,
   `myReviewPostedAt(of:)` and `merge(_:at:)` stay.

GitHub client:
5. `status(of:)` GETs the pull once and decodes that one response both as the request (today `PullPayload`, extended
   with `requested_teams`) and as the facts (today `PullStatusPayload`): one combined private decode. It starts
   `approvals(of:)` at the same time as the pull. When the pull is open it then reads the check runs and the commit
   statuses of the head sha named by that same response (the head sha goes into the path of both lists, as it does
   today), concurrently, with the existing `listed` paging. When the pull is merged or closed it reads no check
   lists (today's `readiness` returns before them). It builds the facts, applies `MergeReadiness.gitHub`, derives the
   pipeline word, and returns the `RequestStatus`. Approvals are always read, also for a merged pull (see Decisions).
   Any failure of the pull or the approvals throws, as `state` did; a check list that cannot be read whole is not an
   error but `incomplete` facts (readiness waiting, pipeline nil), as today.
6. Delete `readiness(of:)`, `state(of:)`, `reviewers(of:)` (and its `/requested_reviewers` request) and the
   `PullStatusPayload` decode. `merge(_:at:)` is untouched.

GitLab client:
7. `status(of:)` GETs the merge request once and decodes the one response as the request (`MergeRequestPayload`) and
   as the facts (`GitLabMergeFacts`), with `approvals(of:)` started at the same time. It returns the head from the
   response's `sha`, readiness from `MergeReadiness.gitLab`, the pipeline word as the raw head pipeline status.
8. `merge(_:at:)` decodes its reply as `GitLabMergeFacts` and interprets it with `MergeReadiness.gitLab` exactly as
   today (merged with fallbacks to the asked sha, ready or waiting as "GitLab has not finished merging it", blocked
   as GitLab's reason). Delete `readiness(of:)`, `state(of:)`, `reviewers(of:)` and the private `MergeStatusPayload`.

App:
9. `SignalHostIO.read`, merge-when-ready path: resolve the number (the task's known number, else
   `request(forBranch:)`), then one `status(of:)`; take the request from `status.request` and keep the existing
   checks on it (the number is the watched one, the source branch is the task's); then `threads(of:)`; then
   `myReviewPostedAt` only when the done condition needs it. Map the status: `facts.hasReviewer` from
   `request.hasReviewer`, `facts.approved` from `approvedBy` not empty, `facts.merged` from the request's state word
   or a merged readiness, `head` as today, `approvals` and `hostReady` from readiness, `greenChecks` from the pipeline
   word being `success`. When the number is already known there is no separate fetch of the request.
10. `SignalHostIO.read`, other done conditions: `.hasReviewer` reads `request.hasReviewer` from the request just
    fetched (no host call of its own); the rest are unchanged. `deleteMergedBranch` takes the merged head from
    `status(of:).readiness`.
11. `docs/architecture.md`: add one sentence to the "Integration and platform owners" paragraph: a request's state is
    read once per watch read (`RequestStatus`), and merge readiness is a pure rule per host.

## Keep

- The merge floor in `RequestWatch.Snapshot.canMerge` and in `SignalHostIO.merge`: the local head must equal the
  status head, the stage must be unchanged, and the host merge itself carries the accepted head and is refused
  with a 409 when the branch moved. Do not weaken or move any of it.
- `RequestWatch`'s re-read after the Oracle round and its re-read after the merge, and its per-pass snapshot cache.
  They are what makes the floor safe against a push in between; each read is now cheaper, not fewer.
- `approvals(of:)` and `threads(of:)` as their own reads, with their `IncompleteRead` behaviour.
- "No checks at all is not green": the pipeline word stays nil for a GitHub head with no runs and no statuses, and
  for a GitLab merge request with no pipeline, so `greenChecks` is false and such a request is not merged
  automatically. This is today's behaviour. Do not make no checks count as green.
- The wording of every `MergeReadiness` reason; the sidebar and the Operator's waiting line read them.
- `PreservedFields`, the saved task record and `DoneCheck.Facts` are untouched: no saved shape changes.

## Decisions already taken

- Consistency. Every fact in a status comes from one fetch of the request, and every list that depends on a commit
  names the commit that fetch returned (GitHub's check runs and statuses are asked for that head sha). The head in
  the status, the head inside `.ready(head:)` and the head inside `.merged` all come from that one response. Approvals
  are a separate listing on both hosts and are not tied to a commit; that was true before and is not changed here
  (do not start comparing a review's commit id to the head). A status is never partial: if the request fetch or the
  approvals fail, the read throws.
- No client-side cache or memo. "Once per watch read" is enforced by the shape of `SignalHostIO.read`, not by
  remembering answers.
- Approvals are read for a merged or closed request too: a signal whose done condition is `.approved` must still see
  the approval after the merge. Check lists are not read for a request that is not open, because readiness never
  uses them then and `greenChecks` is only used for an open one.
- A GitHub merge-when-ready read with a known number now costs: the pull, the reviews (one page plus the empty page
  that ends the list), the check runs, the statuses, then the threads. A task with no known number pays one extra
  fetch, to find the request from its branch, until the first pass saves the number.
- The review-posted time is not part of `RequestStatus` (it is its own multi-list read and only one done condition
  uses it).
- Cannot happen here, no handling: a pull with two heads, a status of a request in another repository (the client is
  bound to one), or a check list that grows between the two pages of one read (a failure to reach `total` already
  reads as incomplete).
- If a merge-readiness reason must change to fit the pure function, do not change it: stop and report.

## Tests

Pure table tests (new `GitHubReadinessTests` and `GitLabReadinessTests` in `AiTermCoreTests`, no stub session):
- GitHub, moved from `GitHubPublishTests`: every row of `readinessReadsThePullRequestItsCheckRunsAndItsStatuses`
  (as facts, not as stubbed JSON); every row of `theMergeAndRunStatusReadEveryCheckTheSameWay`, now asserting both
  the readiness and the pipeline word from the same facts; the "not listed whole" row from
  `checksThatCannotBeReadWholeNeverReadReady` (expects waiting and a nil pipeline); the pipeline-word rows of
  `gitHubStateReadsDraftChecksMergeabilityAndApprovals` (failure, pending, success, and nil for no checks).
- GitLab, moved from `GitLabPublishTests`: every row of `readinessIsGitLabsOwnVerdictWithItsPipeline`;
  `aDraftIsNeverReady`; `aDraftsSkippedPipelineLeavesTheDraftAsItsOnlyBlocker`; `aDraftsPipelineIsSaidBeforeTheDraft`;
  `anUnknownPipelineStatusIsNotGreen`; `aPipelineThatDidNotRunIsNotGreen`.

Stay as client tests, adjusted to `status(of:)` (stubbed `URLSession`): GitHub `aFailingCheckOnALaterPageIsStillSeen`,
`statusesAreReadToTheEndToo`, the paging-bound half of `checksThatCannotBeReadWholeNeverReadReady` (counts requests
against `listedPages`), `readinessThatCannotBeAskedThrows`; one client test per host that the read returns the
request, the head, the approvals and the pipeline word from the stubbed endpoints. GitLab merge reply tests
(`itIsMergedAtTheAcceptedCommit`, `aMergeGitLabHasNotRunYetIsWaitingNotMerged`, `aFastForwardMergeIsTheAcceptedCommit`,
`aRefusedMergeIsBlockedNotThrown`) stay, because they cover the request that is sent and the mapping of its reply.

Delete (nothing else): `GitHubPublishTests.theMergeAndRunStatusReadEveryCheckTheSameWay` and the two
`state`-named tests are replaced by the above; `SignalReviewActivityTests.reviewersIncludeGitHubTeamsAndGitLabPeople`
is replaced by a request-level test (below). The behaviour "readiness and state are separate reads that could
disagree" is deleted.

Add:
- One consistent read: a stubbed GitHub host that answers the pull with head A the first time and head B on any later
  GET of it; the status names A, `.ready(head: A)` carries A, the check runs and statuses were asked at A, and
  exactly one request was made to the pull path. The same for GitLab (one request to the merge request path).
- Request counts: a merge-when-ready `SignalHostIO.read` on GitLab with a known number makes one merge request GET,
  one approvals GET and the discussion pages, and no other; on GitHub one pull GET, no `requested_reviewers` request.
  Update `SignalHostIOTests.aReviewerOnlyWatchReadsItsConditionWithoutChecksThreadsOrLocalGit` (now one request) and
  `anApprovalWatchReadsTheReviewersFromTheRequestItAlreadyFetches` (still two).
- `hasReviewer`: GitHub with only a team asked is true, with a user asked is true, with none is false; GitLab with a
  reviewer is true; the `reviewers` display names are unchanged (a team never appears in them).
- `deleteMergedBranch` still learns the merged head (existing coverage in `SignalHostIOTests`/Operator tests; confirm
  it passes through `status`).
- No fixture is re-recorded. Operator journey (`SignalJourneyTests`) and `RequestWatch` tests must stay green without
  change.

## Proof

- While iterating: `scripts/test.sh swift -- --filter GitHubReadinessTests`, `--filter GitLabReadinessTests`,
  `--filter GitHubPublishTests`, `--filter GitLabPublishTests`, `--filter SignalHostIOTests`,
  `--filter SignalReviewActivityTests`, `--filter RequestWatch`, `--filter SignalJourneyTests`,
  `--filter MergeRequestPublisherTests`.
- Then plain `scripts/test.sh`, started in the background. This phase merges only after `scripts/test.sh all`, which
  the orchestrating session runs.
- No view changes, no wire change, no saved-state change.

## Done when

- `grep -rn "readiness(of\|state(of\|\.reviewers(of\|MergeRequestState\|MergeStatusPayload\|PullStatusPayload\|
  signalReviewers\|requested_reviewers" app/Sources app/Tests` returns nothing. (`requested_reviewers` as a field of
  the pull payload is expected: the grep should find it only in the pull's decode, so check the hits by hand.)
- The only code that decides merge readiness is `MergeReadiness.gitHub` and `MergeReadiness.gitLab`; each is called by
  the client's `status(of:)` (and, for GitLab, by `merge`).
- No test builds a stub session to check a readiness table row.
- Plain `scripts/test.sh` is green.

## Not in this step

- One interface and factory (7a); review threads reader, Jira search, date parsing and the GitLab host rule (7b).
- Any change to when the Operator reads a request (the tick, the watch interval, the caches): phase 5.
- Reading review threads as part of the status, or comparing a review's commit to the head.
