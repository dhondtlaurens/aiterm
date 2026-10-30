# Running and proving a change

## Setup

A fresh worktree needs nothing copied in: there are no env files or certificates for development.
It needs swiftly with the Swift pinned in `.swift-version` (6.4), Python 3.11+ and iTerm2 with its
Python API enabled. `scripts/test.sh` creates `daemon/.venv` with the `dev` extra on first use.
Never invoke `swift` directly; `scripts/swift.sh` and the other scripts pin it.

## Run

- `scripts/make-app.sh` builds `build/AiTerm.app` without launching it.
- `scripts/run-dev.sh` builds a DEV app, quits the running AiTerm, stops an orphaned helper and
  opens the new bundle. This is a live switch: development and installed copies share
  `state.json`, the daemon socket and the hook port, and two must never run at once. Ask before
  running it: other sessions, possibly this one, live in the AiTerm being replaced. Back to the
  release: quit it and open `/Applications/AiTerm.app`.
- The helper logs to `~/Library/Application Support/AiTerm/aitermd.log`, cleared at every launch.

## Prove locally

- Logic: the gate, or while iterating `scripts/test.sh swift -- --filter <Suite>` and
  `daemon/.venv/bin/pytest -k <expr>` from `daemon/`. A filtered run must execute at least one test.
- Anything visual: `scripts/snapshots.sh build/<folder>` draws the sidebar, boards and sheets from
  fixtures with a fixed clock; open the PNGs and look. Check the rules in
  `app/Sources/AiTermUI/README.md`.
- The README picture: `scripts/readme-picture.sh --check` fails when the sidebar changed since
  `docs/desktop.png` was drawn; `scripts/readme-picture.sh` redraws it (Retina main display only).
- The bundle: `scripts/make-app.sh`, then `scripts/test-app-bundle.sh build/AiTerm.app` checks
  resources, pinned dependencies and the signature without running the app.
- Typing into agent CLIs: `daemon/tools/delivery_check.py`, by hand with iTerm2 open (usage in its
  docstring). It opens windows and spends tokens; never part of the gate.
- A real flow in the running app only through `scripts/run-dev.sh`, on the maintainer's go.

## Pitfalls

- `scripts/test.sh` queues behind every other worktree's run; a short timeout kills a run that was
  only waiting. Leave other runs alone.
- Test windows are transparent and click-through; a visible one is a bug.
- Never type `/model`, `/effort` or `/config` into a live Claude Code session; probe with launch
  flags or a scratch `CLAUDE_CONFIG_DIR`.
- More in [scripts](../../scripts/README.md) and [testing](../testing.md).
