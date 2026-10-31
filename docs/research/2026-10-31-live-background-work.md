# Live background work during an active agent turn

## Question

Can AiTerm show a reliable inventory of background terminals and subagents while Claude or
Codex is still working, using telemetry available to the existing sessions?

This feeds the plan for opening the existing work card from a working spinner. Laurens confirmed
the scope on 31 October 2026: background work and subagents, excluding the foreground command.
The card must describe work still in flight without changing agent status, attention or Operator
readiness. Monitors belong in it where their lifecycle can be established.

## Recommendation

Keep the display inventory separate from the existing ended-turn obligations. Plan the card's
availability around the inventory, rather than the row's background status, using verified task
and child signals. Complete, strictly background-only Codex terminal detail is not supported by
the sources established in this spike; keep that requirement open rather than claiming coverage.

Codex offers a useful alternative if the scope changes: its experimental live terminal API can
list all managed running commands for threads hosted by its shared service, including nested
code-mode commands. It also includes foreground commands and cannot see embedded sessions.
Adopting that alternative requires an explicit product choice and separate launch compatibility
work. It is not a transparent replacement for background-only telemetry.

## What was tried

1. Read the sidebar projection, card, daemon status engine, hook parsers, thread resolver and
   launch arguments. Searched plans and Git history for related work. There was no existing
   `docs/research/` directory. The GitHub issue search returned no matching background issues.
2. Inspected existing recordings with a throwaway, read-only Python probe. It emitted schema
   counts and relative timelines, without conversation text, commands or private identifiers.
3. Checked installed CLI help and generated its experimental JSON Schema into a scratch folder.
   Compared the relevant implementation with the matching official source tag.
4. Connected to the already-running Codex service, using only initialise and list requests.
   Tested an unloaded synthetic thread ID and checked that the loaded-thread count stayed zero.

No product code, driver settings, running conversations or agent launches were changed. The
throwaway probes remain outside the repository. No model requests or replacement app launch
were needed.

## Evidence

### Existing AiTerm boundaries

- `app/Sources/AiTermCore/Sidebar/SidebarModel.swift` filters `backgroundJobs` to tabs whose
  turns ended. Its existing active test activity is also appended to that list.
- `app/Sources/AiTerm/Views/SidebarRows.swift` additionally offers the card only for the
  background mark/status. Both task and terminal rows have this restriction.
- `app/Sources/AiTerm/Views/BackgroundCard.swift` always says the turn ended. That wording is
  unsuitable for the proposed active-turn card, including rows with mixed tab states.
- `daemon/aitermd/status.py` clears ended-turn background obligations on a new working event.
  Counted children already have start/stop and transcript reconciliation, but a child's start
  does not itself add a description to the sidebar's job list.
- `app/Sources/AiTermCore/Operators/WorkerTabs.swift` consumes these obligations for readiness.
  Widening their meaning to every active command would also change Operator behaviour.
- Commit `f8da600d` already fixed Operator background reporting when a sibling tab works.
  That change does not expose the sidebar card during an active turn.

### Recorded Codex code-mode commands

The local CLI reports `codex-cli 0.166.0`. A captured scan of the 35 newest rollout files saw
session metadata for 0.163.0, 0.165.0 and 0.166.0. Resumed files may contain multiple metadata
records, so those are not disjoint file counts.

| Captured observation | Result |
| --- | --- |
| Completed command items | 1,681: 1,588 completed, 93 failed |
| Non-final `CommandExecution` items | None in this sample |
| `exec_command_begin` / `exec_command_end` event records | None in this sample |
| Commands with earlier parsed, printed running-session metadata | 130 |
| Decisive code-mode example | Launching cell returned after 1.166 s; command runtime was 156.878 s; its completion arrived 155.871 s after the cell returned, with no earlier printed running-session metadata identifying its process |

The commands without printed metadata include ordinary foreground commands. That total alone
does not prove a missing background inventory. The decisive example does: a command outlived
its launching cell without the optional printed metadata. Matching its command against the
cell's source was a research technique, not a proposed JavaScript or stdout parser for AiTerm.

