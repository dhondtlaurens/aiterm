# Signals: start on a schedule, finish when the Operator decides

Status: agreed 23 Nov 2026 on `feat/cron`. Challenged by Codex in four rounds on 23 Nov 2026 (the last: ready with
one Minor fix); every finding is fixed below (run branches carry the signal id and an untruncated time, an agreed Operator done waits for a merge when
ready, the daemon's tool schema and `OracleLaunch`'s completion question are owned, exhaustive switches move with the
new kinds, a run's origin survives another signal continuing its task, and the tooltip's owner `HeadingValue` is named). Visual design: the proposal "Signals: a schedule to start, the
Operator to finish" on the Proposals tab of `docs/design/design-system.html`, options 1B and 2B picked and drawn
for every step (local file; the live artifact is published later from a session that can afford its read).

## Goal

A signal starts only from an item a Jira, GitLab or GitHub query finds, and is done only when a query matches that
item. Two jobs don't fit: work that should run at a time ("every Monday at 9am, update the dependencies"), which has
no item, and work whose end no query expresses ("investigate this"). Add **A schedule** as a way to start, written
as cron from your own words the way a query is written, and **The Operator decides** as a way to finish, judged by
the Operator and confirmed by the Oracle, on every signal.

## Approach

The Start trigger gains a schedule kind and the Done trigger an Operator kind, both inside the existing
`SignalTrigger` (new `Source` cases plus one optional field), so every saved signal decodes unchanged and an older
build reads a new kind as `unknown` and does not run it. A schedule is a cron expression AiTerm parses itself; the
Operator's tick asks it for the latest due time and turns a firing into a synthetic item, `run`, that flows through
the same `ItemRouter` / `MatchDecision` / `StageRunner` path as a ticket: one new task per firing, in the signal's
project. An Operator Done replaces the Done query with an Oracle-checked `finish_stage(done)`; a merged or closed
merge request still ends the stage, as it does today.

### What the grill decided

1. **A firing is a new task.** Each run gets its own task, branch and worktree in the one project the signal names
   (a project picker under the schedule). Title `<signal name> · <d MMM yyyy HH:mm>` (the scheduled time). The
   branch is the signal name's slug, cut so that an untruncated `-<first 6 of the signal id>-yyyymmdd-HHmm` suffix
   always fits (the id keeps two signals with the same name, firing in the same minute, apart): `BranchNaming.slug` cuts at 48 characters, and a cut timestamp would let a later run adopt an earlier
   run's branch and worktree (`TaskCreator.checkOutWorker` adopts an existing one). A run never continues another task.
2. **One run at a time per signal.** A firing while the signal's previous run is unfinished (`!isFinished`) is skipped,
   with its reason in the signal's tooltip and activity log, as an item without a project is skipped today. A run's
   task records its origin (`SignalTask.scheduledRun`, the signal and scheduled time), kept across stages, so the run
   stays recognisable after another signal continues its task (a run's merge request matching an `assignee:@me`
   signal, as one item keeps one task today): the overlap check looks for any unfinished task with this signal's origin.
3. **Missed firings: only the latest, once.** AiTerm closed, the Mac asleep, or the Operator paused at the scheduled
   time: when it is back, the most recent missed time fires once and older ones are dropped. The journal records the
   scheduled time and the actual start. Times before the signal was created, or missed while it was switched off,
   never fire: creating, switching on, or editing the schedule sets the signal's `scheduledFrom` to now. A per-signal
   cursor (the last scheduled time fired or skipped) is saved in the same flush as the task it creates, so a restart
   never fires one time twice, and is not pruned with `signalSeen`.
4. **Write cron** runs the Operator's Claude once, headless and read-only, exactly as Write JQL does, with the
   current date, time and time zone. AiTerm checks the answer with its own parser; a refused answer goes back once
   with the error. Standard five fields (minute, hour, day of month, month, weekday), lists, ranges, steps, month and
   weekday names, Vixie's OR rule when both day fields are restricted; no seconds, no `@reboot`. Times are the Mac's
   current time zone; a wall-clock time a DST change skips fires at the next valid minute, a repeated one once.
5. **The Operator Done is offered on every signal.** Its description is optional guidance for the Operator and the
   Oracle, not a condition AiTerm checks; empty means "the prompt's work is complete". `finish_stage(done)` on such a
   stage goes to the Oracle with the stage's prompt, the description, the evidence and the worker's last turn, up to
   three rounds per stage, as `answer_worker` does: its yes finishes the stage (`.finish`, then Then); a critique
   returns a `challengeId` for the Operator to act on; three disagreeing rounds, a call for the person, or an Oracle
   that is off or unavailable make the Operator ask the person in its chat, and `finish_stage` with `fromQuestion` and
   the recorded yes finishes it. A merged or closed merge request still ends the stage. The completion check is its
   own `OracleLaunch.Question` (bound to `finish_stage`, three rounds, agree / critique / your decision), not
   `secondOpinion`, which allows one round and reads every answer as agreement. **With Merge it when it's ready**, an
   agreed done does not skip the merge: when the stage's merge request is open and AiTerm has not merged it, the stage
   goes to watching instead of finishing; AiTerm merges once the host says it can (`RequestWatch.check`), hands back to
   the worker as today, and the next agreed done, or a merge or close by anyone else, ends it. With no merge request,
   an agreed done finishes.
