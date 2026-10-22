# PI as the Oracle and as an agent reviewer

## Intent

PI is AiTerm's way to providers other than Anthropic and OpenAI. The Operator's second opinion (the
Oracle: critiques, backlog vetoes, the shell gate, merge and no-verify vetoes) and its agent reviews
(`review_task`) run headless and read-only through `ChallengeLaunch`, today with Claude or Codex only.
This lets either run on PI, at the model and thinking level picked for it.

## Decided

- **One recipe.** PI gets a case in `ChallengeLaunch.invocation` and `critique`; agent reviews already
  reuse them (`AgentReview`), so `review_task` with `agent: pi` runs the same recipe in the task's worktree.
  Every `AgentKind` now has a headless run, so the invocation is no longer optional.
- **The run.** `pi -p --no-session --no-extensions --no-mcp --no-skills --no-prompt-templates --no-approve
  --offline --tools read,grep,find,ls`, then the model words, then `--` and the prompt. The answer is
  PI's stdout as plain text; there is no answer file. Spiked against PI 1.4.0: about 6 s, a write attempt
  refused, an unknown model exits 1 with its error on stderr.
- **Read-only by allowlist, not a sandbox.** PI has no OS sandbox: what keeps its runs read-only is the
  tool allowlist, with extensions and MCP off so nothing adds a tool. Settings › Operator's Oracle help
  says so in one short line.
- **Thinking.** `--thinking <level>` is passed only for a level PI names (`PiModelCatalog.thinkingLevels`);
  anything else is left out and PI runs at its own default, as PI itself does after warning. Settings
  already offers only the levels the picked model lists.
- **Failure.** As today: a PI run that fails, says nothing or times out leaves the act unchallenged
  (`SecondOpinionRunner`).
- **Defaults per agent.** The model an agent runs at when the Operator names none (`defaultModel(for:)`)
  is that agent's own card default or remembered model, for every agent, instead of "not Codex means
  Claude". `AgentIntegrations.fixerModel` takes an `AgentKind`.
- **Settings.** The Oracle's Agent offers every installed agent: Claude Code, Codex and PI. The saved
  profile needs no migration: `OracleSetting.agent` is an `AgentKind` already.

## Not in this change

PI as a worker the Operator plans, steers or messages (part B of the spike): no-go.
`review_task`'s default reviewer stays the other of Claude and Codex.
