#!/bin/zsh
# scripts/readme-picture.sh [--check] — draws the README's picture (ReadmeDesktop: the real sidebar
# over its own fixture, beside a drawn iTerm2 window) and writes it to docs/desktop.png.
# With --check it writes nothing to docs/: it draws into build/readme-picture and fails when the
# committed picture differs, which is how scripts/release.sh refuses a release whose README shows
# an older sidebar. The picture is drawn by a real window, so it needs a Retina main display.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PICTURE="$ROOT/docs/desktop.png"
OUT="$ROOT/build/readme-picture"
DRAWN="$OUT/readme-desktop.png"

die() { print -u2 "readme-picture: $*"; exit 1; }

check=false
case "${1:-}" in
    --check) check=true ;;
    "") ;;
    *) die "usage: scripts/readme-picture.sh [--check]" ;;
esac

rm -rf "$OUT"
AITERM_SNAPSHOT_HOSTED=1 AITERM_SNAPSHOT_ONLY=readme-desktop.png "$ROOT/scripts/snapshots.sh" "$OUT" >/dev/null
[[ -f "$DRAWN" ]] || die "the snapshot run drew no readme-desktop.png"
# A window draws at its display's scale: on a 1× main display the picture comes out half size.
[[ "$(sips -g dpiWidth "$DRAWN" | awk '/dpiWidth/ { print $2 }')" == 144.000 ]] \
    || die "drawn at 1×: make a Retina display the main display and run again"

if $check; then
    cmp -s "$DRAWN" "$PICTURE" || die "docs/desktop.png is out of date (the new one is $DRAWN): run scripts/readme-picture.sh, look at it, commit it and push"
    print "docs/desktop.png is up to date"
else
    cp "$DRAWN" "$PICTURE"
    print "drew docs/desktop.png"
fi
