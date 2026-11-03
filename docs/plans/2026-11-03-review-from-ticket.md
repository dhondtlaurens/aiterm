# Review from a ticket, and GitLab issues as tickets

Branch `feat/review-from-ticket` (worktree exists). Plan file: `docs/plans/2026-11-03-review-from-ticket.md`.

## Goal

Glenn asked for two things in AiTerm:
1. **Start a review from a ticket.** He reviews by ticket: a Jarvis ticket in the Review status and its MR
   (`jarvis/jarvis!545` on `agent/JVS-5793`). Today New Review only searches MRs.
2. **GitLab issues as tickets.** Side projects that don't belong on the Jarvis board (`ai/agentflow`,
   `ai/pauwels-marketplace`) keep their tickets in the repository's own GitLab issues: unassigned, scoped labels,
   branches `53-<slug>`, MRs saying `Closes #53`.

## What we saw (Jira + GitLab, 2026-11-03)

- Jarvis MRs carry the key in their **title** (`JVS-5744 add…`, `Draft: JVS-5793: …`) and **branch** (`JVS-5744`,
  `agent/JVS-5793`, `agent/JVS-5747-2`). A ticket can have several MRs (JVS-5747: !546 closed, !548 merged), and
  its MR can sit in another repo (JVS-5744 → jarvisconfig!25).
- Jira's Development field is empty, and its GitLab remote links are just mentions. Searching GitLab for the key
  is the route that works.
- GitLab gives an issue's MRs directly: `issues/:iid/closed_by` and `issues/:iid/related_merge_requests`.
- Issues: jarvis/jarvis and jarvisconfig have them enabled but 0 open, agentflow has 13 open, pauwels-marketplace 1.

## Scope agreed in the grill

- **One "Ticket" picker** for Jira tickets and GitLab issues together. Each row has its source's brand mark and
  its own key (`JVS-5793`, `#53`). One ticket per task or review. The word is **Ticket** everywhere (field, help,
  checkbox, menus). The MR field keeps following the host: "Merge request" on GitLab, "Pull request" on GitHub.
- **New Task**: the Ticket field stays first. **New Review**: the merge request field first, then Ticket, then the
  name and branch.
- **When GitLab issues are in the picker: automatically**, when the project's remote is on the connected GitLab
  host and the repository has open issues. There's nothing to link, and the Jira project link sheet is unchanged.
  Jira works as today: the linked projects, or every project when none are linked. If Jira isn't connected, the
  picker still searches GitLab issues, and the Jira part's error only shows when there are no GitLab issues either.
- **Empty query**: your open Jira tickets plus the repository's open issues, in **one list by last update**.
  `53` or `#53` jumps to that issue; `JVS-5793` works as today.
- **Auto-resolve in New Review, both ways.** A field you set by hand is never overwritten.
  - Ticket → MR: its open MRs **in this repository**. With one, it's picked, which fills the name and branch.
    With several, the MR list opens showing only those. With none, a help line says "No open merge request for
    JVS-5744 in jarvis/jarvis." and the branch search is pre-filled with the key. Other repositories are not
    searched: you started from this repo, so the line is meant to make you check that.
  - Jira key → its MRs: search by the key, kept only where the key is a whole token in the title, description or
    source branch (`JVS-57` never matches `JVS-5744`). GitLab issue → `closed_by` + `related_merge_requests`,
    open only.
  - MR → ticket: a Jira key in its title or source branch is fetched and filled in. `Closes #N` in the
    description, or a `N-` branch, fills the GitLab issue.
  - GitHub repositories: the PR field as today, plus Jira key ↔ PR resolving through the same key search. No
    GitHub issues.
- **The review keeps its ticket**: the row shows the ticket chip, as a task's does. The Prompt step gets "Include
  ticket details", on by default when there's a ticket, so the reviewer reads the ticket's acceptance criteria
  alongside the MR.
- **Branch for a GitLab issue**: `feat/53-<slug>`. The type comes from the labels (`bugfix`/`bug` → fix,
  `refactor`/`chore`/`docs` → chore, else feat) through `BranchType(issueType:)`'s words. AiTerm opens MRs only
  for operated tasks, so `Closes #53` gets there in two ways. The prompt's ticket block for a GitLab issue ends
  with a line asking for `Closes #53` in the MR description, and `TaskPublisher.description` adds it for an
  operated task.
- **Design first**: every visual touch point goes to the design system's Proposals tab with its options, then we
  publish and **stop for picks** before any Swift.

Out of scope: GitHub issues; the Operator's Jira tools and broadcasts (still Jira-only); MRs in other repositories.

## Design picks (3 Nov 2026, design system Proposals tab)

