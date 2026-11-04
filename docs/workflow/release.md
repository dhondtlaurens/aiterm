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

## Broadcast format

The supported broadcast format is structured Agents/Task/Done. The automated frozen-save and
model-facing contract tests protect current restart behavior; historical broadcast formats are not
a release compatibility requirement. Personal workspace and credential recovery remain protected.

Before switching from a build with unstructured historical broadcasts, end and remove those
broadcasts from its Shelf using that installed build. Confirm its saved workspace and recovery copy
no longer contain unsupported runs before replacing it. The new decoder does not migrate or silently
set such entries aside: an unsupported run blocks loading the workspace, and an equally unsupported
backup cannot repair it. Do not edit or discard projects/tasks to work around this precondition.

## Done

Shipped means `v<version>` is published (no longer a draft) on GitHub with its DMG attached.
