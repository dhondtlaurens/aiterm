# 1b. Delete the code host and Jira write surface

Implementer: Codex `gpt-6.1-sol` high. Depends on: phase 0 only (it also works after 1a). Comes from:
HO F1, TS F1, OC F1 (the thread prompt only).

## Why

The broadcast Operator opened merge requests, edited them, assigned reviewers, answered and resolved
review threads, reran pipelines, looked up users and wrote to Jira (create, transition, comment, link,
sprints). Signals replaced it on 15 Nov and the Operator now has fourteen tools, none of which writes to a
host; a worker writes to its own request through its skill, and AiTerm itself does exactly one host write,
`merge`. The clients, the "outcome unknown" failure taxonomy that guarded those writes, a test double
(`FakeMergeHost`) and about 1,300 lines of tests still carry all of it. After this step the two code host
clients and the Jira client contain only what the app reads, plus `merge`. Behaviour of every read, of
`merge` and of branch protection does not change.

## Today

All paths under `app/Sources/AiTermCore/` unless they start with `app/`. Before deleting any symbol,
re-run the grep given for it; "no caller" means no hit outside the definition, the two clients and their
own tests. Generic names are the danger here: see the last paragraph of this section.

- `CodeHosts/HostRepository.swift`: protocol `MergeRequestPublishing` (name stays until step 7a) with
  `repository`, `protection`, `existingRequest`, `createRequest`, `readiness`, `state`, `merge`, `retarget`,
  `updateRequest`, `markReady`, `assignReviewers`, `threads`, `reply`, `threadDetail`, `resolve`,
  `retryPipeline`, `findUsers`, `approvals`, `currentUser`; types `RequestContent` and `PipelineRetry`; an
  extension giving `markReady` and `assignReviewers` default `beforeWrite`; protocol `HostRepository`
  (`reviewThreads`, `openRequests(pages:)`, `openRequests(closingIssue:)`); enum `MergeRequestPublisher`
  with one static `publisher(for:gitLab:gitHub:session:)` that forwards to `MergeRequestSearch.source`.
  Production callers of the dead ones: none. `grep -rnw "createRequest\|retarget\|updateRequest\|markReady\|assignReviewers\|findUsers\|retryPipeline\|threadDetail" app/Sources`
  hits only this file, the two clients and comments. `MergeRequestPublisher.publisher` has one caller,
  `OperatorPorts.publisher` in `app/Sources/AiTerm/Operators/OperatorPorts.swift`, which nothing reads
  (`grep -rn "\.publisher\b" app/Sources/AiTerm` finds only its definition); the test fixture sets it
  (`OperatorFakes.swift`, `OperatorPorts.scratch`). The `repository` property is read by no production
  code (`grep -rn "\.repository\b" app/Sources` hits only unrelated `ItemRef.repository` and GraphQL payload
  fields).
- `CodeHost.swift`: `HostFailure` protocol (only the three client errors conform), `HostUser`,
  `ReviewThreadDetail`, `MergeRequestState` (fields `iid`, `url`, `draft`, `pipeline`, `mergeable`,
  `approvedBy`, `head`, `Codable`). The only production reader of a `MergeRequestState` is
  `SignalHostIO.read` (`app/Sources/AiTerm/Operators/SignalHostIO.swift`, about line 88), which uses
  `approvedBy`, `head` and `pipeline` only.
- `GitHub/GitHubClient.swift` (struct `GitHubClient`): dead members `repository`, `createRequest`,
  `retarget`, `updateRequest`, `markReady` with `readyMutation`, `assignReviewers`, `reply` with
  `replyMutation`, `threadDetail` with `threadDetailNode`, `threadDetailQuery`, `threadDetailNodeQuery`,
  `resolve` with `resolveMutation`, `retryPipeline` with `failedConclusions`, `findUsers` with
  `assigneePages`, the convenience overload `graphQL(_:query:variables:)` (no `answer`, used only by the
  dead mutations), the "outcome unknown" extension `GitHubError.outcomeUnknown`, the `notSent` case and the
  `HostFailure` conformance of `GitHubError`; `GraphQLProblem.path` (read only by `threadDetail`).
