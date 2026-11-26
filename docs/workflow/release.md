# Shipping

## What ships

A merge only moves `main` on GitHub: there is no CI and nothing deploys. A release is a separate
step: `scripts/release.sh <version>` signs the app with the `AiTerm Release` certificate, wraps it
in a DMG, tags `v<version>` and publishes the GitHub release that every install reads under
AiTerm › Check for Updates. It runs only from the GitHub-origin main checkout, and only on the
maintainer's yes. Releases are listed with `gh release list --repo dhondtlaurens/aiterm`.

After a merge and push, ship offers one release and proposes the version, semver by what a user
sees: major for anything the person must do to upgrade (with a note in `docs/release-notes/`), minor
for new behaviour, patch for fixes and small tweaks only. A change to the saved workspace does not by
itself make a release major: its update script takes the version the release gets.

## Pipeline

1. **Merge**, in the main checkout (the first line of `git worktree list`). Run `git status` there
   first: uncommitted work in it is the maintainer's and is never committed, stashed or discarded
   without asking. `git merge --no-ff <branch> -m "Merge branch '<branch>': <outcome>"`, then
   `git push origin main`. The branch's worktree and branch stay: AiTerm locks its task worktrees
   (`git worktree list` shows `locked`), and removing one by hand strands its task. AiTerm's
   Remove task… removes them.
2. **Release**, on a yes, from the main checkout: `scripts/release.sh <version>`, after the proof
   check in `project.md`'s gate passes; when it does not, `scripts/test.sh all && scripts/release.sh
   <version>` as one background job. `release.sh` refuses unless `main` is clean and equal to
   `origin/main`, a plain full pass covers its test inputs, the version is newer than the latest
   tag, `gh` is logged in, the certificate is in the keychain and Python is 3.11 or newer.
3. It redraws `docs/desktop.png`, and when the picture changed it commits
   `Redraw the README picture for <version>` and pushes it. That commit selects no tests, so the
   earlier full pass still covers it.
4. It builds, stamps the version and build number (counted from the tags), signs, checks the bundle,
   makes the DMG, pushes the tag, uploads the DMG to a draft release and publishes it.

A run that stops after pushing the tag is finished by hand with the two `gh release` commands at
the end of `scripts/release.sh`, using that run's `build/AiTerm-<version>.dmg`. A draft that was not
published: `gh release edit v<version> --repo dhondtlaurens/aiterm --draft=false`.

## Workspace format and update scripts

`state.json` carries a top-level `version`: the format it is in, which is the version of the newest
update script it went through (none means 1.5.0). A build reads only its own format, the newest
script it ships (`AiTerm --workspace-format`), and stamps it on every save.

- A change to anything the workspace saves (a field added, renamed, retyped or removed, a new enum
  value, a value no longer written) adds a script to `UpdateScripts.all`
  (`app/Sources/AiTermCore/Updates/Scripts/`), versioned as the release that ships it, at any level
  (major, minor or patch), and newer than the last released format. It edits the
  file as JSON from the previous format to the new one, and the decoders read only the new one: no
  defaults for keys an older file lacks, no unknown cases for values a newer one might hold.
- At launch, a file in an older format goes through every script after its version, in order,
  under the progress panel; the file as it was is kept as `state.json.before-update-<version>`. A
  file in a newer format is refused. There is no way back: an older build never opens a workspace a
  newer one has updated.
- `release.sh` refuses a release older than the format it saves, and a release that brings a new
  script under any version other than that script's.
- A release with a script has a note in `docs/release-notes/` that says what the update does and
  that the workspace cannot go back, whatever level the release is.

## Checks

- `gh release view v<version> --repo dhondtlaurens/aiterm`: published, not a draft, with the DMG
  attached.
- `scripts/readme-picture.sh` needs a Retina main display. When it keeps finding a difference that
  is not a change, compare the ICC profiles (`sips -g profile`) and park the pointer off the task
  rows before redrawing.

## Done

No tracker to move. Ship reports the merge commit and, when one went out, the release's URL.
