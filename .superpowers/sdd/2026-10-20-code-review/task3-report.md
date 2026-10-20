# Task 3: UI and tooling consolidation

## Audit and design

Inspected Input, SearchField, Logos, their tests and UI test support, shared PumpRunLoop/TestWindows, Package.swift, scripts/test.sh, test-swift-toolchain.sh, test-app-bundle.sh, make-app.sh, swift.sh, scripts/README.md, and daemon/pyproject.toml. Read AiTermUI/README.md and design-system skill. No tokens, public initializers, appearance or artifact content need change; no publishing is authorized.

Evidence: Input observes undo/redo but SearchField does not. Both repeat focus/binding synchronization. Consolidate their binding/focus/undo mechanics in an internal collaborator, keeping secure field construction and caret-at-end in Input and navigation/focus requests in SearchField. Existing secure and focus characterization plus new search undo/redo coverage protect the boundary. Suppress unchanged writes for both fields.

Logos checks name/fill/path but ignores evenOdd, so identically named paths with different winding reuse an incorrect image. Include winding in the key while preserving cheap path comparison.

UI TestSupport duplicates shared run-loop settling and depth-first NSView traversal. Export only those existing shared helpers needed by UI tests; preserve the local firstSubview spelling as a forwarding adapter to avoid broad churn.

Tooling evidence: toolchain guard ignores SWIFT for the good compiler; test.sh's expect_tests argument is always empty and accepts a closing zero-test run; bundle verification ignores PYTHON, repeats dependency pins and compares only the PI hook resource. Use configured interpreters, require positive completed test counts, exercise the wrapper with fake compiler output, read runtime pins with tomllib, compare all three hooks. README omits Grok and misstates signing. Keep existing CLI syntax.

## Validation

Pending regression red/green evidence and focused UI suite.

### Tooling regression evidence

- `scripts/test.sh swift -- --filter fixture` stopped in the fixture guard: `unexpected test-runner status 0 for zero fixture` with `Test run with 0 tests passed`. This is the intended RED evidence before adding the positive-count requirement.
- `SWIFT="$PWD/scripts/fixtures/swift-test-run.sh" scripts/test.sh swift -- --filter fixture` then stopped with `bundle verifier ignored PYTHON (status 1)` and ModuleNotFoundError from the hardcoded Python. This is the intended interpreter regression RED evidence.
- After the fixes the same fixture-only wrapper command exited 0. It exercises passing, zero-test, unfinished, failed and nonzero-exit Swift outputs, configured interpreter selection, and stale Claude/Grok/PI hook rejection. No Swift build occurs in these fixtures. The fake compiler also supplies manifest/version commands, so using it proves the toolchain guard honors SWIFT.

Decisions: require a positive total rather than pinning exact test counts; keep the existing expected host count on an unfiltered run. Read only bundled dependency metadata so a globally installed package cannot satisfy a missing bundled resource. Exact `==` pins remain the packaging contract; malformed requirements fail explicitly. Full signed app verification is an integration check requiring an assembled bundle and is not replaced by these boundary fixtures.

### UI regression evidence and implementation

`scripts/test.sh swift -- --filter 'SearchFieldTests|LogosTests'` exited 1, running 12 tests with exactly two issues: SearchField's editor became empty after undo while the binding remained `abc`; images for equal paths with different winding rules were the same object. Log: `/tmp/aiterm-task3-red.log`.

Added internal `TextFieldEditing` for live binding refresh, focus transitions, changed-text publication and undo/redo observation. Each coordinator retains its public delegate surface. Input still constructs its secure field and owns deferred caret placement; SearchField still owns popup commands and requested-focus retries. Field visuals and native sizing remain in their original views. The cache key now includes evenOdd while retaining the cheap path comparison.

Consolidated the UI support implementation into existing shared fixed settling and depth-first traversal, exporting only those existing helpers. Local UI spelling forwards to them so unrelated tests/imports need no churn.

Additional audit coverage: read Badge, Select, SegmentedControl, IconSource, InterfaceScale, Surface, ControlChrome, FrontToBackStack, FormField/HelpText, SymbolMark, Kbd, SidebarHeading, Hairline, Palette and Metrics. The primitive target contains no other production Swift source. Static immutable token values and small declarative renderers show no additional evidenced lifecycle or duplication defect requiring change. Palette's fixed-dark resolution and Icon's small tint cache are intentional. No token, public initializer or component inventory changes are needed; the design-system page's visible content remains accurate, so there is no local artifact change or publication.

### Green verification

`scripts/test.sh swift -- --filter AiTermUITests` exited 0: **86 tests in 21 suites passed**. Log: `/tmp/aiterm-task3-green.log`. This includes secure/plain Input editing and undo, caret-at-end, focus rings and retained focus, search undo/redo, all logo identity tests, shared-support callers and UI geometry/rendering. Package compilation printed pre-existing ArchiveTests unused-`try?` warnings; the UI tests reported no failures.

Follow-up design review moved changed-write suppression fully into TextFieldEditing and removed Input.edits; the existing characterization test now targets the shared production helper. The shared machinery no longer depends back on an owning component.

The fixture-only command `SWIFT="$PWD/scripts/fixtures/swift-test-run.sh" scripts/test.sh swift -- --filter fixture` also exited 0 after extending bundle coverage: matching isolated dist-info reaches a fake signer boundary, while each wrong runtime version fails the real Python metadata check. No actual signature is created or verified by the fixture. Expected runner failures keep their transient logs under one automatically removed fixture directory.

Residual integration limits: this task did not assemble or verify a real signed app bundle, run the daemon suite, or run the whole unfiltered Swift suite. Root task 4 owns the full suite/release build and independent review. No UI token changes, publishing, remote writes, new dependencies or public UI initializer changes occurred.
