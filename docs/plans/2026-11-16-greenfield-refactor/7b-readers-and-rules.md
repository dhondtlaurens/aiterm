# 7b. One reader per read, one rule per question

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1b, 1h, 7a. Comes from: audit HO F4, F6, F7.

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The plan says one "is this URL on the configured GitLab" rule that compares host and port. A git remote cannot
be compared by port: `RemoteURL` drops the port, and an SSH remote's port is the SSH port, not the web port. Only
a web address (`URL`) can be compared by host and port. So the one rule has two entry points on `GitLabConfig`, one
for web addresses (host and port) and one for a remote's host (host only), both built on the same normalisation
(`comparableHost`, `comparablePort`). The port-bearing GitLab case the audit worried about (a GitLab on port 8443
matching any remote on the same host) therefore stays open for git remotes; it is not fixable from a remote URL.
Evidence: `app/Sources/AiTermCore/Git/RemoteURL.swift` (`hostPort` loses its colon part).

## Why

Three small duplications remain after 7a. The review-thread badge has its own lenient reader beside the strict
one the Operator decides on, twice (GitHub GraphQL, GitLab REST), with option pairs and flags to tell them apart.
Jira tickets are read from the same `/search/jql` endpoint by two methods with two response types, two mappings and
two page sizes. And "is this address on the one GitLab that is configured" is written four times with three
different rules, while date parsing builds a formatter on every call. The end state: one strict thread read per
host that the badge counts, one Jira search with one mapping, one host rule, and formatters made once.

## Today

The code as it is after 1b, 1h and 7a.

Review threads:
- `GitHubClient.reviewThreads(of:)` (lenient, 10 pages, counts only `isResolved`) and `GitHubClient.threads(of:)`
  (strict, 50 pages, `IncompleteRead` on a malformed thread, a repeated cursor or too many pages), both over the
  private `readThreads`, with `threadsQuery` and `threadDetailsQuery`, `ThreadResolution`, `ThreadProblem`,
  `GraphQLProblem`, the constants `threadsPerPage`, `threadPages`, `threadPagesRead`, and `graphQLPages` /
  `GraphQLPageInfo.next` taking optional `exhausted` and `invalidCursor` so a badge read can be lenient. The
  protection-rules read also uses `graphQLPages`, always with both set.
- `GitLabClient.reviewThreads(of:)` (lenient, stops at a short page, 10 pages) and `threads(of:)` (strict, until
  an empty page, 50 pages), over `readDiscussions(complete:)`; constants `discussionsPerPage`, `discussionPages`,
  `threadPagesRead`.