- **1A**: a GitLab issue's result row and picked chip show its first label (`enhancement`, `bugfix`) in the lane
  column, on GitLab's wash; no labels leaves it empty.
- **2A**: a field New Review filled from the other says so in a help line: "Found from JVS-5793." / "Found from
  !545."; it goes when you change that field yourself.
- **3B**: the miss line ("No open merge request for JVS-5744 in jarvis/jarvis.") is plain help, not amber.
- **4C**: a row with a GitLab issue and a GitLab merge request draws **one** GitLab badge: the mark, `#53`, `!29`
  (`Space.snug` apart), then the threads count. Each number opens its own page, the mark the issue's. Each number
  follows its own key switch; with both off, the bare mark opens the merge request and its tooltip names both. A
  Jira ticket keeps its own badge. Built from two existing quiet `Badge`s `Space.snug` apart (reuse before new), so
  `Badge` and `AiTermUI/README.md` are unchanged.
- **5B**: the row menu says "Open in Jira" for a Jira ticket and "Open in GitLab" for a GitLab issue.
- Copy: as the proposal's copy table.

## Changed while building

- **No open-issues call.** The GitLab issue source is on whenever the remote is on the connected GitLab host; a
  repository without open issues answers with none (403/404, issues off, reads as none too), and the placeholder
  names GitLab issues once the list has shown one. Same result as the agreed rule, one request fewer per sheet.
- **4C without a `Badge` variant**: see the design picks.

## Touch points (each one in the proposals)

1. New Task step 1: the Ticket field and placeholder, mixed result rows (Jira status vs GitLab state and labels
   in the detail column), the picked ticket for each source, help and error lines (Jira not connected while
   GitLab issues work, and the reverse), and a type and branch filled from an issue.
2. New Task step 3: the "Include ticket details" checkbox.
3. New Review step 1: MR then Ticket then name and branch. States: empty; ticket picked → one MR auto-picked;
   ticket with several MRs (filtered list open); ticket with none (miss line + branch search pre-filled); MR
   picked → ticket filled; hand-edited fields kept; a pick refusal (fork PR) next to a ticket.
4. New Review step 3: the "Include ticket details" checkbox.
5. Sidebar task and review rows: the ticket chip with the GitLab mark for `#53` (both chip detail settings), and
   the row menu's "Open in Jira" / "Open in GitLab".
6. Archive sheet: a kept task's ticket with the GitLab mark, and the search finding `#53`.
7. Settings › Interface: the "Jira ticket" badge-detail toggle's label becomes "Ticket".
8. Settings › Integrations: the GitLab card's copy says it also serves issues.

## Files

Core (`app/Sources/AiTermCore`)
- `Jira/JiraTicket.swift` modify: a ticket has a `source` (Jira, or a GitLab project's issue), Jira by default, so
  the Operator's uses don't change. Plus a branch key (`53` for `#53`) and `updated` for the one ordered list.
- `Models.swift` modify: `JiraRef` carries the source, and a save without one decodes as Jira.
- `GitLab/GitLabClient.swift` modify: `issues(project:search:)` (opened, updated_at, `#53` fast path),
  `hasOpenIssues(project:)`, `openMergeRequests(closingIssue:)` (closed_by + related, open, deduplicated).
- `Jira/JiraClient.swift` modify: `ticket(key:)` for MR → ticket (reuses `searchKeys`).
- `Tasks/TicketSearch.swift` create: the one ticket search over Jira (as today) and the repo's GitLab issues
  when present, merged by last update. Each source's failure is kept apart, so one can work alone.
- `Tasks/TicketMergeRequests.swift` create: ticket → open MRs in this repo, and MR → ticket key or issue number.
  Candidates are not the picker's text search, which misses a key that is only in the branch (GitLab searches
  title and description) or only in the description (GitHub filters title, branch and author). It reads the
  repo's open requests a page of 100 at a time until a page comes back short, for at most 5 pages (jarvis has
  14 open today). It merges them with the host's text search for the key, then applies the whole-token rule to
  title, description and source branch. If it stops at the cap, the answer is *incomplete*: nothing is
  auto-picked, and the miss line says "None of the 500 most recent open merge requests in … mention JVS-5744"
  rather than "no open merge request".
- `CodeHost.swift` modify: `MergeRequest` gains `description`. `GitLab/GitLabClient.swift`'s payload maps
  GitLab's `description`, and `GitHub/GitHubClient.swift`'s maps `body`. The picker's results carry it too, so
  an MR picked from the list can give its `Closes #N`.
- `Tasks/ReviewDraft.swift` modify: `ticket`, `appendTicket`, `apply(ticket:)` with hand-edit guards; the doc
  line "no ticket" goes.
