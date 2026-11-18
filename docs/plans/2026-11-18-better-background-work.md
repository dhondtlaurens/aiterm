# Make background work descriptive and show up to five jobs

## Goal and agreed scope

Make the background-work card explain what its existing jobs are doing. Keep each job on one
truncated line, but let the card grow downward to five job rows plus its heading before scrolling.
Opening it must leave the sidebar's task and terminal rows at their usual size.

Laurens approved planning verified native descriptions with existing fallbacks after live probes
of Claude, Codex and PI on 18 November. This is display enrichment for the existing inventory:
membership, ordering, turn status, `holdsTurn`, attention and the Operator's contracts stay the
same. Adding active Monitor inventory, Codex/PI background-shell discovery, optional PI packages
or remote task integrations is outside this change.

## Evidence adopted from the probes

The local report is `docs/research/2026-11-18-background-work-descriptions.md`; that directory is
intentionally ignored. The facts needed to implement this plan are recorded here as well:

- **Claude Code 2.1.327:** parent assistant tool-use inputs and their native results join by
  `tool_use_id`. A confirmed Bash background launch has `toolUseResult.backgroundTaskId`, with
  its short description in the input; a foreground command has no background-task ID. An Agent
  launch result has `isAsync`, `agentId` and `description`, before completion. SubagentStart alone
  often says only `general-purpose`. Stop's `background_tasks` supplies descriptions too. A
  command Monitor returns `taskId` but Stop reports it as `shell`; a WebSocket Monitor is
  `monitor`. Statusless monitor events are not completion. Keep existing monitor membership rules.
- **Codex 0.169.0:** in the current parent's rollout, `event_msg` → `payload.type=item_completed`
  → `payload.item.type=SubAgentActivity`, `kind=started` contains `agent_thread_id` and
  `agent_path`, for example `/root/inspect_fixture`. The ID/path record was independently read
  17.8 seconds before completion. Its ID/path join can precede the spawn tool result. Humanize
  the path's last component to `Inspect fixture`; the assigned prompt was encrypted. Hooks
  expose the child UUID and generic type, not this task name. Foreground/yielded shells did not
  expose a durable background-only inventory in their rollouts.
- **PI 1.4.0:** native bash exposes command text. An explicitly loaded shipped foreground
  subagent example exposes assignment text, but emits no `subagents:*` events. The optional
  `pi-subagents` background package is absent in this installation, so its richer payload is
  unverified. Keep PI's current labels and lifecycle; do not infer a job from shell `&` or a PID.

Do not install new production hooks or read/decrypt full assigned prompts. Use the parent files
already followed by the existing off-loop readers. Native metadata enriches jobs owned by the
current lifecycle; it cannot create a child, retire a task, or keep one alive.

## Approach

### Descriptions without changing existing work semantics

Add an optional `displayLabel` to a work item's wire value and its Swift equivalents. Python's
internal jobs carry the corresponding optional display label through the existing ordered work
projection. Keep `text` and `holdsTurn` unchanged for status and Operator consumers. Omit absent
labels from JSON, decode absence as nil, and fall back to the existing `text` in the card. This
is a deliberate small protocol extension, not a persistence-format change.

For existing Claude Stop items, retain a useful short native description as display metadata,
including a shell's description alongside its existing raw command. Carry Bash descriptions
through the current live shell reader's confirmed-ID join as well. For already-counted children,
read native Agent launch results from the parent transcript and attach their short descriptions
by exact child ID. Do not scan every child transcript to obtain prose. Stop-supplied descriptions
take precedence while that Stop item stands; native descriptions improve an otherwise generic
type label. Missing, blank or unverified descriptions leave the current fallback intact.

For Codex, extend the existing parent rollout cursor's prefilter and reading to retain the native
started activity's ID/path mapping. Humanize only the final task-name component by replacing
underscores/hyphens with spaces and capitalizing its initial; avoid arbitrary nickname, prompt or
stdout inference. Apply it to the current parent's counted child, with type/generic fallback.

Metadata reads use existing `ReadPlan`/`SessionKey` ownership and deadlines. Scope caches to the
current process and conversation, bound retained mappings, and reject late results after a
replacement or child generation change. Handle hook-before-read and metadata-before-hook
ordering by IDs; a child stopped before application must stay absent. Drop old-run enrichment
on a resumed child and use fallback if the new assignment cannot be correlated confidently.
An unavailable or catching-up shell inventory must not invalidate an independently verified
child label or change the existing shell availability policy. No additional whole-tree scan or
per-tick child-file read is introduced.

The sidebar display projection carries `displayLabel`, but `backgroundJobs` and `WorkerTab`
consumers keep their existing raw-text meaning. A label-only event must invalidate the affected
row. Card speech uses the complete chosen labels, preserving the row's status and avoiding a
duplicate when its existing detail already describes the same work. Prose labels use
`Typography.help`; a shell falling back to its raw command uses `Typography.mono`. Keep the
raw command available as the shell line's help text when a prose label is shown.

