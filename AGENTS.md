# AiTerm

A native macOS sidebar app (projects → tasks → tabs) that drives real iTerm2 over its Python API.
`app/` is the Swift package, `daemon/` the Python daemon. The repository is public (GPL-3.0): keep
code, fixtures and docs free of company names, internal hosts and real tickets.

`CLAUDE.md` is a symlink to this file, and `.claude/skills` links to `.agents/skills/`: edit the
originals, never the links.

## Invariants

- The design system is code. `app/Sources/AiTermUI/README.md` is the spec: every colour from
  `Palette.swift`, every height, radius, spacing and text size from `Metrics.swift`. Read it before
  changing anything visual. `docs/design/design-system.html` mirrors it for humans, synced on
  request by the `design-system` skill and never a source of truth; its Proposals tab draws visual
  changes with their options before any Swift is written.
- The app is dark-only.
- Swift runs only through `scripts/swift.sh` and `scripts/test.sh`, which pin Swift 6.4.
- Never type `/model`, `/effort` or `/config` into a live Claude Code session: it saves the choice
  as the person's default for every new session.
- Preserve the Signal contracts during refactors, and never regenerate contract goldens to
  accommodate an incidental refactor.

## Where to look

- Decision and effect ownership: `docs/architecture.md`. Signals and the Operator chat:
  `docs/operators.md`. Coverage, isolation and fixtures: `docs/testing.md`. Scripts:
  `scripts/README.md`.
- Workflow: docs/workflow/ (read by the psg skills).
- A workflow fact met during work that `docs/workflow/` lacks and that would clearly help next time
  (a proof step, a pitfall, a release trap): propose it for the matching file, and add it only on
  the user's yes.
