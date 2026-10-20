# Task 2: Swift lifecycle and scheduling

## Design before implementation

- ReviewThreadsWatcher replaces its `pass` without cancellation. A previous manual refresh then escapes `stop`, and an earlier polling result can overwrite a later selection read. Cancel replaced passes and assign row request UUIDs at dispatch; publish only when that UUID still owns the row. Clear row ownership at stop.
- OperatorWaker subtracts an old delivery count from pending news after acknowledgment; new news can disappear. Its coalesce timer can also expire during delivery without a subsequent attempt. Give acknowledgment/forget a fresh generation, only consume delivery snapshots in that generation, and send remaining coalesced news after an accepted delivery completes.
- AgentProcess.groupGone ignores cancelled sleep errors in a cancelled caller, polling continuously until reaping or its ten-second bound. Run bounded group cleanup in an independent task whose sleep remains effective; preserve CancellationError at the existing boundary.
- Scheduler recreates its task dictionary for every active run and computes all runs for a single-run query. Build task and run indexes once per pass while retaining first duplicate-id lookup and per-run duplicate suppression.
- Source-wide references show SidebarModel.dependencyLabel and JSONValue.isNull have no consumers. Remove those helpers under existing model/wire characterization tests.

## Design additions from audit

StateStore.FileIdentity and FileStamps.Stamp both use inode, size and modified time with the same Foundation attributes API. Reuse the internal Sendable stamp for persistence cache identity, with existing StateStore replacement/corruption tests covering behavior.

ReviewWatcher keeps currentUser forever by project ID despite newly connected hosts and credentials each pass, and only tests isWatched after suspension. Read the token identity from the same host each check (no stable credential identifier exists in the publishing interface) and reject results if project, run, ownership or publication identity changed. Cost: one currentUser request each poll rather than one per project lifetime; correctness takes precedence over an unsafe cache.

Remote URL parsers have intentionally different acceptance rules; do not merge them without evidence their contracts agree.

## Validation and coverage

Pending implementation and commands below.

## Additional accepted findings and decisions

Root's cross-file review identified MachineMonitor's cancelled sample publishing after stop/restart, and its loop starting one last sample after a cancelled sleep. A gated stopped-sample regression observed 75% RAM replaced by the stale 25% result. Assign each sample a generation, invalidate on stop, check cancellation before publishing, and end cancelled interval sleeps.

ArchiveSheetModel repeatedly ranks the same archive for rows/highlight/status, and move reads it twice. A counting source regression failed with 2 reads rather than 1. Publish a short-lived projection for a render/command, not a persistent cache: entries come from an observing closure and must stay fresh after a restore/removal. ArchiveSheet consumes one projection. BackpackSheet's cancelled interval sleep now ends its task before another Wi-Fi rescan; this small control-flow correction uses existing sheet coverage rather than a new timing abstraction.

The persistence/catalogue/git stamp now lives at AiTermCore/FileStamps.swift, rather than giving StateStore a dependency on a git-cache implementation file.

AgentProcess test decision: attempted a test-owned group member retained as a zombie plus a single-thread executor, then per-executor CPU measurements. Neither failed reliably against original code; the attempts were removed rather than shipped as false regressions. Root explicitly chose the small cancellation-independent Task wrapper under existing cancellation/timeout/process-group characterization, avoiding a production injection seam built only for a performance test. Structural pacing is fixed; CPU reduction has not been measured on a real lingering group.

## Commands observed so far

- First `scripts/test.sh swift -- --filter 'ReviewThreadsWatcherTests|OperatorWakerTests|OperatorReviewTests|AgentProcessPoolTests'` was blocked before compilation by another lane's intentionally failing tooling regression (`bundle verifier ignored PYTHON`). Retried after tooling was green.
- Retried command: 52 application tests in 3 suites failed with 11 intended issues (both row watcher races, acknowledgment/coalesce cases, publication replacement and token-user change); 2 core pool tests passed. The ineffective additional pool test was subsequently removed as described above.
- `scripts/test.sh swift -- --filter 'AgentProcessPoolTests/cancelledGroupCleanup|MachineMonitorTests|ArchiveSheetModelTests'`: 11 application tests in 2 suites failed with 2 intended issues (stale machine sample, archive duplicate read); ineffective pool test passed and was removed.
- `scripts/test.sh swift -- --filter 'ReviewThreadsWatcherTests|OperatorWakerTests|OperatorReviewTests|AgentProcessTests|AgentProcessPoolTests|RunScheduler|StateStoreTests|WatchedFileCacheTests|DiffStatResolverTests|MachineMonitorTests|ArchiveSheetModelTests|ArchiveTests|JSONValueTests|SidebarModelTests'`: exit 0; 89 application tests in 6 suites and 131 core tests in 8 suites passed. Build showed existing test warnings in OperatorCommandTests, StallWatchTests, NewBroadcastModelTests, ReviewFixTests and RunControlsTests; following cleanup is recorded in the next increment.
