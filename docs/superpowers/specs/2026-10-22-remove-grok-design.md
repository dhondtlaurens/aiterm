# Remove Grok Build support

## Intent

AiTerm gives first-class support to two agents, Claude Code and Codex. PI stays, because it is
extendable: it is how someone uses another provider, Grok/xAI models among them, while keeping as
much of AiTerm's Claude/Codex behaviour as PI's extension can carry. Grok Build as its own harness
goes: its driver, hooks file, model catalogue, status line, vendor mark, palette entry, settings
card, daemon routes and parsers, tests and fixtures.

## Goals

- No `grok` left in the app, daemon, scripts, issue template or the docs that describe the shipped
  product. Old review reports under `docs/superpowers/reviews/` are history and stay as written.
- Code that Grok shared with other harnesses keeps working for them and loses the case: no enum
  case, switch arm, field, parameter or helper that only Grok used.
- Saved data that names Grok still loads: a task keeps loading (as a Claude task, its raw agent
  kept and written back, as for any agent this build does not know), a Grok conversation is not
  resumed, and per-agent preferences for Grok are dropped. A former Grok task's hand-opened Claude
  conversation resumes on Claude's defaults, never with the Grok model the task was launched with.
- Wherever AiTerm explains its agents, it says Claude Code and Codex are fully supported and that
  other providers, such as Grok, work through PI.

## Non-goals

- Rewriting the root README (a later task); only its Grok lines are removed or adjusted.
- Regenerating `docs/desktop.png` or `docs/sidebar.png` (a later task). `ReadmeDesktop` and the
  snapshot fixture may change, which leaves the README picture stale until then.
- Extending PI (the next task). The parity gaps are listed in the hand-off, not fixed here.

## Decisions (the builder's own calls)

- **No clean-up of `~/.grok`.** An existing install leaves AiTerm's hooks file and its status-line
  entry in `~/.grok`. After this change the hooks post to a route the daemon no longer serves and
  the status line names a shim the bundle no longer ships. AiTerm does not edit `~/.grok` to undo
  that: keeping Grok's TOML editor alive only to remove itself is the code this change removes. The
  user-facing note says how to remove both by hand.
- **Unknown agents fall back as they already do.** `TaskItem` already reads an unknown `agent` as
  `.claude` and keeps the raw value; conversations and preferences already drop one. No new
  `AgentKind` decoder: the Operator only ever saved Claude or Codex (`ModelChoice.pair`,
  `oracleAgents`), so its records cannot name Grok.
- **Daemon mechanisms only Grok used go**: turn ids (`promptId`), nested-agent events, process
  title patterns, the Grok status-line route and parser, and the orphan settle for harnesses whose
  end-of-turn signal dies with a deleted cwd, if every remaining harness survives that.
</content>
</invoke>
<invoke name="Bash">
<parameter name="command">cd /Users/laurensdhondt/Sites/personal/aiterm/.worktrees/remove-grok-support-pi-is-the-path-for-other-pro && sed -n 380,420p daemon/aitermd/status.py; grep -n "Notification\|_notification_type\|notifications" daemon/aitermd/hook_events.py | head