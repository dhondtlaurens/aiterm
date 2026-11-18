# 3. Describe it, Write the query

Implementer: Claude Opus 5.5. Depends on: steps 1 and 2 (a signal's Start and Done are `SignalTrigger`s with
`source`, `description` and `query`; the sheet's trigger steps show Reads and a hand-typed query; GitLab and
GitHub queries parse through `GitLabQuery`/`GitHubQuery`; the trigger editors' Metrics height exists).

## Why

People should not need to know JQL or GitLab's search syntax. Each trigger step gets a **Describe it** field:
the person writes what they want in their own words and presses **Write JQL** (or **Write GitLab query**,
**Write GitHub query**). AiTerm runs the Operator's Claude once, headless and read-only, with the context it
needs, and puts the answer in the query field, which stays editable and is still what runs. AiTerm validates
the answer and, when it fails, sends it back once with the error. The description is saved with the trigger.

## Today

- The sheet after step 2: `Views/Operators/SignalSheet.swift`, the trigger step file step 2 created (Reads,
  the query editor, `SignalMatchPreview` on Starts when), `SignalDoneStep.swift`, `Operators/SignalModel.swift`
  (two triggers), `AppController+Signals.swift` `presentNewSignal` (builds the model with `preview`, `save`,
  readiness and completions).
- One-shot agent runs: `Operators/OracleRunner.swift` (`ask(_:prompt:folder:projects:)`, `perform` locates
  the CLI, runs it with a timeout through `AgentProcess.run`, maps missing/failed/timed out to a sentence) and
  `AiTermCore/Operators/OracleLaunch.swift` (`invocation(…)` → `harness.readOnlyHeadless(prompt:folder:
  readable:answerFile:model:reasoning:)`; `fenced(_:)` puts untrusted text in a fence it cannot close;
  `critique(…)` reads the answer through `harness.headlessAnswer`). Claude's read-only headless arguments are
  in `AiTermCore/Harnesses/Harness+Agents.swift` (read tools only, writes and web denied, `--strict-mcp-config`).
- The Operator's model: `OperatorProfile` (`AiTermCore/Operators/OperatorProfile.swift`), always Claude,
  loaded through `OperatorProfileStore` (see `OperatorPorts.profile` and `OperatorChat.swift` L120 for how the
  saved profile is read).
- Context sources: `JiraClient+Signals.swift` `labels()`, `statuses()`; each `Project`'s `jiraProjects` and
  `remoteUrl`; the host usernames through `HostUserMemo` (GitLab, GitHub) and Jira's current user.
- Validation: Jira through a search (`JiraClient.search(jql:…)` returns an error for bad JQL); GitLab through
  `GitLabQuery`'s start or done entry point; GitHub through a one-page `requests(matching:)` read.

## Change

1. **`QueryWriter`** (`AiTermCore/Operators/Signals/Queries/QueryWriter.swift`), pure:
   - `prompt(source:trigger:description:context:)` for `trigger` start or done. It says what to produce: one
     query in the source's syntax, nothing else, no code fence, no explanation. It carries the syntax
     reference (for GitLab exactly the README's grammar and the role rule; for GitHub the search qualifiers it
     needs: `is:pr`, `is:open`, `is:merged`, `author:`, `assignee:`, `review-requested:`,
     `user-review-requested:`, `reviewed-by:`, `review:approved|changes_requested|required|none`, `draft:`,
     `label:`, `base:`, `head:`, `repo:`, and the two `threads:` tokens; for Jira a short JQL reminder with
     `currentUser()`, `openSprints()`, `statusCategory`), the worked examples (the conventions table below),
     and the context: the account's user per source, the Jira projects linked to AiTerm projects (key and
     name), their statuses and labels (cut to a sensible count), and the AiTerm projects' remote paths. A Done
     prompt says the query is checked against one task's own ticket or merge request, so it describes the end
     state, and that `review-state:` with `reviewer:@me` is the person's own review. The person's description
     goes in `OracleLaunch.fenced` as data, never instructions.
   - `retryPrompt(…)`: the same plus the rejected query and the validation error.
   - `query(from answer:)`: the answer trimmed; a single code fence is unwrapped; more than one line of text,
     or prose around the query, is refused (nil).
   - Worked examples (generic; the account is `alex`):

     | Description | Source | Query |
     |---|---|---|
     | Merge requests where I'm a reviewer and haven't reviewed yet, no drafts | GitLab start | `reviewer:@me review-state:unreviewed draft:no` |
     | When I've approved it | GitLab done | `reviewer:@me review-state:approved` |
     | My merge requests a reviewer sent back or commented on | GitLab start | `assignee:@me review-state:requested_changes,reviewed` |
     | When no reviewer is waiting on me any more | GitLab done | `-review-state:requested_changes,reviewed` |
     | My merge requests with a thread waiting on my reply | GitLab start | `assignee:@me threads:waiting-on-me` |
     | My merge requests approved by others, ready, no open threads | GitLab start | `assignee:@me review-state:approved draft:no threads:resolved` |
     | When it's merged | GitLab done | `state:merged` |
     | Assigned to me, reviewed by someone else | GitLab start | `assignee:@me reviewer:any -reviewer:@me` |
     | Someone else's, with me as reviewer | GitLab start | `reviewer:@me -assignee:@me` |
     | My tickets in my open sprints, not started | Jira start | `assignee = currentUser() AND sprint in openSprints() AND statusCategory = "To Do"` |
     | When a reviewer is asked on its merge request | GitLab done | `reviewer:any` |
     | Tickets handed to me in review | Jira start | `assignee = currentUser() AND status = "In Review"` |
     | When it's handed to someone else | Jira done | `assignee != currentUser()` |
     | Pull requests where my review is requested, no drafts | GitHub start | `is:pr is:open user-review-requested:@me draft:false` |
     | When I've reviewed it | GitHub done | `-user-review-requested:@me` |

