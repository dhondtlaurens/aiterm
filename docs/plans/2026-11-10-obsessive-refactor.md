# Obsessive review and refactor, round two

Status: plan agreed on 2026-11-10. Phase 0 is done, reviewed and merged; its numbers are in the
[record](../reviews/2026-11-10-refactor.md). Phases 1 to 9 are not started; "Running phases 1 to 9 as a
broadcast" below says how they are handed to the Operator.

## Goal

Review the whole codebase and restructure what, in hindsight, would be built differently: code
patterns and best practice in general and for Swift, and performance. The previous round
([plan](2026-10-29-obsessive-code-refactor.md), [record](../reviews/2026-10-29-refactor.md)) ended
on 2026-10-29. Since then about 130 commits added roughly 20,000 lines, mostly in the Operator, and
none of that code has had a structural pass.

## Approach

Nine reviewers each read one lane completely (Operator runtime, Operator tool handlers, Core
Operator rules, app shell, views, Core infrastructure, integrations, daemon, tests and scripts) and
reported findings with file and line evidence. Six claims were re-checked against the source and
held. The findings below are that audit; a phase re-reads its evidence before changing anything,
because `main` keeps moving.

What the audit found, in one paragraph: the foundations are sound and stay (Core rules, the daemon
client, publication step recording, harness drivers, design tokens, row-scoped observation). The
debt is in what was added since: the same fact derived in several places with slightly different
rules, parallel per-key dictionaries cleaned up differently, owners wired by closures where a
reference would do, and the same work repeated on every event. Tests protect behaviour well but pin
internals: about 500 test sites await private "last task" handles in the Operator owners.

### Decided while planning

- **Scope: structure and internal formats.** Features, UI and the model-facing Operator contracts
  (generated brief, MCP tool schema, `run_status` payloads, reply and refusal wording) stay as they
  are. The saved state format and the app/daemon wire protocol may change where that clearly
  simplifies the code, with a migration. This plan uses that once (publication outcome kind, phase
  4); the wire protocol does not change.
- **Delivery: one plan, ten phases, each merged to `main` on its own** after `scripts/test.sh all`.
  Each phase below is a self-contained brief, so it can be an Operator task. Phase 0 is done in the
  planning session's worktree, because every later proof rests on its baselines. After it, three
  tracks can run side by side: daemon (1), infrastructure (2 → 3 → 7), Operator (4 → 5 → 6, with 8
  after 4). Phase 9 can start any time after 0. The machine-wide test queue (about 8 minutes a run)
  makes three tracks the useful ceiling.
- **Defects found by the audit are fixed in their phase, each with a reproducing test first.** They
  are listed under "Defects" below, and that list is closed: a phase that finds another defect
  records it and leaves it. No fix changes existing wording, a model-facing contract or a policy.
  Two fixes do change what a person sees, and the maintainer approved both by name on 2026-11-10:
  the Activity tab gains a sentence for `update_request` where it shows the raw tool name today,
  and the sidebar and board stop saying "ready" while a worker is still launching. Two small fixes
  were added after that agreement under the same rule, and the maintainer kept both on 2026-11-10:
  the Codex Stop reply order and token trimming.
- **Everything else that changes what a person or an agent sees is left out** and listed under
  "Left out". Structural consolidation preserves current output byte for byte.
- **Performance changes are proven by deterministic work budgets** (counts of builds, reads, spawns,
  requests), the way the existing `derivations` and registry-sort budgets work. Fixture timings are
  reported separately and never as installed-app latency. No speed-up is claimed without a count.
- **The synchronous save stays.** Phase 0 measured it (about 7 ms for a 312 KB workspace in a debug
  build), and the maintainer decided on 2026-11-10 not to make it asynchronous: it is under half a
  frame, and phase 2's cloned backup halves the writes. No phase adds a suspension point to a flush.

### What phase 0 measured

The baselines are in the record. Three of them change how later phases are weighed:

- Status building is cheap: one build per session event, two per tick, three per mutating call,
  about a millisecond each at 20 tasks. The one-snapshot-per-pass items in phases 4 and 5 are done
  with the restructure and not for their own sake.
- The largest repeated work is the turn reader asking for every unchanged worker's transcript again
  on every event (nine reads per event in the frozen broadcast). Phase 5 lowers that first.
- A synchronous save of a 312 KB workspace takes about 7 ms in a debug build. The maintainer decided
  to keep it synchronous; phase 2's cloned backup halves the writes.

### Standing rules for every phase

- Frozen fixtures are never regenerated or relaxed: `app/Tests/AiTermTests/Fixtures/operator-current/`,
  `app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current/`,
  `daemon/tests/fixtures/operator-current-tools.json`, `daemon/tests/wire/`.
- No reducer framework, event store, plugin architecture, protocol per class, generic job engine,
  line-count target or source-scanning architecture test.
- A deleted test names the surviving test that detects the same failure.
- No visual change. A structural view change renders the same pixels.
- `scripts/test.sh` before each commit, `scripts/test.sh all` before the phase merges. Never
  `scripts/run-dev.sh`: a live smoke test after a merge is the maintainer's call.
- Shared test builders (phase 0) are adopted file by file as a phase touches a test, not in a sweep.

### Defects fixed along the way

