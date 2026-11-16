# 7a. One host interface

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1b (the write surface is gone), 1h. Comes from: audit
HO F2.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

Two small differences from the plan's one-liner, both forced by the code.

- The plan says "one factory". The factory lives today in an enum called `MergeRequestSearch`, named after the
  oldest of the four protocols. After this step nothing is a "search" protocol, so the enum is renamed `CodeHosts`
  and keeps its meaning. The name is mine; the audit's "one `MergeRequestSearch.source`" would leave a misleading
  name behind.
- The audit lists `currentUser` in the interface. Only the two clients themselves call it (inside the review-posted
  read), so it leaves the interface and stays an internal helper of each client.

## Why

A code host is read through four protocols stacked on each other (search, publishing, repository, signal
reading) and three factories, because four phases each added a layer. After 1b only reads and one write remain, and
the only types behind the protocols are `GitHubClient` and `GitLabClient`. No caller needs a partial view: every
call site holds the host as whichever layer it happened to need, and three of them have to repeat the same
two-way switch to build it. The end state is one `HostRepository` protocol with the live operations grouped by who
uses them, and one factory that turns a project's remote and the saved connections into one. Nothing about what is
sent to either host changes in this step.

## Today

The code as it is after 1b and 1h. Re-run the greps first: if 1b left something behind (for example the
`MergeRequestPublisher` enum), delete it here.

- `app/Sources/AiTermCore/CodeHosts/MergeRequestSearch.swift`: protocol `MergeRequestSearching` (one method,
  `mergeRequests(search:)`), enum `MergeRequestSearch` with `Unavailable` (not connected, no repository path, other
  GitLab host), `host(for:)` (which `CodeHost` a remote is on), `Connection` (a GitHub config with a repo, or a
  GitLab config with a project), `connection(for:gitLab:gitHub:)` (the checks that refuse), and `source(for:...)`
  which switches on the connection and builds a client.
- `app/Sources/AiTermCore/CodeHosts/HostRepository.swift`: protocol `MergeRequestPublishing` (what is left of it
  after 1b: protection, the open request from a branch, readiness, state, merge, threads, approvals, current user),
  protocol `HostRepository` which adds the badge's thread count and the two open-request listings, and, if 1b left
  it, `MergeRequestPublisher.publisher(for:...)`.
- `app/Sources/AiTermCore/Signals/Sources/SignalHostReading.swift`: protocol `SignalHostReading` (adds the newest
  request for a branch, the default branch, the reviewers, the time of my review), a protocol-extension default for
  `signalRequest(from:)` that no type uses, and `MergeRequestSearch.signalSource`, a second copy of `source`'s
  switch.
- `GitHubClient` and `GitLabClient` (`AiTermCore/GitHub/GitHubClient.swift`, `GitLab/GitLabClient.swift`) conform to
  `HostRepository`; their `+SignalReview.swift` files hold `extension ...: SignalHostReading` with
  `signalReviewers` and `mySignalReviewPostedAt`. They are the only conforming types: `grep -rn "HostRepository\|
  MergeRequestPublishing\|SignalHostReading" app/Tests` must show no fake once 1b deleted `FakeMergeHost`.
- Call sites that hold a layer of the family:
  - `AiTerm/ReviewCreationModel.swift`: `ReviewCreationModel.searcher` holds `any MergeRequestSearching`;
    `ReviewTicketLookup.init(project:...)` calls `MergeRequestSearch.source` and passes the result to
    `TicketMergeRequests.requests(for:in:)`; `extension MergeRequestSearch.Unavailable` words the refusals.
  - `AiTerm/SheetCoordinator.swift` (about line 297): `MergeRequestSearch.host(for: remote)`.
  - `AiTerm/TaskCreationModel.swift`: `gitLabIssueSource` calls `MergeRequestSearch.connection` and then builds a
    `GitLabClient` itself, because `issues(search:)` is GitLab only and not part of any protocol.
  - `AiTerm/Operators/SignalHostIO.swift`: `binding` returns `any SignalHostReading` from `signalSource`; `request`
    takes the same type; it finds a request by number with `mergeRequests(search: String(number)).first {...}`, a
    text search used as a get.
  - `AiTerm/Operators/SignalWorkerIO.swift` (`requestCheckout`, about line 216): `signalSource`, then
    `existingRequest(from:)`.
  - `AiTermCore/Operators/WorkerGuard/WorkerGuard+Host.swift`: `liveFence` calls `MergeRequestSearch.connection`
    and repeats a two-case switch to build a client, only to ask `defaultBranch()` and `protection(of:)`.
  - `AiTermCore/Tasks/TicketMergeRequests.swift`: `requests(for:in:)` takes `any HostRepository`.
  - `AiTermCore/CodeHosts/ReviewThreadsReader.swift`: builds `GitHubClient`/`GitLabClient` directly for the badge.
