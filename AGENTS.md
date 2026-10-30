# AiTerm

A native macOS sidebar app (projects → tasks → tabs) that drives real iTerm2 over its Python API.
`app/` is the Swift package, `daemon/` the Python daemon.

This file is the instructions for every agent. `CLAUDE.md` is a symlink to it, and the repo's
skills live in `.agents/skills/` with `.claude/skills` linking there — edit the originals, never
the links.

## The design system is code

`app/Sources/AiTermUI/README.md` is the spec: every colour from `Palette.swift`, every height,
radius, spacing and text size from `Metrics.swift`. Read it before changing anything visual. There
is no generated token file, no canvas and no approval gate — write Swift that obeys those rules.

`docs/design/design-system.html` mirrors the system for humans. It is synced from the code on
request (the `design-system` skill); it is never a source of truth. Its Proposals tab holds visual
changes that are not in the code yet, drawn with their options so one can be picked before any
Swift is written.

## Working here

- Workflow: docs/workflow/ (read by the psg skills).
- **Always work in a git worktree.** Other sessions may be editing the main checkout in parallel.
  Check `git status` on `main` before branching.
- Build and test through `scripts/swift.sh` and `scripts/test.sh`, which pin swiftly's Swift 6.4.
  Never invoke `swift` directly. `scripts/test.sh` runs one at a time machine-wide and queues
  behind any other worktree's run, so start it in the background rather than under a short timeout.
  - While iterating: `scripts/test.sh swift -- --filter <Suite>`; for the daemon, `pytest -k <expr>`
    from `daemon/` with its venv (`daemon/.venv/bin/pytest`).
  - Before each commit: plain `scripts/test.sh`. It runs only what the branch's changes can affect
    and says what it picked; a docs-only branch exits at once.
  - Once before merging to `main`: `scripts/test.sh all`, the full suite.
  - Test windows are hidden (transparent, click-through), so a visible one is a bug.
- Never type `/model`, `/effort` or `/config` into a live Claude Code session: it saves the choice in
  `~/.claude/settings.json` as the person's default for every new session. Probe with launch flags
  (`--model`, `--effort`) or a scratch `CLAUDE_CONFIG_DIR`, as `daemon/tools/delivery_check.py` does.
- The app is dark-only.

## Architecture and verification references

- `docs/architecture.md` maps decision/effect ownership; `docs/operators.md` describes the current
  structured broadcast workflow. Preserve the frozen current Operator contracts during refactors.
- `docs/testing.md` defines meaningful coverage, isolation and fixture ownership. Do not regenerate
  contract goldens to accommodate an incidental refactor.
- Debug snapshot entry precedes live controller construction. `scripts/run-dev.sh` is a deliberate
  live switch and must not be used while a running session needs to remain undisturbed.