6. **Sheets (1B, 2B).** Starts when opens with **Starts on** An item · A schedule; under An item today's step,
   unchanged. Under A schedule: Describe it with **Write cron**, **Cron**, **Project**, and **Next runs** (four times)
   in place of the match preview. Done when opens with **Done when** A query matches · The Operator decides; under A
   query matches today's step, unchanged; under The Operator decides: **What done looks like (optional)**, no query.
   A new scheduled signal's Done opens on The Operator decides, an item signal's on A query matches.
7. **On a scheduled signal**: no description checkboxes on Prompt (a run has no ticket or merge request); a Done
   query reads GitLab or GitHub against the merge request the run's branch opens (Jira is disabled in Reads, with a
   tooltip: a run has no ticket); **Merge it when it's ready** is offered, since that request is the person's own.
   The closing summary names the cron and the first run.

## Files

**AiTermCore**
- Modify `Operators/Signals/SignalTrigger.swift`: `Source` gains `schedule` (Start only) and `operator` (Done only),
  saved by name with the existing unknown fallback; optional `project: UUID?` for a schedule; `itemSources` for the
  Reads row; `refusal(start:)` checks cron for a schedule, refuses a schedule as Done or Operator as Start, and a
  schedule without a project; `offersMerge` true for a schedule.
- Create `Operators/Signals/Queries/Cron.swift`: parse with token-naming refusals; `next(after:in:)` and
  `latest(atOrBefore:after:in:)` over a `Calendar`; a plain reading of the fields for the help line.
- Modify `Operators/Signals/Signal.swift`: optional `scheduledFrom: Date?`; `isValid` for the new kinds;
  `mergesWhenReady` allowed on a schedule.
- Modify `Operators/Signals/Item.swift`: `ItemRef.run(SignalRunRef)` (signal id, scheduled time), kind `run`, identity
  `run:<signal>:<ISO time>`.
- Create `Operators/Signals/ScheduleDecision.swift`: the pure rule: given signals, their cursors, `scheduledFrom`,
  now and whether the Operator may act, which run is due per signal, which are skipped (previous run unfinished,
  project gone) and the new cursors.
- Modify `Operators/Signals/MatchDecision.swift`: a `run` item never continues an existing task; its project is the
  signal's; skip with reason when the signal's previous run is unfinished.
- Modify `Operators/Signals/SignalTask.swift`: optional `scheduledRun: SignalRunRef?`, the run a task started from, kept
  across stages and never cleared by a later signal's stage.
- Modify `Operators/Signals/AppState+Signals.swift` and `Models.swift` (`AppState`): the per-signal schedule cursor,
  an optional sparse field; kept out of `signalSeen` pruning.
- Modify `Operators/Signals/DoneCheck.swift`: an Operator Done never matches a query; merged or closed still ends it.
- Modify `Operators/Signals/Queries/QueryWriter.swift`: the cron prompt (syntax, examples, now and time zone).
- Modify `Operators/Signals/OperatorDigest.swift`: a signal's schedule, next run and Done kind; a stage's run time.
- Modify `Operators/Signals/OperatorLaunch.swift`: the brief's lines on scheduled runs (no item text) and on
  `finish_stage` for an Operator Done (Oracle rounds, `challengeId`, `fromQuestion`).
- Modify `Operators/Signals/OperatorTool.swift`: `finish_stage` accepts optional `challengeId` and `fromQuestion`.
- Modify `Operators/OracleLaunch.swift`: a completion `Question` with its prompt, `finish_stage` binding, three-round
  limit and verdict reading (agree, critique, your decision).
- Modify `Operators/Signals/Sources/ItemProjectMapper.swift`: a `run` maps to its signal's project (exhaustive switch).

**daemon**
- Modify `daemon/aitermd/signal_tools.json`: `finish_stage` gains optional `challengeId` and `fromQuestion`. Its schema
  has `additionalProperties: false`, and the contract test compares it byte for byte with the fixture.

**AiTerm**
- Create `Operators/SignalScheduler.swift`: on the Operator tick (and on wake, network return and resume), runs
  `ScheduleDecision` and hands due runs to `ItemRouter` as a complete observation for that signal.
- Modify `Operators/ItemRouter.swift`: `makeTask` for a run (title, project, no descriptions); record skips.
- Modify `Operators/SignalOperatorController.swift` / `AppController+Signals.swift`: register schedule signals with
  the scheduler instead of the poller; set `scheduledFrom` on create, switch on and schedule edits.
- Modify `Operators/SignalConnections.swift`: no host read for a schedule Start or an Operator Done (exhaustive
  switch).
- Modify `Operators/SignalHostIO.swift` and `RequestWatch.swift`: an Operator Done reads no query (baseline is
  "doesn't match"), still watches merged and closed; a run's Done query reads its branch's merge request.
