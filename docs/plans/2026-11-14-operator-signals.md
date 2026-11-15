# The Operator, first class: signals that start and steer tasks

Status: implemented 2026-11-15 on `feat/operator-refactor`, one commit per to-do. Research it adopts: `docs/research/2026-11-14-operator-signals.md`
(the code probe with file and line references, the reuse count, and how other tools handle a
long-lived supervisor and event triggers); `docs/research/` stays local by the repository's
`.gitignore`, so it is in this worktree only. Challenged by Codex in three rounds on 14 Nov 2026;
every finding is fixed below (stage precedence, pending work before Then, the split of the
cut-over, key retirement in the deletion step, the Codex push guard). Visual design: the proposal "The Operator’s
signals and one family of creation sheets" on the Proposals tab of
`docs/design/design-system.html`; its picks are recorded under **Design picks** before any view is
written.

## Goal

Broadcasts (one brief planned into tasks, a goal loop) are what the agent harnesses and the psg
skills now do inside one task. The Operator becomes a first-class part of AiTerm, one-to-one with
projects: under OPERATOR, **signals** stand where projects stand, and their tasks are the same rows
as any task. A signal watches Jira, GitLab or GitHub (a labelled ticket in my sprints, a review asked
of me, my merge request coming back with threads) and, for each item that starts to match, starts a
task with the signal's prompt (such as `/psg:plan` with the ticket's details), runs its review, lets
go when its done condition holds and keeps, archives or removes the task. The Operator and the Oracle
drive tasks headless: they answer a worker's questions together and ask me, in the Operator's own
chat, only when they disagree or it is mine to decide. Broadcasts go; the feature is written as if
they never existed. Every creation sheet becomes one family with the same steps and copy.

## Approach

AiTerm detects matches deterministically (polling, no tokens) and creates or continues tasks; the
one Operator session is woken only for judgment. An item (a ticket or an MR) has one task for its
whole life, so a signal that fires on an item that already has a task continues it as a new stage:
chaining is not configured, it follows from identity. Skills publish (commit, push, draft MR,
comment rounds); AiTerm guards what a worker may push, finds the MR from the branch, watches it and
runs the signal's done condition and what follows. The domain, the tool surface, the brief and the
sidebar's Operator group are rewritten around signals; the board and its question UI go; the worker,
tab, transcript, question, removal and window machinery is reused. About 70 % of what the
new feature needs is existing code (see **Reuse**).

### What the grill decided

1. **Broadcasts go entirely**: planning, plan revisions, backlog budget, goal loop, summary, End,
   New Broadcast, the board. No legacy reader and no migration code: the old keys are retired.
