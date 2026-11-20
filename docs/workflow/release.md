# Shipping

## What ships

A merge to `main` ships nothing. A release is a signed `AiTerm-<version>.dmg` on a published GitHub
release `v<version>` of `dhondtlaurens/aiterm`, which AiTerm › Check for Updates… reads. There is no
CI: `scripts/release.sh <version>`, run by hand from a clean, pushed `main`, does it all. A
build/test command never implies permission to release.

## One-time setup

- **Signing certificate.** Keychain Access → Certificate Assistant → Create a Certificate… → Name
  `AiTerm Release`, Identity Type *Self-Signed Root*, Certificate Type *Code Signing* → Create. No
  trust setting is needed: `codesign` signs with it as it is. Export a backup (Keychain Access → My
  Certificates → AiTerm Release → Export, `.p12`) and keep it somewhere safe: releases signed with
  another certificate cannot update installs signed with this one.
- **GitHub CLI.** `brew install gh`, then `gh auth login`.
- **Python 3.11 or newer**, which `scripts/make-dmg.sh` uses for `dmgbuild` (installed into
  `build/.dmg-venv` on first use).

## Pipeline

1. Require a recent green `scripts/test.sh all` before merging; reuse the branch's proof when test
   inputs match (the [proof check](../testing.md)), otherwise run it. Check the release candidate
   with `scripts/test-app-bundle.sh build/AiTerm.app`.
2. From a clean, pushed `main`: `scripts/release.sh <version>`. It builds and signs the app,
   wraps it in `AiTerm-<version>.dmg`, pushes the tag `v<version>` and publishes the GitHub release.

Before it builds anything, it redraws the README's picture and, when `docs/desktop.png` changed,
commits and pushes it to `main`, so a release never ships a README showing an older sidebar. The
picture is drawn by a real window, so the main display must be Retina.

The release checks full-suite proof before external work and again after the picture commit.
The branch's pass covers a merge with the same contents and the README picture update, so neither
needs another full run. Proof expires after seven days; changed test inputs or a later failed full
run for equivalent inputs require a fresh pass.

The build number is one more than the number of `v*` tags, plus 19: the releases published before
AiTerm moved to GitHub, whose tags this repository does not have. It keeps increasing for every
install that came from them.

### When the run stops

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

## Operator format

The major release changes the shape of the Operator's saved records, `operatorSession` and each
task's `signalTask`; the new build does not read the old shapes. Every other
saved key loads unchanged. The app clears the old records itself on its first load (`StateStore`):
it keeps a dated copy, `state.json.before-reset-<date>`, then drops each `operatorSession` and task's
or archived task's `signalTask` that does not decode, moving a taken-over mark onto its task, saves
the result and shows a note once. `scripts/reset-operator-state.sh` does the same by hand, with
AiTerm quit, for switching between development builds whose records differ. Release notes ask for
Repair only for an agent whose driver gained or changed an entry; this release's drivers only lost
one, so no agent needs it.

Current Signal saved-format, brief and fourteen-tool fixtures have explicit provenance.

## Done

Shipped means `v<version>` is published (no longer a draft) on GitHub with its DMG attached.
