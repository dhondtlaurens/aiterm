# 2. Triggers end to end, typed by hand

Implementer: Claude Opus 5.5. Depends on: step 1 (`GitLabQuery`, `GitHubQuery`, `SignalQueryAccount`,
`GitLabQueryReader`, `GitHubQueryReader`, `JiraQueryReader(client:jql:now:)`, the accounts' `matches(…)` done
read). When this step ends, a person can create a signal whose Start and Done are queries they type, it runs,
and the old condition and event machinery is gone. The query writer (Describe it, Write the query) is step 3.

## Why

A signal today is `source: SignalSource` (Jira condition chips or JQL; a GitLab or GitHub event with two
toggles) plus `finish.doneWhen: DoneWhen` (a fixed list per source). After this step it is a **Start trigger**
and a **Done trigger**, each a source kind (Jira, GitLab, GitHub), a description (empty until step 3) and a
query, plus `then`, `mergesWhenReady` and `deletesMergedBranch`. Matching uses the step 1 readers. Done is an
**edge**, review or own task is decided **per merge request**, the Operator no longer judges done, and old
signals are not kept.

## Today

Re-run before changing anything: `git grep -n "SignalSource\|JiraConditions\|RequestConditions\|JQL\.\|DoneWhen\|choices(for:\|isValid(for:\|operatorJudge\|configuration.source\|mergesWhenReady\|\.watching(" -- app daemon scripts`.