- `GitLab/GitLabClient.swift` (struct `GitLabClient`): dead members `repository`, `createRequest`,
  `retarget`, `readyTitle` with `draftPrefixes`, `markReady`, `updateRequest`, `userId`, `assignReviewers`,
  `reply`, `threadDetail`, `resolve`, `retryPipeline` with the private `RequestWithPipeline` type,
  `findUsers`, `GitLabError.noUser` (thrown only by `userId`), `GitLabError.notSent`, the
  `outcomeUnknown` extension and the `HostFailure` conformance.
- `HTTPJSON.swift`: `HTTPJSON.Failure.outcomeUnknown`, `HTTPJSON.preparingWrite`, `HostAPI.write`. Their only
  callers are the dead write methods and `HTTPJSONTests`. `HostAPI.malformed` is built as
  `<Error>.notSent(.decoding)` in both clients' `api(...)` (and once in `GitLabClient.issues`) and as
  `GitHubError.notSent(.decoding)` in `existingRequest`: those become `.decoding`, the same sentence.
- Jira (`Jira/`): `JiraWrites.swift` (235 lines: `createIssue`, `transition`, `link`, `edit`, `assignable`,
  `comment`, `findComment`, `JiraEdit`, `JiraAssignee`, `commentPropertyKey`, `writeError`, `excerpt`,
  `validKey`), `JiraAgile.swift` (112 lines: `boards`, `sprints`, `columns`, `addToSprint`,
  `moveToBacklog`, `JiraBoard`, `JiraSprint`, `JiraColumn`): no caller outside their tests
  (`grep -rn "JiraWrites\|JiraAgile\|addToSprint\|moveToBacklog\|JiraBoard" app/Sources` finds only the two
  files). In `JiraClient.swift`: `search(jql:in:)` (the project-confined search; no caller), `JiraError.notSent`,
  `.noTransition`, `.refused` (thrown only by the dead code) and `JiraError.outcomeUnknown`, and the
  `HostFailure` conformance. In `JiraTransport.swift`: `send(method:path:json: JSONValue)`, the `write:`
  parameter and branch of `send(method:path:json: Data, write:)`, `writeDecode`, `writeSend`. In
  `HostUserMemo.swift`: `Service.jira` and the `account` key part, whose only reader is `JiraWrites.edit`;
  `JiraSettings.save` calls `HostUserMemo.invalidate(.jira)`.
- `Operators/ChallengeLaunch.swift`: `threadInstructions`, `threadNotes`, `threadNoteLength`,
  `threadPrompt`. Their only consumer is `ReviewThreadDetail`; `threadPrompt` has no caller.
- Tests (under `app/Tests/`): see Tests below.
- Docs: `docs/architecture.md` (the "Integration and platform owners" paragraph says
  `HostFailure.outcomeUnknown` tells whether a failed write may have reached the host);
  `docs/configuration.md` (the GitLab and GitHub rows say an Operator that "opens or merges" requests needs
  `api` or pull-request and contents write access).

How to tell the dead generic names from the live ones:

- `reply` and `resolve`: the dead ones are exactly `GitHubClient.reply(_:thread:body:)`,
  `GitHubClient.resolve(_:thread:)`, `GitLabClient.reply(_:thread:body:)`,
  `GitLabClient.resolve(_:thread:)` and their two requirement lines in `HostRepository.swift`. Do not touch
  `WorkerTranscript.reply`, `TranscriptLocator.reply`, `ChallengeRecord.reply`, the `.reply` cases of
  `QuestionRounds`/`AgentChoiceRounds` outcomes, `DaemonClient.replyToOperator`, `ModelSettings.resolve`,
  `LoginShellLocator.resolve`, `HelpWithProblems.resolve`, `WatchedFileCache.resolve`.
- `threadDetail` versus `threadDetails`: delete `threadDetail(_:thread:)`, `threadDetailQuery`,
  `threadDetailNode`, `threadDetailNodeQuery`. KEEP `threadDetailsQuery` (plural) and the private
  `ThreadDetail` struct: `GitHubClient.threads(of:)` runs on them.
