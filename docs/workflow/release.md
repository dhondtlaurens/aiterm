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

1. Complete `scripts/test.sh all` once before merging and `scripts/test-app-bundle.sh build/AiTerm.app`
   on the release candidate.
2. From a clean, pushed `main`: `scripts/release.sh <version>`. It builds and signs the app,
   wraps it in `AiTerm-<version>.dmg`, pushes the tag `v<version>` and publishes the GitHub release.

Before it builds anything, it redraws the README's picture and, when `docs/desktop.png` changed,
commits and pushes it to `main`, so a release never ships a README showing an older sidebar. The
picture is drawn by a real window, so the main display must be Retina.

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

Signals replace broadcasts without a migration. Before installing this build, end any running
broadcast in the installed build. Its tasks, branches and conversations stay; the next load treats
those tasks as ordinary tasks. `runs`, `foldedRuns` and task `operated` are retired keys: the new
encoder discards them, including inside archived tasks. Old broadcast history and boards do not
appear in the Archive. Release notes must state this prerequisite and the changed keys: New Signal
is ⌘S and Show Archive is ⌘A outside a text field.

Current Signal saved-format, brief and fourteen-tool fixtures have explicit provenance. Historical
broadcast input is retained only to prove retirement and for the frozen before/after model eval;
there is no legacy runtime. Workspace/credential recovery still protects the person's other data.

## Done

Shipped means `v<version>` is published (no longer a draft) on GitHub with its DMG attached.
