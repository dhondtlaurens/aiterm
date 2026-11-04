# MRs that finish_task opens are right, and the Operator can fix them

Plan B of the snags from broadcast "Aikido findings 2026-11". Branch `feat/broadcast-fix`.

## Goal

The snag log from broadcast "Aikido findings 2026-11" (ABAA3E4F, AiTerm 0.39.0, 2026-11-03/04) has
19 snags in 7 areas. We agreed on one plan per area, in this order: **B C A D E G F**. G comes before
F because G's tools reuse the host-edit path built here, and F needs a design proposal before any
Swift is written. This branch carries B. Each later area gets its own branch and plan.

B covers 4 snags. finish_task opened !62–!65 as drafts:
- the description was the whole worker brief (Operator instructions, local paths);
- the title was "<KEY> <title>", without the colon the project's workflow asks for;
- no assignee was set.

Nobody could fix them. The shell gate refuses `glab mr update` and points to finish_task, which
takes no title, description or assignee. The person fixed every MR by hand from a scratchpad file.
On !62 that file was never written, because the Oracle refused the shell command that wrote it.

Rule: AiTerm opens a request that is right, and when it isn't, the Operator can correct it through
AiTerm, with no shell workaround.

## Approach

- **The Operator writes the content, and AiTerm has a safe default.** finish_task takes optional
  `title`, `description` and `assignee`. The Operator follows the repo's `docs/workflow/project.md`
  and MR template, which it can read and AiTerm can't parse reliably. The text travels as tool
  arguments, so no scratchpad file is needed and the Oracle has nothing to block.
- **Default title:** `KEY: title`, with the colon (`TaskPublisher.title`). It stays plain `title`
  when there is no Jira key or the title already starts with the key. GitLab issues keep the current
  rule.
- **Default description:** never the brief. It holds the `Closes #n` link for a GitLab issue, the
  checks the agent ran (as now), and one line "Opened by AiTerm." The acceptance note is dropped,
  because it is the Operator's internal note.
- **Assignee:** by default, the user the host token acts as (`currentUser()`), which is the person.
  An `assignee` passed by the Operator replaces that default.