- `state`: `MergeRequestState` and `state(of:)` stay (trimmed, see Change 3). `readiness`, `merge`,
  `existingRequest`, `protection`, `approvals`, `threads`, `currentUser`, `reviewThreads`, `openRequests`,
  `mergeRequests(search:)`, `signalRequest`, `defaultBranch`, `signalReviewers`, `mySignalReviewPostedAt`,
  `issues(search:)`, `signalUsers`, `labels`, `statuses`, `approximateCount`, `projects`, `search(text:)`,
  `myOpenIssues`, `testConnection` are live or left to another step.
- `refused`: `GitHubError.refused` stays (thrown by `GraphQLAnswer.checked`, which `threads(of:)` uses, and by
  `GitHubAccount`). Only `JiraError.refused` goes.
- `send` and `post`: `HostAPI.send`, `GitHubClient.send`/`post`, `GitLabClient.send` stay (`merge`, GraphQL).

## Change

1. Delete these test files and helpers (see Tests for what survives): `app/Tests/AiTermCoreTests/JiraWritesTests.swift`,
   `JiraAgileTests.swift`, `app/Tests/AiTermTestSupport/FakeMergeHost.swift`, the `FakeMergeHostTests`
   suite and the dead tests inside `MergeRequestPublisherTests.swift`, the dead tests in
   `GitHubPublishTests.swift`, `GitLabPublishTests.swift`, `GitHubClientTests.swift`, `HTTPJSONTests.swift`,
   `HostUserMemoTests.swift`.
2. `HostRepository.swift`: `MergeRequestPublishing` keeps `protection`, `existingRequest`, `readiness`,
   `state`, `merge`, `threads`, `approvals`, `currentUser`; delete every other requirement, `repository`,
   `RequestContent`, `PipelineRetry`, the default-argument extension and the `MergeRequestPublisher` enum.
   Rewrite the file's doc comments so none names `finish_task`, `update_request`, `retry_pipeline`,
   `critique_thread`, a spec section, "Review slice" or "operator whose broadcast allows it": the protocol
   is the reads the app makes of one request plus `merge`, bound to one repository when it is made.
   `HostRepository` and its three requirements stay as they are.
3. `CodeHost.swift`: delete `HostFailure`, `HostUser`, `ReviewThreadDetail`. `MergeRequestState` keeps
   `pipeline`, `approvedBy`, `head` and its initialiser takes those three; it is no longer `Codable`.
   `state(of:)` keeps its parameter, a `MergeRequest`, and uses only its `iid`. In `GitHubClient.state` the
   `mergeable` word and `draft` are no longer computed; `GitLabClient.state` likewise. Reword the
   `BranchProtection` doc that says `TaskPublisher` asks before every push to say a worker's push is asked
   against the host's protection before it is allowed (the worker guard). Reword the `ReviewThread` doc
   comment so it does not say "the Review slice reads it (spec §5)".
4. `GitHubClient.swift` and `GitLabClient.swift`: delete the members listed under Today and the MARK
   comments that introduced them ("Publishing", "The Review slice"). Replace each `notSent(.decoding)` with
   `.decoding`. `GitHubError` and `GitLabError` become plain `Equatable, LocalizedError`; delete their
   `notSent` case and its `errorDescription` arm, `GitLabError.noUser` and its arm, and the
   `outcomeUnknown` extensions. Delete `GraphQLProblem.path` and the `@Lenient` it needs; `GraphQLAnswer.checked`
   is unchanged. Keep `listedPages` (used by `listed` and `protection`), `threadPagesRead`,
   `ownerAndName`, `graphQL(_:query:variables:answer:)`, `graphQLPages`, `post`, `send`.
