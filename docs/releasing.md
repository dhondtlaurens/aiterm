# Releasing

One-time setup:

- **Signing certificate.** Keychain Access → Certificate Assistant → Create a Certificate… → Name
  `AiTerm Release`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing* → Create. No
  trust setting is needed: `codesign` signs with it as it is. Export a backup (Keychain Access → My
  Certificates → AiTerm Release → Export, `.p12`) and keep it somewhere safe: releases signed with
  another certificate cannot update installs signed with this one.
- **GitHub CLI.** `brew install gh`, then `gh auth login`.
- **Python 3.11 or newer**, which `scripts/make-dmg.sh` uses for `dmgbuild` (installed into
  `build/.dmg-venv` on first use).

Then, from a clean, pushed `main`: `scripts/release.sh <version>`. It builds and signs the app,
wraps it in `AiTerm-<version>.dmg`, pushes the tag `v<version>` and publishes the GitHub release.

Before it builds anything, it redraws the README's picture and refuses to go on while
`docs/desktop.png` differs from it, so a release never ships a README showing an older sidebar.
Run `scripts/readme-picture.sh`, look at the new `docs/desktop.png`, commit and push it, and run
the release again. The picture is drawn by a real window, so the main display must be Retina.

The release is created as a draft with its image attached and only then published, so updaters
never see a release without its DMG. If the run stops after pushing the tag, finish it by hand.
First check whether the release exists: `gh release view v<version> --repo dhondtlaurens/aiterm`.
If it doesn't, create it:
`gh release create v<version> build/AiTerm-<version>.dmg --repo dhondtlaurens/aiterm --draft --verify-tag --title "AiTerm <version>" --notes "AiTerm <version>"`.
Then, if the image is missing from the release, upload it:
`gh release upload v<version> build/AiTerm-<version>.dmg --repo dhondtlaurens/aiterm`.
Finally, publish the draft:
`gh release edit v<version> --repo dhondtlaurens/aiterm --draft=false`.

If the `git push` itself failed, the tag exists only locally, and a re-run refuses with "v…
already exists". Retry `git push origin v<version>` and continue with the steps above, or delete
the local tag with `git tag -d v<version>` and re-run `scripts/release.sh <version>`.

The build number is one more than the number of `v*` tags, plus 19: the releases published before
AiTerm moved to GitHub, whose tags this repository does not have. It keeps increasing for every
install that came from them.

## Before a release: manual checks

The automated suites do not cover VoiceOver navigation, multiple displays or a complete real
Jira-to-agent workflow. Run through this list by hand:

1. Launch: the sidebar shows "Waiting for iTerm2…" until iTerm2's API prompt is allowed, then the
   banner clears.
2. Add a GitLab repo, a GitHub repo, a plain local repo and a non-git folder; check the provider
   icons and the "+" menu on each.
3. Project "+" → **New Terminal…**: the sheet prefills a name ("Terminal", then "Terminal 2"); on
   **Create Terminal** the iTerm2 window must open in the project folder, carry that name and snap to the
   right of the sidebar. Run `claude` in it: the row's shell mark becomes the Claude mark and the
   status dot goes live. `Cmd+T` in that window must land in the project folder, not in `$HOME`.
4. **Settings ⌘,** › Integrations → enter Jira, GitLab and GitHub credentials; each card tests them
   once you stop typing.
5. **New Task…** with a real ticket: worktree, branch, iTerm2 window and the agent launching with
   the previewed command.
6. `Cmd+T` inside a task window: a second avatar appears on that task's row. Same in a terminal
   window — starting `codex` in the new tab adds its mark next to the one already there.
7. Trigger an agent permission prompt: amber mark → answer it → spinner → **Stop** → done mark.
8. Run Claude Code and Codex: the footer's USAGE group shows both vendors' limits.
9. Drag the sidebar: task windows re-snap. Close a task window: a second later AiTerm asks Remove's
   question; Cancel keeps the row as "Window closed", its worktree on disk. Click that row: the window
   reopens and the agent resumes its conversation. Quit iTerm2 with task windows open: nothing is
   asked, every row stays. Drag a task window's only tab into another window: nothing is asked, and
   clicking the row raises that window. Close a task window and stay in iTerm2: if AiTerm cannot come
   forward, its Dock icon bounces until you switch to it.
10. **Remove Task…**: the window closes, the worktree is removed, the branch is kept unless the
    checkbox is ticked.
11. Open the release DMG: AiTerm on the left, Applications on the right. Drag AiTerm to
    Applications, replacing the previous release, and open it.
12. On a Mac still running the previous release, **AiTerm › Check for Updates…** offers this
    release and installs it in place.
13. **New Review…** on a GitHub repo: open pull requests list as `#n`; a fork's pull request is
    refused with its fork named.
