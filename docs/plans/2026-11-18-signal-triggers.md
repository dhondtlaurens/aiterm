# Signals: a Start and a Done trigger, each a query you describe

Status: agreed 18 Nov 2026; step briefs in `2026-11-18-signal-triggers/` on `feat/jql`, branched from local `main` at a21c1673. Challenged by Codex in three
rounds on 18 Nov 2026; every finding is fixed below (done as an edge with a baseline read before launch, no
compatibility with old signals and no handling of them, every caller of the deleted types in its
step, the composition point `AppController+Signals`, the stage's triggers in the Operator's status). Visual design: the proposal
"Signals: a Start and a Done trigger" on the Proposals tab of `docs/design/design-system.html`, option A
(describe above, query below, both visible) picked.

## Goal

The Jira signal builder (condition chips for label, sprint, assignee, status and project, the person search, the
JQL switch) is a lot of code for what ends up as JQL. GitLab and GitHub signals are two fixed events with two
checkboxes, which cannot express the review turns of the team's review conventions (Review requested, Returned
to you, Approved by others, Waiting on my reply, assigned to me and reviewed by another, and the reverse).
Replace both with one mechanism: a signal has a **Start** and a **Done** trigger; each reads Jira, GitLab or
GitHub; you describe what you want, the Operator's agent writes the query once, and you can edit it or write it
yourself. It must work with the psg skills (`/psg:plan`, `/psg:implement`, `/psg:review`, `/psg:peer-review`).

## Approach