- **Model** (`app/Sources/AiTermCore/Operators/Signals/`):
  - `Signal.swift`: `Signal.source`, `Signal.finish`; `isRunnable = enabled && source.isSupported && finish.isValid(for: source)`; `SignalFinish` (`doneWhen`, `then`, `mergesWhenReady`, `deletesMergedBranch`, `choices(for:)`, `isValid(for:)`); `DoneWhen` (a `KindTaggedEnum`).
  - `SignalSource.swift`: `SignalSource`, `isSupported`, `JiraConditions`, `RequestConditions` (`Event`), `JQL`.
  - `SignalTask.swift`: `operatorJudged`; `TaskPhase.watching(DoneWhen)` is saved as `{"kind":"watching","value":…}`; `SignalStage.configuration` is a full copy of the `Signal`, made when a match is decided, and every runtime reader uses it, not `state.signals`.
  - `StageMachine.swift`: `continueStage` resets `startedAt`, `waitingOn`, `operatorJudged`; `.workRequested` clears `operatorJudged`; `SignalAction.watch(DoneWhen)` / `.finish(DoneWhen)` (the latter ignores its payload).
  - `DoneCheck.swift`: `Facts`, `evaluate(_:facts:stageStartedAt:)`; `SignalWaitFacts` (`reviewers`, `openThreads`, `mergeBlockers`).
  - `OperatorDigest.swift`: `TaskLine.finish` (the stage's whole `SignalFinish`), `signals` (`state.signals` whole). `run_status`, `read_task` and the Oracle's merge veto use it.
  - `MatchDecision.swift` (`SignalStage(configuration: signal)`), `AppState+Signals.swift` (`isRunnable`).
  - `Sources/`: `ReviewRequestedReader`, `MyRequestReader`, `SignalAccountReading`, the `requests(event:)` reads in `GitLab/GitLabAccount.swift` and `GitHub/GitHubAccount.swift`, `JiraQueryReader(client:conditions:now:)`.
- **Sidebar core**: `Sidebar/OperatorLine+Waiting.swift` (`waiting(for: DoneWhen, facts:, request:, ticket:)`, a line per case; `mergeBlockers` short-circuits to merging), `Sidebar/OperatorLine+Task.swift` (`.watching(condition)` → `.waiting(for:)`).
- **App** (`app/Sources/AiTerm/`):
  - `Operators/ItemRouter.swift` `makeTask`: `review = (gitLab/gitHub && event == .reviewRequested)`, with a silent `default: review = false`. `kind == .review` makes the worker unable to push (`WorkerGuardLaunch`), skips branch deletion, uses the review lock on restore. The checkout follows `task.mr != nil`, not `kind`. The router sees only `SignalItem`s; `SignalObservation.read.accountUser` is not passed in.
  - `Operators/StageRunner.swift` `run(id)`: guards, restores an archived task, then in `activity.acting("starting its worker")` saves the launch intent and flushes, journals, `ports.prepare` (checkout), `ports.launch`; every `await` is followed by `holds(claim, generation:)` (phase still `.launching`). `finish(id, action:, judged:)` sets `operatorJudged`.
  - `Operators/RequestWatch.swift` `pass()`: reads `.working` and `.watching` tasks, skipping busy workers and held effects; `check()`: `met = DoneCheck.evaluate(doneWhen…)`, saves `watchedRequest`, `task.mr`, `waitingOn`; stops for an unjudged `operatorJudges`; the merge path (`canMerge`, Oracle `mergeVeto`, re-read, `ports.merge`, confirming read); with merges on nothing finishes until merged; `.reached` → `stages.finish(id, .finish(doneWhen))`, then `ThenRunner`.
  - `Operators/SignalHostIO.swift` `read(task)`: builds facts per `doneWhen` (ticket by `JiraQueryReader(conditions: JiraConditions(jql: "key = …"))`, request by number or branch, reviewers, approvals, threads, my review posted, with a silent `default: break`); `merge()` guards `mergesWhenReady`; `binding()` checks origin and repository.
  - `Operators/SignalConnections.swift`: `reader(for: SignalSource)`, `registrations(for:)` (read key = hash of token, Jira email and the query; `isJira` drives the ten-minute Jira sweep).
  - `Operators/SignalClaim.swift` L24 `allows(in:)`; `Operators/SignalOperatorController.swift` L143 (`jira_search` builds `JiraConditions(jql:)`), L313 `save()` guard; `Operators/SignalOperatorToolHandler+Calls.swift` `.finishStage` (done/skipped → `.finish(.operatorJudges)` or `.watch(doneWhen)`; `judged:`).
  - `HeadingValue.swift` (`Kind.signal(source:…)`, help text from `JQL.compile` or fixed event text, "This version cannot run these finish settings."); `Views/SidebarHeadings.swift` `ProviderIcon.source(of:)`.
  - Sheet: `AppController+Signals.swift` `presentNewSignal` (preview through `links.reader(for:)`, Jira metadata and the person search, `save`); `Operators/SignalModel.swift`; `Views/Operators/SignalSheet.swift`, `SignalStartsStep.swift` (with `SignalMatchPreview`), `SignalDoneStep.swift` (with `SignalDoneSummary`), `SignalConditionPicker.swift`.
  - Snapshots: `Snapshots/SignalSnapshots.swift` (28 files: kind × event × step plus three), `SignalSidebarSnapshots.swift`, `ReadmeDesktop.swift`.
- **Saved state**: `Models.swift` decodes `signals` strictly (one bad entry fails the load); `StateStore.swift` `OperatorRecordsReset` drops an undecodable `operatorSession` and each task's undecodable `signalTask` (keeping `takenOver`), keeps a `before-reset` copy; it never touches `signals` or `signalSeen`. `scripts/reset-operator-state.sh` deletes `signalTask` and `operatorSession` (tested by `scripts/test-reset-operator-state.sh`).
- **Contracts**: `daemon/aitermd/signal_tools.json` equals `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/tools.json` byte for byte (`SignalOperatorContractTests`); `finish_stage`'s description says "Done watches its configured source condition unless the Operator judges it done". `OperatorLaunch.brief` (around L220) equals the fixture `brief.md` and says "Done hands the task to its source-aware done condition". `state.json` in that folder is the `SignalSavedFormatTests` golden (`AITERM_RECORD_SIGNAL_STATE=1 scripts/test.sh swift -- --filter SignalSavedFormatTests` re-records); `state-0.58.json` is read by `StateStoreUpgradeTests`; `PROVENANCE.md` logs every change.
- **Test support**: `app/Tests/AiTermTestSupport/Builders.swift` `Signal.make()` and `SignalWorld.signal(…, done: DoneWhen = .operatorJudges)` default to the Operator judging; engine, tool-handler, agent-choice and worker-IO tests rely on `finish_stage done` going straight to done.

## Change

1. **`SignalTrigger`** (new, `Operators/Signals/SignalTrigger.swift`): `source` (an open string enum `jira`,
   `gitLab`, `gitHub`, unknown kept), `description: String`, `query: String`. Validation per source and role:
   Jira non-empty; GitLab through `GitLabQuery` (start or done entry point); GitHub through `GitHubQuery`. A
   helper says the Start query's role (`author`, `assignee`, `reviewer`, none) for the sheet's merge offer.
2. **`Signal`**: `start: SignalTrigger`, `done: SignalTrigger`, `finish: SignalFinish` with `then`,
   `mergesWhenReady`, `deletesMergedBranch` only. `isRunnable` = enabled, both triggers valid, `then` known,
   `deletesMergedBranch` only with remove, merge only where offered (rule 9). Delete `DoneWhen`,
   `SignalFinish.choices`, `isValid(for:)`, `SignalSource.swift` whole (`SignalSource`, `JiraConditions`,
   `RequestConditions`, `JQL`; keep a JQL quoting helper only if a caller still needs one, e.g. `key = "…"`).
3. **Readers and connections**: `SignalConnections.reader(for: SignalTrigger)` gives `JiraQueryReader(jql:)`,
   `GitLabQueryReader` or `GitHubQueryReader`; `registrations` keys on source kind and query. Delete
   `ReviewRequestedReader`, `MyRequestReader`, `SignalAccountReading`, `requests(event:)`. `jira_search` uses
   `JiraQueryReader(jql:)`.
4. **Done as an edge with a baseline.** Add to `SignalTask` a per-stage stored observation of the done query
   (matches / does not match), cleared wherever `continueStage` resets `startedAt`. In `StageRunner.run`,
   before the launch intent is saved, read the done query for the task's item (through a new port backed by
   `SignalHostIO`) and store it; an unreadable read holds the launch (the stage stays `.launching` with a
   reason, retried on the next reconcile with the same backoff the source uses); recheck `holds` after the
   await. A Jira-started task with a GitLab or GitHub done query and no merge request yet stores "does not
   match". `RequestWatch` keeps skipping busy workers: each read compares with the stored observation; a
   change from "does not match" to "matches" is done; the stored value is updated on every complete read. A
   merged or closed merge request is done regardless. The done read: Jira `key = "<KEY>" AND (<query>)`
   through `JiraQueryReader(jql:)`; GitLab or GitHub through the account's `matches(…)` on the task's request
   (found as today by number, else by branch). A Jira done query on a merge-request task uses the ticket key
   found in its branch or title (`TicketMergeRequests`); none means "does not match".
