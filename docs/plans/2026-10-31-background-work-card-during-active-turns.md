# Open the existing background work card during active turns

## Goal

Hovering the ordinary working spinner should open the same work list that hovering the
background spinner opens today, whenever the task or terminal has verified work to list.
The person can inspect background work while Claude or Codex continues its turn.

Agreed with Laurens on 31 October 2026: reuse the existing list, card and hover interaction.
Show background work and subagents, excluding foreground commands. The verified subset is
approved; detailed Codex background terminals remain deferred for the reasons in
`docs/research/2026-10-31-live-background-work.md`. This plan does not claim the screenshot's
Codex terminal inventory is solved.

## Approach

### One existing card and list

Keep `BackgroundCard`, `BackgroundCardView`, `BackgroundCardHover`, the mark's hover target and
the existing overlay. Feed the existing task/terminal `row.background` list with the display
projection below; do not introduce another popover, list, badge, panel or interaction.
Preserve hover delays, pointer crossing, scrolling, selection colours, row dimensions and
interface scaling. Keep the spinner that reflects the row's real status.

Open the existing card for a nonempty list on an ordinary status mark, including working and
needs-input marks, and for existing background rows. Continue suppressing it during removal or
for an Operator-queued task. An empty list offers no card. Replace the unconditional “Turn
ended” heading and spoken text with neutral “Background work” wording, retaining the job count
for several entries. This also avoids an incorrect claim for mixed-tab rows.

VoiceOver reads the current status and work details as well as any applicable caption or
Operator line; the existing precedence chain must not hide the work behind an Operator tooltip
or erase an input request. This includes Operator-driven task rows: their job list becomes
inspectable from the spinner too, and the old comment saying only the Operator line describes
it must be updated. The line's tooltip remains available at its own target; compose spoken
details without repeating job descriptions already included there. This changes inspection,
not Operator scheduling. No primitive or token changes are needed.

### Display facts stay separate from obligations

Add an optional process-scoped `displayWork` session object with independently optional
`subagents` and `shells` arrays. Entries carry the existing job kind/text values and an optional
`legacyIndex` identifying their matching position in the same session payload's legacy
`background` array. The daemon derives that correspondence from its internal IDs, not text;
it recomputes the indices against the legacy array emitted in that payload. An absent
object supports older daemons; an absent/null array means that source is unavailable, while
an empty array is a known empty inventory for that source. Keep the existing
`SessionInfo.background`, `SidebarModel.backgroundJobs`, status aggregation and Operator
readiness/obligation rules unchanged.

Project display work in tab order into the existing `row.background` list, with these rules
applied per tab before concatenating them:

| Kind/source | Available new array | Unavailable new array |
| --- | --- | --- |
| Subagent | Use `displayWork.subagents` in place of legacy subagent entries, in any tab state | Use legacy subagent entries in any tab state, as the existing WorkerTabs projection does |
| Shell | Use `displayWork.shells` in place of legacy shell entries, in any tab state | Use legacy shell entries only when that tab's turn ended |
| Monitor/other task | No new active-turn source | Retain legacy entries only when that tab's turn ended |
| Test activity | Append a queued/running test summary only when that tab's turn ended | Same rule, including for Codex |

Preserve the existing list order. For each tab, walk the legacy background array in its current
order and apply the source replacement/fallback rule at each entry, using `legacyIndex` to
place matching new entries at the same positions across interleaved kinds. Then append new
entries with no legacy match: counted children first, shells second, each in stable observation
order. Finally, after every tab's jobs, append the eligible test summaries as today's
`backgroundJobs` does; do not move those summaries between tabs' jobs. Test that a Stop's
shell/monitor/subagent/shell sequence stays interleaved and that test summaries remain at the
end. A new observation may update or retire a job, but source grouping alone must not reorder
the background spinner's existing list.

Do not append both the new and legacy arrays for a kind, and do not carry unverified monitor
snapshots into new active turns. The daemon, not the app, merges a complete valid Stop snapshot
with native transcript observations using internally retained provider task/child IDs before
publishing an array. Preserve Stop shell task IDs internally without changing legacy background
JSON. If IDs or replay completeness cannot establish the full shell set, publish that source
as unavailable and apply the fallback above, rather than publish a partial replacement array.
Two independent jobs with the same command remain two entries.