- `Tasks/TaskCreator.swift` modify: TaskDraft takes any ticket; the branch key and type come from it; the review
  is created with its ticket ref.
- `Tasks/TaskWorkflow.swift` modify: `createReview` and `reviewCommand` pass the draft's ticket and
  `appendTicket` to `composePrompt` (today both pass `nil`), so the ticket reaches the reviewer both in a new
  worktree and in an existing task's review tab.
- `Agents/AgentCommand.swift` modify: the ticket block names its source and adds the `Closes #N` line for an issue.
- `Operators/TaskPublisher.swift` modify: `Closes #N` in the description.
- `Sidebar/SidebarModel.swift`, `Tasks/ArchiveSearch.swift` modify: the ticket source for the mark, and `#53` found.

App (`app/Sources/AiTerm`)
- `TaskCreationModel.swift`, `Views/NewTaskSheet.swift` modify: TicketSearch, the placeholder, a mark per row,
  the copy.
- `ReviewCreationModel.swift`, `Views/NewReviewSheet.swift` modify: the Ticket field, auto-resolve both ways
  (stale lookups cancelled when a pick changes), the help states, the Prompt step checkbox.
- `Views/Operators/BroadcastBoardSheet.swift` (`TaskBadges`, which the Shelf's rows use): the shared GitLab mark (4C).
- `Views/SidebarRows.swift`, `Views/ArchiveSheet.swift`, `Views/InterfaceSettingsPane.swift`,
  `Views/SettingsCard.swift` (or wherever the GitLab card's copy lives) modify: chip mark, menu, copy.
- `SheetCoordinator.swift` modify: hand both sheets the GitLab connection and the remote.
- `TaskLauncher.swift` modify: `openReview` (the branch is already a task's) saves the picked ticket on that row
  when it has none. A row that already has a ticket keeps it, since it's that task's own, but the review tab's
  prompt still carries the picked one.

Docs
- `docs/design/design-system.html` (Proposals, then the sync after shipping), `app/Sources/AiTermUI/README.md` if a
  component changes.

## Proof

- Core tests: `ReviewDraftTests` (apply ticket, hand edits kept, clearing). New `TicketMergeRequestsTests`
  (whole-token match, closed/merged dropped, several, none, MR → key/issue, GitLab endpoints via a stub session).
  New `TicketSearchTests` (merged by update, one source failing, no issues → no GitLab part). `GitLabClientTests`
  (issues decode, `#53` fast path, 404 = none). `ModelsTests` (an old `jira` ref decodes as Jira). Branch slug and
  type from an issue. The prompt block. The publisher's `Closes` line. Archive search on `#53`.
- `TaskWorkflow` tests: the ticket block reaches the launched command for a new review worktree and for a
  review tab in an existing task. `ReviewInTaskTests`: an existing row with no ticket gets the picked one, and one
  with a ticket keeps its own. `TicketMergeRequestsTests` also cover a GitLab key only in the branch and a GitHub
  key only in the description, a match on page 2, the 5-page cap giving *incomplete* (no auto-pick), and
  MR → issue starting from a picker result whose description says `Closes #53`.
- App tests: `ReviewCreationModelTests` (each auto-resolve state, a stale lookup dropped). `NewReviewSheetTests`,
  New Task tests and snapshots for the step 1 states. `ProjectJiraBadgeTests` unchanged. A sidebar snapshot with a
  `#53` chip.
- `scripts/test.sh` before each commit (in the background); `scripts/test.sh all` once before the merge.
- Run it: a dev build against the real hosts. In jarvis: New Review → JVS-5793 picks !545 and
  `agent/JVS-5793`; picking !545 first fills JVS-5793; JVS-5744 shows the miss line. In ai/agentflow (added as a
  project): New Task lists Jira tickets and #55 together, and #55 gives `feat/55-…`. In jarvis, New Task shows
  no GitLab issues.

## To-dos

- [x] Proposals for touch points 1–8, each decision with options and a recommended pick. Publish the design
      system and **stop for picks**. Picked: 1A 2A 3B 4C 5B.
- [x] Ticket source in Core: ticket and ref with a source, old saves decoding, the GitLab issues client,
      TicketSearch. New Task lists GitLab issues end to end (rows, branch, prompt, chip, archive).
- [x] TicketMergeRequests: ticket ↔ open MRs, for Jira keys and GitLab issues.
- [x] New Review: the Ticket field after the MR field, auto-resolve both ways, the review keeps its ticket, the
      prompt checkbox.
- [x] `Closes #N` in the prompt block and the publisher; the copy in Settings.
- [x] Sync the design system to the shipped Swift and empty the Proposals tab of these (published after the merge).
