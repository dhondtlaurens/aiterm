# Repository scripts

Run commands from the repository root in a Git worktree. All Swift operations use `swift.sh` and
`.swift-version` (Swift 6.4). The test queue serializes builds/tests across worktrees; start long
checks in the background and follow their own logs.

## Build and inspect

```sh
scripts/make-app.sh
scripts/test-app-bundle.sh build/AiTerm.app
```

`make-app.sh` produces `build/AiTerm.app` without launching it: release executable, Info.plist,
icon, license, daemon package and delivery-check tool, pinned Python dependencies, Claude status
shim and PI extension. Integration code comes from this checkout. Bundled `PYTHONPATH` keeps
runtime packages out of the user's Python installation.

`build-app.sh [debug|release]` shares Swift build/log handling; it builds only product AiTerm.
Full logs stay in `build/swift-build-<configuration>.log`, with diagnostics printed on failure.
`test-app-bundle.sh` checks resources against source, pinned dependency versions and the strict code
signature without running the app. Both signing and verification must succeed.

| Override | Meaning |
| --- | --- |
| `SWIFT` | Complete Swift 6.4 toolchain executable; default `~/.swiftly/bin/swift`. A different major/minor is refused. |
| `PYTHON` | Python 3.11+ interpreter for vendoring/test setup, default `python3`. |
| `SIGN_IDENTITY` | Signing identity: `AiTerm Release` when available, otherwise ad-hoc (`-`). |
| `AITERM_RELEASE=1` | Release bundle. Otherwise Info.plist marks a DEV build and disables self-update. |

## Switch the running build

```sh
scripts/run-dev.sh
```

This builds a DEV app, normally quits the current AiTerm, stops its orphaned helper and opens the
new bundle. Installed/development copies share their identifier, workspace, socket and hook port.
This is a live switch; do not use it while another run must remain undisturbed. A stable signing
identity preserves automation/Keychain grants across rebuilds.

## Test

```sh
scripts/test.sh
scripts/test.sh all
scripts/test.sh daemon
scripts/test.sh swift -- --filter DesignRulesTests -j 2
```

The default selects affected tests since this branch left `main`, including commits and local/new
files. `test-select.sh` and `test-routes.tsv` explain the selection. Docs-only changes select none;
unknown paths or an unavailable base select everything. `AITERM_TEST_PATHS` supplies a
newline-separated override for routing checks. Arguments after `--` replace the selected Swift
filter, even when no Swift suite was selected; daemon does not accept Swift arguments.

`test-queue.py` provides machine-wide FIFO admission (`/tmp/aiterm-test.lock`, override
`AITERM_TEST_LOCK`). Kernel locks survive a killed supervisor in its live children; crashed waiters
release tickets. A queued run selects again after admission. Per-run metadata records the run's
own queue/result state; a missing completion never becomes success. Leave other runs alone.

`test-swift-toolchain.sh` proves the pin and runner behavior. `test-test-select.sh` guards fixture
readers and routing. `test.sh` creates `daemon/.venv` with the `dev` extra when needed, runs pytest,
then its own venv's mypy/ruff over implementation, tests and tools. `PYTEST` can override the pytest
executable; lint still uses the repository venv.

Swift Testing case parallelism defaults to four, honoring an explicit
`SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`. `-j` independently limits compiler jobs. A pass
requires completed host results and at least one matching test for a filter. Failed logs are kept;
`AITERM_TEST_LOGS_KEEP=0` discards them. New AiTerm preference domains fail the run; tests use
`ScratchDefaults`. The test-only window hook makes ordered windows transparent and click-through.
See [testing](../docs/testing.md) for coverage ownership and opt-in live boundaries.

## Snapshots and README picture

```sh
scripts/snapshots.sh                         # build/snapshots
scripts/snapshots.sh build/my-snapshots
scripts/readme-picture.sh --check
scripts/readme-picture.sh                    # update docs/desktop.png, then inspect it
```

Debug snapshot entry precedes live controller/workspace setup. Rendering uses fixtures, a fixed
clock and stationary working arcs. `snapshots.sh` builds the app product, then replaces only
PNG files at the output folder's top level; failed builds preserve previous images.

The README renderer draws the actual sidebar beside a fixture terminal. Its hosted capture
requires a Retina main display. To capture native AppKit/selection materials:

```sh
AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_NATIVE_CAPTURE=1 scripts/snapshots.sh build/native-dark
```

WindowServer capture requires screen-recording permission; view capture is the fallback and can
render native selection material differently. Neither mode proves VoiceOver or multi-display
behavior. The app is always dark.

## Release

```sh
scripts/make-dmg.sh build/AiTerm.app build/AiTerm-<version>.dmg
scripts/release.sh <version>
```

`make-dmg.sh` uses pinned `dmgbuild` in `build/.dmg-venv`, then verifies the image, mounted app,
version, signature and Applications link. Layout is in `dmg-settings.py`.

`release.sh` publishes externally: it requires clean pushed `main`, the expected GitHub origin,
logged-in `gh`, a newer version, the release certificate, Python 3.11+ and a current README picture.
It stamps the built bundle, creates/pushes the version tag, uploads the DMG to a draft, then
publishes. The development bundle marker is refused. Complete the full gate and manual release
checks first. Signing setup, version numbering and interrupted-release recovery live in
[releasing](../docs/workflow/release.md). A build/test command never implies permission to release.