2. **`QueryWriterRunner`** (`AiTerm/Operators/QueryWriterRunner.swift`): runs the writer as a read-only
   headless Claude with the Operator's model and reasoning, in a scratch folder, reading no project folders,
   with a timeout of about a minute. Share `OracleRunner`'s locate/run/timeout path rather than copying it (a
   small extraction is fine). Then validates the answer for the source and trigger; on failure runs the retry
   prompt once and validates again. Returns the query, or a sentence: the CLI missing, failed, timed out, gave
   no query, or the second answer still failed with its error (the second query is still put in the field, so
   the person can fix it).
3. **`SignalModel`**: per trigger a `description`, a writing flag, and an error sentence; `write(trigger)`
   runs the injected writer (a closure, like `preview`), fills the query, keeps the person's description;
   editing the description or query clears the error. Writing never runs on its own: only the button.
   `canAdvance` unchanged (a query is still what counts).
4. **The trigger step** (option A of the proposal): Reads; **Describe it** (a 56 pt editor using the Metrics
   value step 2 added) with **Write JQL** / **Write GitLab query** / **Write GitHub query** as a small
   secondary button at the trailing end of its label row; while writing, the button shows its own progress
   (spinner and "Writing…") and the fields stay editable; the query editor under it, with help "Written by
   Claude from your description and checked by <Jira|AiTerm|GitHub>. Edit it as you like." once written,
   otherwise naming the syntax; the error under the query in warning tone. Starts when keeps the preview.
   The button is disabled while the description is empty.
5. **`AppController+Signals`**: inject the writer, built from `QueryWriterRunner` with the current Operator
   profile and a context read when the sheet opens (Jira labels and statuses, the linked Jira projects, the
   remotes, the usernames); a context read that fails leaves that part out, never blocks writing.

## Keep

- The query field is the truth; nothing rewrites it except the button.
- `OracleRunner`'s behaviour and its tests.

## Decisions already taken

- The writer is Claude with the Operator's model and reasoning, read-only, no tools beyond reading, no MCP.
- One retry, never more. No writing on typing, on step change or on open.
- The description is saved with its trigger and shown when editing a signal.

## Tests

- `QueryWriterTests`: each prompt carries the syntax, the examples and the context, fences the description
  (a description containing a fence cannot close it), and says start or done; `query(from:)` accepts a bare
  query and a single fenced one, refuses prose; the retry prompt carries the rejected query and the error.
- `QueryWriterRunner` with a fake run: a valid first answer; an invalid first and valid second; both invalid
  (second query returned with the error); missing CLI; timeout.
- `SignalModelTests`: write fills the query and keeps the description; the error clears on edit; the button's
  enabled state.
- Snapshots: the Starts when step with a description and a written query, the writing state, and a Done step
  with a description, for Jira and GitLab, compared with the proposal on the design page.

## Proof

Filtered suites while iterating; plain `scripts/test.sh` green; `scripts/snapshots.sh build/snapshots-step3`
and read the sheet PNGs against the proposal (option A) and the AiTermUI README.

## Done when

Describing a trigger and pressing the button fills a validated query in tests and snapshots; every test
passes.

## Not in this step

`docs/operators.md`, the design page sync, the live run against real Jira and GitLab (step 4).
