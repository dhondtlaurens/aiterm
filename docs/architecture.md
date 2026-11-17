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

Commit ids, remote URLs, real paths and file stamps each have one Core home: the worker guard's
commit-id rule, `RemoteURL` (the provider's reading and the worker guard's same-location key,
which compares percent-decoded paths), `CanonicalPath` and
`FileStamps.Stamp`. Process and git output take an optional limit and report truncation.

## Workspace and observation

`WorkspaceStore` is the persisted workspace's single writer. It coalesces normal saves, serializes
them, and exposes `flush()` for boundaries that must be durable before proceeding. `StateStore`
atomically writes the file and maintains recovery copies. Invalid records fail at this boundary;
they are never silently discarded and then overwritten with a partial workspace. Recovery keeps
the unreadable bytes available. A backup must itself decode to be usable. End running broadcasts in the installed build before
switching to Signals, as described in
[releasing](workflow/release.md).

`AppState` stores projects, tasks, terminals, the archive, signals, seen items and one Operator
session. Unknown keys still round-trip. Runtime jobs and sessions stay separate. `LiveSessions`, `PerRow`
and `SidebarProjection` scope observation to drawn facts. Project and signal headings compare `HeadingValue`;
menus resolve saved tasks at action time. Journals, reply markers and launch history do not redraw
rows. `CheckoutMonitor` samples Git off the main actor and coalesces title updates. No leaf `body`
performs I/O or reads the whole workspace.

`AppController` composes owners. It takes its outside dependencies as `AppPorts` (live or scratch)
and its waits as `AppTimings`, and `choose(_:)` owns what choosing a row
does. Owners publish changes through `HookList`, whose hooks return removal tokens; a hook with one
slot says so in its name. `SheetCoordinator` owns the single sheet slot and cancels stale
preparation. Creation models share `CreationModel`, `CreationSheet` and model/reasoning controls;
provider lookup and missing-model policy remain with the caller. `LatestTask` replaces a prior
request, polling passes run from the Operator's tick, one per host and none while that host's last
pass still reads, and `DebouncedSearch` keeps the latest search after a pause for the pickers and the
ticket field. These lifetimes are deliberately different.

## Task and window operations

Git work that changes a repository runs on that repository's lane (`GitLanes`), keyed by its git
common directory, so a project's folder and its worktrees share one and work on one repository never
waits for another's. Manual creation, worker checkout, restore, removal, pull, rebase,
and the merged-branch check run there through `TaskWorkflow` or the lanes directly; a
head or an unsaved-work question runs on the shared pool. `TaskCreator` owns branch/worktree
creation; worker retry reuses the existing worktree and its original baseline. Scheduling, focus,
claim validation and uncertainty belong to their callers.

`TaskLauncher` starts manual tasks, restores archived rows, makes a worker's checkout and opens a
task's window with what its owner resumes; the Operator reaches its restore and checkout through
ports the app sets. `SignalWorkerIO` owns guarded CLI launch, extra tabs, delivery and conversation recovery.
Launch scope plus task/stage/ownership identifies an interrupted worker; adoption never repeats its
prompt. Durable reply fingerprints distinguish a newly sent turn from the previous transcript.
An accepted launch with no worker eventually blocks for inspection. Checkout work uses repository
lanes while separate windows can open concurrently.