Test-run locks do not establish background execution. An active-turn test appears only as a
shell with independently confirmed background-task evidence, not from `testActivity` alone.
Retain existing exact-worktree test ownership. Suppressing a test summary is not part of this
change: preserve the ended-turn test summary exactly as the current list
builds it, including when a Stop shell also describes that test run. Do not add command-string
heuristics or deduplicate this existing cross-source evidence. Removing duplicate test summaries
would be a separate proposal.

Only display fields trigger display updates. Starting or finishing a displayed job must publish
`session.changed` even if status is already working, and must invalidate the affected row's
projection. The new display field is not read by Operator scheduling, acceptance or completion.
Do not regenerate frozen Operator goldens for this feature.

### Counted subagents

Expose children already counted by `StatusEngine`, including Claude and Codex, through the new
display inventory. Use a verified description when available, the hook's agent type otherwise,
and “Subagent” when neither is known. A bare start must not invent a description or a launch.
The Stop's existing description matched by the counted child's `agent_id` is a verified label
source and takes precedence over a generic agent type, keeping the card and Operator tooltip
consistent.
Use the existing child ID, parent placement and lifecycle: Claude's deferred SubagentStop and
transcript hand-back reconciliation still decide when its child ends; Codex keeps its current
hook lifecycle. Enrich labels without changing any of those status decisions.

### Verified Claude background shells

Create a focused incremental reader of the parent transcript already identified by Claude's
own hooks/status line. Match native tool-use/result records by tool-use ID and register a shell
only after a result confirms `backgroundTaskId`. A requested `run_in_background` flag alone
does not establish a successful launch. Read descriptions/commands from that native tool call,
not stdout or arbitrary embedded output.

Consume native task notifications and successful TaskStop results by task ID; reconcile with a
well-formed Stop task snapshot where available. Preserve missing/malformed evidence as unknown,
not a successful empty inventory or a completed job. Validate failure/stop notification shapes
from actual producer evidence before recognising them. The expanded recorded sample establishes
completed, failed, killed and stopped notices in user, queued attachment and enqueue records.
Unsupported terminal outcomes suppress an unverified display claim
instead of guessing that a task is still running. This does not alter legacy obligations.

Run file I/O through the daemon's existing bounded off-loop mechanism. Use `JsonlCursor`, a
bounded byte budget per pass, complete records and a pruned cache; unchanged files require no
reparse. Do not publish a replay's intermediate inventory before catching up to its captured
end, as an old launch may have a later completion. Handle partial writes, truncation, inode
replacement and unreadable files explicitly.

Apply readings only to the captured session/process/conversation/transcript identity. Drop late
results and clear display state/cache ownership on closure, process replacement or a genuinely
new conversation. Ordinary turn boundaries and compaction must not erase a verified shell that
continues running. On adoption/resume, do not replay an earlier process's unresolved jobs as
current: require current-generation evidence, otherwise leave that source unavailable until a
new observation establishes it. File-read failure must not turn into an authoritative empty
inventory, and unverified retained shell information must not be labelled as current work.

### Deferred work

No Codex terminal API integration, screen scraping, automatic `/ps`, JavaScript/stdout parsing,
launch-mode changes or extra tool hooks. An actively working Codex tab can show counted
children, but has no verified active-turn test-shell source in this change. A mixed-tab row may
also show existing test activity from an ended sibling tab. This change does not promise complete
Codex terminal details. General active-turn monitor tracking is also deferred; the existing
ended-turn monitor list is preserved.

## Files

- Create `daemon/aitermd/claude_background.py`: bounded native transcript parsing and task-ID
  inventory, with explicit unavailable/catching-up results and process-generation ownership.
- Modify `daemon/aitermd/models.py` and `sessions.py`: the optional process-scoped display
  object, per-source availability and internal IDs needed for merging, preserving existing
  background JSON.
- Modify `daemon/aitermd/hook_events.py` and `status.py`: verified child labels, display-only
  child projection and Stop task identities, without changing status/obligation semantics.
- Modify `daemon/aitermd/service.py`: off-loop reader integration, identity validation,
  unavailable handling, pruning and publication on display-only changes.
- Modify `app/Sources/AiTermCore/Daemon/DaemonTypes.swift`: decode the optional display field
  and its optional legacy-position correspondence while continuing to accept sessions from
  an older daemon.
- Modify `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`: keep display work row-relevant;
  add the display projection used by existing task/terminal row lists, separate from aggregation.
