# Operator workload lifetime and ordinary task rows

## Goal

Implement option A selected in the design-system proposal on 16 November 2026. Finished tickets
must not leave the Operator asking for attention. Signal tasks use the ordinary two-line task
layout. Only the Operator activity caption decodes, for each event including repeated words.

## Approach

Configured signals poll without a chat. Unfinished owned stages, pending stages and outstanding
closeout keep one chat alive. Once these finish, close safely before revoking, persist an idle
session record and open a fresh generation for the next matching workload. State changes trigger
retirement immediately after closeout, without waiting for the next minute tick. A new match
arriving during closure survives and starts in that fresh generation. Context renewal retains the existing
150,000-token safe-boundary rule and loses the separate age limit. Pause retains unfinished work.

Task-bound questions must belong to current work. The existing task-less ask_you contract remains
valid: a real global question keeps its chat until answered. Keep real permission prompts and
actionable app failures visible. Drive the caption from identifiable runtime events, including starts, results,
failures and returning to watching, without persisting animation frames or changing tool contracts.
Hold a quick completed action in the caption for one second, including its decode, so rendering
cannot coalesce away its start. New events replace it immediately; task/status state stays current.

## Files

- Modify `AiTermCore/Operators/Signals/`: workload/question policy and durable session closeout.
- Modify `AiTerm/Operators/OperatorSessionKeeper.swift` and `SignalOperatorController.swift`:
  workload-driven open/finish/renew, race recovery and activity publication.
- Modify `AiTerm/Operators/OperatorNotifications.swift`: current questions only.
- Modify `AiTerm/SignalSidebar.swift`, `SidebarProjection.swift`, `AppController.swift`:
  row visibility and focused activity observation.
- Modify `AiTerm/Views/OperatorBadge.swift` and `Operators/SignalRows.swift`: decode per event;
  retain global Pause/Resume in the always-present heading’s menu and show its paused state there.
- Modify `AiTerm/Views/OperatorSettingsPane.swift` and `SidebarView.swift`: current lifecycle copy.
- Modify `AiTerm/Views/SidebarRows.swift`; remove `Operators/SignalStatusLine.swift`:
  ordinary task rows and removal of the extra line and hold.
- Add `AiTerm/Operators/OperatorActivity.swift` for runtime event identity and concurrent actions.
- Modify the corresponding Core and app tests; add owner lifetime and event regression coverage.
- Modify snapshot fixtures, `docs/operators.md`, the UI inventory and design-system HTML:
  remove the accepted proposal, link directly to its component tab and capture the implemented behavior.
- Modify `AiTermCore/Operators/Signals/SignalOperatorCommand.swift` and only the current
  `operator-signals/brief.md` plus provenance: describe the deliberate lifecycle change accurately.

Paths above are relative to `app/Sources/` unless stated otherwise. Keep saved-format goldens,
Signal tool schemas and historical eval baselines unchanged. Edit the current lifecycle paragraph
and its golden together as a deliberate feature change, with provenance and capped comparisons.

## Proof

Reproduce source-only chat creation and obsolete completed-task attention in isolated tests first.
Cover close/revoke/reopen order, held closes and new matches, restart recovery, real permission
and typing deferrals, unfinished watching/paused tasks, context-only renewal and repeat-event
animation. Run focused suites, then `scripts/test.sh`. Capture and inspect native hosted sidebar
fixtures before and after via the debug snapshot entry; do not replace the running app.
For the deliberate current-brief change, run the existing capped Signal/baseline comparison
with three repetitions per scenario, explicit identical model/effort, twelve turns and 600 seconds
per run; retain full isolated streams and record the outcome in current-fixture provenance.

## To-dos

- [x] Reproduce completed-task attention and unnecessary idle chats.
- [x] Implement workload and safe session retirement/restart.
- [x] Publish activity for every event and decode by event identity.
- [x] Restore ordinary task rows and update snapshots/reference.
- [x] Pass the affected gate and inspect rendered fixtures.

## Completed proof

- `scripts/test.sh` passed: 123 UI tests, 1,117 app tests and 1,702 Core tests, plus the
  runner’s isolated Signal snapshot pass. Existing known-issue labels remain unchanged.
- The isolated capped model comparison passed all eighteen runs; every stream resolved
  `claude-sonnet-5-5` at explicit high effort. Current-fixture provenance records the limits
  and `build/operator-workload-lifetime-eval/` retains the complete proof.
- Inspected native hosted acting, question, idle, kept-completed, idle-paused and settings captures
  in `build/operator-after/`, against the baseline acting capture in `build/operator-before/`.
- The updated HTML embeds the current native captures, contains no open proposal and passes
  browser checks for component deep links, loaded images and the retained Proposals tab.
- Three adversarial-review rounds were triaged; all Critical/Important findings are addressed.
  Recovery coverage includes an interrupted opening in a later workload and adopting an
  opened-but-unrecorded window before close and revoke.

The implementation passed review and isolated runtime verification; merge and publication use the repository’s release pipeline.
