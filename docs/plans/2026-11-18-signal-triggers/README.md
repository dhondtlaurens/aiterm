# Step briefs for signal triggers

Each file in this folder is the brief for one to-do of [the plan](../2026-11-18-signal-triggers.md). The
implementing agent for a step gets this page and that step's brief, nothing else. Read both completely
before changing anything.

## What you are working on

AiTerm is a native macOS sidebar (projects, tasks, tabs) that drives real iTerm2 through a Python daemon.
`app/` is the Swift package, `daemon/` the daemon. One **task** is one branch, one git worktree, one iTerm2
window and its agent conversations. The **Operator** automates those same tasks: a **signal** watches Jira,
GitLab or GitHub; each matching **item** (a ticket or a merge request) starts or continues exactly one task
as a **stage** with a prompt, a done condition and a Then (keep, archive, remove). A **worker** is the agent
in a driven task. One Operator chat (a Claude Code session with tools) is woken only for judgment; the
**Oracle** gives second opinions.

This change replaces how a signal says what it matches. Today a Jira signal is built from condition chips
(`JiraConditions`, compiled by `JQL.compile`) and a GitLab or GitHub signal is one of two fixed events
(`RequestConditions`); its done condition is one of a fixed list (`DoneWhen`). After it, a signal has a
**Start trigger** and a **Done trigger**. A trigger is a source (Jira, GitLab or GitHub), the description the
person wrote and a **query**: JQL for Jira, GitLab's search-bar syntax for GitLab (parsed by AiTerm into
GraphQL filters), GitHub's search syntax for GitHub. The query is what runs.

## Words

Use: signal, item, task, stage, worker, Operator, Oracle, trigger, query, Archive. Never: broadcast, run (for
the Operator), board, Shelf, slice, verdict. A comment says what the code does now, never how it got there.

## Decisions that bind every step

- **No compatibility with old signals.** Nothing reads or converts the old signal shape. Do not write a
  migration or a second decoding.
- **GitLab query syntax** (decided and probed against GitLab CE 19.5.3 GraphQL, read-only, 18 Nov 2026):
  whitespace-separated tokens `key:value`; a value may be quoted (`label:"needs review"`); a leading `-`
  negates a token. Keys: `author:`, `assignee:`, `reviewer:` (value `@me`, a username, `none`, `any`),
  `review-state:` (`unreviewed`, `review_started`, `reviewed`, `requested_changes`, `approved`,
  `unapproved`; commas mean or), `approved-by:` (`@me` or a username), `draft:` (`yes`, `no`), `label:`
  (repeat for and), `target-branch:`, `source-branch:`, `milestone:`, `project:` (a full path; commas mean
  or), `state:` (`opened`, `merged`, `closed`, `all`). AiTerm-only tokens, never sent to GitLab:
  `threads:waiting-on-me` (an unresolved thread whose last note's author is known and is not the account)
  and `threads:resolved` (no unresolved thread); both may be negated.
- **The role rule.** A Start query names the account in exactly one positive role: `author:@me`,
  `assignee:@me` or `reviewer:@me`. That role picks the GraphQL list: `currentUser.authoredMergeRequests`,
  `assignedMergeRequests` or `reviewRequestedMergeRequests`, and with it what `review-state:` means (the
  account's own review state under `reviewer:@me`; any reviewer's under the other two). A negated `@me`
  (`-reviewer:@me`) is a filter, not a role. A Start query with no role, or two, is refused with a sentence
  naming what to add or remove. A Done query may name one role or none; with none it is read through
  `project(fullPath:).mergeRequests(iids:)`, where `review-state:` is any reviewer's.
- **Real, then likely.** Before you handle an edge case, ask whether it can really happen for one person's
  signals on one Mac, and whether it plausibly will. If either answer is no, do not handle it.
- **No frameworks.** A protocol only at a real I/O seam a test needs to fake.

## How to work

1. Read the brief. Re-run its evidence (the greps under **Today**) before you change anything; symbols are
   the anchor, line numbers drift.
2. Small differences from **Today** are normal: the code decides what exists, the brief where the step ends.
   Carry on and say what differed. If the brief turns out wrong in a way that changes the step, stop and
   report; do not quietly build something else or widen the step.
3. Do exactly the step. Things you notice outside it go in your report, not in the diff.
4. New logic gets its test first. A deletion needs no new test; say which surviving test covers the same
   failure, or that the behaviour is deleted on purpose.
5. Leave the change uncommitted. The orchestrating session reads the diff, runs the gate and commits.

## Rules of the repository

- Work only in this worktree (`.worktrees/jql`). Never touch the main checkout, another worktree, or
  `git stash`.
- Build and test only through `scripts/swift.sh` and `scripts/test.sh` (they pin Swift 6.4). Never call
  `swift` directly. While iterating: `scripts/test.sh swift -- --filter <Suite>` (a filtered run must run at
  least one test). Before you report: plain `scripts/test.sh`. It queues behind other worktrees' runs: run
  it in the background and wait for your own command to exit; never poll, kill or bypass another run.
- Never run `scripts/run-dev.sh`, `scripts/release.sh`, the delivery check, or anything behind
  `AITERM_LIVE_OPERATOR` or `AITERMD_LIVE`. Never type `/model`, `/effort` or `/config` into a live Claude
  Code session.
- Visual values come from `app/Sources/AiTermUI/README.md`, `Palette.swift` and `Metrics.swift`. The app is
  dark-only. Copy uses no em dashes.
- Frozen fixtures (`app/Tests/AiTermCoreTests/Operators/Fixtures/operator-signals/`) change only when the
  brief says so, by hand, with a line in the fixture folder's `PROVENANCE.md` saying which step and why.
- The repository is public. No private paths, user names, company names, internal hosts or real ticket keys
  in code, tests, fixtures or docs. Use `gitlab.example.com`, `SHOP-412`, `webshop`, `alex`, `sam`.
- Recorded host answers in tests are written by hand in the shape the host returns, as the existing tests in
  `app/Tests/AiTermCoreTests/Operators/SignalSourceTests.swift` do with their URL stubs.

## How a brief is laid out

**Why**, **Today**, **Change**, **Keep**, **Decisions already taken**, **Tests**, **Proof**, **Done when**,
**Not in this step**.

## Your report

What you changed (by file), tests deleted with their survivors, the result of plain `scripts/test.sh` with
its closing lines, anything in the brief that did not hold, and anything you noticed and left alone.