- Modify `app/Sources/AiTermCore/Operators/StallWatch.swift` and its existing tests: exclude
  displayWork from sign-of-life comparison, preserving the pre-change stall clock behaviour.
- Modify `app/Sources/AiTerm/Views/BackgroundCard.swift` and `SidebarRows.swift`: reuse the card
  for populated active rows, neutral wording, and complete row accessibility values.
- Modify `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift`: seeded open-card fixtures for
  working/background task and terminal rows, multiple jobs, selected rows and larger scale.
- Modify `app/Sources/AiTerm/Snapshots/Snapshots.swift`: append the new fixtures after the
  existing rendering order and keep hosted view captures transparent and click-through.
- Create `daemon/tests/test_claude_background.py`; modify `test_status.py`, `test_hook_events.py`,
  `test_models.py`, `test_sessions.py`, `test_service.py` and `test_wire_contract.py` as their
  boundaries change. Explicitly update the session-bearing wire fixtures under
  `daemon/tests/wire/` for the intentional additive protocol field: `event.session.changed.json`,
  `event.session.opened.json`, `reply.sessions.list.json` and `reply.workspace.snapshot.json`.
  These are daemon wire fixtures, separate from the frozen Operator behaviour goldens.
- Modify `app/Tests/AiTermCoreTests/DaemonTypesTests.swift`, `WireContractTests.swift` and
  `SidebarModelTests.swift`, plus `app/Tests/AiTermTests/BackgroundCardTests.swift` and
  `SidebarProjectionTests.swift`: wire compatibility, display/decision separation, interaction,
  geometry, accessibility and observation regressions.
- Modify `docs/status-model.md`, `docs/daemon-protocol.md` and `docs/design/ui-patterns.md`:
  explain the existing card's wider availability, source limits and display-only field.

## Proof

First reproduce a working row with known background work whose current mark opens no card.
Exercise real parent-record shapes in temporary transcript files: confirmed background launch,
ordinary foreground command, completion without another tool poll, successful stop, multiple
identical commands with distinct IDs, repeated events and a Stop snapshot of the same jobs.
Keep failed/unknown shapes from becoming confirmed launches, completions or current-work claims.

Cover child labels and updates while status stays working or needs input, including Claude's
existing hand-back/deferred-stop cases. Cover two tabs in different states, older-daemon
fallback, legacy counted children while their parent stays working, independently
available/empty/unavailable source arrays, foreground tests excluded, confirmed-background test
shells, unchanged ended-turn test summaries and interleaved Stop order, replay catch-up, partial
JSONL, failed reads, rewrite, adoption/resume and a replacement during an off-loop read.
Assert that existing row status, counts, attention and Operator readiness/obligations are identical
with and without display-only work. Preserve the frozen current Operator contract.

Use the existing card's hosted interaction/geometry tests to prove working and background rows
open the same overlay and that the ordinary spinner remains. Cover task and terminal rows,
empty lists, removal/queue suppression, hover-to-card crossing, live job removal and VoiceOver
status plus jobs. Existing empty-card/scroll/Reduce Motion behaviour remains covered.

Iterate through the daemon venv's focused pytest suites and
`scripts/test.sh swift -- --filter <Suite>`. Before implementation commits run plain
`scripts/test.sh`; before merging run `scripts/test.sh all`. Start queued runs in the background
and follow their logs. Generate `scripts/snapshots.sh build/background-work-card` after the
relevant build/test run, then inspect the seeded images. Snapshot entry must stay ahead of live
controller construction. Do not use `scripts/run-dev.sh` to prove this while live work continues.

## To-dos

- [x] Reproduce the hidden active-row card and open that same card for already-known eligible
  jobs, without adding a wire field. Exclude unconfirmed active-turn test summaries. Prove
  status, Operator behaviour, layout and accessibility stay correct.
- [x] Add the optional per-source display transport together with its counted-child producer
  and app projection, so no unfilled field masks legacy data. Prove older-daemon and per-source
  fallbacks, honest labels, display-only publication, child lifecycle and parent placement.
- [x] Add the bounded Claude shell reader end to end through the same inventory/card. Prove
  launch/finish/stop, identity merging, catch-up, unavailable reads and replacement isolation.
- [x] Add the seeded visual fixtures and documentation, run the affected gate and inspect the
  images, then take the finished change through adversarial review.

## Plan review