The matching source explains the gap. The rollout policy drops transient execution begin/end
events. Paginated history keeps completed command items, and unified-exec PostToolUse suppresses
responses while a process ID remains present. A recorded code cell need not print its inner tool
results. See the [rollout policy](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/rollout/src/policy.rs#L128)
and [PostToolUse response rule](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/tools/context.rs#L481).

### Codex's live service API

Official source: `rust-v0.166.0`, commit `6ff1e1ca3b30fc8b914720681fcf5fe62e95f856`.
The same terminal-list method also exists in the inspected 0.165 source; no broader version
compatibility claim is made.

Initialise with `capabilities.experimentalApi = true`, then call
`thread/backgroundTerminals/list` with `threadId`, optional `limit` and `cursor`. Follow
`nextCursor`. Entries carry `itemId`, `processId`, `command` and `cwd`, with optional process
metrics. The handler looks up an already-loaded thread and reads its process store; it does not
resume an unloaded thread. Nested code-mode tools use that same execution manager.
[Protocol](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server-protocol/src/protocol/v2/thread.rs#L1242),
[existing-thread lookup](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/request_processors/thread_processor.rs#L1065),
[list handler](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server/src/request_processors/thread_processor.rs#L2605),
[nested dispatch](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/tools/code_mode/delegate.rs#L304).

Two limitations prevent this API from fulfilling the agreed scope:

1. A process enters the store before the initial exec call waits or yields. The list filters
   only exited processes. The internal `initial_exec_command_active` flag is not exposed, so a
   foreground command also appears. `processId` is a synthetic manager ID; the handler fills
   `osPid` with null, so matching it to `ps` is not a valid workaround.
   [Registration before waiting](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/unified_exec/process_manager.rs#L615),
   [list filter](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/core/src/unified_exec/process_manager.rs#L1837).
2. Embedded sessions have no remote connection. In this Codex version, arbitrary command-line
   configuration overrides can force embedded execution. AiTerm's `Harness.modelArguments`
   supplies `-c model_reasoning_effort=...` when reasoning is selected, which falls outside the
   daemon-compatible override whitelist. Changing launch mode must preserve model, reasoning,
   hooks and conversation ownership; dropping the reasoning flag is not an equivalent launch.
   [Embedded connection](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/app_server_connection.rs#L18),
   [launch exclusions](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/daemon_startup.rs#L61).

The existing local control socket uses WebSocket over Unix. A first JSONL attempt was closed;
the WebSocket connection then succeeded. `codex app-server proxy` relays raw bytes and does not
convert JSONL into WebSocket frames.
[Acceptor](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/app-server-transport/src/transport/unix_socket.rs#L191),
[proxy](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/stdio-to-uds/src/lib.rs#L12).

The read-only live probe produced:

```text
initialize: success
thread/loaded/list: success, 0 loaded, no next page
thread/backgroundTerminals/list for an unloaded synthetic UUID:
  -32600, thread not found
thread/loaded/list afterwards: 0 loaded
```

This proves connectivity, method availability and rejection of an unloaded thread. It does not
prove a nonempty live inventory, embedded-session coverage or live exit latency. No thread was
resumed to create a positive result.

The visible footer can supply a count when present, but not the complete commands. Its count
comes from TUI runtime state; reading it does not resolve the classification or embedded API gaps.
Automatically typing `/ps` would also interfere with the person's terminal input.
[Footer implementation](https://github.com/openai/codex/blob/6ff1e1ca3b30fc8b914720681fcf5fe62e95f856/codex-rs/tui/src/bottom_pane/unified_exec_footer.rs#L45).

### Claude and subagents

A separate scan of 20 recent Claude main transcripts found 49 explicit background tool calls,
33 results with `toolUseResult.backgroundTaskId`, and 31 distinct launched IDs with a later
`<task-notification>` in the same transcript. All 63 sampled task notifications reported
`completed`; their `<task-id>` and `<status>` identify completion without parsing command stdout.
An asynchronous Agent result included `agentId`, `description`, `isAsync` and `status`.

These establish usable active-turn launch and completion evidence for Claude shells and named
children. They do not establish every failure or interruption shape, or a general monitor
lifecycle. Existing child hooks and transcript reconciliation remain important. The Codex
sample contained only two persisted child `started` items and nine `interacted` items, which
does not establish a complete child lifecycle from those recordings alone.

## Reproduction

The throwaway scripts used for this spike are `/tmp/aiterm-recorded-work-probe.py` and
`/tmp/aiterm-live-terminal-probe.py`. They are deliberately not product code or committed helpers.
The recording sample can change while sessions continue writing; the table above records one
captured run. Repeat with:

```sh
codex --version
python3 /tmp/aiterm-recorded-work-probe.py
codex app-server generate-json-schema --experimental --out <scratch>/schema
<python-with-websockets> /tmp/aiterm-live-terminal-probe.py
gh issue list --repo dhondtlaurens/aiterm --state all --search background --json number,title,url
git show --stat f8da600d
```

For a fresh probe, read the newest 35 Codex rollout files and newest 20 Claude main transcript
files, count the record types above, and correlate only explicit IDs. The live script connects
to the existing `~/.codex/app-server-control/app-server-control.sock` with WebSocket over Unix,
initialises with experimental capability, lists loaded threads, lists their terminals, and
queries a synthetic unloaded UUID. It sends no start, resume, subscription, input, terminate or
clean request. A daemon-missing or unsupported-method result must remain unavailable evidence,
not an authoritative empty inventory.

## Open points

- **Product scope:** retain strict background-only commands and defer unsupported Codex terminal
  detail, or explicitly accept all managed running terminals and scope daemon integration.
- **Strict Codex classification:** a supported background/yield field or filter, or another
  verified runtime source, is needed. Existing recordings and hooks do not establish it.
- **Service coverage:** a shared-daemon design needs a launch approach preserving AiTerm's
  reasoning and other settings, capability checks and identity-safe unavailable handling.
- **Claude completeness:** validate failed/stopped tasks, missed notifications, replacement
  conversations and recovery, plus monitor lifecycles before claiming complete support.
- **Implementation proof:** test live launch, continued agent work, exit without a further poll,
  and process replacement. A nonempty direct-API probe remains unperformed. Keep these distinct
  from the successful read-only connectivity check and source analysis.

The research is complete as a feasibility finding. No implementation plan or acceptance of a
reduced scope has been inferred from it.

## Planning decision

Laurens subsequently approved planning the verified subset, with the explicit condition that
it uses the same list currently opened by hovering the background spinner. The plan is
`docs/plans/2026-10-31-background-work-card-during-active-turns.md`. Codex terminal detail stays
deferred. Counted children can appear during a Codex turn; existing test summaries remain
available on ended tabs, including an ended sibling in a mixed-tab row. Test-run locks alone
do not establish background execution during an active turn.

## Additional implementation evidence

The change review exposed delivery forms the first small sample missed. An expanded native
record check found parent `attachment` records whose `attachment.type` is `queued_command`,
`commandMode` is `task-notification`, and `prompt` contains the notification. It also found
`queue-operation` records with `operation: enqueue` and the notification in `content`. Both
forms carry a root timestamp. These can retire shells while the agent's turn continues,
without a `user` record or another tool poll.

In 15 parent files selected by a terminal-notification search, notifications matched to native
`backgroundTaskId` launches included 236 completed, 18 failed, two killed and two stopped
deliveries. These are recorded delivery counts, not distinct jobs; the same job may occur in
more than one carrier. The implementation treats these four statuses only as evidence that
the named shell no longer runs, never as success or an ended agent turn. Tests cover each
status through user, queued attachment and enqueue forms, alongside unknown-outcome recovery.

The initial recommendation to leave unverified terminal outcomes unavailable still applies
to unknown formats. It no longer justifies treating the now-verified failed/killed/stopped
notifications as unknown. This expanded evidence supersedes that part of the initial sample's
limitations. Codex terminal and general active-monitor limits are unchanged.