`RowWindows` clears a row's window when iTerm2 says it is gone, adopts tagged windows through the
pure `AppState.windowPlan(sessions:)`, and opens a chosen row's window through the opener for its
kind. `AppController.choose` decides what choosing a row does, and `RowFocus` raises.
`TaskTeardown` coordinates saved state, window closure and Git safety for Archive, Remove,
removing an archived row and the closing of a task whose worktree went: one prepare (one
`TaskWorkflow.preflight` listing, the unlisted-folder and unsaved-work decisions) and one run
(git's removal, asking again about work written while the window closed), each asking the person
or refusing for the Operator's Then by its `Consent`. A failed removal retains a recoverable task.
`TaskLauncher.restore` restores. See [windows](windows.md).

## Operator ownership

Signals have one runtime and one Operator chat. A saved `SignalTask` owns one stage and an ordered
pending-stage list. Item identity joins tickets, requests and branches to existing tasks. Associated
enum kinds use inert unknown fallbacks rather than losing the workspace.

| Owner | Decisions/effects |
| --- | --- |
| `MatchDecision`, `SignalTransitions`, `DoneCheck`, `FreshStartPolicy` | Pure identity/routing, stage edges, source-specific completion and idle fresh-start decisions. Pending stages outrank Then. |
| `SignalPoller`, source readers | Shared complete reads, minute polling, ten-minute Jira sweeps and failure backoff. Partial reads cannot start tasks. |
| `ItemRouter` | Map matches to existing tasks/projects, persist skipped reasons, choose the oldest signal in a shared pass. No clone or pick-up writes. |
| `StageRunner` | Persist launch intent, prepare/restore the same task, launch one worker, advance or block its stage; a stage with a row or project left to choose waits in `choosing` until a decided choice is applied. |
| `SignalWorkerIO` | Native guarded workers, delivery checks, reply intents, transcript questions and failed-launch detection. Watching tasks do not read transcripts. |
| `RequestWatch`, `SignalHostIO` | Find the branch's request, read the chosen condition, recheck merge floors/head/authority around Oracle and host effects, require host merge confirmation. Cache only read-only details. |
| `ThenRunner`, `TaskTeardown` | Keep/archive/remove only with no pending work; preserve dirty worktrees. Exact merged-tip proof gates optional branch deletion. |
| `OperatorSessionKeeper` | Persist workload-driven chat lifetime as one saved lifecycle (idle, opening, open, closing and revoking before a renewal or a retirement): close/revoke/idle retirement, generation/token handover and context renewal. Close the old window before revoking its token. |
| `AgentChoiceRounds`, `OracleConsult` | Bind the Operator's agent-row (and project) proposal for a stage or work tab to its stage/ownership and run up to three Oracle rounds; the outcome never asks the person. `OracleConsult` runs every Oracle use (worker answers, agent choices, the merge veto, `ask_oracle` and the shell gate), discards a check whose settings changed while it ran, and saves only finished rounds. |
| `QuestionRounds`, `SignalJournal` | Bind three-round answer discussions to the full worker question/conversation/stage/ownership; persist quoted answers/instructions and bounded state tails over append-only journals. |
| `SignalOperatorToolHandler`, `SignalShellGate` | Validate fourteen tools, idempotency and current authority; handle the private gated shell route separately. Missing/stale tokens deny. |
| `SignalOperatorController`, `OperatorWork`, `OperatorActivityTracker` | Compose the owners and wire them, route daemon events and Operator requests, schedule finite jobs, and run one ordered reconcile, the Operator's one-minute tick whose steps each run when due; hold one in-flight set (`OperatorInFlight`) that every Operator effect on a task claims; publish runtime activity identities and each task's running act, cancel owned work on stop. Retention is pure Core: `AppState.pruneOperator(at:)` each minute and `AppState.withdrawObsoleteQuestions(at:)` each reconcile. |
| `OperatorChat`, `OperatorWaker`, `ActivityWriter` | The chat's window and session I/O (open, adopt, remember, close with its delivery-code classification) around `OperatorSessionKeeper`, and the session's own row issue; one pending fixed event/task wake line, typed only into an idle chat and acknowledged by a global `run_status`; the activity log, written in order as recorded, and the per-source `OperatorIssues` it logs. |
| `SignalPauseSignaller`, `SignalQuestionNotification` | Save pause/carry-on obligations and route counted human questions to the one chat. Worker permission prompts keep normal task notifications. |

Every consequential effect rechecks task/stage/ownership, pause and cancellation after suspension.
Host binding checks repository origin, request identity and branch. Merging additionally requires an
explicit per-stage opt-in, approvals, green checks, resolved threads, Oracle yes, unchanged local
and host heads and host confirmation. A done condition of Merged only watches. Skills publish;
AiTerm guards worker pushes and owns automatic merges. The Oracle is read-only and never writes
workspace state. Current saved settings/instructions govern each new check; a changed in-flight
Oracle setting or instruction invalidates its answer.

State tails are bounded: twenty journal entries per task, one hundred snags, fifty closed
questions and five hundred/seven days of idempotency. Unresolved questions and current undelivered
answers survive. Default status gives one journal entry per task; task-specific status gives the
full state tail and prompt. Descriptions arrive only as quoted data on demand. There is no task
concurrency cap. [Operator guide](operators.md); [contract protection](testing.md).

## Integration and platform owners

`HTTPJSON` and `HostAPI` share JSON transport and credential-safe redirects. GitHub, GitLab and Jira
retain their actual pagination and error semantics: a picker may show a bounded subset, while
publication must refuse an incomplete safety read. Each GitHub and GitLab client is bound to one
repository when it is made (`HostRepository`); `CodeHosts.repository` makes it from the project's
remote and saved connections. A request's state is read once per watch read (`RequestStatus`: one
fetch of the request, its approvals, and the checks of the head that fetch names), and merge
readiness is a pure rule per host (`MergeReadiness.gitHub`, `MergeReadiness.gitLab`). A token's user is kept per host
and token until Settings saves. Commands use typed arguments and hermetic Git
configuration in tests.

`HarnessDriver` describes agent installation/checks. `UserConfigFile` protects symlinks and foreign
configuration, writes backups and limits repairs to owned integration entries. Installation and
credential changes are explicit user actions.
Operator startup also records trust for its own private Operator folder in the resolved Claude
profile's global JSON. It preserves unrelated state and a backup, uses Claude's config lock and
an atomic private write, and skips the write when that exact folder is already trusted.

`BackpackController` owns Backpack Mode permissions, network/lid-sleep transitions and cleanup.
`MachineMonitor` samples in-process platform readings. `UpdateController` owns release lookup,
validated download and replacement; development builds disable self-update. These platform owners
keep their existing focused seams rather than using a generic job/workflow framework.

## Daemon