- Tests that name the family: `AiTermCoreTests/MergeRequestSearchTests.swift` (`source` returns
  `any MergeRequestSearching`), `AiTermCoreTests/MergeRequestPublisherTests.swift` (drives the clients through
  `MergeRequestPublisher.publisher`), `AiTermTests/Operators/OperatorFakes.swift` (check that 1b removed the
  `ports.publisher` line), `AiTermCoreTests/Operators/WorkerGuardHostTests.swift` (builds concrete clients; no
  change).

Greps to re-run before and after: `grep -rn "MergeRequestSearching\|MergeRequestPublishing\|MergeRequestPublisher\|
SignalHostReading\|signalSource\|MergeRequestSearch\b" app/Sources app/Tests docs`.

## Change

1. In `app/Sources/AiTermCore/CodeHosts/HostRepository.swift`, keep one protocol, `HostRepository`, and delete
   `MergeRequestPublishing`, `MergeRequestSearching` and `SignalHostReading`. Its operations, grouped by who uses
   them (write the groups as comments in the file, one line each):
   - Picker (New Review and New Task ticket lookup): search open requests by text (`mergeRequests(search:)`); list
     the open requests up to a number of pages and say whether that was all of them (`openRequests(pages:)`); the
     open requests that close or mention an issue (`openRequests(closingIssue:)`; GitHub answers none).
   - Push guard (worker guard, merged-branch cleanup): the default branch (`defaultBranch()`); whether a branch is
     protected (`protection(of:)`).
   - Watch (the Operator's reads of a task's request): one request by its number (`request(number:)`, new: it
     returns the request or nil when the host has no such number); the newest request for a branch, including a
     closed or merged one (`request(forBranch:)`, today `signalRequest(from:)`); the open request from a branch
     (`existingRequest(from:)`, kept as is: open only, forks excluded); merge readiness (`readiness(of:)`); the
     request's state (`state(of:)`); who approved (`approvals(of:)`); its review threads (`threads(of:)`); who is
     asked to review (`reviewers(of:)`, today `signalReviewers`); when the token's user last posted a review
     (`myReviewPostedAt(of:)`, today `mySignalReviewPostedAt`).
   - Effect: merge at an accepted commit (`merge(_:at:)`), the only host write.
   - Badge: the bounded thread counts (`reviewThreads(of:)`). Step 7b removes it; leave it here.
2. `request(number:)` on each client is the direct GET by number that the numeric branch of `mergeRequests(search:)`
   already makes, with the same "not found means nil" rule (GitHub's 404 maps to `repoNotFound`, GitLab's to
   `projectNotFound`, both read as nil here as they are in the search). Make the numeric branch of
   `mergeRequests(search:)` call it, so there is one read of a request by number per client.
3. Rename `signalRequest(from:)` to `request(forBranch:)`, `signalReviewers` to `reviewers(of:)` and
   `mySignalReviewPostedAt` to `myReviewPostedAt(of:)` on both clients. Move their implementations out of the
   `+SignalReview.swift` extensions into the clients' own conformance; keep the two files for what they hold
   (reviewers, review-posted time, the private decoding structs) but remove the `SignalHostReading` conformance
   lines. Delete the protocol-extension default of `signalRequest`.
4. Drop `currentUser()` from the protocol. It stays an internal method of each client, used by
   `myReviewPostedAt`. If the `repository` property still exists after 1b, delete it (no caller).
5. Rename the enum `MergeRequestSearch` to `CodeHosts` (file `CodeHosts/CodeHosts.swift`, replacing
   `MergeRequestSearch.swift`). It holds: `Unavailable` (unchanged cases), `host(for:)`, `Connection` (unchanged
   cases), `connection(for:gitLab:gitHub:)` (unchanged checks), and the one factory
   `CodeHosts.repository(for remote: RemoteInfo, gitLab: GitLabConfig?, gitHub: GitHubConfig?, session:)`, which
   resolves the connection and returns `any HostRepository`. Give `Connection` one method,
   `repository(session:)`, that builds the client for its case, and have the factory call it. That is the only
   place in the code base that switches on the two cases to build a client.
6. Delete `Signals/Sources/SignalHostReading.swift` and, if present, `MergeRequestPublisher`.
7. Retarget the call sites listed under Today:
   - `ReviewCreationModel.searcher` holds `any HostRepository` from the factory; `ReviewTicketLookup.init` calls the
     factory; the `Unavailable` message extension moves to `CodeHosts.Unavailable`; `SheetCoordinator` calls
     `CodeHosts.host(for:)`.
   - `TaskCreationModel.gitLabIssueSource` calls `CodeHosts.connection` and keeps building the concrete
     `GitLabClient` (see Keep).
   - `SignalHostIO.binding` returns `any HostRepository` from the factory; its private `request(task, host:)` calls
     `request(number:)` or `request(forBranch:)` instead of the text search; `SignalWorkerIO.requestCheckout` uses
     the factory.
   - `WorkerGuard+Host.liveFence` calls the factory once and asks the one repository for both facts; it no longer
     switches on the connection.
   - `ReviewThreadsReader` builds its repository through `Connection.repository(session:)`.