- `CodeHosts/ReviewThreadsReader.swift`: `ReviewThreadsReading` (the seam the watcher is tested through) and the
  struct `ReviewThreadsReader`, which parses a request's web address into a repository or project (`target(of:
  gitLabHost:)`), then calls `reviewThreads(of:)`. Its only consumer is `AiTerm/ReviewThreadsWatcher.swift`
  (through `AppController`), which discards a failed read and keeps the last count.
- `GitHubAccount.threads` and `GitLabAccount.threads` already call the strict `threads(of:)`.

Jira:
- `JiraClient.search(jql:)` (internal; the picker: 25 results, fields summary, description, status, issuetype,
  updated; private `SearchBody` and `SearchResponse` with lenient field types) and, in `Jira/JiraClient+Signals.swift`,
  `search(jql:fields:pageToken:)` (public; the signals: 100 results, more fields, `SignalSearchResponse`, returns a
  `JiraSearchPage` with `complete`). Two `JiraTicket` mappings. Callers of the first: `myOpenIssues`,
  `search(text:)`, `searchKeys`, `tickets(_:scope:)`, `lookUp`. Callers of the second: `JiraQueryReader.poll`
  (`Signals/Sources/JiraQueryReader.swift`) and, through it, `SignalHostIO.ticket`.
- `JiraClient.date` builds a `DateFormatter` on every call; `GitLabClient.date` builds two `ISO8601DateFormatter`s
  on every call and is also used by `GitHubClient+SignalReview`, `GitLabClient+SignalReview`, `GitHubAccount`,
  `GitLabAccount` and `GitLabClient`'s issue payload (once per item of a 100-page poll).

The GitLab host rule, written four ways (after 7a's rename):
- `CodeHosts.connection` (was `MergeRequestSearch.connection`): `remote.host == gitLab.hostURL.host?.lowercased()`.
- `ReviewThreadsReader.target`: `comparableHost` and `comparablePort` of the web address.
- `GitLabAccount.threads`: `remote.host == config.hostURL.host?.lowercased()` on `RemoteURL(request.remote)`.
- `GitLabAccount.AccountRequest.item(host:)`: `url.host?.lowercased() == host.host?.lowercased()`.
- `GitLabClient.isIn` checks a path (`/<project>/-/merge_requests/`), not a host; it is a different question.
`URL.comparableHost` and `comparablePort` live in `AiTermCore/HTTPJSON.swift`.

Tests that cover these: `GitHubClientTests` and `GitLabClientTests` (the four `reviewThreads...` tests each, plus
`aRepositoryWithoutAnOwnerIsNotAsked`), `MergeRequestPublisherTests` (strict thread tests), `ReviewThreadsReaderTests`
(`target` cases and the two client round trips), `ReviewThreadsWatcherTests` and `ReviewThreadsBadgeTests` (through
fakes, unaffected), `JiraClientTests`, `SignalSourceTests` (Jira paging), `GitLabAccount`/`GitHubAccount` tests in
`SignalSourceTests`.

## Change

Review threads:
1. Delete `reviewThreads(of:)` from `HostRepository` (the badge group of 7a) and from both clients. `threads(of:)`
   is the one read of a request's review threads on each host: strict, complete, up to the existing 50 pages, and
   `IncompleteRead` for a malformed entry, a thread without an id, a repeated cursor or too many pages.
2. GitHub: delete `threadsQuery`, `ThreadResolution`, `ThreadProblem`, `threadPages`, the `complete:` parameter of
   `readThreads` (inline it into `threads(of:)` if it then has one caller), and the optional forms of `exhausted`
   and `invalidCursor` in `graphQLPages` and `GraphQLPageInfo.next` (both are always given now, so they become
   required and the "badge accepts a repeated cursor" branch goes). Rename `threadDetailsQuery` to `threadsQuery`.
3. GitLab: delete the lenient mode of `readDiscussions` (stop-on-short-page and the 10-page bound), the constant
   `discussionPages`, and fold it into `threads(of:)`. It reads until an empty page, as the strict read does today.
4. `ReviewThreadsReader.threads(of:)` asks `threads(of:)` of the repository for the request's address and returns
   the count `ReviewThreads(resolutions: threads.map(\.resolved))`. It builds the repository through
   `CodeHosts.Connection.repository(session:)` (7a). Its `ReviewThreadsReading` protocol, its nil answer for a host
   that is not connected, and the watcher stay exactly as they are.

One Jira search:
5. One method, `JiraClient.search(jql:limit:pageToken:)`, returns a `JiraSearchPage` (tickets, next page token,
   `isLast`, `complete`). It always asks for one fixed field list (summary, description, status, issuetype, updated,
   labels, project, assignee), decodes one response type, and maps to `JiraTicket` in one place: description through
   `ADFText.plain`, the browse URL from the site, `updated` through the shared date parser, labels, project key,
   assignee account id. `limit` is the page size: 25 for the picker, 100 for signals.
6. Decode fields of the wrong type as absent, as the picker's response does today (`Lenient` on `issuetype`,
   `status`, `updated`, labels, project, assignee); an entry without a key or a summary is dropped alone and makes
   `complete` false. This is the picker's shape, which `JiraClientTests.anIssueThatCannotBeReadDropsAlone...`
   pins; Jira does not send a field of the wrong type, so signals lose nothing real.
7. Delete the old `search(jql:)`, its `SearchBody` and `SearchResponse`, `SignalSearchResponse`, and the second
   mapping. The picker's callers (`myOpenIssues`, `search(text:)`, `searchKeys`, `tickets`, `lookUp`) call the one
   method with `limit: maxResults` and read `.tickets`, ignoring `complete`. `JiraQueryReader` stops passing a field
   list.

Dates:
8. Add a small Core helper `HostDate` with two parsers, each built once: the ISO 8601 time with or without
   fractional seconds (today `GitLabClient.date`), and Jira's `yyyy-MM-dd'T'HH:mm:ss.SSSZ` (today
   `JiraClient.date`). Results must equal today's for the same text, including the nil for text that does not
   parse. Use the Foundation type that is `Sendable` or a `nonisolated(unsafe)` static as the rest of the target
   does for formatters. Replace every caller listed under Today and delete `GitLabClient.date` and `JiraClient.date`.
   The two `ISO8601DateFormatter().string(from:)` calls that write a `since` query (`GitHubAccount`, `GitLabAccount`)
   may use the same helper's formatter for output; they must send the same text.

One GitLab host rule:
9. On `GitLabConfig` add two methods: one that says whether a web address (`URL`) is served by this GitLab
   (`comparableHost` equal and `comparablePort` equal; the scheme is not compared, as today), and one that says
   whether a remote's host string is this GitLab's (lowercased, trailing dot dropped, no port). Both read the
   configured host the same way. Use them in `CodeHosts.connection`, `ReviewThreadsReader.target` (which then takes
   the `GitLabConfig?` instead of a bare URL), `GitLabAccount.threads` (parse `request.remote` as a `URL`, which
   `AccountRequest.item` built from the web address with its port, and use the web method) and
   `GitLabAccount.AccountRequest.item` (give it the config instead of a bare URL). `GitLabClient.isIn` stays.
10. Docs: `docs/architecture.md` (the review-threads row of the table, about line 175) says "read-only, 100 a page, at
    most 10 pages"; change it to say it reads until an empty page, at most 50 pages, and that a list that cannot be
    read whole leaves the last count in place.

## Keep

- The watcher's rule that a failed read, or a host that is not connected, leaves the last good count
  (`ReviewThreadsWatcher.read`). A thread read that now throws `IncompleteRead` falls under it; do not add a second
  fallback.
- `IncompleteRead` itself and its use by the merge floor: it is how a partial list becomes "decides on nothing".
- The picker's text paths in `JiraClient.search(text:)` (key and number fast paths, Lucene escaping, the 400 per-key
  fallback in `tickets`): written after real 400s.
- `JiraQueryReader`'s completeness rules, paging loop and `confined` delta query.
- `GraphQLProblem`/`answer.checked(repo:)` for the strict thread read: it maps FORBIDDEN, NOT_FOUND and other
  errors.
- `OpenPullListing`, `HostUserMemo`, `CredentialGuard`.

## Decisions already taken

- A repository with more than 50 pages of threads (5,000) is not being reviewed by hand; its badge keeps its last
  count, as for any failed read.
- The badge now costs one extra request on GitLab (the terminal empty page) and sends GitHub's larger query
  (last comment of each thread). Real, small, accepted: the poll is once a minute per review row and GitLab here is
  self-hosted.
- A GitLab discussion that does not decode, or a resolvable one without an id, now makes the whole badge read
  incomplete instead of being skipped. Real GitLab always sends both; accepted.
- GitHub's GraphQL answer `{"data":null,"errors":[{"message":...}]}` without a type now throws `refused`, where the
  badge's closure threw `repoNotFound`. Both are failures that leave the count; adjust the one test that asserts it.
- Signals read tickets with lenient fields (step 6). No second strict mode.
- A web address on a GitLab with a custom port matches only a configured host with that port. A git remote's host is
  matched without a port (see the section on where this brief differs from the plan).
- No change to what is sent to Jira except the field list on picker reads (now the longer list) and nothing else.

## Tests

- Delete, each with its survivor:
  - `GitHubClientTests.reviewThreadsStopAtTenPagesToo` and `GitLabClientTests.reviewThreadsStopAtTenPages`: the
    ten-page bound is deleted; the 50-page bound is detected by `MergeRequestPublisherTests.gitHubThreadsPastTheCapAreNoAnswer`
    and `gitLabThreadsPastTheCapAreNoAnswer` (confirm both still exist after 1b; if one is gone, retarget the ten-page
    test to 50 pages instead of deleting it).
  - Tests of `SignalSearchResponse` or the old picker `search(jql:)` as separate methods: none are expected to exist
    by name; the behaviour is covered by the adjusted `JiraClientTests`.
- Adjust: `GitHubClientTests` `reviewThreadsAskGraphQLForThePullRequestsThreads`, `reviewThreadsFollowTheCursor`,
  `aRepositoryOrPullRequestGraphQLCannotSeeThrows` (fourth case now `refused`), `aRepositoryWithoutAnOwnerIsNotAsked`
  call `threads(of:)` and count; the page fixtures gain a thread `id`. `GitLabClientTests` `reviewThreadsCount...`,
  `reviewThreadsReadEveryPageUntilAShortOne` (now until an empty page; rename), `reviewThreadsMapStatusesLikeEveryOtherRead`
  call `threads(of:)`. `ReviewThreadsReaderTests.eachHostIsAskedWithItsOwnConnection`: the GitLab stub also answers
  the empty second page and the expected request list gains it. `ReviewThreadsReaderTests` port cases move to a
  table test of the two `GitLabConfig` methods (new, in `GitLabClientTests` or a new `GitLabHostRuleTests`) plus the
  path-parsing cases of `target` that stay. `SignalSourceTests` calls `search(jql:limit:pageToken:)` through
  `JiraQueryReader` unchanged.
- Add: a test that picker and signal reads send the same field list and differ only in `maxResults`; a test that a
  Jira time and a GitLab time parse to the same dates as before (fractional, whole seconds, bad text is nil); a test
  that a web address with another port, a trailing-dot host or a different case is judged by the web rule, and a
  remote host with a trailing dot or different case by the host rule; a test that an issue-level malformed entry
  makes a search page `complete == false` while a picker read still returns the other tickets.
- No fixture is re-recorded.

## Proof

- While iterating: `scripts/test.sh swift -- --filter GitHubClientTests`, `--filter GitLabClientTests`,
  `--filter MergeRequestPublisherTests`, `--filter ReviewThreadsReaderTests`, `--filter ReviewThreadsWatcherTests`,
  `--filter JiraClientTests`, `--filter SignalSourceTests`, `--filter CodeHostsTests`.
- Then plain `scripts/test.sh` in the background.
- No view changes; the badge's count and its redraw behaviour are covered by the watcher and badge tests.

## Done when

- `grep -rn "reviewThreads(of\|threadPages\b\|discussionPages\|ThreadResolution\|ThreadProblem\|SignalSearchResponse\|
  SearchBody\|GitLabClient.date\|JiraClient.date" app/Sources app/Tests docs/architecture.md` returns nothing (the
  GraphQL query text `reviewThreads(first:` inside a query string is expected; the grep names the Swift members).
- `grep -rn "hostURL.host\|comparableHost" app/Sources` shows the GitLab host compared only inside the two
  `GitLabConfig` methods and `URL.comparableHost` itself.
- `grep -rn "ISO8601DateFormatter()\|DateFormatter()" app/Sources/AiTermCore/{GitHub,GitLab,Jira}` returns nothing.
- `JiraClient` has one `search(jql:...)`.
- Plain `scripts/test.sh` is green.

## Not in this step

- The one interface and factory (7a); the single status read and merge readiness rule (7c).
- Jira paging fallbacks and the old GitLab URL form (1h, already done).
- The shared paging helper for the hosts (2h) and the review-posted read's own paging.
