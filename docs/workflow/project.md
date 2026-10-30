# Workflow

- **Base branch**: `main`
- **Gate**: `scripts/test.sh`, from the worktree root, before each commit. It runs only the suites
  the branch's changes can affect and says what it picked; a docs-only branch exits at once. Once
  before merging to `main`: `scripts/test.sh all`. It fixes nothing; it must end green. Runs queue
  one at a time machine-wide, so start it in the background. Details in `AGENTS.md` and
  [testing](../testing.md).
- **Host**: GitHub, `dhondtlaurens/aiterm` (`gh`). Branches are merged locally; no pull requests.
- **Tracker**: GitHub issues on `dhondtlaurens/aiterm`, bug reports only. No issue keys in branches
  or commits.
- **Branch**: `<type>/<slug>`, type `feat`, `fix` or `chore`, slug the summary lowercased and
  hyphenated (`fix/no-test-line-on-own-tasks`). Always in a worktree under `.worktrees/`.
- **Commit**: one sentence saying what changes, in plain words, no type prefix and no key
  (`Give the daemon one Application Support path, one percent clamp and shared iTerm2 helpers`).
  An optional body says how. A fix round after a review: `Fix round <n> from the review of <sha>: …`.
- **Merge**: on `main`, `git merge --no-ff <branch>` with
  `Merge branch '<branch>': <what the branch does, in plain words>`. No MR/PR. Pushing `main` is
  the maintainer's call; `scripts/release.sh` needs it pushed.

## Ticket style

Taken from this project, 2026-10-30. Issues come from people using AiTerm through the bug report
form (`.github/ISSUE_TEMPLATE/bug_report.yml`): AiTerm, macOS and iTerm2 versions, agents involved,
what happened and what was expected, steps to reproduce, an `aitermd.log` excerpt. Label `bug`.
Feature requests and pull requests are not taken and are closed with a pointer to `CONTRIBUTING.md`.
Planned work is not filed as issues; it starts from a plan in `docs/plans/`.

## Tracker quirks

- Blank issues are disabled (`.github/ISSUE_TEMPLATE/config.yml`): a person can only open the bug
  form. `gh issue create` still works for the maintainer.
- The repository is public: no private paths, names or log lines in an issue.
- Security reports go through GitHub's private vulnerability reporting, never an issue.
