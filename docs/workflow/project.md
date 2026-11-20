# Workflow

- **Base branch**: `main`
- **Gate**: `scripts/test.sh`, from the worktree's root, before each commit. It runs only the suites the branch's changes can affect and prints what it picked; a docs-only branch exits at once. Once before merging, `scripts/test.sh all`, run plain (no `SWIFT`, `PYTEST`, `PYTEST_ADDOPTS` or `AITERM_TEST_PATHS` override, clean tree): only that run counts as the release's proof for its `HEAD`. Both must end green. Runs queue machine-wide behind other worktrees' runs, so start them in the background and wait for your own command to exit; a queued run is not stalled, and another run is never polled or killed.
- **Host**: GitHub, `dhondtlaurens/aiterm` (`gh`), public. No pull requests: a finished branch is merged locally into `main` and pushed (`release.md`). Outside bug reports arrive through the issue form; feature requests and pull requests are not taken (`CONTRIBUTING.md`).
- **Tracker**: none.
- **Worktree**: every change is made in its own worktree, `.worktrees/<slug>` beside the main checkout. Check `git status` on `main` first: other sessions edit in parallel.
- **Branch**: `<type>/<slug>`, type `feat`, `fix` or `chore`.
- **Commit**: `<type>: <summary>`.
- **Merge**: `git merge --no-ff`, message `Merge branch '<branch>': <what a user now sees>`.
