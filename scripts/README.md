# scripts

## `make-app.sh`

Builds `build/AiTerm.app`, the only form of AiTerm that is fully functional (the daemon, Claude
status-line shim and PI status extension are bundle resources).

    scripts/make-app.sh

Environment overrides:

| Variable | Default | Purpose |
|---|---|---|
| `SWIFT` | `~/.swiftly/bin/swift` | Swift 6.4+ toolchain. `scripts/swift.sh` rejects an incompatible override. |
| `PYTHON` | `python3` on `PATH` | Interpreter used for the `pip install --target` vendoring; must be ≥ 3.11. |
| `SIGN_IDENTITY` | `AiTerm Release` when that certificate is in the keychain, else `-` (ad-hoc) | Code-signing identity. A stable one keeps the iTerm2 automation permission and the Keychain's "Always Allow" across rebuilds; `-` forces ad-hoc. |
| `AITERM_RELEASE` | unset | `1` builds a release. Otherwise the bundle gets `AiTermDevBuild` in its Info.plist: a DEV pill on the Dock icon, and no self-update. `release.sh` sets it and refuses a bundle that still carries the key. |

## `run-dev.sh`

Builds a dev `build/AiTerm.app` and runs it instead of whichever AiTerm is open:

    scripts/run-dev.sh

The two share a bundle identifier, `state.json`, the daemon socket and the hook port, so they must
not run together. The script quits the open one through a normal quit (the first run asks to let
your terminal control AiTerm), stops an orphaned `aitermd` so the new build does not adopt old
daemon code, then opens the build.

## `make-dmg.sh`

Wraps a built `AiTerm.app` in the release's drag-to-Applications disk image:

    scripts/make-dmg.sh build/AiTerm.app build/AiTerm-0.2.0.dmg

The layout lives in `dmg-settings.py`: the app on the left, a link to `/Applications` on the right,
no background. `dmgbuild` writes it without driving Finder, from a pinned copy in `build/.dmg-venv`
created on first use. The script then verifies the image, mounts it read-only and checks that the
app inside is signed, is the version it was given, and the image has a link to `/Applications`.

## `release.sh`

Publishes a version that **Check for Updates…** will offer:

    scripts/release.sh 0.2.0

It refuses unless it runs on a clean `main` equal to `origin/main`, `origin` is
`github.com/dhondtlaurens/aiterm`, the version is newer than every `v*` tag, `gh` is logged in to
github.com, the "AiTerm Release" certificate is in the keychain and Python is 3.11 or newer. It
then builds with that certificate, stamps the version and a build number (19 plus one more than the
number of `v*` tags — see `docs/releasing.md`) into the built bundle only, wraps it with
`make-dmg.sh`, pushes the tag `v<version>` and publishes the GitHub release with
`AiTerm-<version>.dmg` attached.

## `swift.sh`

The shared Swift launcher for AiTerm’s build, snapshot, and test commands. It defaults to Swiftly’s
selected toolchain and refuses any compiler older than Swift 6.4 before invoking Swift Package
Manager. The repository’s `.swift-version` pins the selected release to 6.4.0. Set
`SWIFT=/path/to/swift` only for a complete Swift 6.4+ toolchain.

## `test.sh`

Runs the daemon and app suites through the supported toolchain:

    scripts/test.sh

The command runs the portable toolchain guard before either suite, so a toolchain downgrade fails
fast instead of producing opaque compiler errors. On its first run, it creates `daemon/.venv` and
installs the daemon package with its test and lint dependencies (the `dev` extra). Set
`PYTHON=/path/to/python3` to use a specific Python 3.11+ interpreter, or `PYTEST=/path/to/pytest`
to use an existing test runner.

After pytest it lints the daemon: `mypy aitermd tests`, then `ruff check aitermd tests`. The tests
are type-checked too, so `FakeIterm` must keep matching the `ItermPort` it stands in for. The lint
always runs `daemon/.venv`'s own `mypy` and `ruff`, whatever `PYTEST` names: an override need not
live in a venv at all (the toolchain guard's own check passes `/usr/bin/true`). A venv made before
the lint step may lack either tool; the script then stops and prints the `pip` command that
installs the `dev` extra.

The Swift suites run in one `swift test` pass. No test raises a real modal alert — the app's
questions go through a `Prompter` that tests script. `swift test` exits 0 on a run that never
finished, so the pass counts as green only if every test target's host printed swift-testing's
closing "Test run with N tests … passed" line. On a failure the logs are kept, and the script
prints where.

Runtime Python versions are pinned in `daemon/pyproject.toml`; the bundle installs that package
directly so development and release do not maintain different dependency lists.
`scripts/test-app-bundle.sh` checks the executable, icon, hook shim, bundled dependency versions,
and strict code signature. Both signing and signature verification must succeed during a build.

Snapshots always use the app’s dark appearance. For captures of actual AppKit controls and native selection materials:

    AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_NATIVE_CAPTURE=1 scripts/snapshots.sh build/native-dark

WindowServer capture requires screen-capture permission. Without it, the renderer falls back
to view capture, which can show native selection materials as black. Neither capture mode
establishes VoiceOver behavior or multi-monitor placement.

What it produces:

    build/AiTerm.app/Contents/MacOS/AiTerm                     release binary
    build/AiTerm.app/Contents/Info.plist                       copied from app/Sources/AiTerm/Resources
    build/AiTerm.app/Contents/Resources/daemon/aitermd/        the daemon package
    build/AiTerm.app/Contents/Resources/daemon/<deps>          iterm2, websockets, protobuf (pip --target)
    build/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh
    build/AiTerm.app/Contents/Resources/hooks/pi-aiterm-status.ts

Both hook resources are copied from this repository while the app is built. AiTerm never
downloads executable integration code during installation or at runtime.

The app launches the daemon with `PYTHONPATH=<Contents/Resources/daemon>`, so both `aitermd` and
its dependencies resolve from the bundle — nothing is installed into the user's Python.

The bundle is signed ad hoc (`codesign --sign -`). Developer ID signing and notarisation are a
later task; `build/` is git-ignored.