A signal becomes: name · Start trigger · prompt (with the description checkboxes) · agents · Done trigger ·
Merge when ready (where offered) · Then. A **trigger** is a source (Jira, GitLab, GitHub), the description you
wrote and the query; the query is what runs. **Write JQL** (or **Write GitLab query**, **Write GitHub query**)
runs the Operator's Claude once, headless and read-only, as `OracleRunner` runs the Oracle, and fills the
query field; the description is kept with the signal. AiTerm validates the query (Jira through its strict JQL parse, `POST /rest/api/3/jql/parse`, GitLab
through AiTerm's own parser, GitHub through its search) and sends a failing query back to the agent once with
the error. The match preview stays.

### What the grill decided

1. **The one-shot writes the query**, with the Operator's model and reasoning (always Claude), read-only, no
   tools beyond reading. Its context: the account's user, the Jira projects linked to AiTerm projects with their
   statuses and labels, the AiTerm projects' remotes, the source's syntax reference, and the review-conventions
   table below as worked examples. No live Operator chat is needed or woken.
2. **GitLab gets a query language after all.** The instance in use is GitLab CE 19.5.3; its GraphQL
   `currentUser.reviewRequestedMergeRequests`, `assignedMergeRequests` and `authoredMergeRequests` and
   `Project.mergeRequests` accept review state (`UNREVIEWED`, `REVIEWED`, `REQUESTED_CHANGES`, `APPROVED`,
   `UNAPPROVED`, `REVIEW_STARTED`), author, assignee and reviewer (with `ANY`/`NONE` wildcards and `not`), draft,
   labels, target and source branches, approved-by, milestone, project and state. Each was probed read-only on
   18 Nov 2026 and filters on CE (approved-by 40 of 52, not-reviewer 178 of 187). The query is GitLab's
   search-bar syntax: `author:`, `assignee:`, `reviewer:` (`@me`, a username, `none`, `any`), `review-state:`,
   `approved-by:`, `draft:`, `label:`, `target-branch:`, `source-branch:`, `milestone:`, `project:`, `state:`;
   a leading `-` negates, commas mean or. **A Start query names you in exactly one role** (`author:@me`,
   `assignee:@me` or `reviewer:@me`): that role picks the list AiTerm reads, and with it what `review-state:`
   means (yours as reviewer; the reviewers' as author or assignee), as on GitLab's own merge request homepage.
   Without a role it is refused, since it would read every merge request on the server. AiTerm adds two tokens
   GitLab cannot filter: `threads:waiting-on-me` (an unresolved thread whose last note is not yours, today's
   "waiting on my reply") and `threads:resolved`.
3. **GitHub uses its own search syntax** (`is:pr` added when missing), with the same two AiTerm thread tokens.
4. **No starters.** The sheet offers no presets; the conventions are the writer's examples and the proof.
5. **Two triggers, each its own source** (the person's words: a start and an end trigger, each Jira, GitHub or
   GitLab). The Start trigger's source decides what a task is about (a ticket or a merge request). The Done
   trigger is checked against **that task's own item**: Jira checks its ticket (`key = X AND (query)`), GitLab or
   GitHub its merge request (the same query confined to that one request). A Jira-started task without a merge
   request is not done by a GitLab or GitHub done query; a merge-request task maps to its ticket by the key in
   its branch or title, as `TicketMergeRequests` does today. A merged or closed merge request is always done.
   **Done is a trigger too: it fires on an edge.** A stage is done when, during that stage, a read where the
   item does not match the done query is followed by one where it does, exactly as Start fires when an item
   starts to match. **The baseline is read before the worker launches**: when a stage starts, AiTerm reads the
   done query for the task's item and stores the result on the stage (matches, does not match); the worker is
   launched only after that read is complete (an unreadable source holds the launch with the same backoff as an
   unreadable Start source; a Jira-started task with no merge request yet reads as "does not match"). Every
   later complete read compares against the last stored one and replaces it. Reads still skip a busy worker:
   a review posted during the first turn shows as a change at the first read after it, which ends the stage. A done query that already matches at the baseline waits for a fresh match (or
   a merge or close), so evidence from an earlier round never ends a new one. (Decided in triage of the plan review:
   the person's own framing of Done as "a second trigger", and today's `myReviewPosted` stage boundary.)
   In a done query `review-state:` follows the role it names (`reviewer:@me review-state:approved` is your own
   review), and any reviewer's state when it names none.
6. **No chaining inside a signal**: one query per trigger, no AND across sources, no stages. A later signal on
   the same item continues its task, as it already does; that is not presented as a feature.
7. **Rounds come from re-matching.** An item that stops matching and matches again continues the same task as
   a new stage (`MatchDecision` already does this through `SignalSeen.isMatching`). A review asked again sets
   the reviewer back to unreviewed, so `reviewer:@me review-state:unreviewed` starts each re-review in the same
   task and conversation; the Done query (`reviewer:@me review-state:approved`) ends it. Not `approved-by:@me`:
   an approval survives a review asked again, while the review state is reset to unreviewed.
8. **The Done step**: Done when (a trigger), **Merge it when it's ready** (kept, offered when the Start query's
   role is author or assignee or the start is Jira, never applied to a review task; workers never merge, so
   this is the only way a signal merges: once the host says it can be merged, after the Oracle's veto, no
   longer waiting on a done condition), Then (keep, archive, remove; delete the merged branch with remove). **Gone**: the fixed
   done list (has a reviewer, approved, threads resolved, merged, ticket status, my review posted, merged or
   closed: each is now a query) and **the Operator judges it done**. `finish_stage` still records a stage's
   outcome, but no longer ends a stage by itself.
9. **Review task or own task is decided per merge request**, no longer per signal: a review task (checks out
   the colleague's branch, never pushes) unless the account authored the merge request or is one of its
   assignees.
10. **No compatibility with old signals, and no handling of them** (the person's call, 18 Nov 2026: nobody has
    signals saved yet). Nothing reads, converts or drops the old shape; `Models.swift`, `OperatorRecordsReset` and
    `scripts/reset-operator-state.sh` are unchanged. A stage's embedded configuration changes shape, so an old
    `signalTask` is cleared by the existing reset, as for any record shape change. `JiraConditions`,
    `RequestConditions`, `SignalSource`, `JQL.compile`, `DoneWhen` and `SignalFinish.choices` are deleted.

### The conventions as queries (the writer's examples and the proof)

| Situation | Reads | Start query | Prompt | Done query |
|---|---|---|---|---|
| Review requested (and asked again) | GitLab | `reviewer:@me review-state:unreviewed draft:no` | `/psg:peer-review` | `reviewer:@me review-state:approved` |
| Returned to you | GitLab | `assignee:@me review-state:requested_changes,reviewed` | `/psg:review` | `-review-state:requested_changes,reviewed` |
| Waiting on my reply | GitLab | `assignee:@me threads:waiting-on-me` | `/psg:review` | `-threads:waiting-on-me` |
| Approved by others | GitLab | `assignee:@me review-state:approved draft:no threads:resolved` | check it is ready; Merge when ready on | `state:merged` |
| Assigned to me, reviewed by another | GitLab | `assignee:@me reviewer:any -reviewer:@me` | | |
| Assigned to another, reviewed by me | GitLab | `reviewer:@me -assignee:@me` | | |
| Sprint tickets | Jira | `assignee = currentUser() AND sprint in openSprints() AND statusCategory = "To Do"` | `/psg:plan, then /psg:implement and /psg:review` | GitLab `reviewer:any` |
| Handed to me in review (convention option A) | Jira | `assignee = currentUser() AND status = "In Review"` | | Jira `assignee != currentUser()` |
| Review requested on GitHub | GitHub | `is:pr is:open user-review-requested:@me draft:false` | `/psg:peer-review` | `-user-review-requested:@me` |

Examples in code, fixtures and docs stay generic (no company names, internal hosts or real tickets).

## Files

**AiTermCore**
- Create `Operators/Signals/SignalTrigger.swift`: the trigger (source kind, description, query), Codable through
  a `kind` key with an unknown fallback, as every saved enum here.
- Modify `Operators/Signals/Signal.swift`: `start` and `done` triggers; `SignalFinish` keeps then, merges when
  ready and branch deletion; `DoneWhen` and `choices(for:)` go; `isRunnable` needs a valid start and done.
- Delete `Operators/Signals/SignalSource.swift` (`SignalSource`, `JiraConditions`, `RequestConditions`, `JQL`).
- Create `Operators/Signals/Queries/GitLabQuery.swift`: parse the search syntax into a role and GraphQL filters,
  with errors that name the token; the AiTerm thread tokens kept apart.
- Create `Operators/Signals/Queries/GitHubQuery.swift`: normalise (`is:pr`), split off the thread tokens.
- Create `Operators/Signals/Queries/QueryWriter.swift`: the writer's prompt per source (syntax reference, the
  conventions as examples, the context, the description fenced as data) and reading its answer (one query, no
  prose); the retry prompt with the validation error.
- Replace `Operators/Signals/Sources/ReviewRequestedReader.swift` and `MyRequestReader.swift` with
  `GitLabQueryReader.swift` and `GitHubQueryReader.swift` (the thread logic and its cache move over);
  modify `JiraQueryReader.swift` to take a JQL string.
- Modify `GitLab/GitLabAccount.swift`: GraphQL listing per role with the parsed filters, paginated; the done
  read confined to one merge request (`iids` with `projectPath`).
- Modify `GitHub/GitHubAccount.swift`: search by query; the done read confined to `repo:` and the number.
- Modify `Operators/Signals/DoneCheck.swift`: the done trigger matches, merged, closed or unknown; the fixed
  facts that only served the old list go, the waiting facts for the row's line stay.
- Modify `Operators/Signals/SignalTask.swift`, `StageMachine.swift`: `operatorJudged` goes (decoded and dropped).
- Modify `Operators/Signals/OperatorDigest.swift`: each task line carries its stage's own Start and Done triggers
  (source and query) from the stage's saved configuration, and each signal its current ones, so `run_status` and
  `read_task` give a renewed Operator the rule a working stage actually runs under, also after its signal is
  edited or removed.
- Modify `Sidebar/OperatorLine+Waiting.swift`: a waiting task's line is its Done trigger's description, or its
  query when it has none; merge blockers keep their line.
- Modify `Jira/JiraClient+Signals.swift`: the person picker goes; statuses and labels stay for the writer.

**AiTerm (app)**
- Modify `Operators/SignalConnections.swift`: readers and read keys from triggers.
- Modify `Operators/SignalHostIO.swift`, `RequestWatch.swift`: done through the done trigger; merge when ready
  unchanged in behaviour.
- Modify `Operators/ItemRouter.swift`: review or own per merge request (decision 9).
- Modify `Operators/StageRunner.swift`, `SignalOperatorToolHandler+Calls.swift`: `finish_stage` without
  judging done.
- Create `Operators/QueryWriterRunner.swift`: runs the writer headless (sharing `OracleRunner`'s process path),
  validates, retries once.
- Modify `AppController+Signals.swift`: builds `SignalModel` with the writer and the trigger preview instead of the
  metadata and person-search closures (`signalUsers` goes); the one production connection of the writer.
- Modify `Operators/SignalModel.swift`: triggers, description and query per trigger, writing state, validation
  error; the metadata, assignee search, event and condition state go.
- Modify `Views/Operators/SignalSheet.swift`; create `Views/Operators/SignalTriggerStep.swift` (Reads ·
  Describe it with its Write button on the label row · the query · the preview on Start); modify
  `SignalDoneStep.swift` to hold the done trigger, Merge when ready and Then; delete `SignalStartsStep.swift`
  and `SignalConditionPicker.swift`.
- Modify `HeadingValue.swift`: the heading's tooltip shows both queries.
- Modify `Snapshots/SignalSnapshots.swift` (and `ReadmeDesktop.swift` if it seeds a signal).

**AiTermUI**
- Modify `Metrics.swift`: the trigger editors' height (56 pt), a named value, not a literal.
- Modify `README.md`: the inventory and the rule for the trigger editors.

**Operator tools**
- Modify `daemon/aitermd/signal_tools.json` and its copy `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/tools.json`
  (the current schema contract, per `daemon/README.md`): the `finish_stage` description (no judged done).
  A deliberate contract change, written by hand, not regenerated to fit.

**Docs**
- `docs/operators.md` (Create a signal, done conditions), `docs/design/ui-patterns.md`, `docs/keyboard.md` if it
  names the JQL field, and `docs/design/design-system.html` (proposal removed, Components synced).

## Proof

- **Unit tests**
  - `GitLabQueryTests`: every GitLab row of the conventions table parses into the expected role and filters;
    negation, commas, quoting, unknown tokens and a missing or second `@me` role are refused with the token named.
  - `GitHubQueryTests`: normalisation and thread tokens.
  - `QueryWriterTests`: the prompt carries the context and fences the description; the answer reader takes one
    query and refuses prose; the retry prompt carries the error.
  - Readers against recorded GraphQL and search fixtures: role list, pagination, thread tokens with the cache,
    incomplete reads start nothing.
  - Done: a done trigger on the ticket and on the merge request, merged or closed always done, a Jira-started
    task without a merge request not done; the edge (a done query matching when the stage starts does not end
    it; a later fresh match does), and round 2 of a review not ended by round 1's approval.
  - Saved format: `SignalSavedFormatTests`, `SavedEnumBytesTests` and `SignalForwardCompatibilityTests` cover the
    new shape; `state-0.58.json` loses its old-shape signals.
  - `OperatorDigest`: a task line shows its stage's Done trigger after the signal's Done query is edited, and
    after the signal is removed.
  - Done timing: the baseline is stored before launch; a done query that starts matching during the worker's
    first turn ends the stage; an unreadable baseline holds the launch.
  - `ItemRouter`: author or assignee gives an own task, otherwise a review task.
  - `SignalModelTests`: writing, the one retry, validation errors, can-advance per step.
  - Existing journey, controller, poller and sidebar suites stay green with triggers.
- **Snapshots**: every step of a Jira and a GitLab signal, the writing state and the refused-role notice,
  compared with the proposal.
- **Gate**: `scripts/test.sh` before each commit; `scripts/test.sh all` once before merging.
- **Live, read-only**: in a dev build connected to the real Jira and GitLab, describe each row of the
  conventions table, record the query the writer produced and the preview's count, and fix the writer's prompt
  where a query is wrong. `scripts/run-dev.sh` only when the person says the running session may be
  interrupted.

## To-dos

- [x] **Queries and readers.** `GitLabQuery`, `GitHubQuery`, the GraphQL listing and done read in
  `GitLabAccount`, search in `GitHubAccount`, `GitLabQueryReader` and `GitHubQueryReader` (one generic
  `RequestQueryReader` behind both), and `JiraQueryReader` on a JQL string, with their tests. Built unwired; the
  next step wired them in and removed the conditions initializer.
- [x] **Triggers end to end, typed by hand.** `SignalTrigger`, `Signal` with start and done, the old types
  deleted, `SignalConnections` on the new readers, done as an edge on the
  done trigger, review or own per merge request, `operatorJudged` and the judged done removed with the tool
  description and its fixture, the done baseline read before launch (`StageRunner`, `RequestWatch`) . Every caller of the deleted types changes in this step, as found by `git grep` on
  18 Nov 2026: `HeadingValue`, `RequestWatch`, `SignalClaim`, `SignalConnections`, `SignalHostIO`,
  `SignalModel`, `SignalOperatorController`, `SignalOperatorToolHandler+Calls`, `StageRunner`,
  `Views/SidebarHeadings`, `Views/Operators/SignalDoneStep`, `SignalStartsStep`, the snapshots
  (`ReadmeDesktop`, `SignalSidebarSnapshots`, `SignalSnapshots`), `GitHubAccount`, `GitLabAccount`,
  `DoneCheck`, `Signal`, `SignalSource`, `SignalTask`, `JiraQueryReader`, `MyRequestReader`,
  `SignalAccountReading`, `StageMachine`, `Sidebar/OperatorLine+Waiting`, and `OperatorDigest` (the stage's
  triggers in `run_status`). The sheet in the same step, without the writer: `SignalModel` on triggers,
  `SignalTriggerStep` with Reads and the query field (and the preview on Start), the Done step with Merge when
  ready and Then, the heading tooltip; `SignalStartsStep`, `SignalConditionPicker`, the person picker and their
  wiring in `AppController+Signals.swift` deleted. A signal can be made and runs with a query you type.
  Saved-format, journey and model tests green; snapshots.
- [x] **Describe it, Write the query.** `QueryWriter` and `QueryWriterRunner` with validation and the one retry,
  wired in `AppController+Signals.swift`; Describe it with its Write button on the label row (option A), the
  description saved with the trigger, the writing state; snapshots. (The trigger editors' Metrics height lands
  in the previous step, with the hand-typed query field.)
- [x] **Docs and proof.** `operators.md`, the AiTermUI README, `ui-patterns.md`, the design page synced with the
  proposal removed, and the live run of the conventions table recorded here.

## Live proof (18 Nov 2026, read-only)

- **GitLab** (the maintainer's CE 19.5.3): the GraphQL that `GitLabQuery` renders for each GitLab Start query of
  the conventions table ran against the account's lists and returned exactly what GitLab's own filters return
  (review requested and unreviewed, no drafts: 0 and 0; approved, no drafts: 2 and 2; authored: 4 and 4), with
  no GraphQL errors. The thread tokens are applied by AiTerm after the listing.
- **The writer**: the exact read-only Claude invocation `QueryWriter` builds (Opus 5.5, medium effort; the saved
  Operator profile was not readable from the session) ran once per description, eleven in all, most worded
  unlike the prompt's examples. Every answer was the expected query on one line; "assigned to someone else where
  I'm the reviewer" came back as `reviewer:@me assignee:any -assignee:@me`, stricter than the example.
- **Jira** (the maintainer's Jira Cloud): both written JQL Start queries are accepted (2 and 3 matching tickets).
- Not run: the dev build end to end (`scripts/run-dev.sh` replaces the running app; the maintainer's call).