5. `HTTPJSON.swift`: delete `Failure.outcomeUnknown`, `preparingWrite` and `HostAPI.write`.
6. Jira: delete `JiraWrites.swift` and `JiraAgile.swift`; delete `JiraClient.search(jql:in:)`;
   delete `JiraError.notSent`, `.noTransition`, `.refused`, their `errorDescription` arms, the
   `outcomeUnknown` extension and the `HostFailure` conformance. `JiraError` keeps `unauthorized`,
   `network`, `badResponse`, `decoding`, `projectSiteMismatch`, `unconfinedQuery`. In `JiraTransport.swift`
   keep one `send(method:path:json: Data)` that sends and maps failures with `Self.error(for:)` (what the
   `write: false` branch does today) and `decode(_:data:reading:)`; delete the rest. Update the two
   callers (`JiraClient.search(jql:)` and `JiraClient+Signals`: `search(jql:fields:pageToken:)`,
   `approximateCount`) to drop `write: false`. `HostUserMemo`: delete `Service.jira`, the `account`
   parameter of `user(...)` and `Cache.read(...)` and the `account` field of its private `Key`; delete the
   `HostUserMemo.invalidate(.jira)` line in `JiraSettings.save`.
7. `ChallengeLaunch.swift`: delete `threadInstructions`, `threadNotes`, `threadNoteLength` and
   `threadPrompt`. Leave every other prompt in the file for step 1d.
8. `OperatorPorts.swift`: delete the `publisher` field and its two-line doc comment. In
   `app/Tests/AiTermTests/Operators/OperatorFakes.swift` delete the `ports.publisher = ...` line and its
   comment in `OperatorPorts.scratch`.
9. Docs: `docs/architecture.md`: delete the sentence about `HostFailure.outcomeUnknown` and the one after it
   about a failure before sending. `docs/configuration.md`: GitLab "an Operator that merges requests needs
   `api`"; GitHub "An Operator that merges them needs pull-request and contents write access, plus
   administration read access to inspect branch protection."
10. Fix comments in the lines you touch that name removed tools or spec sections; leave the rest of the
    tree's comment sweep to step 1j.

## Keep

- `merge` on both clients, `MergeReadiness`, `readiness`, `state`, `approvals`, `threads`, `reviewThreads`,
  `existingRequest`, `signalRequest`, `protection` and everything under `BranchProtection`,
  `ProtectionUnknown`, `IncompleteRead`. They are what the worker guard, the merge floor and the watcher
  read.
- `MergeRequestSearch` (`source`, `signalSource`, `connection`, `Unavailable`), `MergeRequestSearching`,
  `HostRepository` and `SignalHostReading` (layering is collapsed in step 7a, not here).
- `HostUserMemo` and its tests apart from the `.jira` rows: three live callers (`GitHubClient`,
  `GitLabClient`, the two accounts). `JiraUser` and `signalUsers` (used by the New Signal sheet).
- `JiraClient.confined`, `projectScope`, `scoped`, `JiraError.unconfinedQuery`: `JiraQueryReader` uses
  `confined` for its time-window query. `startAtPages` (used by `projects()`), `inOrder` (used by
  `JiraClient`; its GitLab caller is the one you delete).
- `JiraClient.approximateCount`: no source caller, but the hosts audit keeps it and a test reads it; leave
  it and mention it in your report.
- `OperatorTiming.jiraSearchBudget`: `JiraClientTests.searchHasAResourceDeadline` reads it. Do not touch.
- `ConflictWorld` in `app/Tests/AiTermTestSupport/`: the audit called it host-write test code, but it is a
  39-line git helper used by the Fix tests. It stays.
- `GitHubError.refused`, `GraphQLAnswer.checked`, `GraphQLPageInfo`, `threadDetailsQuery`, `ThreadDetail`.
- The rest of `ChallengeLaunch` (1d owns it).

## Decisions already taken

- Merge safety: `merge` still sends only `sha`, still maps 409/405/422 to `.blocked`; do not edit its body.
- `MergeRequestState.mergeable` and `draft` go even though two test cases assert them; those assertions are
  rewritten (Tests). Step 7c may read the same facts differently later.
- A URL that cannot be built reads as `.decoding` ("Couldn't read GitHub's response"), as it does today
  once the `notSent` wrapper's text is shown. No new case.