- **New tool `update_request`** (task, title?, description?, assignee?). It edits the task's recorded
  request (`publication.mergeRequestNumber`) while that request is open.
  - It is not challenged by the Oracle and needs no slice: finish_task opens requests without the
    Review slice.
  - It is refused after a takeover, a Pause or an End (the write check is read fresh, like
    reply_thread's, without the Review-slice condition), when the task has no request yet, when the
    request is merged or closed, and when origin now resolves to another repository
    (`PublicationGuard.otherRepository`).
  - On GitLab, a draft keeps its `Draft: ` prefix when the title changes: a title without it would
    mark the request ready. An Operator title that starts with `Draft:` has that prefix stripped.
  - Repeating an edit gives the same result, so no key and no pending marker are needed.
- **The shell gate keeps refusing** `glab mr update`, `gh pr edit` and API writes. Its refusal now
  names update_request for edits and finish_task for merges.
- **The Operator's content is recorded before AiTerm acts.** finish_task saves its title, description and
  assignee on the task's publication (new optional fields, saved before the first host call). Every later
  advance reads them from there: a retry after a lost answer, the merge watch, a restart. A retry that finds
  the request already recorded or open doesn't rewrite its title or description. Later changes go through
  update_request. A new finish_task call that passes content replaces what was saved only while no request
  is recorded.
- **Assigning is its own step, retried until it is recorded.** After the request is recorded, AiTerm assigns
  the saved assignee (or `currentUser()`) and records `assigned` on the publication. GitHub needs a second
  call after the create, and GitLab needs a username-to-id lookup first. A failure doesn't fail the
  publish: the answer's note says the request opened but `<name>` couldn't be assigned, and why. The next
  finish_task, or the watch, tries the step again, and update_request can set another assignee. Adding an
  assignee who is already set changes nothing on either host, so repeating the step is safe.
- **Frozen contract:** the served tool schemas change on purpose (finish_task gains 3 optional
  properties, plus one new tool, so 33 schemas). `daemon/tests/fixtures/operator-current-tools.json`
  is updated by hand for these entries only, with this plan and the snag log as the decision and
  evidence (docs/testing.md). Briefs, `contract.json` and `state.json` stay untouched; the tool
  descriptions carry the guidance.

## Files

| File | Change | Why |
|---|---|---|
| `app/Sources/AiTermCore/Operators/TaskPublisher.swift` | modify | `title` with the colon; `description` without brief or note; Operator content passed through `Context`; assignee on open |
| `app/Sources/AiTermCore/Tasks/MergeRequestPublisher.swift` | modify | `createRequest(..., assignee:)` and `updateRequest(number, title:, description:, assignee:, beforeWrite:)` on the protocol, GitLab and GitHub |
| `app/Sources/AiTermCore/GitLab/GitLabClient.swift` | modify | `assignee_ids` on create (look up the username's id), `PUT` to edit with the draft prefix kept |
| `app/Sources/AiTermCore/GitHub/GitHubClient.swift` (or wherever `createPullRequest` lives) | modify | assignees after create, `PATCH` pull for title/body |
| `app/Sources/AiTerm/Operators/TaskFinisher.swift` | modify | `finish(_:noVerify:content:)` saves the content on the publication before advancing; the assigned/not-assigned note in the answer |
| `app/Sources/AiTerm/Operators/OperatorController.swift` | modify | the `tools.finish` bridge (around :297) passes the content to `finisher.finish` |
| `app/Sources/AiTermCore/Operators/OperatorModels.swift` | modify | `TaskPublication`: optional requested title, description, assignee and `assigned`; absent fields decode as now, so `state.json` still loads unchanged |
| `app/Sources/AiTerm/Operators/OperatorToolHandler+Review.swift` (or a new `+Request.swift`) | modify/create | `updateRequest` handler, reusing `reviewHost(of:request:)`, a write check without the slice, `mayHaveLanded` |
| `app/Sources/AiTerm/Operators/OperatorToolHandler.swift` | modify | the `finish` closure (:167) takes the content; the `.finishTask` dispatch (:187, :358) reads the 3 optional arguments; dispatch `.updateRequest` |
| `app/Sources/AiTermCore/Operators/OperatorTool.swift` | modify | `case updateRequest = "update_request"` |
| `app/Sources/AiTermCore/Operators/ShellGate+Denials.swift` | modify | `hostDenial` and `apiDenial` name update_request |
| `daemon/aitermd/operator_mcp.py` | modify | finish_task's 3 properties with descriptions; the `update_request` tool |
| `daemon/tests/fixtures/operator-current-tools.json` | modify (deliberate) | the schema change above, and nothing else |
| `app/Tests/AiTermTestSupport/FakeMergeHost.swift` | modify | record the assignee on create and the edits |
| `docs/operators.md` | modify | Tools table: `update_request` under Finish; one line on MR content |

## Proof

Tests first, each reproducing the snag with !62–!65 as the fixture: a Jira-keyed task whose brief
holds Operator instructions and a `/Users/...` path.

1. `TaskFinisherTests` / `OperatorMergeTests` (fake host): finish_task with a draft-MR end opens the
   request titled `KEY: title`. Its description contains neither the brief nor the path, and it is
   assigned to the fake host's current user. This fails today.
2. Same suite: finish_task with an Operator title, description and assignee opens with exactly those.
   A retry that finds the request recorded doesn't rewrite its title or description. This goes through the
   real `OperatorToolHandler` dispatch, so the closure and the controller bridge are covered.
2b. Same suite: the fake host creates the request, then fails the assignment. The answer is published,
   with a note naming the assignee who couldn't be set. A second finish_task assigns them and records
   `assigned`; a third assigns nothing. (Modelled on
   `TaskPublisherTests.aLostReplyAfterOpeningFindsTheRequestInsteadOfOpeningASecond`.)
3. `GitLabPublishTests` / `GitHubPublishTests`: the request bodies for create with an assignee, and
   for an edit; the GitLab draft prefix is kept and a leading `Draft:` in the title is stripped.
4. Handler tests (new, alongside `OperatorReviewTests`): update_request edits !62's title, description
   and assignee. It is refused for no request, a merged request, a takeover, Pause and another
   repository.
5. `ShellGateTests`: `glab mr update 62 --title …` is still refused, and the refusal names
   update_request.
6. Daemon: `test_operator_mcp.py` against the updated golden; `OperatorToolTests` catches the new case.
7. Gate: `scripts/test.sh` before each commit, `scripts/test.sh all` once before merging.
8. Optional, on your go only: `scripts/run-dev.sh`, then a one-task broadcast on a scratch GitLab
   project, to see the draft's title, description and assignee, and an update_request on it.

## To-dos

- [x] Default title with the colon, and a description without brief or note (TaskPublisher + tests 1)
- [x] Assignee as a recorded, retried step: protocol, GitLab, GitHub, fake host, default `currentUser()` (tests 1, 2b, 3)
- [x] finish_task's optional title, description and assignee, saved on the publication, end to end through daemon, handler dispatch, controller bridge, finisher and publisher (tests 2, 6, golden)
- [x] `update_request`: protocol edit, clients with the draft prefix, handler, daemon tool (tests 3, 4, 6)
- [x] The shell gate's refusals name update_request (test 5)
- [x] docs/operators.md tools table and MR content line