2. **Signal** (the Operator's project) = a starting point (Jira, GitLab or GitHub) with its
   conditions · a prompt, with the ticket's and/or the merge request's description added for it · permitted agent rows · an optional review
   prompt · who answers the worker's questions · done when · merge when ready (opt-in) · then. Many
   signals, each on or off.
3. **Item = task.** One ticket or MR keeps one task (worktree, branch, window, conversation). A
   signal that fires on an item with a task (same ticket key, the task's MR, or its branch) continues
   it as the next stage under that signal; the row moves under it. **One active stage per task**:
   a stage is active while it launches or works. A match on a task whose stage is active waits as a
   pending stage, one per signal (a repeat match of the same signal folds into it); pending stages
   start in the order they matched once the active stage leaves working (watching, done or
   archived), and never during a worker's turn. A match on a task that is watching, done or
   archived continues it at once. When several signals match a new item in the same pass, the
   oldest signal owns it and the others wait as pending stages. **Pending work outranks Then**: when
   a stage reaches its done-when while a pending stage waits, that stage's Then (keep, archive,
   remove) does not run; the next pending stage starts in the same task. Then runs only for the
   last stage, with no pending stage left. Skipped items (no project) are
   listed with why in their signal heading's tooltip and in the activity log.
4. **Starting points**: Jira (chips: label, in my open sprints, assignee, status, Jira project, or
   JQL); GitLab and GitHub (a review is asked of me; my merge request has unanswered threads or comes
   back to me. A GitLab or GitHub signal starts on one of two: "I'm asked to review", or "My merge
   request needs me" with "It's waiting on my reply" and/or "It's sent back to me" ticked (each
   needs its own prompt, so each is its own signal); optionally only some projects. **No manual work** in this plan: no manual signal, no
   hand-over, no `start_item`.
5. **What matches starts.** Creating a signal starts a task for every item that matches then (the
   sheet lists them: "Starts when you create it · n"); after that, each item that starts to match
   starts one. Saving an edit or switching a signal back on starts what matches and never started.
   (The grill first chose "only new matches"; the proposal review reversed it: a ticket labelled
   before its signal existed would otherwise never start.) Nothing starts from an incomplete read.
   An item that stops matching runs on to its done condition. **No concurrency
   cap.** Items with no project in AiTerm are **skipped**; AiTerm never clones. A ticket maps through
   the Project ↔ Jira project links (several: the Operator picks), an MR through the project's
   remote. No acknowledgement writes on pick-up.
6. **One Operator, always on**: one Claude Code session and window. Wake lines name only the event
   and the task; the Operator reads `run_status` (a digest of signals and tasks) or
   `run_status(task:)`. Durable state is AiTerm's: each task's journal (stages, decisions, answers,
   notes). **Fresh sessions**: when idle and over about 150k tokens of current context, or a day
   old, AiTerm ends the session and starts a fresh one with the brief as system prompt and an
   AiTerm-built JSON digest as its first message. Claude Code's idle compaction is off for it. Ticket
   and MR text is never copied into durable notes unfenced.
7. **The Oracle is the Operator's partner.** A worker's question (workers are denied
   `AskUserQuestion`, so a skill's grill question ends the turn as a `Question:` paragraph) gets an
   answer the Operator proposes and the Oracle critiques, up to three rounds. Agreed: typed into the
   worker and journaled. Not agreed, or either says it is the person's call: the Operator asks me.
   This is the only mode: the Operator is as headless as it can be, and a person gives it only
   work they trust it with. Kept: consult on demand (`ask_oracle`), the shell gate, the
   merge veto, thread critique. Gone: plan critique, backlog veto, goal check. With the Oracle off,
   what the Operator would answer reaches me.
8. **Asking me happens in the Operator's chat.** The Operator writes the question as plain text in
   its own window (never `AskUserQuestion`, which would block it from every other task). AiTerm
   records it (`ask_you`) only to count it: the Operator's row reads "waiting on you · n" with the
   attention mark and a notification; its click opens the window, where I answer by typing; the
   Operator resolves it (`resolve_question`). A worker's permission prompt stays in that worker's
   window and marks its row, as for any task. Gone: the question block, the pager, answer buttons,
   `answeredHere`, relays to a board.
9. **The skill publishes, AiTerm guards and watches.** Workers may push their own task branch and
   open a draft MR; the skills' "ask the user" steps, including writes in my name (comments on a
   colleague's MR, thread replies, approvals, ticket moves), go to Operator + Oracle. Workers never
   force-push, push another branch, the default or a protected branch, or merge, Claude and Codex
   alike.
10. **Merging is AiTerm's, opt-in per signal**: merge through the host once approvals, green checks
    and resolved threads hold, after the Oracle's merge veto.
11. **Checking is part of the prompt** (`/psg:plan, then /psg:implement and /psg:review` runs the
    skill's own adversarial review in the worker). Signals have no review tab, no check prompt, no
    verdicts and no fix rounds. **A signal's Done step** holds done when, merge when ready (where it
    applies and isn't already implied by the done-when) and what happens to the task, read as one
    sentence, and offers only what fits the source: "I'm asked to review" never merges (the merge
    request is not mine). **Done when**: Jira: the Operator judges it done · its
    MR has a reviewer · approved · every thread resolved · merged · the ticket reaches status X; my
    merge request: every thread resolved · approved · merged · the Operator judges; a review asked
    of me: **my review is posted** (a review, comments or an approval from me since the task
    started, read from the host) · merged or closed · the Operator judges. **Then**: keep · archive (worktree and window go,
    branch and conversation stay; a later match restores it and resumes the conversation) · remove
    (optionally deleting the branch once merged). Unsaved work always keeps the worktree.
12. **Agents**: per signal a list of permitted agent rows; the Operator picks per task and tab; the
    80 % weekly-usage switch stays.
13. **Sidebar, one-to-one with projects**: OPERATOR mirrors PROJECTS. The Operator's row first (it
    behaves as a task row: its click opens its window). Each signal is a heading drawn exactly like a
    project heading, its source mark where a project has its provider icon, folding and counting
    like one. Its tasks are **the same rows as a project's tasks**; while the Operator acts on one,
    the row's whole badge line (ticket · merge request · diff · branch) decodes into the action
    (scramble, then resolve) and back afterwards; under the pointer the badge line returns. Take Over
    moves the row to its project. The mutual OPERATOR/PROJECTS fold goes.
14. **One family of creation sheets**: New Signal (⌘S, replacing New Broadcast; step 1 is only its
    name and starting point), Add Project (which takes in the Jira-link sheet and the worktree import
    alert; Edit Project reuses it), New Task, New Review, New Terminal, Add Divider: the same chrome,
    the same order of decisions (what and where from → prompt → agent → finish; steps left out, never
    reordered), the agent as one Agent · Model · Reasoning row under the prompt (a list for a signal),
    "Name" and "Prompt" everywhere, "(optional)" in the label, Create/Add/Save buttons. Each step
    asks one thing or one confined group, and the earlier steps stay above it as done lines.
17. **The Shelf becomes the Archive.** Shelve → Archive everywhere the person reads it; Show Archive
    moves from ⌘S to ⌘A, which applies only outside a text field (a key monitor gives ⌘A to Select
    All while a text field is being edited, since Edit › Select All otherwise claims it first).
18. **Context added to a prompt is descriptions only**: the ticket's description and/or the merge
    request's description, ticked per signal, task or review.
15. **Copy that teaches prompting**: Settings › Operator and the Oracle say what each does, never
    does and how to steer it; prompt fields show real example prompts per source and say what
    context AiTerm adds. No internal words (slice, digest, rotation, broadcast, flow) reach the
    person.
16. **Pause** stays on the Operator's row (the pause and carry-on notes are reused); there is no End.
    Each signal can be switched off on its own (Switch Off / Switch On (starts n) in its menu).

### Decided while probing the code

- **Retired keys, not a migration.** `AppState` and `TaskItem` preserve unknown keys and save them
  back (`Models.swift:121-144`), so `runs` and `foldedRuns` join `AppState`'s retired list and
  `operated` joins `TaskItem`'s (`ArchivedTask` nests it). New keys: `signals`, `signalSeen`,
  `operatorSession` on `AppState`, `signalTask` on `TaskItem`. Every new enum with associated values
  decodes through a `kind` key with an unknown fallback, as `SidebarItem` does, since one bad value
  fails the whole workspace load (`StateStore.swift:138-143`). Tasks from an old broadcast become
  ordinary tasks; the release notes say to end a running broadcast in the installed build first.
- **Domain, fresh, in `AiTermCore/Operators/Signals/`**: `Signal`, `SignalSource` (`jira`,
  `gitLab`, `gitHub` with their conditions), `JiraConditions` with a pure `JQL` compiler (quoted
  values; JQL written by hand wins), `RequestConditions` (review asked of me, my request's threads
  or return, project filter), `SignalWork` (prompt, context), `SignalFinish` (`DoneWhen`, `Then`,
  `mergesWhenReady`), `ItemRef` (ticket, MR by host+repo+iid canonicalised through
  `RemoteURL`, branch), `SignalSeen` (baseline, started, skipped; pruned), `MatchDecision` (pure:
  matches → new task, continue task, skip), `SignalTask` (owner signal, item, `TaskPhase`, stage,
  pending stages, worker tabs, people review, watched MR, the Operator's current act, flags),
  `TaskPhase` (launching, working, watching(done-when), blocked, done, archived, stopped),
  `SignalTransitions` (pure; every edge recorded as `OperatedTransitions` does today), `DoneCheck`
  (pure; unknown when the host can't be read), `TaskJournal` (one JSON-lines file per task; the
  newest entries in state; our text and fenced quotes kept apart), `OperatorSession` (identity,
  session generation, window, conversation, fresh-start book, open questions, open Oracle rounds, a
  bounded idempotency ledger), `FreshStartPolicy` (pure), `OperatorDigest`. Carried over unchanged
  or nearly: `LaunchAttempt`, `ExtraTab`, `LaunchRequest`, `PeopleReview`, `GateRequest`,
  `ThreadCritique`, `ChallengeRecord`, `OperatorQuestion` (its origin becomes an enum; the answering
  fields go), `OperatorSnag`, `AgentChoice`, `OracleSetting`,
  `StallWatch`, `WorkerTurn`, `WorkerTabs`, `TaskLiveFacts`, `DiffDigest`, `DeliveryCheck`,
  `AgentDelivery`, `ModelChoice`, `OperatedBranch`, `TaskKeyReference`, `OperatorTiming`,
  `ActivityLog` (kept as the on-disk record; no view).
- **Source-aware finish**: `SignalFinish` is validated against its source (no merge on a review
  signal; merge-when-ready not offered with "merged" as done-when; each source's done-when cases), so creation/editing cannot accept an impossible combination; persistence still round-trips
  unsupported saved records inertly when opened by an older build. The
  sheet derives what it shows from the same rule. "My review is posted" reads the host's reviews,
  notes and approvals by the account's user since the stage started.
- **Sources in `AiTermCore/Signals/Sources/`**: `SignalSourceReader` (poll → items, whether the read
  was complete, a cursor), `JiraQueryReader`, `ReviewRequestedReader` and `MyRequestReader` per host,
  `ItemProjectMapper`. Jira gains a paged `search(jql:fields:pageToken:)`, labels, statuses and an
  approximate count; `JiraTicket` gains labels, project, assignee. Code hosts gain host-wide accounts
  (`GitLabAccount`, `GitHubAccount`) over the existing `HostAPI`: GitLab
  `merge_requests?reviewer_username=…&scope=all&state=opened`, GitHub GraphQL search
  `user-review-requested:@me` (personal requests); for my MRs, author and assignee listings whose
  `updated_at` decides whether threads are read at all.
- **Engine owners**: `SignalPoller` (one `PollLoop` per source and host, each pass a `TickPass`,
  backing off to 5 min on failure; a Jira delta read every minute and a full key sweep every 10 min,
  since sprint membership changes without touching `updated`); `ItemRouter` (item → existing task or
  project, or skipped); `StageRunner` (create or continue a stage: a new branch, or the MR's branch
  for a review through `TaskLauncher`'s review path; the stage prompt with its context; journal);
  `RequestWatch` (replaces `ReviewWatcher`, `ReviewThreadsWatcher` and the finisher's merge watch: one
  read per MR per pass, the MR found from the branch, done-when facts, the merge when allowed);
  `ThenRunner` (from `TaskAutoCloser`: keep, archive through a new prompt-free
  `TaskArchiver.archiveAutomatically`, remove through `TaskRemover.removeAutomatically`; restore
  resumes through `WorkerStarter.reopen`); `OperatorSessionKeeper` (from `OperatorWindows`: start,
  reopen, fresh start, the single folder and a new token per session, the old window closed before
  its token is revoked); `QuestionRounds` (from the relay rounds); `WorkerGate` (below).
  `OperatorController` keeps its composition and reconcile tick; the broadcast lifecycle, goal and
  summary leave it.
- **The Operator's current act**: each tool call and wake that concerns a task sets a short,
  AiTerm-worded act on its `SignalTask` (answering its worker, consulting the Oracle, answering threads,
  waiting on a reviewer, merging), cleared when the turn or wait ends; the row's badge line reads it.
  The decode reuses `OperatorBadge.decodeDuration`, `OperatorTitle.hold` and `.hoverDuration`, with
  Reduce Motion swapping the words without the scramble: a view concern with no state.
- **⌘A for the Archive**: a local key monitor (as `Prompter` uses) routes ⌘A to Select All when the
  key window's first responder is a text field's editor, and to Show Archive otherwise; the View
  menu shows the key, `docs/keyboard.md` and Settings › Interface say "outside a text field".
- **Waker**: reasons that die with broadcasts and the finisher go; new ones are a match started a
  task, a stage continued, threads came in, a review verdict, done-when reached, fresh session.
- **Worker guard**: the push, MR-create, ready and update denials leave
  `AgentCommand.operatedClaudeDenials`; merges and `AskUserQuestion` stay denied. A `pre-push` hook,
  given to every worker's git through its launch environment (`GIT_CONFIG_COUNT`, chaining to the
  repository's own hooks), refuses any ref but the task's branch, the default or a protected branch,
  and non-fast-forward updates. Claude workers also get a local PreToolUse check reusing
  `ShellGate+Denials`' parser for `--no-verify`, force-push and merge commands, answered without the
  Oracle. Codex workers, which run with Codex's sandbox bypassed, get the same check in front of
  `git`, `gh` and `glab` as PATH shims in their launch environment (unless the spike proves Codex
  runs a pre-tool check, which then carries it): `git push --no-verify`, any force or
  force-with-lease, a ref other than the task's branch, the default or a protected branch, and a
  merge are refused before the real command runs, so a skipped hook skips nothing. Codex workers
  keep today's push denial until that check's tests pass under Codex's own launch environment. Not
  a sandbox (a worker calling `/usr/bin/git` by path gets past it), and the brief says so.
- **Tools, 37 → 13**: kept `run_status` (digest, or `task:`), `read_task` (adds the journal and the
  item's text, fenced as untrusted), `message_task`, `open_tab` (work tabs only), `ask_you` (records
  a question asked in chat), `resolve_question`, `report_snag`, `jira_search`, `resume_task` (absorbs
  `retry_task`); adapted `finish_stage` (from `mark_task`: done, blocked, failed, skipped), `note`
  (from `log_decision` and `leave_for_you`); new `answer_worker` (the relay's rounds, turned round),
  `ask_oracle` (absorbs `critique_thread`). Gone: planning, goal, summary, `relay_question`, every
  host and Jira write, `finish_task`, `review_task`, `record_review` and review tabs (checking is in
  the prompt; a second opinion is `ask_oracle`). The trait-based `OperatorTool` validation,
  idempotency keys and authority checks after every suspension stay; `answer_worker`'s and
  `ask_oracle`'s keys are persisted.
- **Brief**: role, hard limits, mechanics, talking to the person (now: ask in your chat, then
  `ask_you`) and the house instructions survive; plan, slices, backlog, ends, goal and summary go;
  new: signals, answering workers with the Oracle, writes in the person's name through the skill,
  fresh sessions. The signals themselves travel in the digest and in `run_status`, not in the system
  prompt, so editing one never leaves the brief stale.
- **Daemon**: one Operator folder (`operators/operator/`) and one live token; the route, gate
  forwarding and register/revoke stay; the tool schemas are rewritten; the gate refuses a revoked
  token rather than failing open.
- **Context size**: the status line's current context size is parsed beside the percentage
  (`hook_events.py`, `SessionInfo`): a fresh start needs tokens, not a share of a 1M window.
- **Creation sheets**: the family shares `SteppedSheetFrame`, `CreationFooter`, `AgentStep` (grown
  to a list for a signal, the same copy) and `PromptStep`; `CreationSteps` gains the agreed step
  layout and every sheet uses it; `NewBroadcastModel` becomes `SignalModel`; the generic chip picker
  is pulled out of `NewBroadcastSheet` for Jira conditions and project filters.
- **Performance**: a task that only watches (waiting on a reviewer for days) leaves the per-tick
  transcript, branch and prompt reads; a full transcript read only for a task whose turn awaits
  judgment; `run_status` cached by workspace revision; one host read per MR per pass; an open
  questions index per `SidebarPass`. Bounds: open questions plus the last 50 resolved, only open
  Oracle rounds in state, decisions in the journals, the idempotency ledger as an LRU (500 entries,
  7 days), the activity log rotated daily or at 5 MB, the seen set pruned to live items plus 90
  days. Blocking work stays off the cooperative pool (`BackgroundWork`, `GitLanes`); owners stay
  `@MainActor` and check identity and authority after every suspension; the decode animation runs
  only on the row whose act changed (`PerRow`).
- **Swift patterns**: value types and enums with associated values for every choice (no
  stringly-typed state), pure decisions in Core tested without the app, effects in small
  `@MainActor` owners built in dependency order by `OperatorController`, protocols only at real I/O
  seams (the source readers, the account clients), one file per type, `Sendable` throughout.

## Design picks

Picked on 14 Nov 2026 over several rounds, drawn at 1 px = 1 pt from the shipped tokens; the page
is self-contained, open it in a browser. The final creation sheets (every step of New Task, New
Review and New Signal, the one-step sheets, the control rule) are on the Proposals tab of
`docs/design/design-system.html`. The sidebar, the decode and Settings are on the same tab as of
commit `9248cd3c` (`git show 9248cd3c:docs/design/design-system.html > /tmp/signals.html`): its
sheet frames there are superseded by the final ones, its sidebar, decode, Operator row and Settings
frames are the picks.

- **The OPERATOR group mirrors PROJECTS**: the Operator's row and its states (at work, waiting on
  you · n, watching n tasks in n signals, starting fresh, paused); signal headings drawn as project
  headings with their source mark, folding with the status count chips; identical task rows; Take
  Over, archived and moved rows; Switch Off / Switch On (starts n).
- **The decode**: the whole badge line gives way to the Operator's act and comes back, reusing
  `OperatorBadge.decodeDuration`, `OperatorTitle.hold` and `.hoverDuration`; under the pointer the
  badge line returns; Reduce Motion swaps without the scramble.
- **No Operator sheet**; questions in the Operator's chat, with the notification wording drawn.
- **Settings › Operator and the Oracle** as 6B: the role in a line, what it does, what it never
  does, when the Operator asks the Oracle, "Steer the Operator" with example instructions.
- **Jira conditions** as chips with a small popover each, an add menu and a JQL mode.
- **The creation sheets**: one family. Each step asks one thing or one confined group, on its own
  (no done lines above it); Back/Continue, a click on a done step in the stepper, or ⌘1…⌘5 move
  between steps. One control rule for every sheet: 2–3 short options → segmented control; more, or
  a growing list → select; on/off → checkbox with its effect as help; a short line → input; prose
  or a prompt → textarea (one height for every prompt); picking from a search → the one search field
  with chips. The same labels, help lines, spacing, "(optional)" rule and field order everywhere.
  Decided on the proposal: JQL is a Conditions / JQL segmented choice and JQL uses the prompt
  editor; Then and Starts from (with source marks) are segmented; Agent is a select; Ticket and
  Merge request are one-chip search fields; Branch is the same input in New Task and New Review
  (New Review offers the repository's branches as you type and says when one doesn't exist); "AiTerm adds" is one checkbox per description; Projects
  is an always-visible optional field; Folder is an input with Choose… (Edit Project shows it under
  the title; projects keep no rename); the prompt editor stays `PromptStep.editorHeight` (150). New Task, New
  Review and New Signal share their step positions (left out, never reordered), show only what
  applies, never disable a control, default so the common path is Continue … Create, and end with
  one closing block (Task and Review: where it opens and what runs; Signal: the task's life in a
  sentence, including that the Operator and the Oracle answer its questions and ask you only when
  they disagree). New Task: Ticket → Name and branch → Prompt → Agent. New Review: Merge request →
  Name and branch → Prompt → Agent. New Signal: Signal → Starts when → Prompt → Agents → Done, five
  steps for every source; Done follows the source (no merge for "I'm asked to review"). Add Divider,
  New Terminal, Add Project and Edit Project follow the same rules in one step. The step lists are
  the ones on the final proposal.
- Changed after review: ⌘S New Signal; the Archive on ⌘A; context as descriptions only; what
  matches starts; the request triggers' wording; no "who answers" choice; checking inside the
  prompt; Done holding what happens to the task.

## Reuse

From the four probes, adjusted for what the revision drops (the board, the question UI, manual
work, the hotkey) and adds (the creation-sheet family), in lines of code including tests:

| Area | Reused | New | Reuse |
|---|---|---|---|
| Runtime engine | ~7.9k | ~2.6k | 75 % |
| Domain and state | ~4.3k | ~1.6k | 73 % |
| Tools, brief, MCP | ~3.8k | ~1.5k | 72 % |
| UI and sources | ~6.4k | ~3.4k | 65 % |
| **Total** | **~22.4k** | **~9.1k** | **~71 %** |

About 15.5k lines are deleted (planning, goal, summary, `TaskFinisher`, `TaskPublisher`, the broadcast
lifecycle, New Broadcast, the board and its question UI); about a third of the 18k-line Operator test
suite goes with them. Reuse here is reused / (reused + new).

## Files

Create:
- `app/Sources/AiTermCore/Operators/Signals/`: `Signal`, `SignalSource`, `JiraConditions` + `JQL`,
  `RequestConditions`, `SignalWork`, `SignalFinish`, `ItemRef`, `SignalSeen`, `MatchDecision`,
  `SignalTask`, `TaskPhase`, `SignalTransitions`, `DoneCheck`, `TaskJournal`, `OperatorSession`,
  `FreshStartPolicy`, `OperatorDigest`, `AppState+Signals`.
- `app/Sources/AiTermCore/Signals/Sources/`: `SignalSourceReader`, `JiraQueryReader`,
  `ReviewRequestedReader`, `MyRequestReader`, `ItemProjectMapper`.
- `app/Sources/AiTermCore/GitLab/GitLabAccount.swift`, `GitHub/GitHubAccount.swift`.
- `app/Sources/AiTerm/Operators/`: `SignalPoller`, `ItemRouter`, `StageRunner`, `RequestWatch`,
  `ThenRunner` (from `TaskAutoCloser`), `OperatorSessionKeeper` (from `OperatorWindows`),
  `QuestionRounds`, `WorkerGate`, `SignalModel` (from `NewBroadcastModel`), `OperatorReadiness`.
- `app/Sources/AiTerm/Views/`: `SignalSheet` and its steps, `ChipsPicker` (out of
  `NewBroadcastSheet`), `SignalHeaderRow`, the act line with its decode.
- The worker `pre-push` hook (shipped in the bundle's resources).
- Tests beside each; `SignalWorld` in `AiTermTestSupport` (from `OperatedWorld`); new contract
  fixtures with their provenance.

Modify: `Models.swift`; `OperatorController(+Controls)`, `OperatorWaker`, `WorkerStarter`,
`WorkerTurnReader`, `WorkerPrompts`, `RunReconciler` (→ `TaskReconciler`), `BranchWatch`,
`OperatorWatchdog`, `OperatorNotifier`, `PauseSignaller`, `TaskArchiver`, `AgentCommand`,
`ShellGate+Denials`, `ChallengeLaunch`, `PublicationGuard` (merge floor only), `MergedBranchCheck`;
`OperatorToolHandler` and its kept extensions, `OperatorTool`, `OperatorCommand(+Brief)`,
`RunStatus`, `OperatorRequests`, `OperatorWakeNotice`, `OperatorProfile(Store)`, `ActivityLog/Line`,
`OperatorTiming`, `TaskLiveFacts`, `WorkerTabs`; the sidebar (`SidebarModel`, `SidebarPass`,
`HeadingValues`, `OperatorLine`, `BroadcastRow` → `OperatorRow`); views (`SidebarRows`,
`SidebarView`, `SidebarRowContent`, `OperatorHeading`, `OperatorMenus`, `OperatorRowView`,
`OperatorBadge`, `OperatorSettingsPane`); the creation sheets (`NewTaskSheet`, `NewReviewSheet`,
`NameSheet`, `CreationSheet`, `SteppedSheetFrame`, `SheetChrome`, `Steps/*`, `JiraProjectSheet` as
picked), `CreationModel`, `TaskCreationModel`, `ReviewCreationModel`, `SheetKind`,
`SheetCoordinator`, `ArchiveSheet` and the Shelf's words (→ Archive), `AiTermApp` (⌘S New
Signal…, ⌘A Show Archive and its key monitor), `KeyboardSettingsPane`, `AppController`,
`AppController+Operators`; `JiraClient`, `JiraTicket`, `CodeHost` (`MergeRequest` facts);
`daemon/aitermd/{operator_mcp,hook_events}.py`; snapshots; the docs (`operators.md` rewritten,
`architecture.md`, `daemon-protocol.md`, `keyboard.md`, `testing.md`, `configuration.md`), the
README inventory and the design page.

Delete: `PlanRevision`, `PlanEndRules`, `BacklogBudget`, `BroadcastCompletion`, `RunSummary`,
`TaskEndChange`, `UpstreamReplacement`, `OperatedTask+Ends`, `OperatedTransitions+State`,
`RunScheduler`, `TaskFinisher` (its merge watch and merged detection move to `RequestWatch`),
`TaskPublisher` (its merge readiness moves too), the review-tab role and `ReviewVerdict` with
`OperatorToolHandler+Verdicts`; `BroadcastBoard`, `BroadcastBoardSheet`,
`BroadcastBoardHost`, `WaitingOnYou`, `BroadcastActivityView`, `ActivityPresentation`,
`BroadcastSummaryView`, `DoneStep`, `TaskStep`, `NewBroadcastSheet`'s body; the
`OperatorToolHandler` extensions for plan, goal, Jira writes, request, merge evidence, relay to the
board and most of challenge and review; `BroadcastContractTests` and the tests of what is deleted.

## Proof

- **Pure decisions** (Core, test first): the JQL compiler (quoting, every chip, JQL by hand);
  `MatchDecision` (new item, continuing item by key, MR and branch; skip; what matches at creation,
  on save and on switching on starts once; nothing from an incomplete read; an unmatched item left
  running); `SignalTransitions` (every edge, re-fire from
  watching, done and archived; pending stages: a match on an active task waits, a repeat folds, two
  signals on one new item give it to the oldest, pending stages start in order after the active one
  leaves working and never mid-turn; a stage done with a pending stage waiting starts it and runs no
  Then, so remove and archive never drop queued work); `DoneCheck` for each condition and an unreadable host;
  `FreshStartPolicy`; `ItemProjectMapper` (one, several, no project); the digest's shape; the
  retired keys (in the deletion step): an old `state.json` with `runs` and `operated` loads, and its
  next save has neither.
- **Sources**: each against `StubURLProtocol` recordings: paging, a 429 and back-off, incomplete
  reads, GitLab and GitHub reviewer and author listings.
- **Engine** (`SignalWorld` and the existing fakes): a matching ticket makes a task and a worker
  with its stage prompt and context; the same item from another signal continues the task and moves
  the row; a worker's question answered after Oracle agreement, and asked of me on disagreement or
  when either calls it mine; the Operator's row counts open questions; done-when runs keep, archive and remove; an
  archived item that matches again is restored with its conversation; merge when ready merges only
  with approvals, green checks, resolved threads and the Oracle's yes; a fresh session starts only
  idle, carries open rounds and questions, and revokes the old token after its window closed; a
  watching task costs no transcript read; the act line is set and cleared.
- **Worker guard**: in a scratch repository the hook refuses another branch, the default branch and
  a force push and lets the task's branch through; the repository's own hooks still run; the Claude
  PreToolUse check and the Codex shims each refuse `git push --no-verify`, force and
  force-with-lease, another ref, the default branch and a merge, the shims run under Codex's launch
  environment.
- **Contract**: the brief, the tool list and the saved-format fixtures are re-captured once,
  deliberately, as this feature's contract change, with their provenance; the before-and-after brief
  evals run as `docs/testing.md` requires; `BroadcastContractTests` goes.
- **Daemon**: `pytest` for the single token, a revoked token refused at the gate, the new schemas,
  the context-size parsing.
- **Keys**: ⌘A selects all in a sheet's text field and opens the Archive from the sidebar; ⌘S opens
  New Signal; `KeyboardSettingsTests` agrees with the menu.
- **Snapshots**, read after each UI slice: the OPERATOR group in every state, a signal heading open
  and folded, a task row before, during and after an act, every step of every creation sheet for
  every source, Settings.
- **Spikes first**: Claude Code's setting that turns idle compaction off, and the status line's
  current-context field; whether Codex runs a pre-tool hook. Findings go in this plan.
- **Gate**: plain `scripts/test.sh` before each commit; `scripts/test.sh all` before the merge.
- **Run**: a real signal (a labelled ticket in a scratch Jira project → `/psg:plan` grill answered by
  Operator and Oracle → draft MR → done when) only through `scripts/run-dev.sh` on the maintainer's
  go; until then the tests and snapshots are the proof, and the report says so.

## To-dos

Each step leaves the package building and the gate green.

- [x] Spikes: idle compaction off and the context-size field for Claude Code; Codex pre-tool hooks.
- [x] Domain in Core: signals, sources' conditions, items, the task's record, phases, transitions
      and pending stages, done check, journal, the Operator's session, fresh starts, digest; the
      new keys decode and encode beside the old ones. Unused yet; the broadcast keys stay.
- [x] Sources: Jira paging, labels and count; host-wide GitLab and GitHub accounts; the mapper; the
      poller behind a fake. Nothing starts a task yet.
- [x] The creation-sheet family as picked, on today's sheets (New Task, New Review, Add Project with
      Edit Project, New Terminal, Add Divider): shared steps, agent row and copy; the Shelf renamed
      the Archive, on ⌘A outside text fields. New Broadcast untouched yet.
- [x] The engine owners beside today's controller, not wired into it: `ItemRouter`, `StageRunner`,
      `RequestWatch`, `ThenRunner` (with `TaskArchiver.archiveAutomatically`), `QuestionRounds`,
      `OperatorSessionKeeper`, the act; each proven in `SignalWorld` with fakes.
- [x] The new tool set and the brief as a second handler and brief generator, not served yet; their
      contract fixtures captured with provenance.
- [x] The daemon, additively: the single Operator folder and token beside the per-run ones; the gate
      refuses a revoked token; the context-size field parsed. `pytest` green.
- [x] The worker guard: the `pre-push` hook for every worker (today's workers may not push at all,
      so it changes nothing for them yet), the Claude PreToolUse check and the Codex shims; proven in
      a scratch repo, `--no-verify` included. Codex's push denial lifts only once its tests pass.
- [x] Activation: `OperatorController` runs one Operator and signals through the new owners, the new
      handler is served, push and MR creation leave the worker denials, New Signal joins the family,
      and the OPERATOR group shows the Operator's row and signal headings over identical task rows.
      Broadcasts can no longer be started; their code is still present but unreachable.
- [x] Deletion: broadcasts, the board, New Broadcast, the old handler extensions, brief and tests go;
      `runs`, `foldedRuns` and `operated` are retired in `Models.swift` with the test that an old
      `state.json` loads and its next save has none of them; the old per-run tokens leave the daemon.
- [x] The act line's decode, the signal heading's fold and counts, Take Over, every row state.
- [x] Settings › Operator and the Oracle: the copy as picked.
- [x] Fresh sessions end to end: context size, idle, digest, token handover.
- [x] Performance: watching tasks out of the per-tick reads, the status cache, the bounds.
- [x] Docs, the README inventory, the design page synced with the proposal removed (the
      `design-system` skill's loop; publishing the page to its artifact is the maintainer's step and
      is not needed to finish).
- [x] Gate, review, one commit per step, `scripts/test.sh all`; stop before the merge.

## Spike findings · 14 Nov 2026

The first to-do is complete; no product code or worker permissions changed. Read first: the
research named above, the current creation-sheet proposal, and the sidebar, decode, Operator-row
and Settings frames from `9248cd3c`. The final sheet picks take precedence over its older sheets.

### Claude Code: idle compaction

Verified against installed **2.1.325**. Pass `"idleCompaction": false` in the Operator's existing
per-launch `--settings` JSON/file, alongside its other settings. Do not write it into the person's
defaults. The [settings reference](https://code.claude.com/docs/en/settings-reference#idlecompaction)
defines this boolean separately from auto-compaction; ordinary auto-compaction can stay enabled.

Evidence beyond accepting an arbitrary settings key: the installed executable's schema declares
`idleCompaction` as an optional boolean, its setting reader defaults it to true, and its idle
eligibility function returns `idle_compaction_off` when that reader returns false. A scratch
`CLAUDE_CONFIG_DIR`, empty setting sources, no MCP servers/tools and a local scripted Anthropic
endpoint successfully completed a `claude --print --settings '{"idleCompaction":false}'` launch
(exit 0, one local model request). No personal credentials or CLI settings were used. Launch
acceptance alone is insufficient: an exploratory invalid string value also allowed a request.
The schema and idle-guard inspection establish the meaning of the valid boolean.

Limit: this checks the setting, its idle guard and the launch path; it does not simulate an
hour-long interactive session with 200k tokens. The fresh-session end-to-end step still owns the
Operator launch wiring and idle handover proof.

### Claude Code: current context size

Use the status-line `context_window.current_usage` object. Current input context is
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`; exclude `output_tokens`.
This matches `context_window.total_input_tokens` and the input-only percentage calculation in
the installed executable and the [status-line reference](https://code.claude.com/docs/en/statusline#context-window-fields).
Despite the earlier research's caution about the name, this version's status-line
`total_input_tokens` is current input context, not lifetime cumulative input. Do not confuse it
with session cost/usage totals elsewhere.

Checked every populated tick in the existing **2.1.323** compatibility capture (12 ticks), without
recapturing or editing the frozen fixture. Example: 2 input + 9,227 cache creation + 30,010 cache
read = **39,239 tokens**, while a 1M window's rounded percentage is 4 (which would estimate 40,000).
The **2.1.325** executable still constructs the same fields with that exact sum. Before the first
response, or after compaction until another response, `current_usage` can be null: retain unknown,
not a measured zero. Later daemon work should prefer the exact component sum; a finite percentage
and positive window size can provide a fallback estimate only when exact usage is absent.

### Codex: native pre-tool hooks work, with explicit trust

Verified against installed **0.169.0**, whose `features list` reports `hooks` stable and enabled.
`PreToolUse` with matcher `^Bash$` receives an `exec_command` as `tool_name: "Bash"`, with the
shell command in `tool_input.command`. Synchronous hooks can deny before execution using
`hookSpecificOutput.permissionDecision: "deny"` with `hookEventName: "PreToolUse"`, or exit 2
with a reason on stderr. The [hook reference](https://learn.chatgpt.com/docs/hooks) documents
these forms and the separate trust requirement.

Ran the actual installed CLI against a local scripted Responses server, in a temporary
`CODEX_HOME` and working directory, using the worker's
`--dangerously-bypass-approvals-and-sandbox`. The server requested one harmless marker-writing
`exec_command`, then completed the turn; no live model or account was involved. Both blocked
cases returned the denial to the next model request, and no marker was written:

| Hook case | Hook calls | Marker written | CLI exit |
| --- | --- | --- | --- |
| Trusted JSON denial | 1 | no | 0 |
| Trusted exit 2 | 1 | no | 0 |
| Trusted allow (control) | 1 | yes | 0 |
| Untrusted denial (control) | 0 | yes | 0 |

The trusted cases used `--dangerously-bypass-hook-trust` only with the scratch config's known
probe hook. Each received `permission_mode: "bypassPermissions"`: sandbox bypass does not skip
a trusted pre-tool hook. Hook trust is separate: without that trust override the new hook was
skipped, and the command ran. A tool denial is a tool result, not a nonzero CLI exit.

**Consequence for the worker-guard to-do:** the plan's native-hook option is available. It may
carry the shared local command check instead of PATH shims only after the launch path proves
the exact hook is enabled and trusted, including on resume. Do not assume sandbox bypass grants
hook trust, or blindly enable unreviewed personal hooks. If that cannot be established for the
worker environment, use the already-planned shims. Keep the git pre-push hook in either case.
The later worker-guard tests must still prove the actual parser, `--no-verify`, force variants,
foreign/default/protected refs, merges and repository-hook chaining under the worker launch
environment before any push restriction lifts. This spike proves native interception only.

### Reproduction and provenance

Local probes and their JSON results are in `docs/research/operator-signals-spike/` (ignored, as
the research is): `probe_claude.py` and `probe_codex.py`. Run either with `python3` from the
worktree root. They allocate their own temporary config and loopback server, need no account,
and clean up their temporary folders. The Claude probe also reads the existing capture at
`daemon/tests/fixtures/compat/claude/posts.jsonl`. They do not use iTerm2 or the live daemon.
Codex SSE construction was checked against the upstream
[hook tests](https://github.com/openai/codex/blob/main/codex-rs/core/tests/suite/hooks.rs).

Installed executable SHA-256 at the probe (versions can update independently of this worktree):

- Claude: `84590fefe6338be9087f5814b61f9a54c5f21524163a4c127cb5a808e31009f2`
- Codex: `739cda86e15d30a6e2b40cf8dcbbfb988aaf48b305b27065573bb8e9fd41d002`

Verification: both isolated probes passed; `git diff --check` passed; plain `scripts/test.sh`
exited 0 with no suites selected for the documentation-only changes. No live app run was needed
for this to-do.

## Implementation progress

- **Domain in Core:** added the new values and workspace keys beside the broadcast records;
  the current runtime is unchanged. Pure rules cover source-specific finish choices, JQL quoting,
  item identity, complete-read matching, stage ordering, pending work before Then, done conditions,
  idle fresh starts, bounded idempotency and seen retention. Journals distinguish our text from
  quoted host text. Unknown associated enum kinds round-trip inertly. New keys are omitted when
  unused, preserving the current saved-format fixtures.
- **Domain proof:** focused domain tests passed, then plain `scripts/test.sh` passed: 2,179 Core,
  2,013 app, 123 UI and 5 snapshot tests. Existing labelled known issues remained known issues.
  No contract fixtures were regenerated and no live app was launched.
- **Sources:** added paged Jira search with labels, project and assignee fields, label/status lists
  and approximate count; host-wide GitLab and GitHub account listings over `HostAPI`; source readers
  and the project mapper. The poller shares equal reads, uses one pass per source/host, performs
  Jira delta reads with ten-minute full sweeps and backs failures off for five minutes without
  advancing cursors. Unchanged MR timestamps reuse complete thread reads. Partial pages, GraphQL
  errors and malformed entries never publish matches. Explicit repository filters never widen to
  every repository when a saved remote cannot be read. The poller is not wired to task creation.
- **Source proof:** synthetic schema recordings and fake-clock/latch tests cover pagination,
  personal-review and author/assignee queries, rate limits, incomplete reads, query sharing,
  cadence, stale completion after stop and thread-read reuse. The focused tests passed, followed
  by plain `scripts/test.sh` (2,192 Core, 2,016 app, 123 UI and 5 snapshot tests). Source schemas
  were checked against the [Jira search reference](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/),
  [GitLab MR reference](https://docs.gitlab.com/api/merge_requests/) and
  [GitHub search reference](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests).

- **Creation sheets:** Task and Review now follow Ticket/Merge request → Name and branch → Prompt
  → Agent, with completed-step navigation, whole-branch inputs, single-selection chips, description
  choices and a final closing block. The shared Agent/Model/Reasoning row uses selects. Add Project
  prepares its combined folder, Jira-link and worktree-import sheet before persisting anything;
  Edit Project reuses it. Terminal and Divider use the same one-step anatomy. Shelf wording is now
  Archive, with ⌘A routed to Select All during text editing and Archive otherwise. AppKit requires
  the shared menu selector to retain both advertised equivalents; the Archive item targets the app
  explicitly. New Broadcast remains available and its body is unchanged.
- **Creation proof:** new model, description-composition, whole-branch and key-routing tests;
  adapted hosted keyboard/picker and controller race tests retain their behavioral coverage for
  the new step positions and explicit Add/Save action. Plain `scripts/test.sh` passed: 2,194 Core,
  2,021 app, 123 UI and 5 snapshot tests, with existing labelled known issues. Native sheet frames
  were inspected against the before frames, with fixed repository answers for the fixtures;
  ImageRenderer also checked the static chrome where native offscreen captures omit a title.
  Final local images are in `build/operator-signals-creation-final/`. No contract goldens were
  regenerated and no live app was launched. Design-page synchronization remains its later to-do.

- **Engine:** added the router, stage runner, request watch, question rounds, automatic Then
  actions and session keeper beside the current controller. Launch and cleanup intents are saved
  before effects; authority is checked after suspension. Pending stages outrank cleanup, archived
  tasks restore with the same identity, and automatic cleanup keeps unsaved work. Question
  ownership prevents parallel answers and preserves the three-round limit across tool keys;
  human questions are counted only when recorded in chat. Fresh starts close before revoking.
- **Engine proof:** fake-world and scratch-repository tests cover stage ordering, ambiguous project
  and agent choice, retries, takeover and stop races, merge floors, question replay after reload,
  cleanup interrupted by pending work, and interrupted token handover. Plain `scripts/test.sh`
  passed: 2,195 Core, 2,047 app, 123 UI and 5 snapshot tests, with existing labelled known issues.
  The engine remains unwired; no live app or contract goldens were changed.

- **Tools and brief:** added the separate thirteen-tool handler and stable role prompt, with mutable
  signals kept in status and the first JSON message. Task calls carry stage and ownership; the
  transport record can carry a session generation. Keyed effects persist an intent before delivery,
  replay completed results after reload, reject changed arguments and keep uncertain effects from
  being repeated. Normal steering rechecks for a newly arrived question. Pending tool replies are
  transient; notes recover once from the journal even if the state save was interrupted. The digest
  includes project and agent choices but excludes quoted descriptions and saved pending prompts.
  New brief and schema fixtures have their own provenance; the old served contract is unchanged.
- **Tool proof:** focused owner and handler tests passed, including session replacement during an
  Oracle read and partial journal recovery. Capped before/after model runs used Sonnet 5.5 at high
  effort, three runs per scenario per brief, 12 turns and 600 seconds maximum: 9/9 passed for each
  contract across waiting, product questions and hostile item text. Initial Fable attempts hit a
  quota limit before any tool call. A real chat-question miss led to explicit bookkeeping copy in
  the brief, schema and tool reply; final full-stream recordings show the question in chat. Runs
  used a local stub and isolated working directories, without the app or a host integration. Plain
  `scripts/test.sh` passed: 1,633 daemon (1 skipped), 2,200 Core, 2,057 app, 123 UI and 5 snapshot
  tests, with existing labelled known issues. The new tools are not served yet.

- **Daemon:** added a private single-Operator folder and generation-bound token beside per-run
  authority. A hash binds the separately atomic token and manifest files; incomplete, public or
  symlinked authority is not loaded. Register/revoke carry generations, stale revokes leave a
  successor alone, and a failed file deletion remains owed on retry. New authority serves the
  thirteen schemas; legacy authority still serves its current catalogue. Missing or revoked
  shell-gate tokens deny, including revocation during an awaited request. Current input context
  now travels from the proven Claude conversation to Swift, using exact input/cache components
  before a valid percentage estimate. Unknown clears the reading rather than becoming zero or
  inheriting a sibling's count. Launch settings disable idle compaction, including on resume.
- **Daemon proof:** fake-clock/file and real HTTP/socket tests cover authority loading, rotation,
  retries, revocation, schema selection and generation forwarding; hook-router tests cover exact
  context, nulls, sibling isolation and process replacement. Native launch/permissions and both
  wire directions passed. The wire capture was deliberately extended only with `contextTokens`
  (including a synthetic 39,239-token worker), with provenance; strict field parity stays intact.
  Plain `scripts/test.sh` passed: 1,657 daemon (1 skipped), 2,204 Core, 2,057 app, 123 UI and 5
  snapshot tests, with existing labelled known issues. Controllers still use the per-run path.

### Worker guard proof · 15 Nov 2026

Every managed first worker, resumed worker and extra tab receives a private launch environment.
Its Git shim and Claude PreToolUse hook share the shell parser; a pre-push hook checks every ref,
the connected repository, the current branch and head, fresh host default/protection, and ancestry.
It preserves Git's existing configuration entries and chains the project's existing pre-push hook
with the original arguments and stdin. No repository or personal CLI defaults are changed.

The installed Codex **0.169.0** was exercised against a scripted local Responses endpoint in an
isolated repository. Its default login shell reset PATH and initially bypassed the shims; the
per-launch `allow_login_shell=false` setting fixes that. The final factory-built launcher proved
an ordinary own-branch push reaches a local bare origin and `--no-verify` leaves it untouched.
No blanket trust of personal hooks is enabled. Claude uses its per-launch settings file. Both
paths refuse force pushes, other branches and merge commands; unknown host protection refuses a
push. These are publishing guards, not a sandbox against deliberately invoking explicit binaries.

The probe executable is a test-only Swift target sharing the production guard entry, with fake
host facts confined to that executable; the app's guard entry reads the connected host itself and
runs before app/controller construction. `WorkerGuardCodexTests` is opt-in; the gate's scratch Git
integration tests exercise the same launch scripts without accounts or model use.

References: [Git pre-push contract](https://git-scm.com/docs/githooks#_pre_push),
[Git configuration environment](https://git-scm.com/docs/git-config#ENVIRONMENT),
[GitHub repository default branch](https://docs.github.com/en/rest/repos/repos#get-a-repository),
[GitLab project default branch](https://docs.gitlab.com/api/projects/),
[Codex per-launch shell policy](https://github.com/openai/codex/blob/main/codex-rs/core/src/config/mod.rs).

The built native AiTerm executable was also invoked with `--worker-guard argv` in a temporary
home: it refused `git push --no-verify` with exit 2 and created no live app state. This checks the
production entry path as well as the test-only probe, without opening or replacing the running app.

### Activation proof · 15 Nov 2026

The native composition now serves the thirteen Signal tools, polls complete source passes, prepares
and resumes guarded workers, watches source-specific finish conditions and owns the single
Operator window. The five-step Signal sheet previews current matches and uses the shared creation
chrome. The permanent Operator row and Signal headings reuse project task rows while Projects
remain visible. Broadcast launch commands are absent from the live menus.

Regression probes caught and fixed a stale-request repository binding, selection observation that
redrew the permanent row on an unrelated arrow key, recovered-launch adoption without a repeated
prompt, and confusing “Merged” with permission to merge. Automatic merging requires its separate
opt-in. A native idle-close RPC checks the exact conversation, prompt and human input before
closing a CLI; the previous wire frames remain unchanged. Isolated hosted snapshots cover the
Signal sheets and full sidebar (`build/operator-signals-sheets-native`); the JQL field, match list,
footer and sidebar hierarchy were inspected. No running app or personal CLI defaults were changed.

Activation gate: plain `scripts/test.sh` passed (1,668 daemon tests; 123 UI, 2,227 Core, 2,083 app and 6 snapshot tests; existing labelled known issues retained).

### Deletion proof · 15 Nov 2026

The former broadcast controller, board, setup sheet, handler extensions, brief, scheduling,
publication and summary machinery and their feature-specific tests have been removed. Ordinary
Archive, row, context, window and save-budget coverage now uses Signal fixtures. The single
Operator retains a private append-only activity log, including skipped items; no Activity view
remains. The thirteen-tool contract has a complete saved-format fixture, captured through
`StateStore` with fixed synthetic identities. The historical input proves that old tasks load and
that the next save drops `runs`, `foldedRuns` and nested `operated` records, including archived
items. Per-run daemon tokens and generation-less RPC overloads are gone. The wire capture's only
changed existing frame is `operator.request`, which now carries its required generation.

Focused proof passed: 54 app UI/cache/window tests and 55 Core persistence/wire/log tests, then
12 controller/engine/persistence tests after restoring activity logging. All 1,598 daemon tests
passed. The release note explains ending installed broadcasts before the update; only historical
eval data is retained for the before/after comparison.

Deletion gate: plain `scripts/test.sh` passed: 1,598 daemon, 123 UI, 999 app, 1,677 Core and 1 snapshot test. Existing labelled known issues remained known issues.

### Sidebar, pause and Take Over proof · 15 Nov 2026

The whole badge line now decodes into an act, holds a short act for three seconds, changes directly
between acts and returns on hover in 0.35 seconds. Reduce Motion swaps without scrambling. Signal
headings participate in keyboard selection and fold independently of projects; only folded headings
show status counts. Switch On previews its current start count. The permanent row, questions,
watching, blocked, completed, paused, closed-window and removed-signal states use the same row grid.
Thirteen native, hidden-window drawings were inspected in `build/operator-signals-row-states`.

Pause and Switch Off defer every engine effect and save the workers told to finish their turn, so
Resume can send carry-on after a restart. Take Over revokes the stage, withdraws its questions,
refreshes every worker guard's ownership, unfolds the project and shows the picked toast. Guard
preparation serializes scope writes and refuses an older ownership or stage. Notifications aggregate
questions into the single Operator chat, including delivered-note reconciliation at startup.

Behavioral red tests exposed the action hold, per-source launch pause, takeover authority and stale
guard writes before their fixes. The plain gate passed: 1,598 daemon tests (one skipped), 123 UI,
1,009 app tests (one known issue), 1,678 Core tests (three known issues), and the snapshot check.
Two daemon queue tests now use an unstarted fake service: the service's periodic poll had raced
their explicitly queued callers in one gate run. Their focused check and the subsequent gate pass.

### Settings proof · 15 Nov 2026

Settings now uses the picked Operator, Oracle and Steer the Operator groups, with their roles,
limits, question rounds and real example instructions. The Oracle’s choices share one Agent ·
Model · Reasoning row and stay saved while off. The old Autonomy fields and `Slices` type are gone;
a saved profile with those keys loads and drops them on its next save. Cancel, unchanged Save,
model selection and Oracle choice retention keep their coverage.

The two full native Settings drawings (Oracle on and off) were inspected in
`build/operator-signals-settings`. The plain gate passed: 1,598 daemon tests (one skipped), 123 UI,
1,009 app tests (one known issue), 1,679 Core tests (three known issues), and the snapshot check.

### Fresh-session and native-boundary proof · 15 Nov 2026

The native controller test follows current input context from 50k to 150k, closes the old CLI,
revokes its authority and opens generation 2 with the saved question and quiescent Oracle round.
Active checks still prevent a fresh start; saved rounds travel in the digest. A saved closing
handover also recovers after a lost reply by confirming the old window is absent, rather than
closing a window by a stale number. A delivered wake stays pending until `run_status` reads it,
including after restart, so an old idle snapshot cannot close the chat just woken.

The digest carries pending worker messages, current worker observations, skipped items, source
failures, open Oracle rounds and resolved answers still awaiting delivery. Worker answers bind the
stage, ownership, terminal session, conversation and full assistant-record fingerprint; a repeated
caption cannot reuse another turn’s answer. Successfully delivered person answers are marked and
leave the pending digest. Oracle settings use a monotonic revision: off/on cycles discard the old
check, and a stale shell check is retried under the current setting. Saved standing instructions
reach the existing chat through a settings wake and status; the current brief fixture records that
intentional rule change and its provenance.

The native proof also covers related ticket/request descriptions found through linked projects and
branches (descriptions only), early API failures blocking a worker, mandatory Claude for the
Operator, a blocked stage refusing Resume while its worker is active, the final local-head check
at merge, and a late branch deletion rechecking pause, ownership and other live tasks.

All regression tests were observed red before their logic changed. The plain gate passed: 1,598
daemon tests (one skipped), 123 UI, 1,020 app tests (one known issue), 1,680 Core tests (three known
issues), and the snapshot check. No installed app, live Operator or host workflow was switched.

### Performance and recovery proof · 15 Nov 2026

Watching tasks do not read worker transcripts. Read-only task details share in-flight reads and
expire by the configured cache/budget; claim, repository, request and connection identity form
the cache key. Finish checks fetch only their selected facts; merge checks always read fresh.
Journals retain twenty state entries, transitions one hundred, closed questions fifty and snags
one hundred; idempotency expires at seven days/five hundred entries. Unresolved questions and
undelivered current-worker answers remain. Seen retention protects live and pending item identities.
The default digest gives one journal entry per task without repeating its prompt; detailed status
retains the prompt and twenty entries. A thousand-task payload stays below one MiB without a task
or concurrency cap. Weekly usage stays visible and the first native launch reuses the 80% rule.

Sidebar projections exclude journals, launch history and other bookkeeping. Headings compare their
drawn facts alone; menus resolve current saved tasks when invoked. Automatic cleanup checks resource
identity after preflight, so a harmless journal append cannot strand completed work. Own permission
prompts outrank acts, runtime failures reach the cached main row, and notifications select its
managed window through the ordinary focus path.

Regression tests also caught native watch boundaries: Operator-judged work keeps watching until an
opted-in merge is confirmed; discovered requests gain ordinary clickable badges; a merged request
can be found even before its first watch. Branch discovery retains open-request preference and uses
the hosts' complete history queries ([GitLab](https://docs.gitlab.com/api/merge_requests/),
[GitHub](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests)); publishing lookup is unchanged.
Steering returns a waiting task to working and journals the instruction as quoted data before
delivery. A missing first/extra worker eventually blocks for inspection without duplicating its
launch. A blocked worker no longer receives a stale pause carry-on. Oracle jobs receive the current
standing instructions and discard results if those instructions change while they run.

Behavioral red tests preceded these fixes. Plain `scripts/test.sh` passed: 1,598 daemon tests
(1 skipped), 123 UI, 1,040 app (1 known issue), 1,683 Core (3 known issues), and the snapshot suite.
No live app switch or host write was performed.

### Documentation and design reference proof · 15 Nov 2026

Rewrote the Operator guide for Signals, shared item stages, questions in chat, publishing guards,
source-specific completion and explicit automatic merging. README, configuration, keyboard,
windows, status, architecture, testing and release guidance now agree; release guidance requires
ending a running broadcast in the installed build before switching. Current fixtures and the
immutable historical evaluation inputs are distinguished by their actual owners/paths.

The UI README and pattern inventory name the shipped types. The design page retains the existing
Palette/Metrics foundations and primitive specimens, replaces the old board/runtime inventory with
57 source-verified pattern types/files, and uses embedded native renders for Signals, creation and
Settings. The implemented proposal and its renderers are removed; Proposals retains its intro and
“No open proposals.” The unused board-height token and its obsolete assertions are removed.
A hidden Retina native render refreshed `docs/desktop.png`. Headless Chrome inspection checked the
three tabs, loaded native images, source names and the page at real point sizes; the local HTML
was synchronized without publishing the external artifact. No live app was replaced.
Plain `scripts/test.sh` passed after synchronization: 1,598 daemon (1 skipped), 123 UI,
1,040 app (1 known issue), 1,683 Core (3 known issues), and the snapshot suite. The protocol guide
also documents required generations, fixed event/UUID wakes and safe idle-conversation closure.

### Final review and release proof · 15 Nov 2026

All sixteen to-dos are implemented, one commit per step. New logic was exercised red before its
fix, including native launch, continuation, worker answers, publishing and fresh-session boundaries.
The research and the named design frames were read before implementation; the creation-sheet picks
take precedence over the older sidebar frames.

The independent Claude review finished with no findings. Its findings were checked and settled:

- Round one: unsupported saved enum values now round-trip without making the workspace unsavable
  or runnable; current copy and the unplugged-power guard use Signals. The request to exclude
  manually created matching tasks was pushed back against decision 3: they intentionally continue,
  after their current turn. The creation preview and guide now make that behavior explicit.
- Round two: scoped status cannot acknowledge coalesced updates for other tasks. A definite idle
  close refusal restores the current chat; uncertain close outcomes retain the durable handover.
  A reproduced FIFO case also now prevents a new match overtaking queued stages.
- Round three: a queued stage uses its own permitted agent; only explicit pre-close refusal codes
  restore a closing chat; refused scoped status is logged with its actual error. Round four
  accepted those corrections without findings.
- Round five: queued stages in watching, completed and archived tasks are retried when all workers
  become idle, without requiring another match. Work observed during a refused finish wakes the
  Operator once it ends, including unkeyed companion tabs and a refusal between reconciliation
  ticks. Round six accepted both corrections without findings.
- Round seven accepted the final native launch correction without findings: saving an unsent
  launch intent must allow its first RPC, while a sent launch still waits for its first hook.
  Existing live work, questions, pause, authority and recovery guards remain in force.

No Critical, Important or listed Minor finding remains open. The final focused native/controller
run passed all 22 tests. The plain project gate passed 1,598 daemon tests (one skipped), 123 UI,
1,050 app (one existing known issue), 1,686 Core (three existing known issues), and the snapshot
suite. The signed `build/AiTerm.app` passed resource, dependency and signature verification without
launching it. Native creation, sidebar and Settings renders were inspected, and the synchronized
HTML's three tabs and embedded images were checked in isolated headless Chrome.

Both the frozen historical contract and current Signal brief passed all nine isolated runs on
`claude-sonnet-5-5` at explicit high effort: three each of unavailable app, product question and
hostile source text (eighteen passes). Each run was capped at twelve turns and six hundred seconds.
`app/build/operator-signals-eval-final/table.txt` and its local streams/calls/replies/grades retain
the evidence; fixture provenance records the comparison. No historical fixture was regenerated.

The final step's commit is followed by plain `scripts/test.sh all` on its clean HEAD, with no
`SWIFT`, `PYTEST` or `AITERM_TEST_PATHS` override. The gate history owns that exact-HEAD release
proof, so this record does not require a further commit after it. The installed app and running
sessions were left undisturbed. The real Jira-to-MR flow still requires the maintainer's go for a
live switch, as agreed; no merge, push, PR or external design-page publication was performed.