5. **`TaskPhase.watching`** loses its `DoneWhen` payload; `SignalAction.watch` and `.finish` take none.
6. **Remove the Operator's judgment of done**: `operatorJudged` (field, facts, resets), `judged:` on
   `StageRunner.finish`, the `.operatorJudges` branches in `RequestWatch`, `SignalHostIO` and the tool
   handler. `finish_stage` with `done` or `skipped` moves the stage to watching; `blocked`/`failed` as today.
7. **The waiting line** (`OperatorLine+Waiting`): a watching task's line is the stage's Done trigger
   description when it has one, else its query, cut to the line; merge blockers keep their line. Drop the
   `reviewers`/`openThreads` facts that only served the fixed list, unless the merge path still uses them.
8. **Review or own per merge request**: pass the read's account user into `ItemRouter.makeTask`. A merge
   request item is a review task unless the account is its author or one of its assignees (case-insensitive);
   a ticket item is always an own task. No `default:` fallthrough.
9. **Merge when ready** stays and no longer waits on a done condition: when on, and the task is not a review
   task, AiTerm merges once the host's readiness says it can (as `canMerge` does today), after the Oracle's
   veto, with the same re-read and confirmation; nothing finishes before merged while it is on. It may be on
   only when the Start source is Jira or the Start query's role is `author` or `assignee`.
10. **`OperatorDigest`**: each task line carries its stage's own Start and Done triggers (source and query)
    and finish from `current.configuration`; the signals list carries each signal's current ones.
11. **Saved state: nothing.** Old signals are not handled at load in any way (the maintainer: nobody has
    signals saved yet). `Models.swift`, `OperatorRecordsReset` and `scripts/reset-operator-state.sh` stay as they
    are. A test fixture holding old-shape signals for an unrelated test (`state-0.58.json`) loses those signals
    and their seen rows, with a `PROVENANCE.md` line.
