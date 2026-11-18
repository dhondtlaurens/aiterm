# 1. Queries and readers

Implementer: Claude Opus 5.5. Depends on: nothing. The app must build and behave exactly as before when
this step ends: nothing here is wired into signals yet.

## Why

Signals will run a query per trigger. Jira already reads JQL. GitLab and GitHub need what this step builds:
a parser for GitLab's search syntax that turns it into GraphQL filters, a normaliser for GitHub's search
syntax, account reads that list merge requests for such a query and that answer "does this one merge
request match this query", and the readers that turn those into a `SignalRead`. The next step switches the
signal model onto them and deletes the old event readers.

## Today

- `app/Sources/AiTermCore/GitLab/GitLabAccount.swift`: `GitLabAccount: SignalAccountReading`. `requests(event:since:)`
  lists through REST `/api/v4/merge_requests` with `scope=all`, `state=opened` and `reviewer_username`, or
  `author_username` plus `assignee_username[]`, paged by `HTTPJSON.pages`; maps each entry with the private
  `AccountRequest.item(config:)` into a `SignalItem` (item `.request(remote:number:)`, title, description,
  `MergeRequest`, updated, assignees, changesRequested). `threads(of:)` reads a request's threads through
  `GitLabClient.threads(of:)`. The account's username comes from `HostUserMemo.user(.gitLab, …)`.
- `app/Sources/AiTermCore/GitHub/GitHubAccount.swift`: `GitHubAccount`. `requests(event:since:)` runs GraphQL
  `search(query:type:ISSUE)` for `is:pr is:open` plus `user-review-requested:@me`, or `author:@me` and
  `assignee:@me`, follows the cursor, checks `issueCount` against what it read, maps `AccountPull.item`.
- `app/Sources/AiTermCore/Operators/Signals/Sources/`: `SignalAccountReading` (`requests(event:since:)`,
  `threads(of:)`), `ReviewRequestedReader`, `MyRequestReader` (filters authored requests and decides
  "sent back" and "waiting on my reply"; caches threads per request by `updated`), `JiraQueryReader`
  (`init(client:conditions:now:)`, compiles `JQL.compile(conditions)`, polls with a delta window, pages by
  token), `SignalRead`, `SignalItem`, `SignalSourceReader` (`poll(since:full:)`).
- Tests: `app/Tests/AiTermCoreTests/Operators/SignalSourceTests.swift` stubs URL sessions and asserts request
  shapes and paging; reuse its stubbing pattern.
- `grep -rn "RequestConditions.Event" app/Sources` shows who depends on the event enum; leave those alone.

## Change

1. **`GitLabQuery`** in `app/Sources/AiTermCore/Operators/Signals/Queries/GitLabQuery.swift`. Parse a query
   string into a value: the role (`author`, `assignee`, `reviewer`, or none), the GraphQL filter arguments,
   the project paths, the state, and the thread tokens kept apart. Grammar and keys as in the README. Two
   entry points: one for a Start query (the role rule: exactly one positive `@me` role) and one for a Done
   query (zero or one). Errors are a value with the offending token and one plain sentence
   (`"Unknown filter colour:red."`, `"Name yourself in one role: author:@me, assignee:@me or reviewer:@me."`,
   `"review-state takes unreviewed, review_started, reviewed, requested_changes, approved or unapproved."`).
   Mapping to GraphQL arguments (names are the GraphQL schema's):
   - the role's own token is the root (`authoredMergeRequests`, `assignedMergeRequests`,
     `reviewRequestedMergeRequests`) and adds no argument;
   - `author:x` → `authorUsername`; `assignee:x` → `assigneeUsername`, `assignee:none|any` →
     `assigneeWildcardId: NONE|ANY`; `reviewer:x` → `reviewerUsername`, `reviewer:none|any` →
     `reviewerWildcardId: NONE|ANY`; `@me` as a non-role value is the account's username;
   - `review-state:a,b` → `reviewStates: [A, B]`; `approved-by:x` → `approvedBy: [x]`; `draft:yes|no` →
     `draft: true|false`; each `label:` → appended to `labels`; `target-branch:` → `targetBranches`;
     `source-branch:` → `sourceBranches`; `milestone:` → `milestoneTitle`; `state:` → `state` (default
     `opened` for a Start query, `all` for a Done query); `project:` → one read per path through
     `projectPath`;
   - negation goes into `not:` for the fields GitLab can negate there: `approvedBy`, `assigneeUsernames`,
     `authorUsername`, `labels`, `milestoneTitle`, `reviewStates`, `reviewerUsername`, `sourceBranches`,
     `targetBranches`. `-reviewer:any` is `reviewer:none` and the reverse, likewise for assignee.
     `-draft:` is refused (write `draft:yes` or `draft:no`); any other negation GitLab cannot express is
     refused naming the token.
   - A token that repeats the root's own role (`reviewer:@me` twice) is fine; a value list on a key that
     takes one value is refused.
   The value also renders the GraphQL query text and its variables JSON, with every user value passed as a
   variable, never spliced into the query text.
2. **`GitHubQuery`** in `…/Queries/GitHubQuery.swift`: split off the two `threads:` tokens; refuse
   `is:issue`; add `is:pr` when missing; for a Start query add `is:open` unless the query already states
   `is:open`, `is:closed`, `is:merged` or `state:`. GitHub validates the rest itself.