`Service` composes the iTerm2 port, registry, status readers, delivery adapters, hook receiver,
window manager, RPC and Operator MCP. It talks to iTerm2 through `ItermPort` (`iterm_port.py`);
`ItermBridge` is the one SDK adapter and patches authentication when it connects. Screen recognition
is pure (`screens.py`). `ItermSupervisor` owns reconnect/cookie handling. A locked refresh serializes
snapshots and creation; tick consumers reuse that pass's session view, and task lookups use its
index. Each corroborating read is a `ReadPlan` captured on the loop, run off the loop under a
deadline and applied on the loop: the agent-neutral steps are in `corroboration.py`, each agent's
own reads in its module under `agents/`. `SessionNotFound` marks a session that is truly
absent. Generation/session identity prevents late telemetry
from attaching to a replacement process.

The app-resolved Claude configuration directory travels in `workspace.snapshot` and is echoed as a
bootstrap compatibility check. A snapshot is a barrier before later events; overflow, malformed
frames or an unreadable known event disconnect and bootstrap again. The app talks only to a helper
it started: one a crash left holding the socket is ended, and the app starts its own.
[Protocol reference](daemon-protocol.md) and
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
| review threads | GitLab REST (`/merge_requests/:iid/discussions`, a discussion with a resolvable note, resolved when all of them are) on the configured GitLab host and port only, and GitHub GraphQL (`reviewThreads { isResolved }`), with the tokens Settings saved; read-only, 100 a page until an empty page on GitLab or the last cursor on GitHub, at most 50 pages; a list that cannot be read whole leaves the last count in place |
| models | each CLI's own catalogue cache, so the picker follows `/model` |
| conversation | each agent's own hooks — Claude's and Codex's `session_id`, PI's session id — kept only for a post placed on its tab by pid or by the tab id it carries, never by a pin or the directory; a subagent's start or stop names none, and it goes with the agent's process. Codex's proven thread and process ID are also kept on its iTerm tab; a fresh helper recovers them only for that same Codex process, then reads the CLI version from its rollout before allowing delivery |
| a worker stopped on an API error | Claude Code's `StopFailure` hook, in place of `Stop`: its `error` (`rate_limit`, `billing_error`, `authentication_failed`...), and for a limit when it resets, read only from the transcript's own record of it (`apiErrorParams.rate_limit_info.resetsAt`) within 30 s of the hook. Cleared on a new prompt, a clean Stop, or parent transcript activity newer than the failure and last hook. While children run, a busy session file alone proves no parent recovery; the stopped marker stays until its parent carries on. A stopped worker's transcript tail is parsed again only once the file changes. the worker status reports the stopped reason; its task blocks with the usage-limit reason |
| skills & commands | discovered on disk per agent and per project, for the prompt step's completions |

## What AiTerm writes, and where

| Data | Owner/location |
| --- | --- |
| Workspace, recovery and logs | `~/Library/Application Support/AiTerm/`; `StateStore`, `WorkspaceStore`, logging and daemon supervisor. |
| Credentials | Keychain service `com.laurensdhondt.aiterm`, account `secrets`: service tokens and hotspot password. Settings validates before writing and rolls back failed changes. |
| Task worktrees | `<repo>/.worktrees/<slug>`; task operations reserve archived paths and check branch/worktree ownership before deletion. A folder git still lists counts as taken, and cleanup prunes git's record of a worktree deleted outside AiTerm. `.worktreeinclude` copies selected ignored files. |
| Agent drivers | Claude's resolved config directory, `~/.codex/` and `~/.pi/agent/extensions/`; explicit Install/Repair keeps backups and foreign entries. Hook resources ship in the app bundle. |
| Codex tab identity | iTerm user variable `aiterm_codex_thread`, containing the proven thread and foreground process ID. Written after corroboration and reused only for that process; subagent hooks and inferred directory matches cannot supply it. |
| Operator artifacts | One private `operators/operator` folder with generation-bound token/manifest, brief/configuration and journals under application support; large worker messages under the task's `.aiterm/messages/`. |
| Preferences | Interface and integration choices, hotspot name and engagement marker. Tests use scratch defaults. |
| Lid sleep permission | `/etc/sudoers.d/aiterm`, installed/removed only through the Mac permission action. |
| Local transports | Application-support Unix socket; hook HTTP on `127.0.0.1:47821`. |

Archiving saves the record before removing the worktree and keeps its branch/conversations. Restoring
uses its reserved path and checks that the folder/branch can be used. Removing a project forgets
its rows; it does not recursively delete its repository. Current workspace/credential recovery
remains necessary even though historical broadcast compatibility is removed.

## UI and verification

The app is dark-only. Palette and Metrics are the source of visual values; the
[UI README](../app/Sources/AiTermUI/README.md) defines component rules. The design-system HTML mirrors
the code and holds proposed visual changes separately. Refactors change no visual values.

[Testing](testing.md) describes the gate, current-format fixtures, real adapter proofs and opt-in
live checks. Debug snapshot entry occurs before live workspace setup/controller construction,
so fixture rendering does not connect to the running app's state or daemon.
