# Shipping

## What ships

A merge only moves `main` on GitHub: there is no CI and nothing deploys. A release is a separate
step: `scripts/release.sh <version>` signs the app with the `AiTerm Release` certificate, wraps it
in a DMG, tags `v<version>` and publishes the GitHub release that every install reads under
AiTerm › Check for Updates. It runs only from the GitHub-origin main checkout, and only on the
maintainer's yes. Releases are listed with `gh release list --repo dhondtlaurens/aiterm`.

After a merge and push, ship offers one release and proposes the version, semver by what a user
sees: major for a change to the saved workspace or anything the person must do to upgrade (with a
note in `docs/release-notes/`), minor for new behaviour, patch for fixes and small tweaks only.

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

## Operator format

The saved workspace carries the Operator's records: signals, each task's `signalTask` or
`signalOrigin`, and the Operator's folds. A change to them is a change to the saved workspace, so ship
proposes a major version and the change brings a note in `docs/release-notes/` saying what an older
build does with a workspace this one saved.

- `TaskItem` and `AppState` keep keys they do not know (`PreservedFields`), so an older build writes
  a newer task's `signalOrigin`, `operatorFolded` and saved `signalDividers` back unchanged.
- `Signal` (and the copy each stage keeps) has no such store: an older build that saves the workspace
  drops a field it does not know. A project signal then loses its `kind` and becomes an Operator
  signal there, and one whose Done is "You decide" (`person`) decodes it as unknown and stops running.
- Opening such a workspace with the older build is therefore not supported. To go back, remove the
  project signals first, or expect them to come back as Operator signals.
- Going forward needs nothing: a newer build reads every older record, and its own new fields are
  optional and left out while empty, so `operator-signals/state.json` keeps its bytes.

## Checks

- `gh release view v<version> --repo dhondtlaurens/aiterm`: published, not a draft, with the DMG
  attached.
- `scripts/readme-picture.sh` needs a Retina main display. When it keeps finding a difference that
  is not a change, compare the ICC profiles (`sips -g profile`) and park the pointer off the task
  rows before redrawing.

## Done

No tracker to move. Ship reports the merge commit and, when one went out, the release's URL.