### A floating card with bounded height

Replace the row-bound presentation with a sidebar-owned floating card in a borderless,
nonactivating child NSPanel above the native List, outside individual table-row clipping. Keep
the panel attached to the sidebar window at its level, unable to take key focus, and close/hide
it with its parent. Keep the existing row-top and pill-to-mark horizontal
alignment, width, `menuChrome`, glyphs, typography and hover delays. Rows report source identity
and anchor to one sidebar presenter; it observes the current jobs through `controller.rows` for
that open task/terminal, rather than retaining a second copy handed over by a row. A missing or
no-longer-drawn source closes the card, and a label-only projection update refreshes it. Share one
source-eligibility rule between row and presenter: in particular a task with
`controller.teardown.state(of: id)?.inProgress == true` offers no jobs and closes an open card,
even while its projected row and background jobs still exist. Accept the already-projected row
facts when called from a row, avoiding a whole-projection search during every row draw. Use an
AppKit view anchor converted into the sidebar's coordinates across hosting boundaries;
`SidebarListViewport` is a separate NSHostingView, so SwiftUI preferences alone must not be
assumed to cross it.

The heading stays fixed; only the jobs area scrolls. Size to one through five job rows, capped at
five even for a longer list. Derive heights and gaps from the existing scaled chip and spacing
tokens; five is a documented local item-count policy. Keep one line per job with tail truncation.
Do not add shared UI primitives or change Palette/Metrics for this local composition.

Normally grow below the row's top. Keep the card within the available sidebar list viewport,
below the titlebar/banners and above the footer: move it upward when the bottom lacks space,
and reduce its visible job count and scroll if the viewport itself cannot fit five. Keep the
source mark reachable across the repositioned card. This placement must be verified in a real
hosted sidebar, not just the snapshot column.

Preserve the delayed transition from mark to card and the ability to scroll while hovering it.
Only one card is open per sidebar. Close it when its jobs become empty, its source row vanishes
or is reused, task teardown begins, another mark takes ownership, or the native list scrolls
its anchor away. Inner
card scrolling must not count as list scrolling. Reposition on window resize, scale or layout
changes without changing selection or activating iTerm. The overlay must intercept events
only inside its card; uncovered rows keep their existing click/keyboard behaviour.

Covered rows must neither draw a hover wash nor show their row/branch/badge tooltips through
the card. Use the separate native child window deliberately: SwiftUI z-order in the same window
does not isolate the inner host's AppKit tracking/tooltip areas. The presenter owns the panel's
tracking and hit testing and the mark-to-card handoff. Hover must work while AiTerm is inactive
and iTerm2 is key: native tracking areas use `.activeAlways`, with their options checked in a
test, rather than `.activeInKeyWindow`/`.activeInActiveApp`. Prove the native host structure in a
real hosted List before adding larger sizing; do not accept a rendering-only pass or disable
the entire list to achieve it. Actual covered-row hover/tooltip isolation relies on AppKit
routing pointer events to the topmost native window. Hidden tests cannot confirm that OS
behaviour or exercise the tooltip popup manager; the structural/synthetic proof below explicitly
covers that limit.

## Files

Paths in the following table are relative to the repository root.

