# Running and proving a change

## Setup

A new worktree needs nothing copied. `scripts/swift.sh` and `scripts/test.sh` use swiftly's Swift
6.4 from `.swift-version` (`~/.swiftly/bin/swift`; a different major or minor is refused), and the
first `scripts/test.sh` that tests the daemon creates `daemon/.venv` with the `dev` extra. Never call
`swift` directly. After a daemon dependency pin changes, an existing venv keeps the old library until
`daemon/.venv/bin/pip install -e 'daemon[dev]'` runs in it.

## Run

Agents never run the app. `scripts/run-dev.sh` quits the maintainer's installed AiTerm and opens
the development build in its place; the two share `state.json`, the helper's socket and the hook
port `127.0.0.1:47821`, so two never run at once. A live check belongs to the maintainer: say what
to look at, and leave the switch to them.

Building without launching is fine: `scripts/make-app.sh` writes `build/AiTerm.app`, and
`scripts/test-app-bundle.sh build/AiTerm.app` checks its resources, pinned versions and signature.

## Prove locally

- **Behaviour**: a test that fails without the change. Iterate with
  `scripts/test.sh swift -- --filter <Suite>`, or `daemon/.venv/bin/pytest -k <expr>` from
  `daemon/`; finish with the gate. What belongs in which suite is in `docs/testing.md`.
- **Anything visible**: `scripts/snapshots.sh build/snapshots-before` on the base, the same into
  `build/snapshots-after` on the branch, then read both sets of PNGs yourself and compare. A visual
  check is never handed to the maintainer. Native AppKit materials need
  `AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_NATIVE_CAPTURE=1` and screen-recording permission.
- **Packaging** (bundle, daemon vendoring, signing): `scripts/make-app.sh` then
  `scripts/test-app-bundle.sh build/AiTerm.app`.
- **Live boundaries** stay opt-in and out of the gate, run only when asked: `AITERMD_LIVE=1`
  (iTerm2 integration, needs iTerm2's Python API enabled), `AITERM_LIVE_OPERATOR=1` (spends quota), and `scripts/compat-check.sh`
  (updates the agent CLIs, opens iTerm2 windows, spends quota).

## Pitfalls

- A visible test window is a bug: test windows are transparent and click-through. A new AiTerm
  preference domain fails the run; tests use `ScratchDefaults`.
- Wall-clock tests flake under load. Check `uptime` and rerun the test alone before blaming the
  change.
  The GitLab artwork in `marks.png` and the signal sheets comes out in two exact variants across
  captures of one commit; capture again before calling that a regression.
- Never block on `DispatchQueue.global()` or inside async tests: it starves the cooperative pool.
  Use a `Thread` and mark blocking suites `.blocking`. `DispatchQueue.main.async` never runs inside
  a main-actor test; use `RunLoop.main.perform`.
- `#require` nested inside `#require` fails the whole test target's build.
- Pixel diffs compare RGB, not RGBA: `getbbox()` on RGBA checks alpha only.
- An `@Observable` write of an equal value does not notify. ⌘A cannot be a View-menu key, and an
  `NSAlert` modal inside a key handler is not allowed.
- Probing Claude Code: launch flags (`--model`, `--effort`), or a scratch `CLAUDE_CONFIG_DIR` with
  an empty `CLAUDE_SECURESTORAGE_CONFIG_DIR=` to keep the login, as
  `daemon/tools/delivery_check.py` does. `codex exec` waits on stdin forever: add `< /dev/null`.
