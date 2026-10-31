# Make the README useful and inviting for prospective users

## Goal

Help a first-time visitor understand what AiTerm does, why it helps and how to try a first task.
Balance a welcoming introduction with concrete feature coverage and accurate setup guidance.
This is documentation work on the existing `feat/improve-readme` worktree.

The user approved this scope in chat: a benefit-led README, six core features, the existing
screenshot, installation and a first-task walkthrough, a separate configuration reference, and
preservation of current disclosures and contribution policy.

## Approach

Restructure the README around discovery and first use, then link to detailed references.
Describe capabilities through things the user can do, with concrete mechanisms where they help.
Use clear, human language and grounded claims. Keep the README useful on its own for deciding
whether to try AiTerm and starting an ordinary task.

The adopted research found strong coverage but weaker benefit explanation, invitation and first
use in the current README: an editorial 6/10, not a measured conversion result. The relevant
patterns are concrete feature examples in [bat](https://github.com/sharkdp/bat/blob/a3f202f3677c8b5d13f45d0fb2b408ec1175fa89/README.md),
a demonstrated workflow in [Atuin](https://github.com/atuinsh/atuin/blob/93bbf9c95e68a821b805737d54ed0029496ca498/README.md),
and a clear product introduction with linked depth in
[Ghostty](https://github.com/ghostty-org/ghostty/blob/95fb39ae0cb8d0f8cfe2e4e50a5278d2b8983335/README.md).
The full local evidence is in `docs/research/2026-10-31-readme-benchmark.md`; this plan includes
the adopted conclusion and source links so it does not depend on that ignored file being shared.

### Reader journey

1. Open with the everyday benefit of organising coding agents across projects. Identify native
   macOS, real iTerm2, Claude Code and Codex early, and provide a direct latest-release link.
   Give PI its qualified support description in the agent/configuration material.
2. Keep `docs/desktop.png` and its descriptive alt text. Add a short visible caption explaining
   the sidebar and selected task's terminal. Do not redraw the image or add an animation.
3. Explain six core capabilities in short, scannable sections: isolated task branches/worktrees;
   several agent tabs within a task; attention states and Focus View; Operator coordination of
   one brief across selected projects; review worktrees; shelving and restoration. Explain
   Operator and broadcast in plain terms when introduced. Distinguish isolated tasks from tabs
   that share a task's worktree. A manual review can open in an existing task's checkout when that
   branch is already owned; distinguish ordinary New Review from the Operator's read-only review
   tabs. Describe launch restrictions without promising a complete security sandbox.
4. Give requirements and the current installation path, including macOS 26+, iTerm2, Python
   3.11+, Python API enablement, self-signed first launch, connection approval, agent installation
   and updates. Retain the link and prompt for the AI installation guide. Explain any sign-in
   required by the chosen agent without implying AiTerm supplies an account or subscription.
5. Walk through a first ordinary task in an existing Git repository with a usable committed base
   branch: File > Add Project, choose the checkout, select its project, File > New Task, complete
   Task, Agent and Prompt, inspect the command and choose Create Task. Jira is optional; this
   path needs no Jira/GitHub/GitLab service token. Name the expected sidebar row, new branch,
   separate worktree and iTerm2 agent window. Direct readers to the linked guide for broadcasts.
6. Briefly retain additional capabilities such as plain terminals/folders, project dividers,
   Jira/host integration, supported usage/context readings, Git recovery and Unplugged. Link
   configuration, window behaviour, keyboard and status guides for the operational details.
7. End with a concise local-data summary, direct bug-report and private security-report routes,
   the existing contribution boundary, development commands/reference links and licence.

### Preserve information and boundaries

Move detailed settings information into `docs/configuration.md`, grouped by the existing Agents,
Operator, Integrations and Interface panes. Cover Save/Cancel exceptions, immediate Install/Repair
and Help with problems effects, sidebar-size preview/Cancel behaviour, driver backups, Messaging
Run check, agent support distinctions, service token permissions and Keychain storage. Link the
existing Operator guide for its full workflow rather than duplicating its contracts.

The configuration reference also documents Help with problems and Unplugged setup, permissions
and stop conditions. Retain raw local transport/data paths through the existing architecture
reference; retain detailed reconnect, close and restore behaviour through the windows reference;
retain worktree include behaviour in the configuration reference. Keep all previous capabilities
discoverable in the README or through a labelled reference link.

Keep the exact Codex approval/sandbox-bypass disclosure visible before the first task can be
launched. Keep self-signed installation guidance at installation, Keychain and local-data facts
easy to find, and Unplugged permissions with its description. Do not imply that separate worktrees
isolate agent permissions or that local workspace storage means agent processing is offline.
Preserve the maintainer-led policy: bug reports are welcome; feature requests and PRs are not
taken. Moving that policy does not change it.

No Swift/Python behaviour, design tokens, screenshot, release packaging, installation automation,
live sessions or publishing changes are included. A future demonstration video is outside scope.

## Files

- Modify `README.md`: write the reader journey, feature explanations, walkthrough and reference
  links; preserve the material caveats and existing development guidance.
- Create `docs/configuration.md`: give relocated settings/operational details a public, linked
  destination without losing current information.
- Modify `CONTRIBUTING.md`: replace the stale *Build from source* reference with a link to the
  README's final development heading. Preserve the contribution and security-report policy.
- Modify `docs/design/ui-patterns.md`: add the configuration guide to its introductory list of
  user documentation destinations. This is a reference-link edit only.
- Create this plan in `docs/plans/2026-10-31-improve-readme.md`; record review and proof here.
  Keep the research note under the repository's existing local ignore rule.

Read-only implementation sources for checking documentation include `AiTermApp.swift` for menu
labels, `ProjectActions.swift`, `AppController.swift`, `Views/NewTaskSheet.swift`,
`Views/CreationSheet.swift` for the command preview, `Views/Steps/AgentStep.swift`,
`Views/HarnessSettingsPane.swift`, `Views/SettingsView.swift`, `Views/MacSettingsCard.swift`,
`AiTermCore/Agents/AgentCommand.swift` and the harness definitions, plus existing installation,
Operator, keyboard, windows, architecture and status documents. No source edits are required.

## Proof

No new automated tests are appropriate for this prose-only change. Verify the following:

- Read the README from top to bottom as an unfamiliar user: product, primary agents, platform,
  benefit and download are clear early; core features appear before installation details;
  installation leads to a concrete first-task result.
- Check every UI label and first-task prerequisite against current code. Use a committed Git
  repository for the walkthrough; plain folders have no New Task action. Keep agent selection,
  model/readiness, authentication and command-preview guidance consistent with current behaviour.
- Account for every current README capability/detail: kept in the README, moved to the linked
  configuration reference, or already present in a specifically linked existing document.
  Check `.worktreeinclude`, agent support qualifications, messaging checks, service permissions,
  settings effects, window lifecycles, local data and development/live-switch cautions explicitly.
- Verify the six feature descriptions distinguish each task's isolation from its shared tabs,
  describe optional Operator/review features accurately and add no unsupported promises.
- Verify all relative file links and heading fragments, including links into the README from
  CONTRIBUTING and the new configuration guide. Read the Markdown layout for heading order,
  list/table formatting, caption placement and discoverable routes to the new guide.
- Confirm `docs/desktop.png` is unchanged. No live launch or screenshot refresh is needed.
- Run `git diff --check` and the required plain `scripts/test.sh` before each commit. The expected
  result for documentation-only changes is no selected application suites; record what ran.
  If later merging, run `scripts/test.sh all` once before merging as the repository requires.
- Use the independent change-review workflow when implementation is complete, and triage findings
  before committing the documentation rewrite. No merge or release is implied by this plan.

## To-dos

- [x] Create the configuration reference from the current README's detailed settings information,
  check its facts against source/existing guides and add its link to the user-documentation list
  in `docs/design/ui-patterns.md`. The current README remains usable during this additive step.
- [x] Rewrite the README's discovery and first-task journey, link the configuration guide and fix
  CONTRIBUTING's development link. Check all relocated facts have a labelled reference destination.
- [x] Verify first-task instructions, feature accuracy, full information coverage, links and
  Markdown layout; confirm the picture is unchanged and run the required documentation gate.
- [x] Obtain independent change review, triage findings, repeat checks affected by fixes and
  record final evidence before the documentation commit.

## Plan review

One independent Claude adversarial-review round returned Ready, with three Minor findings and
no Critical or Important findings. All three were verified and fixed in this plan:

- Split the configuration-reference creation from the README rewrite so each is a working step.
- Add `AiTermApp.swift` and `Views/CreationSheet.swift` to the verification sources for menu labels
  and the visible command preview.
- Include the configuration link in `docs/design/ui-patterns.md`'s list of user guides.

Follow-up source reads also confirm the command preview is drawn on the Agent/Prompt steps.
Ordinary task creation uses the Git/worktree path, independent of hosted-service API tokens;
normal Git transport authentication can still apply to remote Git operations. Explicitly distinguish
ordinary manual reviews from read-only Operator review tabs and note checkout reuse.

Findings and per-finding triage are retained outside the repository under this worktree's Git
directory, in `psg/plan-claude.md` and `psg/plan-triage.md`. No findings remain open. The initial
documentation gate passed with no selected application suites; final plan whitespace/path checks
also passed. Product documentation had not been edited at plan approval.

## Implementation evidence

The approved plan was committed as `cf6776b4` before implementation. The documentation changes
were kept uncommitted through implementation and independent review.

The README now presents the benefit, download/navigation links, existing picture with caption,
six core capabilities, installation, a five-step first-task walkthrough and additional features.
The contribution boundary is near the end; requirements, self-signing and the exact Codex launch
disclosure remain with setup. Manual reviews and the Operator's read-only review tabs are
distinguished using `TaskWorkflow.swift` and `AgentCommand.swift`.

Information coverage was checked against the previous README:

| Previous material | Destination |
| --- | --- |
| Projects, tasks, tabs, reviews, broadcasts, Shelf, status, Focus/List View, usage/context | README features and additional capabilities; linked status and keyboard references. |
| Reconnect adoption, window closing choices, restoration, quitting leaves agents running | Linked window guide; quitting behaviour remains in README features. |
| Four settings panes, Save/Cancel exceptions, preview sizing, zoom and badges | Configuration guide opening and Interface section. |
| Claude/Codex/PI support, install/repair backups, Messaging Run check, model defaults | Configuration guide Agents section; primary and additional providers remain discoverable in README. |
| Operator settings, optional slices, house instructions, Oracle | Configuration guide Operator section and existing linked Operator guide. |
| Keychain, Jira linkage, GitLab scopes, GitHub permissions | Configuration guide Integrations section; README data summary and project features. |
| Help with problems and explicit Apply; Unplugged permissions, battery/idle stops, rule removal | README feature links and configuration guide details. |
| Worktree include files, workspace/log paths, hook telemetry, optional sudoers rule | Configuration guide worktree/data sections and existing architecture reference. |
| Updates, AI installation prompt, development/live-switch cautions, licence, contribution policy | Retained in README; CONTRIBUTING's development reference is now a working link. |

Verification performed:

- Parsed all four user-facing changed Markdown files with the installed MarkdownIt parser,
  including HTML and tables. All 41 local links/image references and heading fragments resolve.
- Rendered the README and configuration guide to temporary HTML and inspected headless Chrome
  screenshots of the opening/features, install/first-task instructions and configuration/table.
  These are local layout previews, not a claim of exact GitHub rendering. A blank fragment-based
  preview was replaced by a successful render of the install/walkthrough excerpt.
- Compared `docs/desktop.png` by SHA-256 with its committed bytes: unchanged. No application,
  daemon, script or screenshot edits were made, and no live app switch or agent install was run.
- Checked menu labels and Task/Agent/Prompt steps against `AiTermApp.swift`, `NewTaskSheet.swift`,
  `CreationSheet.swift` and `CreationModel.swift`; checked optional Jira against `TaskCreationModel`.
  Confirmed Git worktree creation uses Git authentication independently of service API tokens.
- Checked agent installation, model/PI behaviour, configuration effects, token requirements and
  Unplugged stop conditions against their current settings/harness/backpack implementations.
- `scripts/test.sh` exited zero: only Markdown documentation paths changed, so no application
  suites were selected. No new tests were added. `git diff --check` passed.

One independent Claude change-review round returned Ready with fixes, with one Minor finding:
the multiple-agent feature should explain that the extra tab is opened with ⌘T inside the task's
iTerm2 window. Verified against the keyboard/window guides and fixed the feature paragraph with
the exact action and example agent commands. This distinguishes it from AiTerm's ⌘T, which opens
a project terminal. No Critical or Important findings were raised, and no findings remain open.
The findings and fixed triage are retained in the worktree's Git directory as
`psg/change-claude.md` and `psg/change-triage.md`. The changed Markdown was rendered and validated
again after this fix, and the final documentation gate and whitespace checks passed.

All implementation to-dos are complete. The full suite and live app flow were not run for this
documentation-only change; the full suite is required if the branch is later merged.

## Review handoff

The user requested the review workflow after implementation. Rechecked the current diff and
Claude's completed review/triage: the one Minor is fixed, with no open findings or listed Minors.
The product documentation has not changed since its final validation. The review workflow adopts
that completed challenge and its rendered previews; no further challenge round is needed for the
small verified fix. The documentation gate and whitespace/link checks were repeated before commit.

The final change contains the README, configuration guide, CONTRIBUTING link, user-guide index
link and this plan's completion evidence. The repository uses local merges and no pull requests,
so this handoff ends with a local documentation commit and verification that its tree matches
the staged tree. Next integration step: the full pre-merge suite and the maintainer's local merge.
Nothing has been pushed or published.