| Action | File(s) | Purpose |
| --- | --- | --- |
| Modify | `daemon/aitermd/models.py` | Optional display metadata on internal jobs and ordered wire work items; preserve raw text, ordering and readiness. |
| Modify | `daemon/aitermd/agents/claude.py` | Stop descriptions, confirmed Bash description joins, parent Agent launch descriptions; preserve inventory and reader availability. |
| Modify | `daemon/aitermd/agents/codex.py` | Native ID/task-path parsing in the existing cursor and guarded read application. |
| Modify | `daemon/aitermd/status.py` | Scoped child display enrichment with existing lifecycle ownership and unchanged state decisions. |
| Modify | `app/Sources/AiTermCore/Daemon/DaemonTypes.swift` | Optional wire field, app job display value and fallback; keep raw `text`. |
| Modify | `app/Sources/AiTermCore/Sidebar/SidebarModel.swift` | Carry labels only in the display projection, preserving raw background/Operator projections. |
| Modify | `app/Sources/AiTerm/SidebarProjection.swift` | Resolve the open source's current projected jobs and visibility; the shared row/presenter eligibility rule also applies task teardown. |
| Modify | `app/Sources/AiTerm/Views/BackgroundCard.swift` | Label, font, speech/help, fixed heading and five-row scrolling layout; route hover presentation through the sidebar owner. |
| Create | `app/Sources/AiTerm/Views/BackgroundCardPresenter.swift` | App-specific nonactivating child-panel presenter, shared source eligibility, cross-host anchors, placement, hover ownership and cleanup. |
| Modify | `app/Sources/AiTerm/Views/SidebarView.swift` | Install the presenter around the native viewport, above List clipping and below reserved chrome. |
| Modify | `app/Sources/AiTerm/Views/SidebarRows.swift` | Source-row identity/anchor handoff, covered-row interaction isolation where needed, and standalone fixture integration without changing row geometry. |
| Modify | `app/Sources/AiTerm/Snapshots/SidebarSnapshots.swift` | Representative cards for long labels, counts and scales using the same card content/layout; do not expect ImageRenderer to capture a native child panel. |
| Modify | `daemon/tests/builders.py`, `daemon/tests/test_claude_background.py`, `daemon/tests/test_codex_sessions.py`, `daemon/tests/test_status.py`, `daemon/tests/test_models.py`, `daemon/tests/test_hook_events.py` | Synthetic native metadata, ID joins, lifecycle isolation and ordered projection coverage. |
| Modify | `daemon/tests/test_service.py`, `daemon/tests/test_tick_budgets.py`, `daemon/tests/test_compat_captures.py` | Guarded reader-to-event integration, bounded unchanged-tick I/O, and matching existing native captures. |
| Modify | `daemon/tests/test_wire_contract.py`, affected session frames under `daemon/tests/wire/`, `daemon/tests/wire/PROVENANCE.md` | Exercise and document the deliberate optional protocol field; review only intended frame differences. |
| Modify | `app/Tests/AiTermCoreTests/DaemonTypesTests.swift`, `app/Tests/AiTermCoreTests/WireContractTests.swift`, `app/Tests/AiTermCoreTests/SidebarModelTests.swift`, `app/Tests/AiTermCoreTests/Operators/WorkerTabsTests.swift`, `app/Tests/AiTermTests/SidebarProjectionTests.swift` | Decode/fallback, description-only redraw and preservation of raw text/readiness/ordering. |
| Modify | `app/Tests/AiTermTests/BackgroundCardTests.swift` | Replace fixed-row-height assumptions and prove sizing/hover/speech with useful labels. |
| Create | `app/Tests/AiTermTests/BackgroundCardPresentationTests.swift` | Real native List placement, hit testing, scrolling, disappearing sources and presenter lifetime. Reuse `HostedSidebar` and hidden test windows. |
| Modify | `docs/daemon-protocol.md`, `docs/status-model.md`, `docs/design/ui-patterns.md` | Document display-label ownership, supported fallbacks and the larger card's presentation. |

Keep PI's driver/parser, CLI launch configuration, persisted workspace, Signal/Operator goldens,
Palette/Metrics, and the human design-system mirror outside this change. Compatibility captures
remain real evidence: use focused synthetic records in builders for new combinations rather
than editing native captures to fit tests.

## Proof

Tests must fail for the old behaviour and assert externally meaningful results:

- Feed the observed Claude shapes through native readers and status application: descriptions
  appear for an existing shell/child, foreground Bash stays absent, blank metadata falls back,
  and shell/monitor completion and unavailable-read behaviour remain the same. A metadata-only
  change must not change the job IDs/count/order, raw text, state or `holdsTurn`.
  Specifically keep a confirmed child's description visible while a separate shell makes the
  shell inventory uncertain/unavailable; the shell must retain its existing availability rules.
  Also exercise descriptor-cache overflow with a still-valid shell: bounding metadata must not
  consume the shell tracker's existing budget or clear otherwise-available shell state.
- Read an incrementally appended Codex started activity while its child is alive, with both
  hook/read arrival orders. Verify path humanization by exact child ID, old/malformed format
  fallback, partial/replaced files, bounded retained metadata and unchanged-tick reads. A late
  result must not relabel a replacement conversation, ended child or different child generation.
- Exercise reader results through a synthetic Service, the optional wire field, production Swift
  decoding and sidebar projection. Compare raw worker/background text and readiness before and
  after a label-only update. Preserve Signal contract goldens.
- Test card content/layout with 0, 1, 3, 5 and 6+ jobs: no card for zero, increasing height through
  five, fixed heading and only jobs scrolling beyond five, one-line truncation, prose/code font
  choice, complete speech and a row that never grows. Cover task and terminal sources and all
  three interface scales.
- Host the actual sidebar with native List and neighbouring rows. Verify the panel's parent,
  ordered-above relationship, nonactivating/key-focus policy, frame and hosting-view hit testing.
  Derive covered/uncovered point ownership only from those app-owned objects and
  `contentView.hitTest`; never query the window server or the person's desktop with
  `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`. The panel's frame must contain the
  covered point and its hosting view must hit the card content, while the uncovered point lies
  outside the panel. Include a red control using a plain same-window SwiftUI overlay: it must
  fail the separate-window assertion. This control proves the assertion detects the chosen
  host architecture, not that hover cannot leak. After closing the card, app-owned geometry/hit
  testing again resolves the covered coordinates to the underlying row's hover/help target.
  Actual OS event/tooltip isolation remains the stated AppKit assumption, not a tested popup.
