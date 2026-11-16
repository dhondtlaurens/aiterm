# 2g. Worker guard: local merge allowed, one argument table and one "this API call writes" rule

Implementer: Codex `gpt-6.1-sol` high. Depends on: 1c (the push stack is gone; `sameLocation`, `shortBranch`, `folded` and the full-commit-id rule now sit beside the worker guard) and 1j (the shell gate's refusal texts name existing tools). Comes from: audit OC F9.

## Why

A worker that brings its branch up to date with `git merge origin/main`, an ordinary step after a conflict, is refused, while `git pull` (which merges) and `git rebase` pass. The outcome the refusal was meant to prevent, a merge landing on the default or another branch, is already prevented by the pre-push hook, which lets a worker push only its own task branch at its current commit, as a fast-forward. The plan's "workers never merge" meant merges on the host. Separately, the Operator's shell gate and the worker guard each carry their own copy of git's option table, gh and glab's option table, and the rule that says whether a `gh api` or `glab api` call writes; the two copies differ, and a short-option cluster such as `-iXPUT` is understood by only one. Two paths were written for cases nobody has met: reading GraphQL bodies from files, and following git aliases four levels deep. After this step a worker may merge locally, one table and one writes rule serve both parsers, and those two paths are gone.

## Today

- Shell gate: `Operators/ShellGate+Denials.swift`. `ShellGate.hardDenial` (the Operator's shell) and `ShellGate.publishingDenial(_:check:)` (the worker guard's entry) share one reader of the command's words: simple commands between `;`, `&&`, `||`, `|`, `&`, newlines and parentheses, `$( )` and backticks, `sh -c` and `eval` strings, and inline `-c alias.<name>=...`, to a depth of four (`deepest`). With a `check` it hands every `git`, `gh` or `glab` call's program and arguments to `check`; without one it applies the Operator's rules: `gitDenial` (push; commit, checkout, switch, clean; `reset --hard`), `requestDenial` (the `gh pr` and `glab mr` verbs in `ghVerbs`, `glabVerbs`) and `sendsToTheAPI`. Its tables are `private`: `gitValued` (options before git's subcommand that take a value) and `hostValued` (gh and glab options that take a value). `sendsToTheAPI` decides "this `api` call is not a GET": a method named by `-X`, `-XPUT`, `--method`, `--method=`, or a short-option cluster such as `-iXPUT` or `-iftitle=x`, or, with no method, any field or `--input`.
- Worker guard: `Operators/WorkerGuard/`. `WorkerGuard+Commands.swift` has its own `gitValues` (equal to `gitValued`), `gitCommand`, a private `hostValues` (equal to `hostValued` minus `-t --template -p --preview --cache`), `hostDenial` (positionals, then merge verbs, then the API check), `graphqlMerges`, `hostField`. Its API check reads `-X`, a `-X<verb>` prefix and `--method=` by hand, and fields through `hostField`; it does not understand a cluster, so `gh api -iXPUT repos/a/b/pulls/1/merge` is read as a GET and allowed. `WorkerGuardCLI.swift` runs `hook`, `argv` and `push` modes; `additionalDenial` adds two things: configured git aliases (a `git config --get alias.<verb>` lookup, recursing up to four levels, with a "cannot verify this chain of git aliases" refusal) and, for `gh api` and `glab api`, reading a GraphQL query from `-F query=@file`, `--input file` or `--input -` to find a merge mutation.
- The merge rule: `WorkerGuard+Commands.swift` `gitDenial`, `if command.verb == "merge"`, refuses with "Workers never merge; ...". Pinned by `WorkerGuardRulesTests` (`"git merge main"` in the refused list) and `WorkerGuardLaunchTests.theLaunchEnvironmentRefusesBypassesAndMerges` (a real process). A second refusal of the same command sits in `Agents/AgentCommand.swift`: the Claude denial list a publishing worker launches with (`publishingClaudeDenials` today) contains `Bash(git merge:*)`. A review tab's own list (`reviewClaudeDenials`, read-only) also denies merge and stays.
- Live callers of the guard: `AiTerm/Operators/WorkerGuardEntry.swift`, `AiTermApp.swift`, `SignalWorkerIO.swift` (launch), `SignalShellGate.swift` (the Operator's gate). Docs: `docs/operators.md`, "Publishing, done conditions and merging" (the sentence about the guard).

## Where this brief differs from the plan's one line

Checked by the planner; build what this brief says.

The plan lists `git merge` for the shell and shim guard only. The Claude launch denial list refuses `git merge` too, so a Claude worker would still be refused after the guard is fixed. I removed that one entry as part of this step. The compat capture does not record the publishing list (`compat/launch.json` has `worker` and `review` only; its `git merge` entries are the review tab's), so no fixture changes. The audit also names `GIT_CONFIG_COUNT` leading-zero stripping and its 1024 cap in `WorkerGuardLaunch.launchScript` as speculative; the plan does not list it, so I left it alone and raise it in the report.

## Change

1. Make `ShellGate.gitValued` and `ShellGate.hostValued` the only tables (internal instead of private). Delete `WorkerGuard.gitValues` and `WorkerGuard.hostValues`; `WorkerGuard.gitCommand` uses `ShellGate.gitValued`. The worker therefore gains the five extra gh options (`-t --template -p --preview --cache`), which is correct: they take a value.
2. Add one shared helper on `ShellGate` for "the leading positionals of a gh or glab call, up to two, skipping options and the values of `hostValued` options", moved out of `requestDenial`; `requestDenial` and `WorkerGuard.hostDenial` both use it.
3. Make `ShellGate.sendsToTheAPI` internal: it is the one "this API call writes" rule. `WorkerGuard.hostDenial` drops its hand-written method and field reading. Its API check becomes: positionals say `api` and an endpoint (percent-decoded); an inline GraphQL query (the value of a `query=` field given by `-f`, `-F`, `--field`, `--raw-field`, in the spelled-out and attached forms `hostField` reads today) that holds a merge mutation (`graphqlMerges`) is refused whether or not the method is named; a call that `sendsToTheAPI` and whose endpoint ends in `/merge` (with or without a query string) is refused. Both refusals keep their texts. A method of `HEAD` now counts as a write because `sendsToTheAPI` treats anything but GET so; against a `/merge` endpoint that is harmless.
4. Delete the `merge` branch in `WorkerGuard.gitDenial`. Keep the `core.hooksPath` override refusal. Delete `"Bash(git merge:*)"` from the Claude denial list a publishing worker launches with.
5. `WorkerGuardCLI`: delete the `gh`/`glab` file-reading half of `additionalDenial` (the `--input` and `query=@file` paths, the `"-"` refusal, the one-megabyte limit and its refusals). Keep the configured-alias half, but look an alias up once: its expansion is scanned with `publishingDenial` and the argv rules only, with no further alias lookup and no `depth` parameter, and delete the "cannot verify this chain of git aliases" refusal. Rename the function for what it now does (the configured alias) and fix its doc comment, which speaks of API input files. Keep the catch that turns a failed `git config` read into "could not verify this command".
6. `WorkerGuard.hostField` becomes private if nothing else reads it. Update the sentence in `docs/operators.md` to say the guard refuses "worker-initiated merges of a request on the host" and that a worker may merge branches locally.

## Keep

- The pre-push hook and everything behind it: `WorkerGuard.pushDenial`, the `push` mode, `Scope`, the host fence (`liveFence`), the re-read of the scope after the host read. It is the real protection and the reason local merges are safe; `WorkerGuardCLITests.scratchRepositoryChecksObserveHostAuthorityAgainAfterItsRead` and `WorkerGuardRulesTests.thePushHookChecksEveryRef...` pin it.
- The Operator's own refusals in `ShellGate` (`gitDenial`'s push, commit, checkout, switch, clean and `reset --hard`; `ghVerbs`, `glabVerbs`; the API denial of any non-GET call). The worker's verb policy is different (a worker may comment and, when publishing is on, create a request) and stays in `WorkerGuard`; only the tables and the writes rule are shared.
- The inline `-c alias.<name>=...` reading and the nested-shell depth `deepest = 4` inside `ShellGate`: they serve the Operator's gate as well, and cost nothing.
- Inline GraphQL merge detection (`graphqlMerges`): cheap, and a cooperative worker can write a merge mutation inline.
- The `-c core.hooksPath` override refusal and the `argv` and `hook` modes: they keep a worker from disabling the pre-push hook.
- `GIT_CONFIG_COUNT` handling in the launch script (not in this step).

## Decisions already taken

- A GraphQL merge mutation placed in a file (`-F query=@file`, `--input`) is no longer inspected. Real, but not likely from a worker that was already refused `gh pr merge`. No replacement.
- A git alias that names another alias is not followed past the first. Real, not likely. No replacement.
- A short-option cluster in a worker's `gh api` call (for example `-iXPUT`) is read with the shared rule. An inline GraphQL query given inside a cluster (`-ifquery=...`) is not extracted; it was not before. Do not extend `hostField`.
- Refusal texts do not change except that the merge refusal for local `git merge` disappears with its rule.

## Tests

- `WorkerGuardRulesTests`: move `"git merge main"` from the refused list to the allowed list (`workerCanCommitAndPublishItsOwnBranch`), and add `"git merge origin/main"`. Add to the refused list `"gh api -iXPUT repos/a/b/pulls/4/merge"` and `"glab api -XPUT projects/1/merge_requests/3/merge"` (the cluster case that only the shell gate read), and to the allowed list `"gh api repos/a/b/pulls/4/merge -iX GET"`.
- `WorkerGuardLaunchTests.theLaunchEnvironmentRefusesBypassesAndMerges`: remove `"git merge main"` from the arguments and rename it for bypasses only.
- `WorkerGuardCLITests.graphqlQueriesReadFromFilesStillRefuseMerge`: delete (the behaviour is deleted). `aConfiguredAliasCannotHideThePushOptionsPassedToIt` stays and must pass.
- `SignalWorkerProfileTests`: add one assertion that the publishing worker's launch words do not contain `Bash(git merge:*)`, while the review launch (`readOnly: true`) still does.
- `ShellGateTests` must pass unchanged; if a case there changes behaviour, stop and report.
- No fixture is re-recorded. The probe executable (`AiTermWorkerGuardProbe`) is rebuilt by the suite that uses it.

## Proof

While iterating: `scripts/test.sh swift -- --filter WorkerGuardRulesTests`, `WorkerGuardCLITests`, `WorkerGuardLaunchTests`, `ShellGateTests`, `SignalWorkerProfileTests`, `WorkerGuardCodexTests`. The compat and Codex scratch checks are the maintainer's. Then plain `scripts/test.sh` in the background.

## Done when

- `grep -rn "gitValues\|hostValues\|Workers never merge; " app/Sources` returns nothing except the host-merge refusals in `hostDenial` (`gh pr merge`, `glab mr accept`).
- `grep -rn "git merge:" app/Sources` hits only the review denial list's generated entries (no literal in the publishing list).
- `grep -rn "query=@\|cannot verify this chain" app/Sources` returns nothing.
- `WorkerGuard` and `ShellGate` both call `ShellGate.sendsToTheAPI` and the shared positionals helper.
- Suites above and plain `scripts/test.sh` are green.

## Not in this step

The push stack and the `CommitId` wrapper (1c, done). The shell gate's refusal wording (1j). The shared Operator/worker vocabulary and the Oracle gate (5c).
