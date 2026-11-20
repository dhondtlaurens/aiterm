# Workflow

- **Base branch**: `main`
- **Gate**: `scripts/test.sh`, from the worktree's root, before each commit. It runs only the suites the branch's changes can affect and prints what it picked; a docs-only branch exits at once. Before merging, a recent green full suite must cover the branch's test inputs: `python3 scripts/test-history.py require-full "$PWD" "${AITERM_TEST_LOCK:-/tmp/aiterm-test.lock}.history.jsonl"` exits 0 when one does (proof follows equivalent contents across worktrees and merge commits, and changes that select no tests, for seven days; a later failed full run revokes it; details in `docs/testing.md`). Otherwise run `scripts/test.sh all` plain, with no `SWIFT`, `PYTEST`, `PYTEST_ADDOPTS` or `AITERM_TEST_PATHS` override, on a clean tree. Both must end green. Runs queue machine-wide behind other worktrees' runs, so start them in the background and wait for your own command to exit; a queued run is not stalled, and another run is never polled or killed.
- **Host**: GitHub, `dhondtlaurens/aiterm` (`gh`), public. No pull requests: a finished branch is merged locally into `main` and pushed (`release.md`). Outside bug reports arrive through the issue form; feature requests and pull requests are not taken (`CONTRIBUTING.md`).
- **Tracker**: none.
- **Worktree**: every change is made in its own worktree, `.worktrees/<slug>` beside the main checkout. Check `git status` on `main` first: other sessions edit in parallel.
- **Branch**: `<type>/<slug>`, type `feat`, `fix` or `chore`.
- **Commit**: `<type>: <summary>`.
- **Merge**: `git merge --no-ff`, message `Merge branch '<branch>': <what a user now sees>`.