3. **Account reads.** A new protocol at the I/O seam, `SignalQueryAccount` in `…/Sources/`, with:
   `user()` (the account's username, through `HostUserMemo`), `requests(matching:)` (every open item a Start
   query lists, as a `SignalRead`, complete only when every page was read and every node decoded), the
   done read `matches(_:request:branch:)` (true, false, or throws when unreadable) and `threads(of:)`.
   - `GitLabAccount`: GraphQL at `/api/graphql` through the existing `HostAPI` (`GitLabClient.api`),
     `first: 100`, following `pageInfo.endCursor`, at most 100 pages, nodes mapped to the same `SignalItem` as
     `AccountRequest.item` builds today (web URL, iid, title, branches, author, assignees, description,
     updatedAt, draft, state, fork from source vs target project id, `changesRequested` from the merge
     status as today). The done read asks the root for the role if the query names one, else
     `project(fullPath:).mergeRequests`, with `iids: [n]` and `projectPath` (or the project's full path), and
     answers whether that one request came back. GraphQL `errors` beside data make a read fail, never an
     empty complete read.
   - `GitHubAccount`: the same search loop as today, with the normalised query; the done read adds
     `repo:<owner/name>` and `head:<branch>` to the query and answers whether the number came back.
   - Keep `requests(event:since:)` and `SignalAccountReading` as they are; the next step deletes them.
4. **Readers** in `…/Sources/`: `GitLabQueryReader` and `GitHubQueryReader` (`SignalSourceReader`) take a
   parsed query and a `SignalQueryAccount`. They list, then apply the thread tokens per item with the same
   cache rule `MyRequestReader` uses (reuse a request's threads while its `updated` is unchanged; drop cache
   entries for items no longer listed). Waiting on me: an unresolved thread whose last author is known and is
   not the account (case-insensitive). Resolved: no unresolved thread. An incomplete listing stays incomplete;
   `full` is true; the cursor is the read time.
5. **`JiraQueryReader`**: add `init(client:jql:now:)` beside `init(client:conditions:now:)`; the conditions
   initializer becomes a call to the new one with `JQL.compile(conditions)`. Behaviour otherwise unchanged.

## Keep

- `SignalAccountReading`, `requests(event:since:)`, `ReviewRequestedReader`, `MyRequestReader`, `JQL`,
  `RequestConditions`: still used by the app until step 2.
- `HostUserMemo`, `HostAPI`, `Lenient`, `HostDate`: reuse them.

## Decisions already taken

- `state:` in a Start query: GitLab lists only open items unless the query says otherwise.
- `project:` with several paths reads once per path and merges by identity.
- Unknown author on a thread's last note is not evidence that someone else spoke (as today).
- `@me` in the GraphQL variables is the account's username; GitLab's `ME` wildcard is not used.
- GitHub forks: as today (`forkHead`).

## Tests

- `GitLabQueryTests` (new): every GitLab row of this table parses into the expected root and arguments, and
  the rendered variables carry the values (the account is `alex`):

  | Query | Root | Arguments |
  |---|---|---|
  | `reviewer:@me review-state:unreviewed draft:no` | reviewRequested | reviewStates [UNREVIEWED], draft false |
  | `assignee:@me review-state:requested_changes,reviewed` | assigned | reviewStates [REQUESTED_CHANGES, REVIEWED] |
  | `assignee:@me threads:waiting-on-me` | assigned | none; thread token waiting-on-me |
  | `assignee:@me review-state:approved draft:no threads:resolved` | assigned | reviewStates [APPROVED], draft false; thread token resolved |
  | `assignee:@me reviewer:any -reviewer:@me` | assigned | reviewerWildcardId ANY, not.reviewerUsername alex |
  | `reviewer:@me -assignee:@me` | reviewRequested | not.assigneeUsernames [alex] |
  | `author:@me label:"needs review" target-branch:main project:shop/webshop` | authored | labels, targetBranches, projectPath |

  Refusals: no role, two roles, unknown key, bad review state, `-draft:no`, a list on `author:`, an unclosed
  quote. A Done query without a role parses to the project root. `state:` defaults per entry point.
- `GitHubQueryTests` (new): `is:pr`/`is:open` added only when missing, thread tokens split off, `is:issue`
  refused.
- Account tests (in `SignalSourceTests` or a new suite): the GitLab GraphQL body for a role root carries the
  query and variables, pages follow the cursor, `errors` beside data fail the read, an undecodable node makes
  it incomplete; the done read uses the role root with `iids`/`projectPath` or the project root, and answers
  true/false; the GitHub search carries the normalised query and the done read adds `repo:` and `head:`.
- Reader tests: thread tokens (waiting on me, resolved, negated) with a stub `SignalQueryAccount`; the cache
  reuses threads for an unchanged `updated` and reads again after a change.
- `JiraQueryReader`: one test that the string initializer sends the JQL given.

## Proof

`scripts/test.sh swift -- --filter GitLabQueryTests`, the same for the other new suites and
`SignalSourceTests`, then plain `scripts/test.sh` green.

## Done when

The new types and reads exist with their tests; nothing in the app uses them yet; every existing test passes
unchanged.

## Not in this step

The `Signal` model, triggers, wiring in `SignalConnections`, the done edge, deleting the old readers and types
(step 2); the sheet and the query writer (steps 2 and 3).
