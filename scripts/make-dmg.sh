#!/bin/zsh
# scripts/make-dmg.sh <app> <dmg> — wraps a built AiTerm.app in a drag-to-Applications disk image
# and checks what it wrote. dmgbuild lays the window out without driving Finder, so it runs the
# same headless. Requires python3 >= 3.11.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}" DMG="${2:-}"
PY="${PYTHON:-python3}"
VENV="$ROOT/build/.dmg-venv"
DMGBUILD_VERSION="1.6.7"

die() { print -u2 "make-dmg: $*"; exit 1; }

[[ -n "$APP" && -n "$DMG" ]] || die "usage: scripts/make-dmg.sh <AiTerm.app> <output.dmg>"
APP="${APP:A}"  # absolute, no trailing slash (tab-completion adds one; dmgbuild needs the basename)
[[ -d "$APP" && "${APP:t}" == AiTerm.app ]] || die "expected a path to AiTerm.app, got $APP"
"$PY" -c 'import sys; assert sys.version_info >= (3, 11)' 2>/dev/null || die "python3 >= 3.11 required"

installed="$("$VENV/bin/python" -m pip show dmgbuild 2>/dev/null | sed -n 's/^Version: //p' || true)"
if [[ "$installed" != "$DMGBUILD_VERSION" ]]; then
    rm -rf "$VENV"
    "$PY" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi

mkdir -p "${DMG:h}"
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" AiTerm "$DMG" >/dev/null

hdiutil verify -quiet "$DMG" || die "the image does not verify"
MOUNT="$(mktemp -d)"
trap 'hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
codesign --verify --deep --strict "$MOUNT/AiTerm.app" || die "the app inside the image does not verify"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]] || die "the image has no link to /Applications"
want="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/AiTerm.app/Contents/Info.plist")"
[[ "$got" == "$want" ]] || die "the image holds AiTerm $got, not $want"
print "built $DMG"