- Modify `Operators/SignalOperatorToolHandler+Calls.swift`, `OracleConsult.swift` (and `QuestionRounds.swift` where
  the round bookkeeping is shared): the Operator-Done finish rounds.
- Modify `Operators/QueryWriterRunner.swift`: cron writing and checking.
- Modify `Operators/SignalModel.swift`: Starts on / Done when kinds, project, next runs, defaults per kind,
  `canAdvance` for a schedule.
- Modify `Views/Operators/SignalTriggerStep.swift`, `SignalDoneStep.swift`, `SignalSheet.swift`: the two-way rows,
  the schedule fields and Next runs, the Operator Done field, the Name help, Prompt without checkboxes on a
  schedule, the summary sentences, Jira disabled in a run's Done Reads.
- Modify `SignalSidebar.swift` (section data: next run, last skip) and `HeadingValue.swift` (builds the tooltip, today
  the two raw queries): the tooltip shows the cron in words and the next run for a schedule Start, and "The Operator
  decides" with any guidance for an Operator Done, never an empty `Done:` line.
- Modify `Views/SidebarHeadings.swift`: `ProviderIcon.source(of:)` gains a clock mark for `.schedule` and a mark for
  `.operator` (exhaustive switch).
- Modify `Snapshots/SignalSnapshots.swift`: fixtures for the new sheet states.

**Docs**
- Modify `docs/operators.md`: schedules, missed runs, one run at a time, the Operator Done.
- Modify `docs/design/design-system.html`: the proposal (in this commit); once shipped, removed and synced.
- Modify `app/Tests/.../operator-signals/` fixtures and `PROVENANCE.md`: a deliberate contract change (new brief
  lines, `finish_stage` fields, new saved kinds), not an incidental refactor.

## Proof

- **Core tests (new)**: run branch naming with a long signal name (two runs, two branches, suffix intact) and with two
  same-named signals firing in the same minute (two branches);
  `OracleLaunch` completion question (three rounds, agree, critique, your decision); `CronTests` (parse and refuse, names, steps, OR rule, next and latest across month ends and
  both DST changes in Europe/Brussels); `ScheduleDecisionTests` (on time, latest-only catch-up after two misses,
  nothing before `scheduledFrom`, switched off, paused then resumed, previous run unfinished, project gone, cursor
  never fires a time twice); `MatchDecision` for a `run` item; `DoneCheck` for an Operator Done (merged still ends).
- **Saved format**: focused tests that a signal and task saved before this change decode unchanged, that the new
  `Source` cases and `run` kind round-trip, and that an unknown kind stays unknown; `SignalSavedFormatTests` and
  `SignalOperatorContractTests` fixtures updated deliberately with provenance.
- **App tests**: the scheduler with a fake clock driving a full journey on fakes: a firing starts a task in the
  project, a second firing while it works is skipped, the Operator's `finish_stage(done)` with Oracle agreement
  finishes it and Then runs; with Merge it when it's ready, an agreed done waits for AiTerm's merge and the
  hand-back before it ends; a run whose merge request another signal continues still blocks that schedule's next firing; Oracle critique, three disagreements and Oracle off route as described; Write cron's
  retry on a refused answer.
- **Snapshots** of every new sheet state, compared against the proposal's mocks.
- **Gate**: `scripts/test.sh`, then before merge the full-suite proof from `docs/workflow/project.md`.
- **Opt-in**: `SignalOperatorEvalRunner` (`AITERM_LIVE_OPERATOR=1`, spends quota) rerun once for the changed brief, on
  your go.
- How it is shown to work in the real app follows `docs/workflow/verify.md`; agents never run the app.

## To-dos

- [ ] Cron: parser, next/latest, plain reading, with `CronTests`.
- [ ] Saved shape: `Source.schedule` / `.operator`, `project`, `scheduledFrom`, `ItemRef.run`, the schedule cursor, with
      the decode-compatibility tests, and every exhaustive switch over them adapted in this same step
      (`ItemProjectMapper`, `SignalConnections`, `ProviderIcon.source(of:)`, the sheet's labels and marks), so the project
      still builds.
- [ ] Scheduling rule: `ScheduleDecision`, `MatchDecision` for runs and `SignalTask.scheduledRun`, with their tests.
- [ ] Scheduler wiring: `SignalScheduler`, `ItemRouter.makeTask` for runs, registration and `scheduledFrom`; journey
      test with a fake clock (Done still a GitLab query).
- [ ] Operator Done: `DoneCheck`, host reads, `finish_stage` rounds with the Oracle and the person, brief and tool
      schema in `daemon/aitermd/signal_tools.json`, the completion `OracleLaunch.Question`, contract fixtures with
      provenance; tests for the question's rounds and verdicts, and journey tests including an agreed done with Merge
      it when it's ready on and an open merge request.
- [ ] Write cron: writer prompt and runner check.
- [ ] Sheets: Starts on, schedule fields and Next runs, Done when, Prompt, Name help, summaries; snapshots.
- [ ] Sidebar tooltip (`SignalSidebar` data, `HeadingValue` text) and Operator digest.
- [ ] Docs: `docs/operators.md`; design system synced once shipped (proposal removed, Components updated).
