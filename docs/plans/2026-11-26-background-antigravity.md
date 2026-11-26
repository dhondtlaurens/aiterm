# Antigravity background work: commands and subagents

## Goal

In an Antigravity (`agy`) tab, a command that outlasts its `WaitMsBeforeAsync` becomes a background task,
and `invoke_subagent` starts child conversations. While either runs, AiTerm shows the tab as **done** with
an empty work card. A Claude or Codex tab shows the work and holds the turn instead: status `background`, an
Operator worker not ready. A subagent's own hooks also fire from the parent's tab. Today they **rebind the
tab to the subagent's conversation**, reset its turn, and flip its state with each of the child's turns.

The evidence is in `docs/research/2026-11-26-antigravity-background-work.md`: a live tab plus two isolated
probes on agy 1.5.18. In short:
- A Stop's `fullyIdle` is `false` while work runs.
- The parent's transcript names each command (`Task Description`) and each subagent (its `invoke_subagent`
  prompt and the `conversationId` it was created with).
- The end of each is a `SYSTEM_MESSAGE` from `<conv>/task-N` or from `<child conv>`.
- The status line carries `task_count` and `subagents[].status`.
- A subagent's posts carry the parent's iTerm id, its own `conversationId`, and an empty `lastUserInput`.
- A parent Stop can say `fullyIdle: false` with no later Stop after the work ends.

Agreed while grilling: commands **and** subagents, both holding the turn as Claude's do.

## Approach

**Daemon only.** The app is agent-neutral: `SidebarModel.status` already shows `background` for a tab whose
ended turn has work, and `WorkerTabs` reads `holdsTurn`.

1. **Subagent posts are a child's, never the tab's.** In `agents/agy.py` an agy post becomes a child event of
   its tab in two cases:
   - It is a SessionStart naming a conversation other than the tab's own, with an empty `lastUserInput`. The
     tab's own conversation always starts with the prompt that started it, `/clear` included, since agy's
     hooks only speak with the next prompt. A subagent starts from a system message.
   - It names a conversation already counted as a child of that tab.

   The hook router (`hook_router._place_and_apply`) then treats it as Claude's children are treated:
   - Its SessionStart and any PreInvocation become `subagentStart` (the child id is its conversation id,
     the label is "subagent"). A woken child counts again.
   - Its Stop with `fullyIdle: true` becomes `subagentStop`, which ends it, since agy children have no
     transcript to wait on. A Stop with `fullyIdle: false` means the child's own task still runs, so the
     child stays counted.
   - It never sets the tab's conversation or transcript, and never resets its turn.

   The child set lives on the turn's children (`StatusEngine.subagent_started` / `_subagent_ended`). A parent
   Stop is already deferred while a child lives (docs/status-model.md), so the parent shows working while a
   subagent works, as with Claude.