12. **The sheet without the writer**: steps Signal (name only, with the intro text), Starts when, Prompt,
    Agents, Done when. A trigger step: "Reads" segmented control (Jira, GitLab, GitHub) and the query in a
    `PromptStep`-style mono editor at a new named Metrics height (56 pt; add it to `Metrics.swift` and the
    AiTermUI README), with help naming the syntax; Starts when keeps `SignalMatchPreview`; Done when adds
    Merge it when it's ready (offered per rule 9), Then and branch deletion, and the closing summary from
    the queries. A GitLab query error shows as help under the field in warning tone. `SignalModel` holds the
    two triggers and loses `jira`, `queryMode`, `event`, toggles, `requestProjects`, metadata, assignees and
    `done`; `AppController+Signals` loses the metadata and person-search closures (`signalUsers` in
    `JiraClient+Signals` goes; labels and statuses stay for step 3). Delete `SignalStartsStep.swift` (move
    `SignalMatchPreview` into the new step file) and `SignalConditionPicker.swift`.
13. **Heading and icon**: `HeadingValue` shows "Starts: <query>" and "Done: <query>"; `ProviderIcon` uses the
    Start trigger's source.
14. **Contracts**: `finish_stage`'s description becomes "Record a stage result with evidence. Done hands the
    stage to its Done trigger, which AiTerm checks against the task's own ticket or merge request. Pending
    stages outrank Then." in both `signal_tools.json` and the fixture `tools.json`; `OperatorLaunch.brief` and
    `brief.md` say the same in their own sentence. Re-record `state.json` with the switch above; rewrite
    `StateStoreUpgradeTests`' expectation for `state-0.58.json` (its old-shape signals are dropped, tasks
    keep loading). Add a dated `PROVENANCE.md` line for each fixture: "Signal triggers, step 2: …".

## Keep

- `SignalSeen`, `MatchDecision`'s re-match logic (an item that stops matching and matches again continues
  its task: this gives review rounds), `pendingStages`, Then, archive and restore, the Oracle's merge veto,
  `WorkerGuard`, `TaskLauncher`'s checkout rule (`task.mr != nil`).
- `SignalWork` and the description checkboxes.

## Decisions already taken

- No compatibility and no handling: nothing reads, converts or drops old signals. Old `signalTask` records are
  cleared by the existing reset, as for any record shape change.
- The done edge compares with the last stored observation; no reads while a worker is busy.
- The review rule is per merge request; a Jira-started task stays an own task even after it gets an MR.
- `review-state:` in a Done query follows the role it names, else any reviewer (step 1 implements this).
- Copy: no em dashes; "Reads", "Starts when", "Done when", "Merge it when it's ready".

## Tests

- Rewrite `Signal.make()` and `SignalWorld.signal(…)` to build triggers (default Start `jira` with a JQL,
  Done `jira` `status = Done`), and fix the suites that relied on `operatorJudges` finishing at once: make
  them drive the done edge or the watching phase explicitly. Keep each test's subject.
- Delete with the behaviour: `DoneWhen`/`SignalSource` byte pins in `SavedEnumBytesTests` (replace with pins
  for the trigger's source kinds and `TaskPhase.watching` without payload), `doneChoices`, the event and
  condition tests in `SignalModelTests`/`SignalSourceTests`, the per-`DoneWhen` waiting lines (replace with
  description/query lines).
- Add: done edge (baseline stored before launch; a match during the first turn ends the stage at the next
  read; a done query matching at baseline does not end it; a later fresh match does; merged or closed always
  done; an unreadable baseline holds the launch); review or own per merge request (author, assignee, neither,
  case); merge when ready never on a review task and merges without a done condition; `OperatorDigest` keeps a
  stage's Done trigger after the signal is edited and after it is removed.
- Snapshots: every step of a Jira and a GitLab signal, a refused GitLab query, the Done step with merge
  offered; update `SignalSnapshotTests`' expected count. Sidebar snapshots with the new waiting line.

## Proof

`scripts/test.sh swift -- --filter <each touched suite>` while iterating; plain `scripts/test.sh` green;
`scripts/snapshots.sh build/snapshots-step2` and read the signal sheet and sidebar PNGs against the AiTermUI
README rules and the proposal "Signals: a Start and a Done trigger" on the Proposals tab of
`docs/design/design-system.html` (option A; the Describe field comes in step 3).

## Done when

No reference to the deleted types remains (`git grep` above is empty but for docs and the plan), a signal can
be created with typed queries and runs in the journey tests, every test passes.

## Not in this step

The query writer, Describe it and its button, the writing state (step 3). `docs/operators.md`, the design
page sync (step 4).
