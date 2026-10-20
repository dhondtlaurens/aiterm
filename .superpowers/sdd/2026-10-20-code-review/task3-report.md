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