2. **The Stop's work, from the transcript.** On a parent Stop with `fullyIdle: false`, the router reads the
   hook's `transcriptPath` off the event loop: `run_detached`, bounded, cached by stat like `StopTranscripts`.
   The Stop then carries `background_work`:
   - each task started (`GENERIC` `RUNNING` "running as a background task with task id: X" + "Task
     Description") and not finished (no `SYSTEM_MESSAGE` from `sender=X`), as a `shell` job with `task_id`
     X and its command;
   - each subagent created ("Created the following subagent" + the `invoke_subagent` prompt) and not yet
     heard from (no `SYSTEM_MESSAGE` from `sender=<child>`), as a `subagent` job with `agent_id` = its
     conversation.

   These flow through the existing path unchanged: `stop_work`, `work_items` (holdsTurn), and a counted
   subagent's removal when it ends (`status._show_children`). If the read fails, it lists nothing.
   `fullyIdle: true` lists nothing either.
3. **The status line closes what no hook closes.** `parse_agy_statusline` reads `task_count` (absent = 0). An
   agy status line from the tab's own conversation with no `task_count` drops the `shell` items from that
   tab's `stop_work` and clears its `shown_shells`. That covers a killed task, and a task whose end did not start a turn. Subagents are
   ended by their own Stop (1). The next turn's `working` clears everything as it does today.
4. **Live, and closed when done.** The same transcript reading runs on every tick, like
   `claude.background_plan`, for each agy tab with a transcript, working or ended. It sets `shown_shells` to
   the tasks started and not yet ended. The card then lists a background command while the turn still
   works, as Claude's does, and drops it once its end is in the transcript, even if no working tick came
   between. Counted children already show through `shown_subagents`.
5. **The compat capture keeps the contract.** `capture_agy` dismisses agy's announcement banner (`esc to
   dismiss`) on start and adds three turns: a backgrounded `sleep`, one subagent (waiting for the parent's
   final idle), and `/clear` followed by a prompt. That last one checks the assumption in (1) that the tab's
   own new conversation starts with a non-empty `lastUserInput`. If a later agy breaks it, the cost is a
   `/clear` that does not rebind, never a subagent that hijacks the tab. The recapture becomes the fixture the contract tests read, so a future agy that renames these
   records fails the compat check rather than going quietly blind.

## Files

- modify `daemon/aitermd/agents/agy.py`: the Stop's `fullyIdle`; child-post recognition; a transcript reader
  for tasks and subagents (started, ended); the status line's `task_count`; a tick plan for working tabs.
- modify `daemon/aitermd/hook_events.py`: `StatusLine` gains the task count; `HookEvent` carries `fully_idle`
  and the empty-prompt mark the router needs.
- modify `daemon/aitermd/hook_router.py`: route an agy child's posts to the tab's children without rebinding;
  read the transcript off the loop for a `fullyIdle: false` Stop; apply the task count.
- modify `daemon/aitermd/status.py`: drop the `shell` items of `stop_work`, and `shown_shells`, on a zero
  task count.
- modify `daemon/aitermd/service.py`: the agy tick read beside "reading Claude background shells".
- modify `daemon/aitermd/models.py`: docstrings that say "a Claude turn" (`BackgroundJob`, `stop_work`).
- modify `daemon/tools/compat_capture.py`: the banner and the two turns; recapture
  `daemon/tests/fixtures/compat/agy/` (posts, transcripts, capture note).
- modify `daemon/tests/test_agy.py`, `daemon/tests/test_compat_captures.py`, and a router or status test for
  the child routing.
- modify `docs/status-model.md` (an agy background section), `docs/configuration.md` (agy now reports
  background work). The findings, `docs/research/2026-11-26-antigravity-background-work.md`, stay local:
  `docs/research/` is gitignored.

## Proof

- **Tests first**, from the probe's scrubbed posts and transcripts:
  - a `fullyIdle: false` Stop lists the running command and the subagent, and a `true` one lists nothing;
  - a finished task's or subagent's message drops it;
  - a child's SessionStart, PreInvocation and Stop never change the tab's conversation or state, and do
    count and end the child;
  - the parent's late `fullyIdle: false` Stop followed by the child's final Stop leaves the tab done with no
    work (the race in the probe);
  - a status line without `task_count` drops the shells from both `stop_work` and `shown_shells`;
  - a command shown while the turn works, whose end is written before the next tick (no working tick in
    between), leaves neither the card nor the stopped tab's work;
  - `/clear`'s SessionStart (non-empty prompt, idle tab) still rebinds the tab, checked against the
    recaptured fixture's `/clear` turn.
- The gate, `scripts/test.sh`, and a plain full pass before merging.
- `scripts/compat-check.sh agy` recaptures and passes the contract suites.
- **In the app** (the `run` skill), an agy task:
  - a backgrounded `sleep 60` shows `background` with the command on the card, then working, then done when
    it ends;
  - a subagent shows on the card while it runs, and the tab keeps its own conversation (resume opens the
    parent's);
  - an Operator worker on agy is not ready while its test run is in the background.

## To-dos

- [ ] Child posts: recognise, count and end agy subagents without touching the tab's conversation or state.
  Tests first.
- [ ] Stop's work: transcript reader for tasks and subagents; a `fullyIdle: false` Stop carries them. Tests
  first.
- [ ] Status line `task_count` closes stale shells. Test first.
- [ ] Tick reading for every agy tab with a transcript (`shown_shells`, ended tasks dropped). Test first.
- [ ] Compat capture: banner, then background, subagent and `/clear` turns; recapture fixtures; contract
  tests.
- [ ] Docs: status model, configuration.
- [ ] Prove in the app and with an Operator worker; full suite.
