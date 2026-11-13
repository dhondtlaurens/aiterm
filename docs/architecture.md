# Architecture

AiTerm is a native macOS sidebar over real iTerm2. The Swift app owns the workspace and user intent;
the Python daemon owns iTerm2 access and agent telemetry. The Unix socket joins them. iTerm2 owns the
terminal windows and running agents, which keep running when AiTerm quits.

## Package boundaries

| Target | Responsibility |
| --- | --- |
| `AiTermCore` | Domain values, pure decisions, Git/HTTP/process/persistence adapters. No UI dependency. |
| `AiTermUI` | Palette, metrics, appearance-aware surfaces and reusable controls. No Core or app imports. |
| `AiTerm` | Main-actor runtime owners, view models, AppKit integration and SwiftUI compositions. |
| `aitermd` | asyncio composition of iTerm2, session registry, hooks, delivery, RPC and Operator MCP. |

Use concrete owners for stable behavior and protocols for real I/O seams. A new feature should use an
existing operation before adding a parallel service. Blocking work never runs on the cooperative
executor; putting it in an actor would still block that executor. Work that ends within a deadline
(git, a file read, a process with a timeout) runs through `BackgroundWork`, on the shared pool or on
a repository's lane. Jobs that block for seconds run on a `SerialThread`; one such call runs on
`ThreadWork`. `FolderCheck` asks whether a folder exists on a thread of its own. `AgentProcess`
separately owns long-running cancellable process groups.