- Deliver synthetic mouse enter/exit/move and wheel events directly to the hidden windows or
  native tracking handlers; never move the person's real cursor or use `keepVisible`. Verify
  event/tracking callbacks in a positive control before counting a negative hover assertion;
  if `window.sendEvent` does not exercise SwiftUI tracking, use the explicit presenter handlers
  and the structural isolation proof, and record that limit. Cache drawing where it is useful,
  rather than claiming a missing tooltip/hover from an event that never reached its handler.
  Prove mark-to-card delayed handoff, inner scrolling and return to uncovered list interaction.
  Inspect native tracking options to require `.activeAlways`; directly sent events alone do
  not establish that tracking also runs while the app is inactive.
- Verify one owner; close on empty/removal/reuse/list scroll and when the sidebar hides/closes.
  Start task teardown while its row/jobs still exist and the pointer state is on the card: it
  must close and the row must offer none. Verify bottom-row/short-viewport placement,
  titlebar/footer clearance, resizing, and a label-only update without reopening. All test
  windows and panels remain hidden under the existing hook; no visibly interactive test window.
- Capture `scripts/snapshots.sh build/background-before` before product edits, then
  `scripts/snapshots.sh build/background-after` afterward and inspect the PNGs. Include standard
  and extra-large long-label/many-job cases. ImageRenderer fixtures compose the production
  card content directly for appearance proof; hidden hosted tests own native panel placement
  and routing. Column snapshots alone cannot establish those properties.

While iterating, use `scripts/test.sh swift -- --filter <Suite>` and the worktree daemon venv's
pytest on the affected suites, with at least one selected test. Run plain `scripts/test.sh` before
every commit; start queued test runs in the background and let the command finish. Once before
merging this HEAD to main, run plain `scripts/test.sh all` with no suite overrides. Do not use
`scripts/run-dev.sh` or disturb the running session for verification.

## To-dos

- [ ] Before any product edit, record the starting HEAD and capture
  `scripts/snapshots.sh build/background-before`. Then add the optional display metadata end to
  end, including label/font/speech/help rendering in `BackgroundCard.swift`, absent-field
  fallback, a deliberate wire example, and tests proving raw text, readiness and display ordering
  are unchanged. The card still uses its current placement and height in this step.
- [ ] Enrich existing Claude shell/child labels from Stop and confirmed parent launch records,
  with reader/status/Service tests for identity, availability and lifetime boundaries.
- [ ] Enrich existing Codex children from the incremental native ID/path activity, proving a
  label-only redraw and guarded lifecycle/cache behaviour without additional scans.
- [ ] Move the current-height card into the shared floating presenter, observing the current
  projected jobs for the open source. Prove native List anchors, hit testing, covered-row
  hover/tooltip isolation, one-owner hover and source lifetime with hosted tests.
- [ ] Give that presenter/card downward growth through five job rows, a fixed heading and
  scrolling jobs, plus viewport-aware placement. Prove sizing, short/bottom-row placement and
  interface scaling while leaving row geometry unchanged. Label/font/speech rendering remains
  owned by the first step; this step changes geometry only.
- [ ] Update the representative snapshots and product/protocol docs, inspect before/after
  evidence, run the branch gate and take the implemented change through review.

## Plan challenge

Three independent Claude review rounds completed; all findings addressed, none left open.

- Round 1: fixed one Important finding about covered-row hover/tooltips and four Minor findings
  about proof, capture ordering, step size and presenter state ownership. Made the uncertain-shell
  label test explicit, moved before-captures to the first step, separated presentation from sizing,
  and adopted the source identity/anchor lookup rather than copying job lists.
- Round 2: fixed one Important finding about vacuous hidden-window hover tests and one Minor
  finding about task teardown. Chose the child-panel host explicitly, specified structural and
  synthetic checks with positive controls and stated the limits of tooltip-manager proof. Shared
  row/presenter eligibility preserves no-card-during-teardown. Round 3 accepted both fixes.
- Round 3: no Critical/Important findings. Fixed two Minor findings by explicitly prohibiting
  window-server point queries in hidden tests, limiting what the architecture control claims,
  and requiring inactive-app `.activeAlways` tracking with an options check. Also made descriptor
  budget isolation explicit from the review's unverified-risk notes.

No product implementation or runtime proof has been claimed in this planning phase. Native OS
tooltip/event isolation is a documented platform assumption; the planned hidden tests prove host
structure and synthetic routing, not observation of the system tooltip popup manager.