| Defect | Evidence | Phase |
| --- | --- | --- |
| Two daemon tick reads wait with no deadline while holding the tick lock; a session on a dead mount hangs every tick | `daemon/aitermd/service.py:394,412`, `resolver.py:60` | 1 |
| Codex's `/mcp` Stop bridge answers only after the hook is fully routed | `daemon/aitermd/hooks_server.py:243-254` | 1 |
| A worktree deleted outside AiTerm leaves a locked git record; the same slug or branch then fails (suspected, confirm by test) | `Repository+Worktrees.swift:54,111`, `TaskRemover.swift:412-417`, `BranchNaming.swift:60` | 2 |
| A failed login-shell read is kept for the whole launch, fixing the Claude directory to `~/.claude` | `ClaudeConfig.swift:13-14` | 2 |
| Errors raised before a host write is sent are reported to the Operator as "may have landed" | `OperatorToolHandler+Review.swift:360-384`, `GitHubClient.swift:136,315,444,655` | 3 |
| GitHub `find_user` reads only the first 100 assignees | `GitHubClient.swift:468-475` | 3 |
| Model and skill lists go stale behind symlinked config files | `FileStamps.swift:36-41`, `ModelCatalogue.swift:60-66` | 3 |
| GitLab and Jira tokens are stored untrimmed (GitHub's is trimmed) | `GitLabSettings.swift:5-6`, `JiraSettings.swift:5` | 3 |
| The sidebar and board say "ready" while `run_status` counts the worker as still launching (visible, approved) | `WorkerTabs.swift:91-101,126`, `RunStatus.swift:561-571`, `RunReconciler.swift:185` | 4 |
| `update_request` has no Activity line; the tab shows the raw tool name (visible, approved; the new sentence follows the neighbouring request tools' lines) | `ActivityLine.swift:18-73` | 4 |
| Stop leaves pause notes, the closing sweep and replaced registrations running | `OperatorController.swift:1016-1038`, `OperatorController+Controls.swift:222-230,432-437` | 5 |
| Critique and gate Oracle processes survive Stop, End and quit | `OperatorToolHandler+Review.swift:242-313`, `+Challenge.swift:546-548`, `+Gate.swift:79` | 6 |

## Phases

Paths are under `app/Sources/` unless they start with `daemon/`, `scripts/`, `docs/` or `app/Tests/`.
`H` stands for `AiTerm/Operators/OperatorToolHandler`.

### Phase 0. Safety net and baselines (first; no product behaviour change)

Brief: add the tests and counters every later phase proves itself with, record today's numbers, and
give tests the shared builders and scratch folders that keep later churn small.

- **Saved-state byte round trip.** Today the contract test compares key sets only
  (`OperatorCurrentContractTests.swift:20-33`). Add: decoding the frozen `state.json` and encoding it
  again gives the same bytes; plus all-default and all-set encodes of the Operator records, captured
  once from unmodified code as new fixtures with provenance.
- **Work budgets, with today's numbers recorded:**
  - `RunStatus.build` calls per daemon session event, per tick and per mutating tool call.
  - `OperatorRequests.open` and worker-tab builds per `SidebarProjection.refresh`.
  - `WindowReconciler` passes per N `session.changed` events.
  - Transcript tail reads per `WorkerTurnReader.observe` with one idle worker.
  - Git spawns per `BranchWatch` tick, per archive and per restore.
  - Host requests per `ReviewWatcher` pass and per `run_status` at 1, 5 and 20 tasks.
  - Synchronous saves across the frozen contract journey: a flush that writes in its caller's own
    task. Background saves are debounced by wall time, so their number is no deterministic count.
  - Daemon: registry sorts per tick with Claude and Codex tabs carrying telemetry (the current
    budget models shell tabs only, `daemon/tests/test_service.py:108-126`), and file opens,
    directory listings and process spawns per tick through an audit hook.
- **Fixture timings, reported only:** `StateStore.save` on the frozen state padded with about 500
  shelved tasks; one status build at 20 tasks and 60 sessions.
- **Shared test builders** for `TaskItem`, `Project`, `SessionInfo` and `OperatorRun` in
  `AiTermTestSupport` (today 83, 126 and 37 direct initialiser sites and about 70 local builders).
  Settle the `@testable` contradiction between `Stubs.swift:18-29`, `OperatorUIFixtures.swift:2` and
  `Package.swift:16-18`.
- **Scratch folders** under one per-process root removed at exit, with a sweep of dead roots at
  start (197,000 leaked entries in `$TMPDIR` today).

### Phase 1. Daemon (after 0)

Brief: bound every off-loop read, stop re-reading whole transcripts, move reader logic out of the
composition root, and separate the iTerm2 port from its adapter.

- Run the test-activity and Claude-file reads through `_off_loop`; put the resolver scan behind a
  deadline (`service.py:394,412,572-599`).
- Background-shell reader: start at the transcript size recorded when work started, and prefilter
  lines by marker before parsing (`claude_background.py:45-55,152`).
- Codex rollouts: one cursor filled in one pass, one path lookup per thread per tick, the same
  8 MiB cap as the Claude readers; a named tuple for the reading (`codex_sessions.py:27-35,94-147`).
- Test activity: injectable records directory (tests read the live machine-wide queue today),
  records cached by stamp, age checked before locking, nothing resolved when there is nothing to
  place (`test_activity.py:66,77-93,114-117`, `service.py:118`).
- Answer the Codex Stop tool call first, then route it (`hooks_server.py:243-254`).
- Each corroborating reader owns its request building and its identity check; `Service` runs plan,
  bounded read, apply. `Service` stops reading `Turn` fields (`service.py:400-569`).
- New `iterm_port.py` (protocol, exceptions, typed screen) under strict mypy and `screens.py`
  (screen recognition); the auth patch applies in `ItermBridge.connect`, not at import
  (`iterm_bridge.py:39-76,89,141,307-381`, `delivery.py:52-169`, `pyproject.toml:38-44`).
- Remember a subagent transcript's real path (`claude_subagents.py:105-128`).
- A task index in the registry so `for_task` stops sorting (`sessions.py:170-174`, `status.py:234`).
- `SessionNotFound(KeyError)` raised on purpose; guards catch only it (`iterm_bridge.py:592,617`,
  `delivery.py:461-462`, `rpc_params.py:50-51`).
- Ruff `BLE` and `RUF100` so the 29 existing `noqa: BLE001` comments mean something.
- `HookEvent` fields keyword-only after `cwd` (`hook_events.py:17-48,193,223`).
- `tests/builders.py` for session files, transcript records and rollouts; seams for the private
  attributes that tests reach into where this phase restructures (`test_service.py`).
- Doc drift: `daemon/README.md:66` says 32 schemas, 37 are served.

### Phase 2. Core infrastructure (after 0)

Brief: stop unrelated projects waiting on each other's git work, bound git output, and give git
queries and path identity one typed home.

- One serial lane per repository, keyed by the git common directory; read-only queries leave the
  lane. This reopens a 2026-10-29 keep on new evidence: local merge, merged-branch checks, Fix
  landing and worker checkout joined the single queue since, with jobs of up to 300 s
  (`Tasks/TaskWorkflow.swift:33,47-255`, `Git/LocalMerge.swift:43`,
  `Operators/MergedBranchCheck.swift:12,16`, `Fix/TaskWorkflow+FixLanding.swift:9`).
- Checkout cleanup forgets the locked worktree record; slug and branch checks treat a registered
  path as taken (defect, test first on a real temporary repository).
- Process and git output take an optional limit and report truncation; trimming becomes a
  convenience above the runner. Diff readers ask for a bound (`ProcessRunner.swift:100`,
  `GitRunner.swift:204`, `H+Tasks.swift:169,173`, `H+WorkingDiff.swift:8`).
- Typed queries on `Repository` for head, cleanliness and commit lookup; one commit-id type (three
  validations disagree today: `LocalMerge.swift:48`, `Repository+Publish.swift:197`,
  `H+Verdicts.swift:23`); one remote-URL parser (`ProviderDetector.swift:16-33`,
  `Repository+Publish.swift:174-194`). Callers in this lane migrate; others as they are touched.
- One preflight per removal or archive from a single worktree listing (archive lists five times,
  `TaskArchiver.swift:84-106`; removal three, `TaskRemover.swift:357-370`).
- The backup copy is a clone of the current primary, not a second write (`StateStore.swift:45-56`).
- Only a successful login-shell answer is kept (`ClaudeConfig.swift:13-14`).
- One canonical path helper and one file stamp type (`Worktree.swift:56`, `VerifySandbox.swift:22`,
  `FileStamps.swift:11`, `DiffStatResolver.swift:38`).
- `BackgroundWork` takes a priority; polling passes utility (`BackgroundWork.swift:9`,
  `CheckoutMonitor.swift:168`). One written policy for BackgroundWork versus SerialThread.
- Delete `SerialThread.sync` and its unchecked box (tests only, `SerialThread.swift:35-42,78`).
- Expiry and backoff use a monotonic clock (`TimedOut.swift:16-24`, `DiffStatResolver.swift:102`).

### Phase 3. Integrations (after 2)

Brief: decide "outcome unknown" once, bind each host client to its repository, and remove leftovers.

- Core classifies a host failure as outcome-unknown while mapping the transport failure; errors
  raised before sending get their own case. The app's three-enum switch reads one property.
- Each client carries its repository binding and conforms to the host protocol directly; the two
  forwarding structs go, and the publishing types move from `Tasks/` to the host folders
  (`MergeRequestPublisher.swift:7-192`). Repository-level client methods become internal.
- GitHub repository paths are built once with each segment encoded; a thread detail also checks its
  repository (`GitHubClient.swift:45,69,159,286,417`).
- `find_user` reads a bounded number of pages or checks a whole login directly.
- Catalogue sources are stamped through symlinks (a parameter on the stamp, git caches unchanged).
- The open GitHub request listing is kept for a sheet's life and filtered locally
  (`GitHubClient.swift:44-74`, `ReviewCreationModel.swift:194-204`).
- The token's user is kept per host and token until Settings saves; GitLab's closing-issue pair
  runs concurrently (`GitLabClient.swift:114-120`).
- Jira write bodies and ADF use `JSONValue` (`JiraWrites.swift:40-133`, `ADFText.swift:4-52`).
  Text output is unchanged.
- Fix: tips travel with the look answer instead of a shared mutex; session states carry their own
  data (`FixPipeline.swift:37-65`, `FixSession.swift:12-29,79,107`).
- Dead code: `SkillCatalog.file(named:)`, the single-case `FixerAgent` parameter and its unused
  typed throws, the multi-host shape of the update error, stale Codex and GitLab comments.
- Small shared helpers for the paging loop, number parsing, branch-name stripping and protection
  wrapping; `inOrder` moves to a neutral place (`GitLabClient.swift:306`).
- GitLab and Jira tokens and email trimmed as GitHub's is.

### Phase 4. Core Operator rules (after 0)

Brief: give each derived Operator fact one home in Core, and make the model say what it means
without changing what is stored.

- **One live projection per pass.** A per-task live value built once from the per-pass session
  index with `now` required; readiness has one predicate over it, used by `run_status`, the row
  line, the board and the reconciler. The pure `liveFacts` projection moves from the controller
  into Core. `run_status` bytes stay identical; the sidebar changes only in the launch window,
  which is the defect fix.
- **Requests and worker tabs computed once per sidebar refresh** and passed down
  (`SidebarProjection.swift:144-155`, `BroadcastRow.swift:122-206`, `BroadcastBoard.swift:394-647`).
- **`RunStatus.build` splits** into obligations and line assembly, so consumers that need only the
  obligations stop building lines (`RunStatus.swift:517-602`).
- **The transition table covers every edge.** Publish, enter review, end review on commit end,
  revoke and un-claim become actions that reproduce today's exact field writes
  (`OperatedTransitions.swift:9-31`; direct writes at `TaskEndChange.swift:53-56`,
  `UpstreamReplacement.swift:27-55`, `TaskFinisher.swift:765,914,926`, `WorkerStarter.swift:546`).
- **One writer for a question and its held flag** (`OperatorModels.swift:1103-1110`; five writers).
  Read sites keep the flag; `run_status` flags unchanged.
- **Computed views, storage unchanged:** question kind (21 prefix and string checks in 10 files),
  a first-or-extra tab reference (22 conversions in 11 files, each field keeps its encoding),
  merge outcome (13 predicates over four fields), challenge record role, a two-case run intent.
- **Tool traits on `OperatorTool`,** exhaustive and without a default: mutating, read-only, act
  kind, challenge class. `ActivityLine` switches over the tool exhaustively (fixes `update_request`).
- **Publication outcome kind is persisted** (hold, failure, permanent) instead of being recovered
  by matching English wording (`OperatorModels.swift:120-129`, `PublicationGuard.swift:104-110`,
  `TaskFinisher.swift:447-451,998-1002`). The persisted `problem` text stays byte-identical. A save
  without the key is read through today's wording match; an older build ignores the key.
- **Synthesized Codable with two small property wrappers** for defaulted and omitted-when-default
  fields, replacing about 240 hand-written lines (`OperatorModels.swift:203-242,417-510,963-1079`).
  Only after the phase 0 round-trip test passes on unmodified code.
- **Housekeeping:** persisted vocabulary moves beside its model (`BroadcastBoard.swift:84` is read
  by `OperatorModels.swift:593-595`); done-ness predicates in one file; the frozen brief text
  separates from launch I/O (`OperatorCommand.swift:16-260` versus `:262-609`, bytes identical);
  one `said` helper; stale comments (`RunStatus.swift:221,385-388`).

### Phase 5. Operator runtime (after 4)

Brief: make the runtime owners restructurable, then give each fact one snapshot per pass and each
owner direct references and one state record per key.

- **First: a test "settled" seam.** One injected work tracker that Operator owners register spawned
  work with, exposed to tests as one await. The awaits on `last*` handles migrate (294 in 40
  files, limited to owners this phase restructures); the handles then become private. Long-lived
  loops are excluded, or a settle would hang.
- Transcript tail reads are gated on the file's stamp and shared between the turn reader and the
  branch watch (`WorkerTurnReader.swift:121-123,162-164`, `BranchWatch.swift:70-75`).
- One status builder; one snapshot per pass handed to the waker and the watchdog; the tick's second
  build goes (`OperatorController.swift:380-384,886,921,1066`, `H.swift:416-430`,
  `OperatorWaker.swift:94`). Wake timing is proven by the waker suite.
- Owners are built in dependency order and passed as references; closures stay for upward events
  only. A claim pass defers its follow-up start instead of recursing; ending a run goes through the
  same run-changed path (`OperatorController.swift:256-331`, `WorkerStarter.swift:83-96,565-582`,
  `AppController+Operators.swift:283-284`).
- One record per worker in the turn reader and one per task in the starter, with one removal path
  (`WorkerTurnReader.swift:45-60`, `WorkerStarter.swift:18-47`).
- One small value for "requested, not listed yet", used by the five copies; each owner keeps its
  own adoption rule.
- Stop cancels pause notes, the closing sweep, replaced registrations and replaced reads.
- The branch watch caches what a message names, keyed by message, head and a refs digest
  (`BranchWatch.swift:71-77,136-159`).
- Review watching resolves host and current user once per pass per project
  (`ReviewWatcher.swift:51-61`, `CodeHostCheck.swift:29`).
- Session-event loops mutate once and use the session index
  (`OperatorController.swift:563-568,839-857`).
- Typed reopen refusal and one "leaves the outcome unknown" property on the daemon error (compared
  by message text today at `OperatorController+Controls.swift:507`; the code list is copied three
  times).
- An Operator-window owner and a pause signaller take their state out of the controller extension
  (`OperatorController+Controls.swift:182-334,494-612`).
- Ports are non-optional, resolved once for live and scratch (`OperatorController.swift:53-72`).
- The shelved board derives once; the notification observer is removed
  (`BroadcastBoardHost.swift:53-55`, `OperatorController.swift:243-245`).
- Wake reasons become a closed set tested directly; the two source-scanning tests go
  (`OperatorWakerTests.swift:719-737`, `OperatorPlanToolsTests.swift:306-322`). Survivors: the
  generic-line fallback test and the notification-id assertions in `RunControlsTests`.

### Phase 6. Operator tool handlers (after 5)

Brief: one owner for Oracle jobs, fewer host and git round trips per call, and handler state that
only the handler changes. Replies stay byte-identical.

- One helper starts an Oracle job and registers it in one cancellable table, cancelled on Stop and
  End; the four copies keep their own settle logic (`H+Challenge.swift:220-251`,
  `H+Relay.swift:126-148`, `H+Review.swift:288-316`, `H+Gate.swift:72-80`).
- The handler uses the tool traits from phase 4; a test checks the daemon's challenged tools
  against Swift's (`H.swift:198-241`, `H+Challenge.swift:16-26`, `operator_mcp.py:199`).
- `run_status` reads threads and request states concurrently and resolves each project's host once
  per call (`H.swift:445-457`, `H+Review.swift:394-405`).
- A judged merge reuses the gate's landing check instead of fetching twice
  (`H+Challenge.swift:120-128`, `TaskFinisher.swift:467-488,679-691`).
- The finisher is a direct reference and takes its call value (`H.swift:178-195`,
  `TaskFinisher.swift:68-73,178`). It classifies outcomes by the persisted kind from phase 4.
- Oracle settings sync on the save notification and the tick only (`H+OracleSettings.swift:7-34`).
- Handler tables become private to mutate, with named methods (`H.swift:104-150`).
- `mark_task` outcome is an enum parsed once; one host-failure sentence helper; the timeout helper
  moves beside `BackgroundWork`.
- Skip the before and after status builds when the waker holds no state for the run.
- Finisher bookkeeping becomes one record per task, dropped on removal
  (`TaskFinisher.swift:95-134`).
- Finish-task tests: Core owns step semantics, the finisher suite keeps what the finisher adds,
  each removed duplicate names its survivor.

### Phase 7. App shell (after 2 and 5)

Brief: one teardown path, one way to search and to hook, and no blocking file work on the main actor.

- Remove and Shelve share "prepare" and "run, retrying late unsaved work" in `WorktreeTeardown`,
  using the phase 2 preflight (`TaskRemover.swift:354-377`, `TaskArchiver.swift:81-127`).
- One observable debounced search, used by both search fields and the catalogue load
  (`CreationModel.swift:344-361,415-457`, `ReviewCreationModel.swift:87-88,248-279`).
- One hook list with removal tokens; single-slot hooks are named as such; the Fix pipeline is an
  init parameter (`RowFocus.swift:117-131`, `SheetCoordinator.swift:67`).
- Grouped app ports and timings, live and scratch (`AppController.swift:117-145,592-635`).
- Folder-existence checks share one async helper off the shared pool; the slug resolves when the
  draft changes; Keychain writes leave the main actor (`TaskLauncher.swift:87`,
  `WindowReconciler.swift:293`, `CreationModel.swift:303-314`,
  `IntegrationSettingsModel.swift:248-276`).
- Window reconciliation runs on row-relevant session changes and reads its owners, not the per-row
  display copies (`WindowReconciler.swift:137-143,205`), after confirming nothing relies on stray
  events.
- The checkout pass compares only the fields it scans (`CheckoutMonitor.swift:164,172,251-259`).
- One owner for "a row was chosen" (`AppController.swift:535-574`, `RowFocus.swift:233-236`).
- `PollLoop` moves beside `LatestTask`; hand-rolled latest-wins counters use it where the lifetime
  matches. `TickPass` and the checkout monitor's join-then-trailing pass stay separate.

### Phase 8. Views (after 4)

Brief: remove hand-written state storage and the copied row, badge, sheet and header code, with
identical pixels.

- Plain `@State`; the 52 hand-written sites rest on a comment the code disproves
  (`SidebarRows.swift:50` already compiles). Convert one file and build first.
- One badge line driven by a value, for the row, card, Shelf and question block
  (`SidebarRows.swift:483-530`, `BroadcastBoardSheet.swift:577-599`, `WaitingOnYouList.swift:110`).
  Each surface keeps today's mark; the drift is listed under "Left out".
- One stepped-sheet frame that knows nothing of the model (`CreationSheet.swift:38-94`,
  `NewBroadcastSheet.swift:29-129`).
- Section headers and the Operator heading read narrow values, with a redraw test for a status
  change (`SidebarRows.swift:108,169-197`, `OperatorHeading.swift:33`).
- One fold-on-tap modifier, one heading inset, one row content layout for the three rows.
- One ring helper for the 16 copies of the stroke rule.
- Activity and Shelf lists are lazy; days and titles are computed once per append; a highlight move
  does not re-rank (`BroadcastActivityView.swift:39-72`, `ArchiveSheet.swift:25-61`).
- One ticket picker field, one clear button (with its VoiceOver label), key-column widths in
  Metrics; app code uses the chrome AiTermUI already has; one tab-shortcut modifier.
- Step one of New Task and New Review reads its derived values in leaf views.
- Snapshot renderers share the column wrapper and one New Broadcast fixture.

### Phase 9. Gate speed and close-out (any time after 0; close-out last)

Brief: take the known minute out of every gate run, then document and prove the whole.

- Split the serialized `AppControllerTests` (50 tests, the last 53 to 62 s of every app run) into
  unserialized suites by owner, keeping serialized only what touches application state.
- Git fixtures copy a per-process template and build off the main actor; host-only tests take a
  plain project path (204 fixture sites run git on the main actor today).
- A runtime check that git or process work in a test runs under the blocking trait (six Core suites
  skip it today).
- Time-ordered tests use latches (`ReviewTicketFieldTests.swift:104-115`, the waker's fixed waits).
- Measure the real number of concurrent test bodies against the documented bound.
- Gate history: keep per-suite timings and failing test names for about a week, in a file of the
  runner's own beside the queue's records, not in the records. Moved here from phase 0 on
  2026-11-10: the daemon reads every retained record on each tick until phase 1 changes that, so
  keeping records longer would raise the cost phase 1 lowers, and the runner scripts are copied by
  the toolchain guard's fixtures, which makes this a slice of its own.
- `scripts/release.sh` refuses without a green full gate for `HEAD`.
- Close-out: `docs/architecture.md`, `docs/testing.md`, the READMEs and the design-system page
  follow the code; a review record with baselines and final budgets; a full gate; an adversarial
  review of the integrated result.

## Running phases 1 to 9 as a broadcast

One task per phase, in the AiTerm project, each ending in a local merge to `main`. A task branches
from `main` once the tasks it depends on are merged, so every dependency is an order dependency.

| Task | Phase | Starts after |
| --- | --- | --- |
| `daemon` | 1 | nothing |
| `core-infrastructure` | 2 | nothing |
| `core-operator-rules` | 4 | nothing |
| `gate-speed` | 9, to-dos 9a and 9b | nothing |
| `integrations` | 3 | `core-infrastructure` |
| `operator-runtime` | 5 | `core-operator-rules` |
| `views` | 8 | `core-operator-rules` |
| `operator-tools` | 6 | `operator-runtime` |
| `app-shell` | 7 | `integrations` and `operator-runtime` |
| `close-out` | 9, to-do 9c | every other task |

At most three workers at once: every test run goes through the machine-wide queue, about eight
minutes a run, and more workers only wait on it.

What every task's worker is told, beyond its phase's brief:

- Read this plan's "Decided while planning", "Standing rules for every phase", its own phase and
  that phase's rows under "Files" and "To-dos", and the record's baselines. Re-read each finding's
  evidence in the code first: `main` has moved since the audit.
- Work its to-dos in order, each a commit that leaves the gate green. A defect gets its failing test
  first. A performance item lowers its budget's number in the test in the same commit; a budget that
  does not move means the item is dropped and said so.
- Before reporting done: `scripts/test.sh all` green, the phase's to-do boxes ticked here, and the
  record given a section for the phase with each budget's baseline and final number and what was
  not proven.
- Stop and ask, through the Operator, before anything that would change a frozen fixture, a
  model-facing contract, what a person sees, or the saved format beyond phase 4's one key; and
  when a finding's evidence no longer holds.
- Never `scripts/run-dev.sh`, never the installed app, its daemon or a real account. The broadcast
  itself runs on the installed AiTerm, which this work must not replace.

## Files

Create or modify, and why. Paths a phase finds it must add (a moved type's new file) follow the
phase's brief.

| Phase | Files | Action |
| --- | --- | --- |
| 0 | `app/Tests/AiTermTests/Operators/OperatorCurrentContractTests.swift`; new fixtures beside the frozen ones | Modify, create: byte round trip and default/all-set encodes |
| 0 | `AiTermCore/WorkMeter.swift` | Create: a task-local meter a test binds, so tests running side by side count only their own work; nothing is counted in the app |
| 0 | `AiTermCore/Operators/RunStatus.swift`, `OperatorRequests.swift`, `WorkerTabs.swift`, `AiTermCore/StateStore.swift`; `AiTerm/WindowReconciler.swift`, `Operators/WorkerTurnReader.swift` | Modify: one note to the meter each |
| 0 | `app/Tests/AiTermTestSupport/` (builders, `ScratchFolder`, `Stubs.swift`, `OperatorUIFixtures.swift`); `app/Package.swift` | Create, modify: shared builders, per-process scratch root, the `@testable` note |
| 0 | `app/Tests/AiTermTests/` and `AiTermCoreTests/` budget suites; `daemon/tests/test_service.py` | Create, modify: budgets with recorded baselines |
| 0, 9 | `docs/reviews/2026-11-10-refactor.md` | Create: baselines, then final numbers and limits |
| 1 | `daemon/aitermd/service.py`, `resolver.py`, `claude_background.py`, `codex_sessions.py`, `test_activity.py`, `hooks_server.py`, `status.py`, `stop_failures.py`, `claude_subagents.py`, `sessions.py`, `delivery.py`, `keystrokes.py`, `iterm_bridge.py`, `rpc_params.py`, `hook_events.py`, `operator_mcp.py` | Modify |
| 1 | `daemon/aitermd/iterm_port.py`, `screens.py`; `daemon/tests/builders.py` | Create |
| 1 | `daemon/pyproject.toml`, `daemon/README.md`, `daemon/tests/` (conftest, fake, affected suites) | Modify |
| 2 | `AiTermCore/Tasks/TaskWorkflow.swift`, `TaskCreator.swift`; `Fix/TaskWorkflow+FixLanding.swift`; `Operators/MergedBranchCheck.swift`; `Git/` (`GitRunner`, `Repository+*`, `LocalMerge`, `BranchNaming`, `ProviderDetector`, `DiffStatResolver`, `TimedOut`, `Worktree`); `ProcessRunner.swift`, `BackgroundWork.swift`, `SerialThread.swift`, `StateStore.swift`, `ClaudeConfig.swift`, `FileStamps.swift` | Modify |
| 2 | `AiTerm/TaskRemover.swift` (cleanup path only), `CheckoutMonitor.swift` (priority); bounded-diff callers in `H+Tasks.swift`, `H+WorkingDiff.swift` | Modify |
| 3 | `AiTermCore/HTTPJSON.swift`, `CodeHost.swift`, `GitHub/`, `GitLab/`, `Jira/`, `Fix/`, `Updates/`, `Agents/SkillCatalog.swift`, `Harnesses/ModelCatalogue.swift`, `Harnesses/ModelFiles.swift`; `Tasks/MergeRequestPublisher.swift`, `Tasks/ReviewThreadsReader.swift` | Modify, move |
| 3 | `AiTerm/IntegrationSettingsModel.swift`, `FixSession.swift`, `ReviewCreationModel.swift` (listing reuse); `H+Review.swift` (one property read) | Modify |
| 4 | `AiTermCore/Operators/` (`OperatorModels`, `RunStatus`, `WorkerTabs`, `OperatedTransitions*`, `TaskEndChange`, `UpstreamReplacement`, `OperatorRequests`, `OperatorTool`, `ActivityLine`, `OperatorCommand`, `PublicationGuard`, `StallWatch`, `OperatorTiming`, `RunSummary`); `Sidebar/` (`BroadcastBoard`, `BroadcastRow`, `OperatorLine`, `SidebarModel`) | Modify; create files for moved types |
| 4 | `AiTerm/SidebarProjection.swift`; callers of the moved or typed values in `AiTerm/Operators/` | Modify |
| 4 | A current-format state fixture captured once after the format change, with provenance | Create; the frozen fixture stays untouched as the migration input |
| 5 | `AiTerm/Operators/` runtime owners (`OperatorController*`, `OperatorWaker`, `OperatorWatchdog`, `WorkerStarter`, `TabOpener`, `RunReconciler`, `WorkerTurnReader`, `WorkerTranscript`, `WorkerPrompts`, `WorkerQuietWatch`, `BranchWatch`, `ReviewWatcher`, `CodeHostCheck`, `BroadcastBoardHost`); `AiTerm/AppController+Operators.swift`; `AiTermCore/Daemon/` (error property) | Modify; create the window owner, pause signaller and work tracker |
| 5 | `app/Tests/AiTermTests/Operators/` (settle seam adoption, two scans removed) | Modify |
| 6 | `H.swift` and `H+*.swift`; `TaskFinisher.swift`; `TaskAutoCloser.swift` (finisher calls) | Modify |
| 6 | `app/Tests/AiTermTests/TaskFinisherTests.swift` (it also holds the `TaskFinisherControllerTests` suite), `app/Tests/AiTermTests/Operators/OperatorFinishReplyTests.swift`, `app/Tests/AiTermCoreTests/Operators/TaskPublisherTests.swift` | Modify |
| 7 | `AiTerm/` shell: `WorktreeTeardown`, `TaskRemover`, `TaskArchiver`, `CreationModel`, `ReviewCreationModel`, `TaskCreationModel`, `RowFocus`, `Notices`, `SheetCoordinator`, `AppController`, `TaskLauncher`, `WindowReconciler`, `CheckoutMonitor`, `IntegrationSettingsModel`, `LatestTask`, `Operators/TickPass.swift`; `app/Tests/AiTermTests/ScratchController.swift` | Modify; create the search and hook types |
| 8 | `AiTerm/Views/` (all), `AiTermUI/` (ring helper, Metrics tokens, modifiers), `AiTerm/Snapshots/`; `AiTermCore/Sidebar/SidebarModel.swift` (header values); `app/Tests/AiTermTests/SidebarRowRedrawTests.swift` | Modify; create shared views |
| 9 | `app/Tests/AiTermTests/AppControllerTests.swift`; `app/Tests/AiTermTestSupport/` (git fixtures, blocking trait); `scripts/release.sh`, `scripts/test-routes.tsv`, `scripts/test.sh` (gate history) | Modify, split |
| 9 | `docs/architecture.md`, `docs/testing.md`, `README.md`, `daemon/README.md`, `scripts/README.md`, `app/Sources/AiTermUI/README.md`, `docs/design/design-system.html`, `AGENTS.md` | Modify to match the code |

## Proof

- **Contracts.** The frozen brief, tool schema, wire and status/reply fixtures pass unchanged in
  every phase. The saved-state byte round trip from phase 0 passes in every phase before the format
  change. After it (phase 4): the frozen save still loads, with outcome kinds matching the wording
  match; a new current-format fixture round-trips byte for byte; `run_status` bytes for the journey
  are identical.
- **Budgets.** Each performance item names its phase 0 budget and asserts the new number. The
  review record lists baseline and final count per budget. A budget that does not move means the
  change is dropped, not kept on faith.
- **Defects.** Each has a test that fails before the fix and passes after. A suspected defect that
  cannot be reproduced is recorded and left.
- **Structure-only changes** rely on existing suites. Where a phase restructures an area the audit
  rated brittle (Operator runtime owners, daemon `Service`), the seam goes in first and the suites
  move to it before the restructure.
- **Views.** `scripts/snapshots.sh` into a folder before and after phase 8, compared image by
  image; a difference is a bug unless it is the known native variation of the disabled-goal
  fixture. `scripts/readme-picture.sh --check` passes. The redraw test for a status change is added
  before the header change and shows the count drop.
- **Daemon.** The gate's pytest, mypy and ruff. The port module is strict from its first commit.
- **Gate.** `scripts/test.sh` before each commit; `scripts/test.sh all` before each phase merges;
  after phase 9, the bundle check (`scripts/make-app.sh`, `scripts/test-app-bundle.sh`).
- **Not proven here:** installed-app latency, real hosts and accounts, real agent behaviour. A live
  smoke test through `scripts/run-dev.sh` is the maintainer's choice after a merge.

## To-dos

Each box leaves the project working and is one or a few commits.

- [x] 0a. Saved-state byte round trip and default/all-set fixtures, on unmodified product code.
- [x] 0b. Swift work budgets with today's numbers; fixture timings recorded.
- [x] 0c. Daemon budgets: agent-path registry sorts and the audit-hook counts.
- [x] 0d. Shared test builders, per-process scratch root, the `@testable` note.
- [x] 0e. Review record started with the baselines.
- [ ] 1a. Deadlines on the unbounded reads; Codex Stop answered first (tests first).
- [ ] 1b. Background reader offset and prefilter; one rollout cursor with a cap; subagent path memo.
- [ ] 1c. Test activity: injectable directory, stamp cache, age before lock.
- [ ] 1d. Readers own plan and apply; `Service` runs the fixed list; test seams.
- [ ] 1e. Port and screens modules, strict typing, auth patch at connect.
- [ ] 1f. Task index, `SessionNotFound`, ruff rules, keyword-only hook fields, test builders, README.
- [x] 2a. Locked worktree record (test first); successful-only login-shell answer.
- [x] 2b. One lane per repository, with the rendezvous test.
- [x] 2c. Bounded output and untrimmed runner; bounded diff readers.
- [x] 2d. Typed git queries, commit id, remote-URL parser; one preflight per removal and archive. Restore lists
  once (6 to 4 processes); the removal and archive preflight is dropped here, Shelve stays at 9: its listings are
  asked by `TaskArchiver` and `TaskRemover`'s removal, phase 7's files, which build it with the shared teardown.
  One commit-id rule and one remote-URL rule are dropped for now: `CommitId` and `RemoteURL` keep today's rules
  (three for commit ids, the push's own for the same-location check), because one rule changes refusals the
  maintainer has not approved; the question is with them, and each answer is a one-line switch.
- [x] 2e. Cloned backup, path identity and stamp, priorities, dead code, monotonic clocks.
- [ ] 3a. Outcome-unknown classification in Core (test first); token trimming.
- [ ] 3b. Clients bound to their repository; forwarding removed; access narrowed; path encoding.
- [ ] 3c. `find_user`, symlinked catalogue stamps (tests first); listing and user reuse.
- [ ] 3d. Jira on `JSONValue`; Fix state; dead code; small shared helpers.
- [x] 4a. Tool traits and exhaustive Activity lines (test first for `update_request`).
- [x] 4b. One live projection and one readiness predicate (test first for the launch window). The reconciler keeps
  reading tabs as they list themselves: given the launch window it would block a relaunched finished task (record).
- [x] 4c. Requests and tabs once per refresh; `RunStatus.build` split.
- [x] 4d. Transition table covers every edge; one question writer.
- [x] 4e. Computed views: question kind, tab reference, merge outcome, record role, run intent.
- [x] 4f. Persisted publication outcome kind with its migration read and new fixture.
- [x] 4g. Synthesized Codable with the two wrappers; housekeeping moves. Dropped for `OperatedTask`, whose
  `firstRevision` default and unknown-flag rule neither wrapper expresses: it keeps its hand-written coder (record).
- [ ] 5a. Settle seam; suites moved to it; `last*` handles private.
- [ ] 5b. Stop cancels everything it owns (test first); observer removed.
- [ ] 5c. Gated, shared transcript reads; one status builder and one snapshot per pass.
- [ ] 5d. Owners in dependency order with references; deferred start pass; ports non-optional.
- [ ] 5e. Per-key records; the listing-wait value; batched mutations; typed errors.
- [ ] 5f. Window owner and pause signaller; branch-watch and review-watch caches; closed wake reasons.
- [ ] 6a. One Oracle-job owner, cancelled on Stop and End (test first).
- [ ] 6b. Handler on tool traits; private tables; `mark_task` enum; sentence and timeout helpers.
- [ ] 6c. Concurrent `run_status` host reads; reused landing check; settings sync sites.
- [ ] 6d. Finisher as a reference with one record per task; outcome kind; test layering.
- [ ] 7a. Shared teardown prepare and run.
- [ ] 7b. Debounced search; hook list; grouped ports.
- [ ] 7c. Blocking checks off the main actor; reconciler trigger; scan projection; row chooser.
- [ ] 8a. Plain `@State` (one file first, then the rest).
- [ ] 8b. Badge line, row content, fold modifier, heading inset, ring helper.
- [ ] 8c. Stepped-sheet frame; picker field, clear button, Metrics tokens, chrome reuse.
- [ ] 8d. Narrow header values with the redraw test; lazy Activity and Shelf; leaf reads.
- [ ] 8e. Snapshot helpers; before and after image comparison.
- [ ] 9a. `AppControllerTests` split; template and off-main git fixtures; blocking check; latches.
- [ ] 9b. Concurrency measurement; gate history; release gate check; routing entries.
- [ ] 9c. Docs, design-system page, review record, full gate, bundle check, adversarial review.

## Left out

Each changes what a person or an agent sees, or was weighed and judged not worth its cost. None is
implemented by this plan.

**For separate branches, on the maintainer's decision**

- Require https for GitLab and Jira hosts (`IntegrationSettingsModel.swift:35,48`).
- Keep tables, nested lists, status marks and dates when a Jira description goes into a worker
  prompt (`ADFText.swift:17-35`).
- Preserve the leading space of `git status --porcelain` lines the Operator reads
  (`H+MergeEvidence.swift:34`, `H+Tasks.swift:128`); the runner change in phase 2 keeps today's
  trimmed text at these two call sites.
- Daemon: cache the process-table probe (`process_agents.py:24-44`) and walk Codex history newest
  first (`codex_sessions.py:186-226`). Both trade latency or an edge case; phase 1 records their
  counts.
- Design proposals: a GitLab issue shows Jira's mark on board cards and in Waiting on you; an
  Operator row in background status opens no work card; the Interface tab mixes heading styles.
- Read sites using `holds(task:)` instead of the held flag; a typed hold-or-failure field exposed
  in `run_status`.
- An async durable save, or splitting the shelf and ended runs out of the saved state: decided
  against on 2026-11-10, after phase 0's timing.

**Weighed and rejected**

- Lifecycle states that carry their own data; one runtime record per worker across all owners; a
  typed challenge subject decided once.
- A process object in the daemon; a per-file tail follower; iTerm2 change subscriptions.
- Renaming `JiraTicket`; removing live-resource default arguments; rows off `AppController`;
  replacing the creation model's generic.
- Finer test routing; CI; phased workspace change hooks.
- `Keychain` lock held across an access prompt (`Keychain.swift:85-110`): unverified, not acted on.

## Review record

Agreement: the maintainer agreed to the drafted plan on 2026-11-10, including the defect list, the
left-out list, the persisted publication outcome kind and phase 0 in the planning session.

Codex challenged the plan read-only through `psg:adversarial-review` in two rounds.

- Round 1, "ready with fixes". Important: the `update_request` Activity sentence and the sidebar's
  readiness during a launch are visible changes, while the plan said fixes change nothing visible.
  Pushed back on removing them, since the maintainer approved both by name; fixed the plan to say
  they are visible and approved, to close the defect list and to require byte-identical output
  from all other consolidation. Minor: two wrong paths in the file inventory; fixed, with four
  more found while checking.
- Round 2, "ready", no findings. The reviewer accepted the approval from the triage and did not
  reproduce the audit's coverage.

No finding is open. Nothing was built or run for this plan: the audit and the review were
read-only, and the baselines are phase 0's first job.
