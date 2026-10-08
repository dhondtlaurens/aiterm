#!/bin/zsh
# scripts/release.sh <version> — builds AiTerm <version>, signs it with the "AiTerm Release"
# certificate, wraps it in a DMG and publishes the GitHub release that AiTerm › Check for Updates…
# reads. Run from a clean, pushed main.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
REPO="dhondtlaurens/aiterm"
IDENTITY="${SIGN_IDENTITY:-AiTerm Release}"
PY="${PYTHON:-python3}"
APP="$ROOT/build/AiTerm.app"
DMG="$ROOT/build/AiTerm-$VERSION.dmg"
# Releases published before the move to GitHub, whose tags this repository does not have. The build
# number counts on from them, so every install keeps seeing it increase.
PRIOR_RELEASES=19

die() { print -u2 "release: $*"; exit 1; }

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "usage: scripts/release.sh <major.minor.patch>"
cd "$ROOT"
[[ "$(git branch --show-current)" == main ]] || die "run from main"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
origin="$(git remote get-url origin)"
[[ "$origin" == (git@github.com:|https://github.com/|ssh://git@github.com/)"$REPO"(.git|) ]] || die "origin is $origin, not github.com/$REPO"
git fetch --quiet --tags origin main
[[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]] || die "main is not the same as origin/main"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "v$VERSION already exists"
latest="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [[ -n "$latest" ]]; then
    newest="$(printf '%s\n%s\n' "${latest#v}" "$VERSION" | sort -V | tail -1)"
    [[ "$newest" == "$VERSION" ]] || die "$VERSION is not newer than $latest"
fi
gh auth status --hostname github.com >/dev/null 2>&1 || die "gh is not logged in to github.com (gh auth login)"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || die "no \"$IDENTITY\" code-signing certificate in the keychain (see docs/releasing.md)"
"$PY" -c 'import sys; assert sys.version_info >= (3, 11)' 2>/dev/null || die "python3 >= 3.11 required"
# The README's picture is drawn from the sidebar's code: a visual change since it was last drawn
# shows as a different picture, and the release waits until the new one is committed.
"$ROOT/scripts/readme-picture.sh" --check || die "redraw the README picture first (scripts/readme-picture.sh)"

AITERM_RELEASE=1 SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/make-app.sh"
BUILD=$(( PRIOR_RELEASES + $(git tag -l 'v*' | wc -l) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --deep --sign "$IDENTITY" "$APP"
"$ROOT/scripts/test-app-bundle.sh" "$APP"
/usr/libexec/PlistBuddy -c 'Print :AiTermDevBuild' "$APP/Contents/Info.plist" >/dev/null 2>&1 && die "the bundle is marked as a dev build"
codesign -d -r- "$APP" 2>/dev/null | grep -q '^designated => .*certificate leaf' || die "the bundle is not certificate-signed"
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG"

git tag -a "v$VERSION" -m "AiTerm $VERSION"
git push --quiet origin "v$VERSION"
# A draft first, so the release goes public only with its image attached: updaters never see a
# draft, and a run that stops here is finished by hand (docs/releasing.md).
gh release create "v$VERSION" "$DMG" --repo "$REPO" --draft --verify-tag --title "AiTerm $VERSION" --notes "AiTerm $VERSION"
gh release edit "v$VERSION" --repo "$REPO" --draft=false >/dev/null
print "released AiTerm $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/v$VERSION"
