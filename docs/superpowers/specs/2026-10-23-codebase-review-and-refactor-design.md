# Codebase review and refactor: dead code, duplication, practice, performance

## Intent

AiTerm grew fast once the Operator work began (2026-10-15: 509 commits in eight days). Round one's
concepts (many operators with personas, operations, an overview sheet, a debrief, Fix with AI with
its own agent select, a milestone delivery plan) were repurposed into one Operator per broadcast, a
board with Activity and Summary, Help with problems, and slices. Token tracking, Backpack's iPhone
push and Grok Build left the product. Each repurposing left code behind: types and cases nothing
produces, parameters nobody reads, copies of the same rule in several files, names of things that no
longer exist, and tests that pin behaviour no build ships.

This review removes that, consolidates real duplication, applies Swift and Python practice where it
lowers risk, removes work from hot paths, and fixes the functional defects the audit found. The
codebase should end smaller, with one home for each rule, and behave the same except where a defect
is fixed on purpose.

## Goals

- Every dead declaration, parameter, case, file, test helper and fixture the audit evidenced is gone,
  each removal backed by a `git grep -w` reference check over app, daemon, scripts and hooks.
- Each duplication left by a repurposed feature has one home; the change names the copies it replaced.
- Concurrency, access control, error handling and view identity follow the practice the codebase
  already states (its own comments and the UI README), where the audit found a departure.
- Hot paths do less: the daemon's per-post session-file scan, the Operator's shell gate with the Oracle
  off, transcript lookups per tick, per-keystroke view work, repeated status derivation.
- The functional defects marked "do now" are fixed test-first: each has a test that failed before.
- More lines removed than added in code (Swift, Python, scripts, tests), measured excluding
  docs/superpowers. The count is a signal, never the goal.
- Docs say what the code does: the Operator's tool lists, the README picture note, scripts/README,
  the keyboard list, the UI README inventory.

## Non-goals

- New features, a redesign, or a new architecture. Boundaries that work stay: Core/app/UI modules,
  ItermPort, HTTPJSON, the creation frame, per-row observation, the daemon's module split.
- Changing visuals. Snapshots stay byte-identical to a baseline drawn at the start, except the
  images whose words a copy fix changes on purpose (at least `settings-help-with-problems.png` and
  `settings-interface-full.png`); those are listed in the final report.
- Changing wire or data contracts: daemon RPC names and payload keys, hook schemas, the delivery
  policy file, persisted JSON, the Operator's MCP tool names and parameters. Exceptions are only what
  is dead on both sides, named in the plan.
- Unifying things that look alike but differ in contract: the per-host HTTP failure maps, Jira's three
  pagers, the remote-URL parsers, the self-timed pollers (ReviewThreadsWatcher, CheckoutMonitor).
- Re-running the 2026-10-20 review's fixes. Its residuals were re-checked: its "three remote-URL
  parsers" were misnamed (the real pair is ProviderDetector and Repository.sameLocation; still kept
  apart, see Report only), and its deferred external-path completion cost is fixed here.

## Anti-goals (a failure even if it compiles)

- A refactor that changes a request, a payload, a saved file or a pixel without saying so.
- Trading clarity for line count: no clever generics over three lines, no merged types whose
  semantics differ, no removed test that was the only pin of a behaviour.
- Churn without evidence: renaming persisted keys or notification identifiers, rewriting comments
  that only carry provenance, splitting files other open branches are editing, unless decided below.
- A behaviour change without a test that failed first.

## Constraints

- Work only in this worktree, on this branch; commit per subsystem; push nothing.
- Build and test only through `scripts/swift.sh` and `scripts/test.sh`. Swift test runs are serialized
  machine-wide; plain `scripts/test.sh` before each commit, `scripts/test.sh all` at the end, run in
  the background.
- The design system is code: every colour from `Palette`, every size from `Metrics`; a change to a
  primitive's inventory updates `app/Sources/AiTermUI/README.md` in the same commit.
- `scripts/readme-picture.sh --check` passes at the end.
- Org rules: no permanent deletion outside the repository without asking (the 185 leaked
  `~/Library/Preferences/aiterm-guard-*.plist` files a test wrote are reported, not deleted).

## Approach (decided)

1. **Audit** (done): nine read-only lanes, one per subsystem, each reporting dead code with reference
   counts, duplication with every copy, practice, performance, repurposing artefacts, tests and
   functional defects. The orchestrator re-verified each headline claim before planning. The item list
   lives in the audit's final report, not in the repository.
2. **Implement by lane**, disjoint file ownership:
   - Swift lanes run one after another, because they share one worktree and one `.build`:
     L1 Operator core, L2 Operator app, L3 Core infrastructure, L4 Core harnesses/hosts/fix/backpack,
     L5 app shell, L6 views/UI kit/snapshots, L7 shared test support (last, so it sweeps the files the
     other lanes left).
   - The daemon lane (Python only, daemon/ and hooks/) runs alongside the Swift lanes.
   - Cross-language items (a wire field dead on both sides; the daemon's timing constants a Swift test
     reads) run in one wire task after the daemon lane and L1.
   - Scripts, then docs, run last, so the docs describe the final code.
   - An item that crosses lanes is owned by the earlier lane, which edits the few files it needs.
3. **Each lane**: an implementer subagent with the lane's item list; test-first for every behaviour
   change; reference check before every removal; plain `scripts/test.sh`; coherent commits; then a
   review subagent (requesting-code-review) before the next lane starts. View refactors are checked
   against the baseline snapshots (`build/snapshots-baseline`, drawn at b29ffc4) with `cmp`.
4. **Finish**: `scripts/test.sh all`, `readme-picture.sh --check`, a whole-branch review, then
   finishing-a-development-branch (keep the branch), and the fast-forward of feat/refactor-broadcast.