8. Update the sentence in `docs/architecture.md` (the "Integration and platform owners" paragraph) that says each
   client is bound to one repository "(`HostRepository`)" to add that one factory, `CodeHosts.repository`, makes it
   from the project's remote and the saved connections.

## Keep

- Binding to one repository when a client is made (`boundPath`): it is why a token never asks about another
  project. Do not move the binding into the protocol or add a repository argument to any operation.
- `GitLabClient.issues(search:)`: GitLab issues as tickets, used by New Task and New Review. It is not an operation
  of a request repository on both hosts, so it stays a concrete `GitLabClient` method and is not added to the
  protocol. Its caller already builds the concrete client.
- `existingRequest(from:)` stays open only: `SignalWorkerIO.requestCheckout` needs a request that is still open and
  not from a fork. `request(forBranch:)` is a different question (newest, any state).
- `GitHubClient.testConnection` and `GitLabClient.testConnection` (static, used by Settings) and `HostUserMemo`.
- `ReviewThreadsReading` (the protocol the badge watcher is tested through): a real seam with three test readers.
- The refusal wording of `Unavailable` as `ReviewCreationModel` words it today.

## Decisions already taken

- No fake of `HostRepository` is written. After 1b the tests drive the real clients through a stubbed `URLSession`
  (`StubSession`), as `SignalHostIOTests` does. Do not add a protocol-typed test double.
- The factory returns the same client types as before; `as? GitHubClient` in a test that reads `repo` still works.
- `request(number:)` for a number the host does not have returns nil. A real failure (401, 403, 5xx, undecodable)
  throws as it did through the search.
- A name that still says "Signal" in a host type, or "search" for the factory, is renamed in this step; a name
  elsewhere (`SignalConnections`, `SignalAccountReading`) is not touched.
- Cannot happen here: two hosts behind one repository, or a client built for a repository other than the one the
  remote names. No handling.

## Tests

- Delete: nothing that detects a failure. The tests of `MergeRequestSearchTests` and the factory tests of
  `MergeRequestPublisherTests` (`aGitLabRemoteIsPublishedOnTheConfiguredGitLab`, `aGitHubRemoteIsPublishedOnGitHub`,
  `aHostThatIsNotConnectedOrAnotherGitLabIsRefused`, `aRemoteOnNoConfiguredHostIsUnavailableNotGuessed`,
  `searchAndPublishingAskTheSameConnection`) are retargeted to `CodeHosts`, not deleted. Where two tests then
  assert the same refusal, keep the one in `MergeRequestSearchTests` (rename the file `CodeHostsTests`) and drop the
  duplicate; say which in the report.
- Adjust: every test that calls `MergeRequestPublisher.publisher` or `MergeRequestSearch.*` calls `CodeHosts.*`;
  the helper in `MergeRequestSearchTests` returns `any HostRepository`; calls to `signalRequest`,
  `signalReviewers`, `mySignalReviewPostedAt` use the new names (`SignalReviewActivityTests`,
  `SignalHostIOTests`).
- Add: a test that `request(number:)` returns the request for a known number and nil for an unknown one on both
  hosts (stubbed 200 and 404), and that `mergeRequests(search:)` with a bare number makes the same single request.
- No fixture is re-recorded.

## Proof

- While iterating: `scripts/test.sh swift -- --filter CodeHostsTests`, then `--filter MergeRequestPublisherTests`,
  `--filter SignalHostIOTests`, `--filter SignalReviewActivityTests`, `--filter ReviewCreationModelTests`,
  `--filter WorkerGuardHostTests`, `--filter TicketSourcesTests`.
- Then plain `scripts/test.sh`, started in the background.
- No view changes, so no snapshots.

## Done when

- `grep -rn "MergeRequestSearching\|MergeRequestPublishing\|MergeRequestPublisher\|SignalHostReading\|signalSource\|
  MergeRequestSearch\b\|signalRequest\|signalReviewers\|mySignalReviewPostedAt" app docs/architecture.md` returns
  nothing.
- `grep -rn "GitHubClient(\|GitLabClient(" app/Sources` shows construction only inside `Connection.repository`,
  `TaskCreationModel.gitLabIssueSource`, the two account types' `threads` and Settings' connection tests.
- One protocol, one factory; `HostRepository` has no operation without a caller (check each with a grep).
- Plain `scripts/test.sh` is green.

## Not in this step

- The review-threads reader per host and the badge's count (7b); one Jira search, shared date parsing, one rule for
  "this URL is on the configured GitLab" (7b).
- One status read per request and the pure merge-readiness rule (7c); `state`, `readiness` and `reviewers` keep
  their meaning here.
- Deleting the write surface (1b, already done).