Commit ids, remote URLs, real paths and file stamps each have one Core home: `CommitId` (one rule
for the push, the local merge and `record_review`), `RemoteURL` (the provider's reading and the
push's same-location key, which compares percent-decoded paths), `CanonicalPath` and
`FileStamps.Stamp`. Process and git output take an optional limit and report truncation.

## Workspace and observation

`WorkspaceStore` is the persisted workspace's single writer. It coalesces normal saves, serializes
them, and exposes `flush()` for boundaries that must be durable before proceeding. `StateStore`
atomically writes the file and maintains recovery copies. Invalid records fail at this boundary;
they are never silently discarded and then overwritten with a partial workspace. Recovery keeps
the unreadable bytes available. A backup must itself decode to be usable; historical unstructured
broadcasts require cleanup in the installed build before switching, as described in
[releasing](workflow/release.md).

`AppState` stores projects, tasks, terminals, the shelf and structured Operator runs. Runtime jobs,
current sessions and derived attention/readiness are separate. `LiveSessions`, `PerRow` and
`SidebarProjection` keep observation scoped to what a row draws. One `SidebarPass` per derivation
matches the live runs' requests and their tasks' worker tabs once, as of one time, for the headers,
the rows and the board; the headings read only their own values. `CheckoutMonitor` samples Git off
the main actor, reuses unchanged facts and coalesces title updates. Avoid whole-workspace reads in a
leaf view or I/O in `body`.

`AppController` composes owners. It takes its outside dependencies as `AppPorts` (live or scratch,
the Fix pipeline among them) and its waits as `AppTimings`, and `choose(_:)` owns what choosing a row
does. Owners publish changes through `HookList`, whose hooks return removal tokens; a hook with one
slot says so in its name. `SheetCoordinator` owns the single sheet slot and cancels stale
preparation. Creation models share `CreationModel`, `CreationSheet` and model/reasoning controls;
provider lookup and missing-model policy remain with the caller. `LatestTask` replaces a prior
request, whereas `TickPass` drops overlapping polling passes, and `DebouncedSearch` keeps the latest
search after a pause for the pickers and the ticket field. These lifetimes are deliberately
different.

## Task and window operations

Git work that changes a repository runs on that repository's lane (`GitLanes`), keyed by its git
common directory, so a project's folder and its worktrees share one and work on one repository never
waits for another's. Manual creation, worker checkout, restore, removal, pull, rebase, Fix landing,
local merge and the merged-branch check run there through `TaskWorkflow` or the lanes directly; a
head or an unsaved-work question runs on the shared pool. `TaskCreator` owns branch/worktree
creation; worker retry reuses the existing worktree and its original baseline. Scheduling, focus,
claim validation and uncertainty belong to their callers.

`TaskLauncher` starts manual tasks and restores conversations. `WorkerStarter` claims ready tasks,
prepares the same lower-level checkout operation, and launches workers in the background.
`TabOpener` tags additional workers/reviewers in the task's window. A lost launch reply is resolved
through tags, never a blind duplicate launch. Closing AiTerm prevents unstarted launches while
allowing an already-requested window to be recorded.

`WindowReconciler` compares desired rows with tagged sessions. It adopts, restores, asks about a
single user close or removes a terminal row. A pass runs when the tabs as a pass reads them move, a
checkout reads missing or back, the workspace can change again, or a workspace change leaves a row
owed a window; each checkout poll checks in memory whether a pass would act. `ClosedWindowTriage`
distinguishes a lone close from iTerm2 shutting down. `TaskRemover`, `TaskArchiver` and
`WorktreeTeardown` coordinate saved state, window closure and Git safety: Remove and Shelve share its
prepare (one `TaskWorkflow.preflight` listing, the unlisted-folder and unsaved-work questions) and
its run (git's removal, asking again about work written while the window closed). A failed removal
retains a recoverable task. See [windows](windows.md).

## Operator ownership

The supported broadcast format has structured Agents, Task and Done settings. There is one
execution path, generated brief and current model-selection policy. Sparse fields deliberately
omitted by the current encoder still decode; historical broadcast format readers and unknown-field
round-trip machinery are absent.

| Owner | Decisions/effects |
| --- | --- |
| `RunScheduler`, `OperatedTransitions`, plan rules | Pure readiness, ownership and task/plan transitions; every edge is an `OperatedEdge` recorded through `OperatedTransitions.record`. |
| `TaskLiveFacts`, `TaskItem.workerTabs(in:now:)` | One live projection per pass, with the launch window: the one readiness input for `run_status`, the reconciler, the row line and the board. |
| `BroadcastCompletion` | Shared completion and goal-loop decisions used by runtime and tool adapters. |
| `OperatorController` | Build owners in dependency order and hand them references (callbacks only carry events up), schedule work, reconcile runs and summaries. |
| `OperatorWork` | The finite work owners start, which tests await as one `settled()`; the reconcile loop and a wake retry stay out of it. |
| `RunStatusSource` | The one status builder every reader uses; a tick builds one snapshot per open run. |
| `OperatorToolHandler` | Parse/validate MCP calls through the `OperatorTool` traits, invoke rules/effects and produce current tool replies; its tables change only through its own methods. |
| `OracleJobs` | Challenge, relay, critique and gate jobs: Stop and quit cancel all, End its run's, a Settings save the unacted challenges; a late completion cannot settle its replacement. |
| `WorkerPrompts` | Per-session prompt probes, post-delivery probes and generation-based cancellation. |
| `WorkerTurnReader`, `WorkerQuietWatch` | Ended-turn facts and quiet/stall evidence; consume an immutable `WorkerSessions` index per pass. One record per worker. |
| `TranscriptLocator` | Transcript tails read again only when the file's stamp changed, shared by the turn reader and `BranchWatch`; only a conversation's newest read keeps what it found. |
| `OperatorWaker` | Coalesced notifications and safe wake delivery over the closed set of `WakeReason`s, invalidated on stop/takeover. |
| `OperatorWindows`, `PauseSignaller` | Reopening the Operator's window and the closing sweep; the pause and carry-on notes. |
| `BranchWatch`, `ReviewWatcher` | Bounded asynchronous reads, dropping late replies after cancellation; a host and its user found once per pass. |
| `TaskFinisher` / `TaskPublisher` | One publication per task, one work record per task in the finisher; durable step recording, current authority checks and merge watches. `TaskPublication.problemKind` is saved beside a problem and read instead of its wording. |
| `TaskAutoCloser` | Close eligible completed tasks while preserving unsaved work and recorded evidence. |

Host reads share only when repository, request and accepted commit match. An in-flight identity
prevents an old response from replacing a newer owner's cache. Stop cancels owned reads, probes,
ticks, watches, summary waits, pause notes, the closing sweep, replaced registrations and Oracle
jobs; End cancels its own run's Oracle jobs. After every suspension, an effect owner checks cancellation and
current identity/authority before starting consequential work. A completed external write is still
recorded; shutdown prevents the next step, rather than pretending the completed step never happened.

Publication checks the pushed repository's protection and the accepted commit. Review/merge policy
uses complete reads; a truncated protection/thread listing is not evidence of permission. Human
review and agent review tabs remain separate. The Oracle is a second-opinion process, not a second
workspace writer. [Operator guide](operators.md); [contract protection](testing.md).

## Integration and platform owners

`HTTPJSON` and `HostAPI` share JSON transport and credential-safe redirects. GitHub, GitLab and Jira
retain their actual pagination and error semantics: a picker may show a bounded subset, while
publication must refuse an incomplete safety read. Each GitHub and GitLab client is bound to one
repository when it is made (`HostRepository`). `HostFailure.outcomeUnknown` says whether a failed
write may have reached the host; a failure before sending is not. A token's user is kept per host
and token until Settings saves. Commands use typed arguments and hermetic Git
configuration in tests.

`HarnessDriver` describes agent installation/checks. `UserConfigFile` protects symlinks and foreign
configuration, writes backups and limits repairs to owned integration entries. Installation and
credential changes are explicit user actions.
Operator startup also records trust for its own generated run folder in the resolved Claude
profile's global JSON. It preserves unrelated state and a backup, uses Claude's config lock and
an atomic private write, and skips the write when that exact folder is already trusted.
`FixSession` owns an isolated clone through proposal, apply, landing and cleanup; quit cannot begin
a new landing after an awaited agent reply.

`BackpackController` owns Unplugged permissions, network/lid-sleep transitions and cleanup.
`MachineMonitor` samples in-process platform readings. `UpdateController` owns release lookup,
validated download and replacement; development builds disable self-update. These platform owners
keep their existing focused seams rather than using a generic job/workflow framework.

## Daemon

`Service` composes the iTerm2 port, registry, status readers, delivery adapters, hook receiver,
window manager, RPC and Operator MCP. It talks to iTerm2 through `ItermPort` (`iterm_port.py`);
`ItermBridge` is the one SDK adapter and patches authentication when it connects. Screen recognition
is pure (`screens.py`). `ItermSupervisor` owns reconnect/cookie handling. A locked refresh serializes
snapshots and creation; tick consumers reuse that pass's session view, and task lookups use its
index. `CorroboratingReaders` captures each corroborating read on the loop, runs it off the loop
under a deadline and applies it on the loop. `SessionNotFound` marks a session that is truly
absent. Generation/session identity prevents late telemetry
from attaching to a replacement process.

The app-resolved Claude configuration directory travels in `workspace.snapshot` and is echoed as a
bootstrap compatibility check. A snapshot is a barrier before later events; overflow, malformed
frames or an unreadable known event disconnect and bootstrap again. An adopted daemon is not killed
as though it belonged to the current app. [Protocol reference](daemon-protocol.md) and
[daemon development](../daemon/README.md).

## Where the facts come from

| Fact | Source |
|---|---|
| status dot | agent hooks, plus Claude's own session file and the tab title's spinner glyph as corroboration |
| avatars | iTerm2's session list, plus a native agent child of an unrecognized foreground runner (such as a piped review). A single current-user process-table read per snapshot resolves children in the runner's process group, using the agent's own pid; background jobs and ambiguous parallel agents keep the terminal mark. One mark per tab, in tab order |
| branch | the *agent's* working directory, never iTerm2's: `session.path` is the shell's and never follows a Claude that entered a worktree |
| diff badge | `git diff --numstat` from the merge-base with the task's base, plus the untracked files' lines (at most 2,000 files and 20 MB; a file over 1 MB is skipped). Kept 5 s, inside the 2 s checkout pass; the merge-base is kept until a ref it joins moves. While the refs stand still an expiry costs two git processes per task — 40 at 20 tasks, where it was 100 |
| Claude usage | the `statusLine` shim — Claude Code hands rate limits to that command and to nothing else. It posts with `curl` to the hook port its driver recorded in `hook-port` and starts no `python3` |
| Codex usage | the `rate_limits` block Codex writes into every `token_count` record of its rollout file under `~/.codex/sessions` — the same file the context fill comes from, no subprocess |
| context fill | the same `statusLine` payload's `context_window`; the reporting session updates its task's last-known value, and the footer draws it only while that task is selected |
| provider icon | the git remote URL, or the repo itself |
| tickets | Jira Cloud REST, credentials in the Keychain |
| review threads | GitLab REST (`/merge_requests/:iid/discussions`, a discussion with a resolvable note, resolved when all of them are) on the configured GitLab host and port only, and GitHub GraphQL (`reviewThreads { isResolved }`), with the tokens Settings saved; read-only, 100 a page, at most 10 pages |
| models | each CLI's own catalogue cache, so the picker follows `/model` |
| conversation | each agent's own hooks — Claude's and Codex's `session_id`, PI's session id — kept only for a post placed on its tab by pid or by the tab id it carries, never by a pin or the directory; a subagent's start or stop names none, and it goes with the agent's process as the model does |
| a worker's live model and effort | Claude's own word on its session: `SessionStart`'s model, `PostModelSwitch`'s `to_model`, the status line's `model.id` and `effort.level`; only from a post placed by evidence and not from inside a subagent (`agent_id`), and never a hook's own `effort`, which is its turn's. `run_status` shows them beside the planned model, for Claude workers only, and on the board card's model tooltip; they never wake the Operator |
| what became of a slash command | the Claude tab's transcript, named by its own hooks and status line (`transcript_path`) and read on every tick, off the loop, from where it ended when `message_task` typed the command: its command record, or a `queue-operation` enqueue holding it (`slash_commands.py`, docs/status-model.md) |
| a worker stopped on an API error | Claude Code's `StopFailure` hook, in place of `Stop`: its `error` (`rate_limit`, `billing_error`, `authentication_failed`...), and for a limit when it resets, read only from the transcript's own record of it (`apiErrorParams.rate_limit_info.resetsAt`) within 30 s of the hook. Cleared once the session works again. `run_status` lists the task under no obligation and says why under `stoppedOn`; its card reads `blocked · usage limit, resets 13:20` |
| skills & commands | discovered on disk per agent and per project, for the prompt step's completions |

## What AiTerm writes, and where

| Data | Owner/location |
| --- | --- |
| Workspace, recovery and logs | `~/Library/Application Support/AiTerm/`; `StateStore`, `WorkspaceStore`, logging and daemon supervisor. |
| Credentials | Keychain service `com.laurensdhondt.aiterm`, account `secrets`: service tokens and hotspot password. Settings validates before writing and rolls back failed changes. |
| Task worktrees | `<repo>/.worktrees/<slug>`; task operations reserve shelved paths and check branch/worktree ownership before deletion. A folder git still lists counts as taken, and cleanup prunes git's record of a worktree deleted outside AiTerm. `.worktreeinclude` copies selected ignored files. |
| Agent drivers | Claude's resolved config directory, `~/.codex/` and `~/.pi/agent/extensions/`; explicit Install/Repair keeps backups and foreign entries. Hook resources ship in the app bundle. |
| Operator artifacts | Per-run brief/configuration and local token-managed access under application support; large worker messages under the task's `.aiterm/messages/`. |
| Preferences | Interface and integration choices, hotspot name and engagement marker. Tests use scratch defaults. |
| Lid sleep permission | `/etc/sudoers.d/aiterm`, installed/removed only through the Mac permission action. |
| Local transports | Application-support Unix socket; hook HTTP on `127.0.0.1:47821`. |

Shelving saves the record before removing the worktree and keeps its branch/conversations. Restoring
uses its reserved path and checks that the folder/branch can be used. Removing a project forgets
its rows; it does not recursively delete its repository. Current workspace/credential recovery
remains necessary even though historical broadcast compatibility is removed.

## UI and verification

The app is dark-only. Palette and Metrics are the source of visual values; the
[UI README](../app/Sources/AiTermUI/README.md) defines component rules. The design-system HTML mirrors
the code and holds proposed visual changes separately. Refactors change no visual values.

[Testing](testing.md) describes the gate, current-format fixtures, real adapter proofs and opt-in
live checks. Debug snapshot entry occurs before live workspace migration/controller construction,
so fixture rendering does not connect to the running app's state or daemon.
