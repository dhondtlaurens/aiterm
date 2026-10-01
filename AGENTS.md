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

- **Always work in a git worktree.** Other sessions may be editing the main checkout in parallel.
  Check `git status` on `main` before branching.
- Build and test through `scripts/swift.sh` and `scripts/test.sh`, which pin swiftly's Swift 6.4.
  Never invoke `swift` directly.
- The app is dark-only.