Challenged through `psg:adversarial-review` with Claude in three rounds. The first round raised
source availability/merge ambiguity, foreground test classification, missing wire checks and
slice size; these were fixed. Its Operator-row scope objection was checked and rejected because
the approved draft includes populated working task rows and preserves Operator decisions.
The second round removed an unrelated test-summary deduplication rule, restored already-known
working subagents to the legacy fallback and clarified the limited active-turn Codex coverage.
The third round found only a minor ordering gap. The plan now specifies stable Stop ordering,
same-payload legacy-position correspondence and the existing final test-summary suffix.

All raised findings have been triaged; no Critical or Important finding remains open. The last
minor ordering clarification was checked against `SidebarModel.backgroundJobs` and the Stop
parser; it was not sent through a fourth review round. The review did not independently probe
live transcript timing or validate every producer record shape. Those limits remain in the
research and implementation proof rather than being reported as verified runtime behaviour.
No product code had been changed at the plan-review handoff.

## Implementation evidence

The active-card pixel regression failed for working/input marks before the status gate was
removed, while the existing background case passed. The initial focused Swift checks passed
81 tests after implementation. Daemon checks include source availability, current-generation
and replacement isolation, native IDs and display-only updates; the full daemon gate passed
1,428 tests before the final notification coverage was added.

The implementation review required multi-pass recovery from unknown evidence, rather than
a permanent reader disable, and handling native queued notifications during active turns.
Expanded recorded evidence verified completed, failed, killed and stopped shell notices in
user, queued attachment and enqueue forms. The final reader covers these carriers, recovers
on later verified completion or an authoritative Stop, and keeps unsupported evidence unknown.
Unknown-outcome recovery tests also failed under a controlled simulation of the old permanent
disable behaviour. The existing Operator contract goldens have not been regenerated.

Hidden hosted captures were inspected at standard and extra-large scale. They show the same
existing card and readable scrolling content beside working, background and input marks.
Offscreen ImageRenderer alone leaves scroll content blank, so those captures were not used
as visual proof. Before the fourth review's fixes, daemon verification passed 1,443 tests
(one skipped), mypy and ruff. Focused Swift checks passed 88 tests across six suites, including the frozen
Operator contract. A conversation-ownership regression failed before the display-only child
filter was added, then passed in the daemon gate; counted-child obligations remain unchanged.

The affected full gate passed the daemon, AiTermUI and AiTermCore suites, but the app suite
failed in two existing picker keyboard tests: Down then Return chooses the first entry instead
of the second. The same failures reproduce in an isolated detached worktree at the untouched
starting commit `3eb32d27`, with only those picker suites running. The feature has not changed
picker product code or tests. On the final affected-gate run the app suite passes all 1,734
tests, including those two pickers, without changing them. The earlier baseline failures are
intermittent; the passing rerun does not establish a picker fix.

The third implementation review settled the earlier native-completion findings but found two
remaining issues, both verified in the implementation:

- Important: unrelated Monitor or artifact-watch task notifications lacking shell status/ID
  currently mark the entire shell source unavailable until another valid Stop. Such notices
  should not invalidate verified shells they say nothing about.
- Minor: StallWatch compares whole SessionInfo values; the new displayWork field therefore
  restarts an Operator stall clock even when no legacy session fact changed. The display-only
  contract requires excluding that field from its sign-of-life comparison.

Laurens approved fixing both findings and running a fourth review. The narrow StallWatch
comparison change above preserves the existing Operator contract; it does not redefine its
stall policy. Regressions first reproduce the unrelated-notice source blackout and display-only
clock reset for both first and extra worker tabs.

Both regressions reproduced before the fixes: seven shell-notice cases failed, and the
stall-clock test failed for each worker-tab position. After the fixes all 33 shell-reader tests
pass, along with all 22 StallWatch tests and the two frozen Operator contract tests. The fourth
review returns no findings and confirms both round-three fixes; all earlier findings are settled.
It did not independently run tests or snapshots, probe live sessions or establish complete
Codex terminal coverage. The final affected gate (`scripts/test.sh`) exits zero: 1,453 daemon
tests pass (one skipped), mypy and ruff pass, and the Swift runs pass 1,734 app, 1,984 core,
92 UI and four separately rendered snapshot tests. Swift's three existing known issues remain
labelled as such. No live app restart or merge was performed. The implementation remains
uncommitted for the psg review handoff. The temporary baseline worktree has been removed
after preserving its failure logs; no picker changes were brought into the feature worktree.