- The `MergeRequestPublisherTests` suite name says "publisher", a word with no meaning after this step:
  rename the suite and its file to `HostRepositoryTests`.
- A comment you cannot make true in one line is deleted, not reworded at length.
- Cannot happen here: a second implementer of `MergeRequestPublishing`. The only conformers are the two
  clients once `FakeMergeHost` is gone; no protocol compatibility is needed.

## Tests

Delete whole files: `JiraWritesTests` (364 lines), `JiraAgileTests` (112), `FakeMergeHost.swift` (264).
Behaviour deleted, no survivor.

`GitHubPublishTests`: delete `aThreadDetailBelongsToTheBoundRepositoryIgnoringCase`,
`aThreadDetailKeepsReadingWhenTheRepositoryCannotBeResolved`,
`onlyTheAdditionalRepositoryLookupsErrorCanLeaveTheDetailReadable`, `anOpenPullRequestIsRetitledRedescribedAndReassigned`,
`eachWriteOfAnEditIsCheckedRightBeforeIt`, `anAssigneeAloneTouchesOnlyTheIssue`,
`theFailedLatestRunOfEachWorkflowIsRerun`, `eachEventsLatestRunIsJudgedApart`, `aHeadWithNoFailedRunIsNotRetried`,
`aReviewThreadIsReadWholeAndOnlyFromItsOwnPullRequest`, `aReviewThreadIsResolvedByItsNodeId`,
`aDraftIsOpenedFromTheTasksBranch`, `aPullRequestThatIsNotADraftIsOpenedAsOne`, `aPullRequestIsRetargeted`;
and the helper `workflowRuns`. In `readinessThatCannotBeAskedThrows` remove only the `retarget` line, keep
the rest. `gitHubStateReadsDraftChecksMergeabilityAndApprovals` and `theMergeAndRunStatusReadEveryCheckTheSameWay`
keep their assertions on `pipeline`, `approvedBy` and `head`; drop the `draft`/`mergeable`/`iid`/`url`
expectations. Survivors that detect the same read failures: every other test in this file.

`GitLabPublishTests`: delete `aDraftIsOpenedFromTheTasksBranch`, `aMergeEndsRequestIsNoDraft`,
`anOpenDraftIsRetitledRedescribedAndReassignedAndStaysADraft`, `anEditChangesOnlyWhatItGives`,
`aFailedHeadPipelineIsRetried`, `aPipelineThatDidntFailIsNotRetried`, `aDiscussionIsReadWhole`,
`aDiscussionIsResolved`, `anAssigneeGitLabDoesNotKnowWritesNothing`, `anOperatorsTitleWithADraftPrefixIsNotDoubled`,
`aRequestIsRetargeted`. `noWriteAsksGitLabToMergeSquashOrDeleteAnything` loses its `createRequest` and
`retarget` calls and keeps what it asserts about the merge call. `gitLabStateReadsDraftPipelineMergeabilityAndApprovals`
is adjusted like its GitHub twin. Everything else stays.

