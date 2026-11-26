# Background work with vendor avatars

## Goal

Each line of the background-work card leads with a `VendorMark` instead of an SF Symbol. Agent work (a subagent, a
teammate, a workflow, a cloud session, a dream) shows the vendor of the tab it runs in: Claude or Codex. Everything
else (shells, monitors, MCP tasks, memory saves, auto-mode scans) shows the terminal mark. When two or more agents
run, the card's heading also shows them as an avatar group.

Picked on the design-system Proposals tab (`#p-bgwork`, 26 Nov 2026):

- **A, at 16 pt for every mark.** Agents and tools alike are drawn at `Size.vendorMark`, in a `Size.vendorMark`
  column.
- **B2 without the idle heading.** An idle teammate wears a `zzz` disc of `Size.cornerBadge` on its avatar's corner.
  The `Idle (can be messaged)` heading is removed. Idle lines still follow the running ones.
- **C1.** An `AvatarGroupView` at `Size.vendorMark` sits at the trailing end of the heading, from two running agents
  up. It follows the task row's rule: at most `avatarMax` slots, the last becoming `+n`.

## Evidence

Claude Code 2.1.332 names its Stop `background_tasks` types from this table in its binary: `local_agent: subagent`,
`local_workflow: workflow`, `local_bash: shell`, `monitor_mcp` and `monitor_ws: monitor`, `mcp_task: MCP task`,
`in_process_teammate: teammate`, `dream: dream`, `auto_mode_scan: auto-mode scan`, `post_turn_memory: memory save`,
`remote_agent: cloud session`. Codex reports only subagents (SubAgentActivity). PI reports no background work.

## Approach

- **Daemon.** A new wire kind, `agent`, for agent work Claude Code does not count as a child: `workflow`,
  `cloud session` and `dream`. In `work_items` it behaves exactly as `task` does, so `holdsTurn` and the rest of the
  lifecycle stay unchanged. An older app decodes it as `.task` (lenient decoding).
- **Core.** `BackgroundJob.Kind` gains `.agent`, and `BackgroundJob` gains `agent: SessionAgent?`, the vendor of its
  tab. Only `SidebarModel.displayJobs` (the card) sets it. `backgroundJobs` (status and the Operator) stays as it is.
  `SidebarModel.avatars(of:)` builds an `AvatarGroup` from agents, and `avatars(for:)` uses it.
- **UI.** A new `Surface.menu` for a popover's ground (`Palette.menu`), so rings drawn on the card occlude in the
  card's own colour. `AvatarGroupView` takes a size (default `Size.avatar`). `BackgroundCard.mark` replaces `glyph`:
  vendor or terminal. `lines` becomes the running jobs, then the idle ones, with no heading between them.

## Files

- `daemon/aitermd/agents/claude.py`, `daemon/aitermd/models.py`, `daemon/tests/test_hook_events.py`
- `app/Sources/AiTermCore/Daemon/DaemonTypes.swift`, `app/Sources/AiTermCore/Sidebar/SidebarModel.swift`
- `app/Sources/AiTermUI/Surface.swift`, `app/Sources/AiTermUI/README.md`
- `app/Sources/AiTerm/Views/BackgroundCard.swift`, `AvatarGroupView.swift`, `Snapshots/SidebarSnapshots.swift`
- `app/Tests/AiTermTests/BackgroundCardTests.swift`
- `docs/design/design-system.html`: delete the proposal, sync the Background work component

## Proof

- Tests: the daemon maps `workflow`, `cloud session` and `dream` to `agent`; the card's marks, its idle order and
  its heading group; `displayJobs` carries the tab's vendor.
- The gate, `scripts/test.sh`.
- Snapshots before and after (`scripts/snapshots.sh`), comparing the work-card PNGs. A new
  `sidebar-work-cards-agents.png` shows a Claude subagent, a Codex subagent, a workflow and a shell together.

## To-dos

- [x] Daemon `agent` kind and its test
- [x] Core: `.agent`, the job's vendor, `avatars(of:)`
- [x] UI: `Surface.menu`, sized `AvatarGroupView`, the card's marks, idle corner and heading group
- [x] Tests and snapshots
- [x] Design-system page synced, the proposal removed