## Decisions taken (the builder's calls; check these while reading)

- **Provenance comments stay.** 267 `spec §…` tags cite the Operator greenfield spec, which was never
  committed and no longer exists on disk. They are provenance, like the UI README's "design canvas"
  rule; only docs/architecture.md's two lines that name the missing file are fixed.
- **Persisted strings stay.** Internal "operation"/"overview"/"debrief" identifiers are renamed to
  board/broadcast/summary where they are code only; the `aiterm.overview` notification userInfo key,
  the `debrief-` notification id prefix, and any saved key keep their spelling.
- **Migrations stay** unless no shipped build can need them: the legacy pending `jira_create/` marker
  refusal stays (v0.24.0 shipped 2026-10-20); the `find_` key reservation goes (labels are hashed
  since v0.24.0, so it collides with nothing); `Project`'s legacy single `jiraProject` write goes
  (only pre-0.15 builds read it, none of which any feed serves).
- **Help with problems stays write-through.** Settings › Agents says it takes effect at once and Cancel
  does not undo it; its help text is corrected to stop pointing at an agent choice that doesn't exist.
- **open_tab gets no act**: its entry in the "acts on a task" list is dead and goes.
- **Retired settings keys are cleaned at launch** (`fixer`, `fixerIsOn`, `modelDefaults.grok`), beside
  the existing retired-key clean-up.
- **docs/sidebar.png goes** (0.15.0 picture with Grok marks; nothing draws or embeds it).
- **docs/superpowers stays tracked** as this repo does, despite its ignore line.
- **Kept although test-only**, as documented seams: the controllers' `last…` handles, timing pins
  mirrored from the daemon, `TOMLStatements.Table.text`.
- **ctl-only RPCs stay** (`sessions.list`, `usage.get`): `python -m aitermd ctl` uses them.
- **The daemon lane stages only `daemon/` and `hooks/`** and gates its commits with `scripts/test.sh daemon`.
- **No live checks** (the delivery check, the Operator evals): they open windows and spend tokens; the
  final report recommends them.
- **The known flaky test** (`aWideDiffStaysSmallWhateverItsParts`, failing at b29ffc4 too) is investigated
  in L2; if it still fails the final run once after a rerun, it is reported rather than blocking.
- **Subagents run on Opus 5.5**, at most three at a time: one Swift implementer, the daemon implementer
  and one reviewer.

## Decisions for the operator (each changes what gets built)

Answered 2026-10-23: 1-9 as recommended (10: no splits). 11: fix the test only; the existing plists are
left alone and the final report gives the clean-up command. Fast-forward: at the end, if the main checkout
is still on feat/refactor-broadcast, clean, and the branch is where it was when last merged in, run
`git -C <main checkout> merge --ff-only <head>`; otherwise change nothing and report. If the branch moves,
merge it in at the next lane boundary and re-run the reference checks.

Plan changes from the operator: the daemon lane runs in a separate Codex worker tab in this worktree; it
owns daemon/ and hooks/ and commits only those paths. This session never touches daemon/ or hooks/; the wire
task, scripts and docs run here after the Codex tab reports done. At most two subagents at a time, Opus 5.5
at high effort, no optional extra review passes. A commit that meets index.lock waits and retries.

The questions as put:

1. Retire the Operator's milestone ladder (M1/M2/M3): production is always M3; M1/M2 rules live only
   in tests. Recommend yes.
2. Delete the Fix pipeline's Codex path: Help with problems always runs Claude; the Oracle reuses only
   the shared pieces. Recommend yes.
3. Retire the GitLab update feed: shipped builds use the GitHub feed and the bundle check rejects any
   other; the GitLab home is archived. Recommend yes, moving its credential-redirect tests to HTTPJSON.
4. `jira_edit`'s required `key` is never read (an edit is idempotent by its values). Recommend dropping
   it from the schema and the handler (a dead MCP parameter).
5. `message_task` answers an identical text to the same tab from its record for ten minutes, so a
   deliberate second "continue" is never typed. Recommend shortening to twice the request timeout.
6. Remove deletes a folder under `.worktrees/` that git no longer lists without asking. Recommend only
   deleting a leftover this row's own removal reached, else asking.
7. A paste iTerm2 may have taken (timeout mid-send) is reported refused, so a retry can paste twice.
   Recommend reporting it partial and marking the input unsent.
8. Unify the three Model/Reasoning field groups; AgentStep then falls back to the model's default
   reasoning, as Settings does, instead of the first level. Recommend yes.
9. Split SidebarRows.swift (954 lines) and move AppController's Operator wiring into its extension
   files. Pure moves; they conflict with other open branches. Recommend no for now.
10. The final fast-forward: `feat/refactor-broadcast` is now checked out in the main checkout (since
    08:37 on 2026-10-23), so moving the ref from here would leave that tree showing the refactor
    reversed. Options: fast-forward in the main checkout only if it is clean and the branch has not
    moved, else stop and report; or leave the fast-forward to the operator. Recommend the former.
    Also: will anyone commit to that branch meanwhile? If so, this branch merges it at lane
    boundaries and re-runs the reference checks.
11. A test leaked 185 `aiterm-guard-*.plist` files into `~/Library/Preferences`. The test is fixed here;
    the files are only reported. Moving them to the Trash needs the operator's yes.

## Left to the builder

- Exact helper names and file homes, within the module boundaries and CoreFoldersTests' folder rules.
- Whether an S3 consolidation is clean enough once in the code: if the shared form reads worse than the
  copies, keep the copies and say so in the lane's report.
- Test names and the split of oversized test files, keeping one suite per owner.