`MergeRequestPublisherTests` (rename to `HostRepositoryTests`): the suite builds hosts with
`MergeRequestPublisher.publisher(for:gitLab:gitHub:session:)`; every surviving test builds them with
`MergeRequestSearch.source(for:gitLab:gitHub:session:)` instead (same arguments, same `any HostRepository`
result). Delete the whole `FakeMergeHostTests` suite and the private `Gate` actor at the end of the file,
and these tests: `gitLabCreatesTheRequestWithEachArgumentInItsOwnField`,
`gitHubCreatesThePullRequestWithEachArgumentInItsOwnField`, `gitLabMarkReadyDropsTheDraftPrefix`,
`gitLabMarkReadyLeavesAReadyRequestAlone`, `gitLabAssignsReviewersByTheirIdsBesideTheOnesAsked`,
`gitLabRefusesAReviewerItDoesNotHave`, `gitLabRepliesInTheDiscussion`, `gitHubAssignsReviewers`,
`gitHubMarksReadyThroughGraphQL`, `gitHubLeavesAReadyPullRequestAloneAndSaysWhatGraphQLRefused`,
`aReviewWriteStopsWhenItsLastCheckRefusesAfterTheReads`. Split, keeping the read half:
`aGitLabRemoteIsPublishedOnTheConfiguredGitLab` (drop the `createRequest` call; keep the host selection by
making the stub answer an empty list and calling `existingRequest(from:)`, then assert the request went to
the configured host's project merge-requests URL; rename it to say "is read on"), `gitLabReadsMergesAndRetargetsTheRequestByItsIid`
and its GitHub twin (drop `retarget`, rename to "...ReadsAndMerges..."), `gitLabFindsTheProjectsUsersAndWhoApproved`
(keep `approvals`, rename), `gitHubReadsThreadsAndRepliesByTheirNodeId` (keep `threads`, rename),
`gitHubFindsAssigneesAndTheLatestApprovals` (keep `approvals`, rename). Delete the private helpers only
those tests used (`sentBody`, `body`) and the `repository` assertion. The merge floor and protection tests
(`theProtectionAsked...`, `protectionThatCannotBeEstablished...`, the `...ThreadsPastTheCap...`,
cursor and approvals tests) stay unchanged except for the factory call.

`GitHubClientTests`: delete `findUsersReadsPastTheFirstHundredAssignees` and `findUsersStopsAtItsPageBound`.
`HTTPJSONTests`: delete `transportMappingKeepsTheCurrentUncertainOutcomeEvenForConnectFailures` and
`aPreparationFailureKeepsItsSentenceAndClosesItsOutcome` (the outcome taxonomy is deleted; `mappingTurnsEachFailureIntoTheClientsOwn`
still detects a wrong error mapping). `HostUserMemoTests.identitiesKeepTheirHostServiceTokenAndAccountSeparate`:
remove the two `.jira` rows and the `account` argument everywhere in the file.

No fixture is re-recorded.

## Proof

- Iterate with `scripts/test.sh swift -- --filter <Suite>` for `GitHubPublishTests`, `GitLabPublishTests`,
  `HostRepositoryTests`, `GitHubClientTests`, `GitLabClientTests`, `HTTPJSONTests`, `JiraClientTests`,
  `HostUserMemoTests`, `JiraSettingsTests`, `MergeRequestSearchTests`, `SignalHostIOTests`,
  `SignalSourceTests`, `ChallengeLaunchTests`, `SignalWatchTests`.
- Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rnE "\b(createRequest|retarget|updateRequest|RequestContent|markReady|assignReviewers|findUsers|retryPipeline|PipelineRetry|threadDetail|ReviewThreadDetail|HostUser|HostFailure|outcomeUnknown|notSent|preparingWrite|FakeMergeHost|MergeRequestPublisher)\b" app daemon`
  returns nothing (note: `MergeRequestPublishing` and `MergeRequestPublisherTests` are not in the pattern;
  the first stays until 7a, the second is renamed).
- `grep -rn "JiraWrites\|JiraAgile\|JiraBoard\|JiraSprint\|JiraColumn\|JiraEdit\|JiraAssignee" app` and
  `grep -rn "finish_task\|update_request\|retry_pipeline\|critique_thread" app/Sources/AiTermCore/CodeHosts app/Sources/AiTermCore/GitHub app/Sources/AiTermCore/GitLab app/Sources/AiTermCore/Jira app/Sources/AiTermCore/CodeHost.swift`
  return nothing.
- `grep -rn "func reply(_\|func resolve(_" app/Sources/AiTermCore` returns nothing.
- All suites above and plain `scripts/test.sh` are green. `docs/architecture.md` and
  `docs/configuration.md` no longer mention `HostFailure`, or an Operator that opens requests.

## Not in this step

- One `HostRepository` interface and one factory (7a), strict review-thread reads (7b), one request read
  and a pure readiness rule (7c), Jira paging fallbacks and the old GitLab URL form (1h).
- The other dead Oracle prompts and the rest of `ChallengeLaunch` (1d); `finish_task` names in shell gate
  refusals (1j).
- `OperatorPorts` fields other than `publisher` (1d for `finishReplyBudget`, 1e for the rest).
